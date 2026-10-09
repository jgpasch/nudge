import AppKit
import SwiftUI

@main
struct NudgeBarApp: App {
    @State private var monitor = SessionMonitor(notifier: Notifier())

    init() {
        // Menu bar only: no Dock icon, even when run outside the bundle (LSUIElement).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: monitor)
        } label: {
            MenuBarLabel(attentionCount: monitor.attention.count, anyWorking: !monitor.working.isEmpty)
        }
        .menuBarExtraStyle(.window)
    }
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
