import Foundation
import NudgeCore
import UserNotifications

/// Posts macOS notifications. Needs to run from the .app bundle: without a bundle
/// identifier, UNUserNotificationCenter crashes, so a bare `swift run` skips them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notificationsEnabled"
    /// Bundled into Contents/Resources by scripts/build-app.sh.
    private static let permissionSound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))

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

    func post(for session: Session, title: String? = nil) {
        guard let center, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let content = UNMutableNotificationContent()
        // Lead with the task, which is what tells sessions apart at a glance.
        content.title = title ?? session.project
        content.subtitle = title == nil ? "" : session.project
        content.body = body(for: session)
        // A permission prompt blocks Claude, so it gets a sound that stands out.
        content.sound = session.state == .needsPermission ? Self.permissionSound : .default
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
        case .needsPermission: "Needs your permission"
        case .readyForReview: "Ready for review"
        case .failed: "Stopped on an error"
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
