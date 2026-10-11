import NudgeCore
import SwiftUI

struct MenuView: View {
    let monitor: SessionMonitor
    @AppStorage(Notifier.enabledKey) private var notificationsEnabled = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if monitor.sessions.isEmpty {
                Text("No Claude sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            section("Needs attention", monitor.attention) {
                Button("Mark all seen") { monitor.markAllSeen() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            section("Working", monitor.working)
            section("Idle", monitor.idle)
            section("Headless (claude -p)", monitor.headless)

            if let error = monitor.focusError {
                Label("Couldn't switch to the tab: \(error). Check System Settings › Privacy & Security › Automation.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = monitor.hotKeyError {
                Label("Switcher shortcut unavailable: \(error).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("⌘⇧J to find a session from anywhere")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Toggle("Notifications", isOn: $notificationsEnabled)
                    .toggleStyle(.checkbox)
                if LoginItem.isAvailable {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
        // Titles cost an AppleScript round trip; fetch after the menu has drawn.
        .task { monitor.refreshTitles() }
    }

    @ViewBuilder
    private func section(
        _ title: String, _ sessions: [Session], @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    accessory()
                }
                ForEach(sessions, id: \.id) { session in
                    SessionRow(
                        session: session, title: monitor.title(for: session),
                        now: monitor.now, seen: monitor.isSeen(session)
                    ) {
                        monitor.focus(session)
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let title: String?
    let now: Date
    let seen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                SessionSubtitle(topic: title, status: detail)
            }
            Spacer()
            Text(age)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(session.projectDir ?? session.cwd ?? session.id)
    }

    private var detail: String { session.statusText(seen: seen) }
    private var color: Color { session.statusColor(seen: seen) }
    private var age: String { Session.age(from: session.since, to: now) }
}

/// "Topic · Status" under the repo name. A long topic truncates; the status stays whole.
struct SessionSubtitle: View {
    let topic: String?
    let status: String

    var body: some View {
        // The topic is context, not something to read first: smaller and fainter than
        // the status, which stays at secondary so it's still easy to scan.
        HStack(spacing: 0) {
            if let topic {
                Text(topic).lineLimit(1).foregroundStyle(.tertiary)
                Text(" · ").foregroundStyle(.tertiary)
            }
            Text(status).lineLimit(1).fixedSize().foregroundStyle(.secondary)
        }
        .font(.caption2)
    }
}

/// Shared by the menu rows and the switcher.
extension Session {
    func statusText(seen: Bool) -> String {
        var text = state.label
        if state == .needsPermission, let tool = permissionTool { text += ": \(tool)" }
        return seen ? "Seen · \(text)" : text
    }

    func statusColor(seen: Bool) -> Color {
        if seen { return .gray }
        return switch state {
        case .needsPermission: .orange
        case .readyForReview: .green
        case .failed: .red
        case .working: .blue
        default: .gray
        }
    }

    static func age(from date: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
