import Foundation

/// When a session that needs attention is worth interrupting the user for.
public enum AttentionPolicy {
    /// A permission prompt the user is already looking at usually gets answered within seconds.
    public static let permissionGrace: TimeInterval = 5
    /// A quick turn was probably watched; only long ones are worth a ping.
    public static let minTurnForReview: TimeInterval = 30

    public enum Decision: Equatable, Sendable {
        case notify
        case wait   // ask again later
        case skip   // never notify for this episode
    }

    public static func decide(_ s: Session, now: Date) -> Decision {
        guard s.needsAttention else { return .skip }
        switch s.state {
        case .needsPermission:
            return now.timeIntervalSince(s.since) >= permissionGrace ? .notify : .wait
        case .readyForReview:
            let turn = s.turnStartedAt.map { s.since.timeIntervalSince($0) } ?? 0
            return turn >= minTurnForReview ? .notify : .skip
        default:
            return .notify
        }
    }

    /// Identifies one stretch of a session in one state. A new state, or re-entering
    /// the same state later, is a new episode.
    public static func episodeKey(_ s: Session) -> String {
        "\(s.id)|\(s.state.rawValue)|\(s.since.timeIntervalSince1970)"
    }
}
