import Foundation
import NudgeCore
import Observation

/// Follows the event log and keeps the menu's session list current. Decides when a
/// session's change is worth a notification.
@MainActor
@Observable
final class SessionMonitor {
    private(set) var sessions: [Session] = []
    /// Ticks every refresh so relative ages in the menu stay current.
    private(set) var now = Date()

    var attention: [Session] { sessions.filter(\.needsAttention) }
    var working: [Session] { live.filter { $0.state == .working } }
    var idle: [Session] { live.filter { $0.state == .idle } }
    var headless: [Session] { sessions.filter { $0.headless && isLive($0) } }

    private var live: [Session] { sessions.filter { !$0.headless && isLive($0) } }

    @ObservationIgnored private let tailer = LogTailer()
    @ObservationIgnored private var store = SessionStore()
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var timer: Timer?
    /// Attention episodes (session + state + start) already notified or deliberately skipped.
    @ObservationIgnored private var handled: Set<String> = []

    init(notifier: Notifier) {
        self.notifier = notifier
        refresh()
        // Anything already waiting when the app starts doesn't get a notification.
        handled = Set(sessions.filter(\.needsAttention).map(episodeKey))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        refresh()
        notifyIfNeeded()
    }

    private func refresh() {
        let (entries, reset) = tailer.read()
        if reset { store = SessionStore() }
        for entry in entries { store.apply(entry) }
        now = Date()
        // Ended sessions linger for an hour so a just-closed tab doesn't vanish mid-glance.
        sessions = store.resolved().filter { isLive($0) || now.timeIntervalSince($0.since) < 3600 }
    }

    private func notifyIfNeeded() {
        for s in sessions where s.needsAttention {
            let key = episodeKey(s)
            guard !handled.contains(key) else { continue }
            let waited = now.timeIntervalSince(s.since)
            switch s.state {
            case .needsPermission:
                // Give the user a moment to answer a prompt they're already looking at.
                guard waited >= Policy.permissionGrace else { continue }
            case .readyForReview:
                // A quick turn was probably watched; only long ones are worth a ping.
                let turn = s.turnStartedAt.map { s.since.timeIntervalSince($0) } ?? 0
                if turn < Policy.minTurnForReview {
                    handled.insert(key)
                    continue
                }
            default:
                break
            }
            handled.insert(key)
            notifier.post(for: s)
        }
    }

    private func episodeKey(_ s: Session) -> String {
        "\(s.id)|\(s.state.rawValue)|\(s.since.timeIntervalSince1970)"
    }

    private func isLive(_ s: Session) -> Bool { s.state != .ended && s.state != .gone }

    enum Policy {
        static let permissionGrace: TimeInterval = 5
        static let minTurnForReview: TimeInterval = 30
    }
}
