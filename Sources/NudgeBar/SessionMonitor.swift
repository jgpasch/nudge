import Foundation
import NudgeCore
import Observation

/// Follows the event log and keeps the menu's session list current. Decides when a
/// session's change is worth a notification, and tracks which ones the user has seen.
@MainActor
@Observable
final class SessionMonitor {
    private(set) var sessions: [Session] = []
    /// Ticks every refresh so relative ages in the menu stay current.
    private(set) var now = Date()
    /// Attention episodes the user marked as seen. Persisted so a restart doesn't
    /// bring back everything they already dismissed.
    /// iTerm2 tab titles by session UUID, and transcript topics by session id. The tab
    /// titles take ~170ms of AppleScript, so both refresh when the menu or switcher opens
    /// or a banner is posted, not every tick.
    private(set) var tabTitles: [String: String] = [:]
    private(set) var transcriptTitles: [String: String] = [:]
    /// Set when focusing a tab fails, e.g. Automation permission for iTerm2 was denied.
    private(set) var focusError: String?
    /// Set when the switcher's shortcut couldn't be registered.
    var hotKeyError: String?
    private(set) var seen: Set<String> {
        didSet { UserDefaults.standard.set(Array(seen), forKey: Self.seenKey) }
    }
    /// Which kinds of banner each project gets, edited in the Settings window.
    var prefs: NotificationPrefs {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(prefs), forKey: Self.prefsKey) }
    }
    /// Every project directory with an interactive session in the log, most recently
    /// active first, plus any with saved settings. Listed in the Settings window.
    private(set) var knownProjects: [String] = []

    var attention: [Session] { sessions.filter { $0.needsAttention && !isSeen($0) } }
    var working: [Session] { interactive.filter { $0.state == .working } }
    /// Idle sessions, plus attention ones the user already saw.
    var idle: [Session] { interactive.filter { $0.state == .idle || ($0.needsAttention && isSeen($0)) } }
    var headless: [Session] { sessions.filter(\.headless) }

    private var interactive: [Session] { sessions.filter { !$0.headless } }

    @ObservationIgnored private let tailer = LogTailer()
    @ObservationIgnored private var store = SessionStore()
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var timer: Timer?
    /// Episodes already notified or deliberately skipped.
    @ObservationIgnored private var handled: Set<String> = []
    /// Session id → episode whose banner may still be in Notification Center.
    @ObservationIgnored private var banners: [String: String] = [:]
    /// When the user last jumped to each session, for the switcher's ordering.
    @ObservationIgnored private var lastFocused: [String: Date] = [:]

    private static let seenKey = "seenEpisodes"
    private static let prefsKey = "notificationPrefs"

    init(notifier: Notifier) {
        self.notifier = notifier
        seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        prefs = UserDefaults.standard.data(forKey: Self.prefsKey)
            .flatMap { try? JSONDecoder().decode(NotificationPrefs.self, from: $0) } ?? NotificationPrefs()
        refresh()
        // Anything already waiting when the app starts doesn't get a notification.
        handled = Set(sessions.filter(\.needsAttention).map(AttentionPolicy.episodeKey))
        notifier.onOpen = { [weak self] id in
            guard let self, let session = sessions.first(where: { $0.id == id }) else {
                NSLog("nudge: banner clicked for unknown session \(id)")
                return
            }
            focus(session)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The conversation topic from the transcript, else the iTerm2 tab title. Tells apart
    /// several sessions in the same repo.
    func title(for s: Session) -> String? {
        transcriptTitles[s.id] ?? s.itermSessionID.flatMap(TerminalFocus.itermUUID).flatMap { tabTitles[$0] }
    }

    func refreshTitles() {
        tabTitles = TerminalFocus.itermTitles()
        var titles: [String: String] = [:]
        for s in sessions {
            if let path = s.transcriptPath, let title = Transcript.title(path: path) { titles[s.id] = title }
        }
        transcriptTitles = titles
    }

    func switcherResults(query: String) -> [Session] {
        SessionSearch.rank(sessions, query: query, title: title(for:), isSeen: isSeen, lastFocused: lastFocused)
    }

    /// Brings the session's terminal tab forward. Looking at it counts as seeing it.
    func focus(_ s: Session) {
        lastFocused[s.id] = Date()
        switch TerminalFocus.focus(s) {
        case .failed(let message):
            focusError = message
            NSLog("nudge: focus failed for \(s.id): \(message)")
        case let result:
            if result != .focused { NSLog("nudge: focus \(s.id): \(result)") }
            focusError = nil
        }
        markSeen(s)
    }

    func isSeen(_ s: Session) -> Bool { seen.contains(AttentionPolicy.episodeKey(s)) }

    func markSeen(_ s: Session) {
        guard s.needsAttention else { return }
        seen.insert(AttentionPolicy.episodeKey(s))
        clearStaleBanners()
    }

    func markAllSeen() {
        seen.formUnion(attention.map(AttentionPolicy.episodeKey))
        clearStaleBanners()
    }

    private func tick() {
        refresh()
        notifyIfNeeded()
        clearStaleBanners()
    }

    private func refresh() {
        let (entries, reset) = tailer.read()
        if reset { store = SessionStore() }
        for entry in entries { store.apply(entry) }
        now = Date()
        sessions = store.resolved().filter { $0.state != .ended && $0.state != .gone }
        // Drop seen markers for episodes that are over; they can never match again.
        let current = Set(sessions.map(AttentionPolicy.episodeKey))
        if !seen.isSubset(of: current) { seen.formIntersection(current) }
        if !entries.isEmpty || reset { updateKnownProjects() }
    }

    private func updateKnownProjects() {
        let logged = store.sessions.values.filter { !$0.headless }
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .compactMap { $0.projectDir ?? $0.cwd }
        var projects: [String] = []
        for dir in logged where !projects.contains(dir) { projects.append(dir) }
        projects += prefs.projects.keys.filter { !projects.contains($0) }.sorted()
        if projects != knownProjects { knownProjects = projects }
    }

    private func notifyIfNeeded() {
        for s in sessions where s.needsAttention && !isSeen(s) {
            let key = AttentionPolicy.episodeKey(s)
            guard !handled.contains(key) else { continue }
            switch AttentionPolicy.decide(s, now: now) {
            case .wait:
                continue
            case .skip:
                handled.insert(key)
            case .notify:
                handled.insert(key)
                guard prefs.allows(s) else { continue }
                refreshTitles()
                notifier.post(for: s, title: title(for: s))
                banners[s.id] = key
            }
        }
    }

    /// Removes banners for sessions that moved on or were marked seen, so Notification
    /// Center doesn't fill up with things already dealt with in the terminal.
    private func clearStaleBanners() {
        let current = Dictionary(sessions.map { ($0.id, AttentionPolicy.episodeKey($0)) }, uniquingKeysWith: { a, _ in a })
        for (id, key) in banners where current[id] != key || seen.contains(key) {
            notifier.remove(sessionID: id)
            banners[id] = nil
        }
    }
}
