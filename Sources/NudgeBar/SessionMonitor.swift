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
    /// iTerm2 tab titles by session UUID. Fetching takes ~170ms of AppleScript, so it
    /// happens when the menu opens or a banner is posted, not every tick.
    private(set) var titles: [String: String] = [:]
    /// Set when focusing a tab fails, e.g. Automation permission for iTerm2 was denied.
    private(set) var focusError: String?
    private(set) var seen: Set<String> {
        didSet { UserDefaults.standard.set(Array(seen), forKey: Self.seenKey) }
    }

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

    private static let seenKey = "seenEpisodes"

    init(notifier: Notifier) {
        self.notifier = notifier
        seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
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

    func title(for s: Session) -> String? {
        s.itermSessionID.flatMap(TerminalFocus.itermUUID).flatMap { titles[$0] }
    }

    func refreshTitles() {
        titles = TerminalFocus.itermTitles()
    }

    /// Brings the session's terminal tab forward. Looking at it counts as seeing it.
    func focus(_ s: Session) {
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
