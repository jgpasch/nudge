import ServiceManagement

/// Launch at login, via the app's own login item. Only works from the .app bundle.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("nudge: login item change failed: \(error)")
        }
    }
}
