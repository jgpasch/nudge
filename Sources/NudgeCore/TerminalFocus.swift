import AppKit

/// Brings a session's terminal tab to the front. iTerm2 only for now, via AppleScript.
/// NSAppleScript isn't thread-safe, so call these from the main thread.
public enum TerminalFocus {
    public enum Result: Equatable, Sendable {
        case focused
        case notFound           // the tab was closed, or iTerm2 isn't running
        case unsupported        // not an iTerm2 session; we just activate the terminal app
        case failed(String)     // AppleScript error, e.g. Automation permission denied
    }

    /// `ITERM_SESSION_ID` looks like `w0t1p0:<UUID>`. The prefix is the tab's position
    /// when it was created and goes stale as tabs move; only the UUID is stable.
    public static func itermUUID(_ sessionID: String) -> String? {
        guard let uuid = sessionID.split(separator: ":").last, UUID(uuidString: String(uuid)) != nil else { return nil }
        return String(uuid)
    }

    public static func focus(_ session: Session) -> Result {
        guard let raw = session.itermSessionID, let uuid = itermUUID(raw) else {
            if let app = appName(forTermProgram: session.termProgram) {
                _ = run("tell application \"\(app)\" to activate")
            }
            return .unsupported
        }
        // Selecting window, tab and session covers split panes; activate last so the
        // window is already frontmost within iTerm when the app comes forward.
        let script = """
            if application "iTerm2" is not running then return "notFound"
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(uuid)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notFound"
            """
        switch run(script) {
        case .success("focused"):
            // Selecting the window again once iTerm2 is frontmost is what moves to its
            // Space; the first select happened while iTerm2 may still have been inactive.
            activateITerm { _ = run(script) }
            return .focused
        case .success: return .notFound
        case .failure(let message): return .failed(message)
        }
    }

    /// Current tab titles keyed by iTerm2 session UUID. Claude Code titles its tab with
    /// the conversation topic, which reads better than a directory name.
    public static func itermTitles() -> [String: String] {
        let script = """
            if application "iTerm2" is not running then return ""
            set out to ""
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set out to out & (unique id of s) & tab & (name of s) & linefeed
                        end repeat
                    end repeat
                end repeat
            end tell
            return out
            """
        guard case .success(let text) = run(script) else { return [:] }
        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { titles[String(parts[0])] = cleanTitle(String(parts[1])) }
        }
        return titles
    }

    /// "◐ QR code phone handoff (claude)" → "QR code phone handoff": drops Claude's
    /// activity spinner and the job name iTerm2 appends.
    static func cleanTitle(_ title: String) -> String {
        var t = Substring(title)
        while let c = t.first, !c.isLetter, !c.isNumber { t = t.dropFirst() }
        if t.hasSuffix(")"), let open = t.lastIndex(of: "("), open > t.startIndex {
            t = t[..<open]
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// AppleScript `activate` is only a request. Since macOS 14, an app that isn't frontmost
    /// (Nudge handling a banner click) can't hand activation over, so iTerm2 selects the
    /// tab without coming forward. Opening the app through LaunchServices activates it, but
    /// if iTerm2 has a window on the current Space macOS stays there, so `then` runs on the
    /// main thread afterwards to bring the target window forward. A CLI that exits right
    /// away never gets there; it runs inside iTerm2, so the first select already worked.
    private static func activateITerm(then: @escaping @MainActor () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    private static func appName(forTermProgram program: String?) -> String? {
        switch program {
        case "iTerm.app": "iTerm2"
        case "Apple_Terminal": "Terminal"
        case "ghostty": "Ghostty"
        case "WezTerm": "WezTerm"
        case "vscode": "Visual Studio Code"
        default: nil
        }
    }

    private enum ScriptResult { case success(String), failure(String) }

    private static func run(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure("could not compile") }
        let output = script.executeAndReturnError(&error)
        if let error {
            return .failure(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        return .success(output.stringValue ?? "")
    }
}
