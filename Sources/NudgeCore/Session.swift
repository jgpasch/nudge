import Foundation

public enum SessionState: String, Sendable {
    case idle               // started, no prompt yet
    case working
    case needsPermission    // attention: blocked on a permission prompt
    case readyForReview     // attention: Claude stopped responding; not proof of success
    case failed             // attention: turn ended on an error (StopFailure)
    case ended
    case gone               // never saw SessionEnd, but the agent process is dead

    public var needsAttention: Bool { self == .needsPermission || self == .readyForReview || self == .failed }
}

public struct Session: Sendable {
    public let id: String
    public var cwd: String?
    public var state: SessionState = .idle
    public var since: Date
    public var lastEvent: String
    public var lastMessage: String?
    public var transcriptPath: String?
    public var agentPID: Int32?
    public var itermSessionID: String?
    public var termProgram: String?
    /// Started with `claude -p`: a scripted job, not something waiting on a human.
    public var headless = false

    /// Directory the session belongs to. Payload `cwd` follows `cd` inside Bash,
    /// so this prefers CLAUDE_PROJECT_DIR and otherwise the first cwd seen.
    public var projectDir: String?

    public var project: String {
        (projectDir ?? cwd).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
    }

    public var needsAttention: Bool { state.needsAttention && !headless }
}

public enum SessionReducer {
    /// Replays log entries in order into per-session state.
    public static func reduce(_ entries: [LogEntry], checkLiveness: Bool = true) -> [Session] {
        var sessions: [String: Session] = [:]

        for entry in entries.sorted(by: { $0.ts < $1.ts }) {
            let p = entry.payload
            var s = sessions[p.session_id] ?? Session(id: p.session_id, since: entry.date, lastEvent: p.hook_event_name)
            s.cwd = p.cwd ?? s.cwd
            s.projectDir = entry.env["CLAUDE_PROJECT_DIR"] ?? s.projectDir ?? p.cwd
            s.headless = entry.headless ?? s.headless
            s.lastEvent = p.hook_event_name
            s.transcriptPath = p.transcript_path ?? s.transcriptPath
            s.itermSessionID = entry.env["ITERM_SESSION_ID"] ?? s.itermSessionID
            s.termProgram = entry.env["TERM_PROGRAM"] ?? s.termProgram
            // Hooks run via a shell; the first non-shell ancestor should be the agent.
            if let pid = entry.env["CLAUDE_PID"].flatMap(Int32.init) {
                s.agentPID = pid
            } else if let agent = entry.procs.first(where: { !ProcessTree.shells.contains($0.comm) }) {
                s.agentPID = agent.pid
            }

            if let next = transition(from: s.state, on: p) {
                if next != s.state { s.since = entry.date }
                s.state = next
                if let message = p.message { s.lastMessage = message }
            }
            sessions[p.session_id] = s
        }

        if checkLiveness {
            for (id, s) in sessions where s.state != .ended && s.state != .gone {
                if let pid = s.agentPID, !ProcessTree.isAlive(pid) {
                    sessions[id]?.state = .gone
                }
            }
        }
        // Esc interrupts and Esc-denied permission prompts fire no hook at all; the only
        // trace is a marker in the transcript. The user was at the keyboard, so it's idle.
        for (id, s) in sessions where s.state == .working || s.state == .needsPermission {
            if let path = s.transcriptPath, Transcript.lastTurnWasInterrupted(path: path) {
                sessions[id]?.state = .idle
            }
        }
        return sessions.values.sorted { $0.since > $1.since }
    }

    /// nil means the event doesn't change state.
    static func transition(from state: SessionState, on p: HookPayload) -> SessionState? {
        switch p.hook_event_name {
        case "SessionStart":
            return state == .ended || state == .gone ? .idle : nil
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            return .working
        case "PermissionRequest":
            return .needsPermission
        case "Notification":
            switch p.notification_type {
            case "permission_prompt": return .needsPermission
            case "idle_prompt": return state == .needsPermission ? nil : .readyForReview
            default: return nil
            }
        case "Stop":
            return .readyForReview
        case "StopFailure":
            return .failed
        case "SessionEnd":
            return .ended
        default:
            return nil  // SubagentStop etc. are logged but ignored
        }
    }
}
