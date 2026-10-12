import AppKit
import NudgeCore
import SwiftUI

/// A plain window rather than a SwiftUI `Settings` scene: Nudge has no Dock icon, and
/// `SettingsLink` opens behind other apps when the app isn't active.
@MainActor
final class SettingsWindowController {
    private let monitor: SessionMonitor
    private var window: NSWindow?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(monitor: monitor)))
        window.title = "Nudge Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 420))
        return window
    }
}

/// Which banners each project gets: one row per project, one checkbox per kind.
struct SettingsView: View {
    let monitor: SessionMonitor
    /// The master switch, also in the menu.
    @AppStorage(Notifier.enabledKey) private var notificationsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose which notifications each project sends. Projects you haven't changed follow the defaults.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Project")
                        ForEach(NotificationKind.allCases, id: \.self) { kind in
                            Text(kind.label).gridColumnAlignment(.center)
                        }
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    GridRow {
                        Text("Defaults").fontWeight(.medium)
                        ForEach(NotificationKind.allCases, id: \.self) { kind in
                            Toggle(kind.label, isOn: Binding(
                                get: { monitor.prefs.defaults.contains(kind) },
                                set: { monitor.prefs.setDefault(kind, $0) }
                            ))
                            .labelsHidden()
                        }
                    }
                    Divider()

                    if monitor.knownProjects.isEmpty {
                        Text("Projects appear here once they've run a Claude session.")
                            .foregroundStyle(.secondary)
                            .gridCellColumns(NotificationKind.allCases.count + 2)
                    }
                    ForEach(monitor.knownProjects, id: \.self) { dir in
                        projectRow(dir)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.trailing, 8)
            }

            Toggle("Send notifications", isOn: $notificationsEnabled)
                .toggleStyle(.checkbox)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 300)
    }

    private func projectRow(_ dir: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: dir).lastPathComponent).lineLimit(1)
                Text(abbreviated(dir))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(dir)
            ForEach(NotificationKind.allCases, id: \.self) { kind in
                Toggle(kind.label, isOn: Binding(
                    get: { monitor.prefs.kinds(for: dir).contains(kind) },
                    set: { monitor.prefs.set(kind, $0, for: dir) }
                ))
                .labelsHidden()
            }
            if monitor.prefs.isCustomized(dir) {
                Button("Reset") { monitor.prefs.reset(dir) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Follow the defaults again")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
