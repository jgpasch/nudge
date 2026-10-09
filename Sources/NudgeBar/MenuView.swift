import NudgeCore
import SwiftUI

struct MenuView: View {
    let monitor: SessionMonitor
    @AppStorage(Notifier.enabledKey) private var notificationsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if monitor.sessions.isEmpty {
                Text("No Claude sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            section("Needs attention", monitor.attention)
            section("Working", monitor.working)
            section("Idle", monitor.idle)
            section("Headless (claude -p)", monitor.headless)

            Divider()
            HStack {
                Toggle("Notifications", isOn: $notificationsEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(sessions, id: \.id) { SessionRow(session: $0, now: monitor.now) }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
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
        .help(session.projectDir ?? session.cwd ?? session.id)
    }

    private var detail: String {
        if session.state == .needsPermission, let tool = session.permissionTool {
            return "\(session.state.label): \(tool)"
        }
        return session.state.label
    }

    private var color: Color {
        switch session.state {
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
