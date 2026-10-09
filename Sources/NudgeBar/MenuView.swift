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
                Text(title ?? session.project)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(title == nil ? detail : "\(session.project) · \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private var detail: String {
        var text = session.state.label
        if session.state == .needsPermission, let tool = session.permissionTool { text += ": \(tool)" }
        return seen ? "Seen · \(text)" : text
    }

    private var color: Color {
        if seen { return .gray }
        return switch session.state {
        case .needsPermission: .orange
        case .readyForReview: .green
        case .failed: .red
        case .working: .blue
        default: .gray
        }
    }

    private var age: String {
        let s = max(0, Int(now.timeIntervalSince(session.since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
