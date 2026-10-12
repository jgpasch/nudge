import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct NudgeBarApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: app.monitor, openSettings: app.showSettings)
        } label: {
            MenuBarLabel(attentionCount: app.monitor.attention.count, anyWorking: !app.monitor.working.isEmpty)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the session monitor, which the menu, notifications and switcher all read.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SessionMonitor(notifier: Notifier())
    private var switcher: SwitcherController?
    private var hotKey: HotKey?
    private lazy var settings = SettingsWindowController(monitor: monitor)

    override init() {
        super.init()
        // Menu bar only: no Dock icon, even when run outside the bundle (LSUIElement).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let switcher = SwitcherController(monitor: monitor)
        self.switcher = switcher
        hotKey = HotKey(keyCode: kVK_ANSI_J, modifiers: cmdKey | shiftKey) { switcher.toggle() }
        if hotKey == nil { monitor.hotKeyError = "⌘⇧J is taken by another app" }
    }

    func showSettings() { settings.show() }
}

struct MenuBarLabel: View {
    let attentionCount: Int
    let anyWorking: Bool

    var body: some View {
        if attentionCount > 0 {
            Image(systemName: "bell.badge.fill")
            Text("\(attentionCount)")
        } else {
            Image(systemName: anyWorking ? "bell.and.waves.left.and.right" : "bell")
        }
    }
}
