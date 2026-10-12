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

private func session(_ state: SessionState, since: Double, turnStart: Double? = nil, headless: Bool = false) -> Session {
    var s = Session(id: "s1", since: Date(timeIntervalSince1970: since), lastEvent: "", lastEventAt: Date(timeIntervalSince1970: since))
    s.state = state
    s.turnStartedAt = turnStart.map(Date.init(timeIntervalSince1970:))
    s.headless = headless
    return s
}

@Test func permissionWaitsForGracePeriod() {
    let s = session(.needsPermission, since: 100)
    #expect(AttentionPolicy.decide(s, now: Date(timeIntervalSince1970: 103)) == .wait)
    #expect(AttentionPolicy.decide(s, now: Date(timeIntervalSince1970: 105)) == .notify)
}

@Test func reviewNotifiesOnlyAfterLongTurns() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(AttentionPolicy.decide(session(.readyForReview, since: 200, turnStart: 190), now: now) == .skip)
    #expect(AttentionPolicy.decide(session(.readyForReview, since: 200, turnStart: 100), now: now) == .notify)
    #expect(AttentionPolicy.decide(session(.readyForReview, since: 200), now: now) == .skip)
}

@Test func failuresNotifyAndHeadlessNeverDoes() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(AttentionPolicy.decide(session(.failed, since: 999), now: now) == .notify)
    #expect(AttentionPolicy.decide(session(.failed, since: 0, headless: true), now: now) == .skip)
    #expect(AttentionPolicy.decide(session(.working, since: 0), now: now) == .skip)
}

@Test func notificationPrefsPerProjectFallBackToDefaults() {
    var prefs = NotificationPrefs()
    var s = session(.readyForReview, since: 0)
    s.projectDir = "/repos/a"
    #expect(prefs.allows(s))

    prefs.set(.review, false, for: "/repos/a")
    #expect(!prefs.allows(s))
    s.state = .needsPermission
    #expect(prefs.allows(s))
    s.projectDir = "/repos/b"
    s.state = .readyForReview
    #expect(prefs.allows(s))

    // Defaults only reach projects that weren't customized.
    prefs.setDefault(.permission, false)
    #expect(prefs.kinds(for: "/repos/b") == [.review, .error])
    #expect(prefs.kinds(for: "/repos/a") == [.permission, .error])

    // Matching the defaults again drops the custom setting.
    prefs.set(.permission, false, for: "/repos/a")
    prefs.set(.review, true, for: "/repos/a")
    #expect(!prefs.isCustomized("/repos/a"))
    #expect(!prefs.allows(session(.working, since: 0)))
}

@Test func itermIDsAndTitles() {
    #expect(TerminalFocus.itermUUID("w0t1p0:9492661F-78E8-4517-911C-69B09CB1E048") == "9492661F-78E8-4517-911C-69B09CB1E048")
    #expect(TerminalFocus.itermUUID("not-a-uuid") == nil)
    #expect(TerminalFocus.cleanTitle("◐ QR code phone handoff (claude)") == "QR code phone handoff")
    #expect(TerminalFocus.cleanTitle("-zsh") == "zsh")
    #expect(TerminalFocus.cleanTitle("✳ Fix (the) bug") == "Fix (the) bug")
}

private func ranked(_ sessions: [Session], query: String = "", seen: Set<String> = [], focused: [String: Date] = [:]) -> [String] {
    SessionSearch.rank(
        sessions, query: query, title: { $0.id == "b" ? "Fix login bug" : nil },
        isSeen: { seen.contains($0.id) }, lastFocused: focused
    ).map(\.id)
}

private func named(_ id: String, _ state: SessionState, since: Double, dir: String = "/repos/nudge", headless: Bool = false) -> Session {
    var s = Session(id: id, since: Date(timeIntervalSince1970: since), lastEvent: "", lastEventAt: Date(timeIntervalSince1970: since))
    s.state = state
    s.projectDir = dir
    s.headless = headless
    return s
}

@Test func switcherPutsUnseenAttentionFirstOldestFirst() {
    let sessions = [
        named("a", .working, since: 300),
        named("b", .readyForReview, since: 200),
        named("c", .needsPermission, since: 100),
        named("d", .idle, since: 400, headless: true),
    ]
    #expect(ranked(sessions) == ["c", "b", "a", "d"])
    // A seen attention session sorts with the rest by recency.
    #expect(ranked(sessions, seen: ["c"]) == ["b", "a", "c", "d"])
}

@Test func switcherOrdersTheRestByLastUse() {
    let sessions = [named("a", .idle, since: 100), named("e", .working, since: 200)]
    #expect(ranked(sessions) == ["e", "a"])
    #expect(ranked(sessions, focused: ["a": Date(timeIntervalSince1970: 300)]) == ["a", "e"])
}

@Test func switcherSearchMatchesEveryWordAcrossFields() {
    let sessions = [named("a", .idle, since: 100, dir: "/repos/api"), named("b", .idle, since: 200, dir: "/repos/web")]
    #expect(ranked(sessions, query: "LOGIN") == ["b"])
    #expect(ranked(sessions, query: "web login") == ["b"])
    #expect(ranked(sessions, query: "api login").isEmpty)
    #expect(ranked(sessions, query: "repos") == ["b", "a"])
}

@Test func transcriptTitleIsTheLatestAITitle() throws {
    let url = tempLog()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(Transcript.title(path: url.path) == nil)
    try append(#"{"type":"user","message":{"content":"hi"}}"# + "\n", to: url)
    #expect(Transcript.title(path: url.path) == nil)
    try append(#"{"type":"ai-title","aiTitle":"First topic","sessionId":"s1"}"# + "\n", to: url)
    try append(#"{"type":"assistant","message":{"content":"ok"}}"# + "\n", to: url)
    try append(#"{"type":"ai-title","aiTitle":"Renamed topic","sessionId":"s1"}"# + "\n", to: url)
    try append(#"{"type":"assistant","message":{"content":"ok"}}"# + "\n", to: url)
    #expect(Transcript.title(path: url.path) == "Renamed topic")
}
