import Foundation

/// Append-only JSONL log of raw hook events. Hooks write to it; the app and
/// `nudge status` rebuild session state by replaying it.
public enum EventLog {
    /// `$NUDGE_HOME` overrides the default `~/.nudge` (useful for tests).
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["NUDGE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nudge", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("events.jsonl") }

    /// Env vars worth capturing for terminal identity.
    static let capturedEnv = [
        "ITERM_SESSION_ID", "TERM_PROGRAM", "TERM_SESSION_ID", "TMUX", "TMUX_PANE",
        "CLAUDE_PID", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_ENTRYPOINT",
    ]

    /// Payload fields we keep. Everything else (prompts, tool input/output, assistant
    /// messages) is dropped so the log never holds conversation content.
    static let keptPayloadKeys: Set<String> = [
        "session_id", "hook_event_name", "cwd", "transcript_path", "notification_type", "message",
        "source", "reason", "tool_name", "tool_use_id", "permission_mode", "prompt_id", "agent_id", "agent_type",
    ]

    /// Wraps a raw hook payload with timestamp, terminal env, and process ancestry,
    /// and appends it as one line.
    public static func append(rawPayload: Data) throws {
        let env = ProcessInfo.processInfo.environment
        let procs = ProcessTree.ancestors(of: getpid(), limit: 6)
        var entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "env": env.filter { capturedEnv.contains($0.key) },
            "procs": procs.map { ["pid": Int($0.pid), "comm": $0.comm] },
        ]
        let agentPID = env["CLAUDE_PID"].flatMap(Int32.init) ?? procs.first { !ProcessTree.shells.contains($0.comm) }?.pid
        if let agentPID, let args = ProcessTree.arguments(of: agentPID) {
            entry["headless"] = args.contains("-p") || args.contains("--print")
        }
        if let payload = try? JSONSerialization.jsonObject(with: rawPayload) as? [String: Any] {
            entry["payload"] = payload.filter { keptPayloadKeys.contains($0.key) }
        } else {
            entry["payload_raw"] = String(decoding: rawPayload, as: UTF8.self)
        }

        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // O_APPEND keeps concurrent single-line writes from different hooks from interleaving.
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads and decodes every entry, skipping lines that don't parse.
    public static func readAll() throws -> [LogEntry] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
    }
}

public struct LogEntry: Decodable, Sendable {
    public let ts: Double
    public let env: [String: String]
    public let procs: [ProcessTree.Proc]
    public let headless: Bool?
    public let payload: HookPayload

    public var date: Date { Date(timeIntervalSince1970: ts) }
}

/// The subset of Claude Code's hook stdin we care about. Unknown fields are ignored.
public struct HookPayload: Decodable, Sendable {
    public let session_id: String
    public let hook_event_name: String
    public let cwd: String?
    public let transcript_path: String?
    public let notification_type: String?
    public let message: String?
    public let source: String?
    public let reason: String?
    public let tool_name: String?
}

/// Follows the event log, returning only entries appended since the last read.
public final class LogTailer {
    public let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(url: URL = EventLog.fileURL) { self.url = url }

    /// New complete entries since the last call. `reset` is true when the file shrank
    /// or was replaced, meaning the caller should drop state built from earlier reads.
    public func read() -> (entries: [LogEntry], reset: Bool) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return ([], false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var reset = false
        if size < offset {
            offset = 0
            partial = Data()
            reset = true
        }
        guard size > offset else { return ([], reset) }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)

        // Keep a trailing line without its newline for the next read.
        var buffer = partial + data
        if let lastNewline = buffer.lastIndex(of: 0x0A) {
            partial = buffer[buffer.index(after: lastNewline)...]
            buffer = buffer[..<lastNewline]
        } else {
            partial = buffer
            return ([], reset)
        }
        let decoder = JSONDecoder()
        let entries = buffer.split(separator: 0x0A).compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
        return (entries, reset)
    }
}
