import Foundation

/// The kinds of banner a session can raise, one per attention state.
public enum NotificationKind: String, CaseIterable, Codable, Sendable {
    case permission
    case review
    case error

    public init?(_ state: SessionState) {
        switch state {
        case .needsPermission: self = .permission
        case .readyForReview: self = .review
        case .failed: self = .error
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .permission: "Permission"
        case .review: "Ready for review"
        case .error: "Error"
        }
    }
}

/// Which kinds of banner each project gets. A project without its own choice uses the
/// defaults, so changing the defaults also changes every project not yet customized.
/// Projects are keyed by their directory, so two repos with the same name stay apart.
public struct NotificationPrefs: Codable, Equatable, Sendable {
    public var defaults: Set<NotificationKind> = Set(NotificationKind.allCases)
    public var projects: [String: Set<NotificationKind>] = [:]

    public init() {}

    public func kinds(for projectDir: String?) -> Set<NotificationKind> {
        projectDir.flatMap { projects[$0] } ?? defaults
    }

    public func allows(_ s: Session) -> Bool {
        guard let kind = NotificationKind(s.state) else { return false }
        return kinds(for: s.projectDir ?? s.cwd).contains(kind)
    }

    public func isCustomized(_ projectDir: String) -> Bool { projects[projectDir] != nil }

    public mutating func set(_ kind: NotificationKind, _ on: Bool, for projectDir: String) {
        var kinds = kinds(for: projectDir)
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        // Matching the defaults again means it follows them from now on.
        projects[projectDir] = kinds == defaults ? nil : kinds
    }

    public mutating func setDefault(_ kind: NotificationKind, _ on: Bool) {
        if on { defaults.insert(kind) } else { defaults.remove(kind) }
    }

    public mutating func reset(_ projectDir: String) { projects[projectDir] = nil }
}
