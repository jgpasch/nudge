import Foundation
import NudgeCore

let usage = """
    usage: nudge <command>

      hook              Read a Claude Code hook payload on stdin and log it (used by hooks).
      status [--all]    Show sessions. --all includes ended sessions.
      path              Print the event log path.
    """

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "hook":
    // Must stay silent and always exit 0: stdout from some hooks is injected into
    // Claude's context, and a failing hook should never disrupt a session.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    try? EventLog.append(rawPayload: input)
    exit(0)

case "status":
    let showAll = args.contains("--all")
    let sessions = SessionReducer.reduce((try? EventLog.readAll()) ?? [])
        .filter { showAll || ($0.state != .ended && $0.state != .gone) }
    printStatus(sessions)

case "path":
    print(EventLog.fileURL.path)

default:
    print(usage)
    exit(args.isEmpty ? 0 : 1)
}

func printStatus(_ sessions: [Session]) {
    let attention = sessions.filter(\.needsAttention)
    let live = sessions.filter { !$0.headless && $0.state != .ended && $0.state != .gone }
    let groups: [(String, [Session])] = [
        ("NEEDS ATTENTION (\(attention.count))", attention),
        ("WORKING", live.filter { $0.state == .working }),
        ("IDLE", live.filter { $0.state == .idle }),
        ("HEADLESS (claude -p)", sessions.filter { $0.headless && $0.state != .ended && $0.state != .gone }),
        ("ENDED", sessions.filter { $0.state == .ended || $0.state == .gone }),
    ]
    if sessions.isEmpty { print("No sessions. Log: \(EventLog.fileURL.path)") }
    for (title, rows) in groups where !rows.isEmpty {
        print(title)
        for s in rows {
            let cols = [
                pad(s.project, 18),
                pad(s.state.label, 22),
                pad(age(s.since), 5),
                pad(String(s.id.prefix(8)), 9),
                pad(s.agentPID.map { "pid \($0)" } ?? "", 10),
                s.itermSessionID ?? s.termProgram ?? "",
            ]
            print("  " + cols.joined(separator: " "))
        }
        print()
    }
}

func age(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
}
