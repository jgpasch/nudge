import Foundation
import NudgeCore
import UserNotifications

/// Posts macOS notifications. Needs to run from the .app bundle: without a bundle
/// identifier, UNUserNotificationCenter crashes, so a bare `swift run` skips them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notificationsEnabled"

    private let center: UNUserNotificationCenter?
    /// Called with the session id when the user clicks a banner.
    var onOpen: ((String) -> Void)?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var isAvailable: Bool { center != nil }

    func post(for session: Session, tabTitle: String? = nil) {
        guard let center, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = session.project
        content.subtitle = tabTitle ?? ""
        content.body = body(for: session)
        content.sound = .default
        content.threadIdentifier = session.id
        content.userInfo = ["sessionID": session.id]
        // One notification per session: a newer state replaces the older banner.
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    func remove(sessionID: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [sessionID])
    }

    private func body(for session: Session) -> String {
        switch session.state {
        case .needsPermission: session.permissionTool.map { "Claude wants to use \($0)" } ?? "Claude needs your permission"
        case .readyForReview: "Claude finished and is waiting for you"
        case .failed: "Claude stopped on an error"
        default: session.state.label
        }
    }

    // Show banners even if the app happens to be frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["sessionID"] as? String
        else { return }
        await MainActor.run { onOpen?(id) }
    }
}
