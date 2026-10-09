import Foundation
import Testing
@testable import NudgeCore

private func line(_ event: String, session: String = "s1", ts: Double, extra: String = "") -> String {
    #"{"ts":\#(ts),"env":{},"procs":[],"payload":{"session_id":"\#(session)","hook_event_name":"\#(event)"\#(extra)}}"# + "\n"
}

private func tempLog() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nudge-\(UUID().uuidString).jsonl")
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@Test func tailerReturnsOnlyNewCompleteLines() throws {
    let url = tempLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let tailer = LogTailer(url: url)
    #expect(tailer.read().entries.isEmpty)

    let second = line("Stop", ts: 2)
    try append(line("UserPromptSubmit", ts: 1) + second.prefix(20), to: url)
    #expect(tailer.read().entries.map(\.payload.hook_event_name) == ["UserPromptSubmit"])

    try append(String(second.dropFirst(20)), to: url)
    #expect(tailer.read().entries.map(\.payload.hook_event_name) == ["Stop"])
    #expect(tailer.read().entries.isEmpty)
}

@Test func tailerResetsWhenLogShrinks() throws {
    let url = tempLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let tailer = LogTailer(url: url)
    try append(line("UserPromptSubmit", ts: 1) + line("Stop", ts: 2), to: url)
    _ = tailer.read()

    try Data(line("SessionStart", ts: 3).utf8).write(to: url)
    let result = tailer.read()
    #expect(result.reset)
    #expect(result.entries.map(\.payload.hook_event_name) == ["SessionStart"])
}

@Test func storeTracksTurnStartAndPermissionTool() throws {
    let decoder = JSONDecoder()
    var store = SessionStore()
    for text in [
        line("UserPromptSubmit", ts: 100),
        line("PermissionRequest", ts: 110, extra: #","tool_name":"Bash""#),
        line("PostToolUse", ts: 115),
        line("Stop", ts: 160),
    ] {
        store.apply(try decoder.decode(LogEntry.self, from: Data(text.utf8)))
    }
    let s = try #require(store.sessions["s1"])
    #expect(s.state == .readyForReview)
    #expect(s.permissionTool == "Bash")
    #expect(s.since.timeIntervalSince(try #require(s.turnStartedAt)) == 60)
}
