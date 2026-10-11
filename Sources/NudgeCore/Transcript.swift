import Foundation

/// Reads the tail of a Claude Code transcript (JSONL) for signals hooks don't provide.
public enum Transcript {
    /// True if the most recent user/assistant entry is an interrupt marker, written
    /// when the user presses Esc mid-turn or denies a permission prompt.
    public static func lastTurnWasInterrupted(path: String, tailBytes: Int = 64 * 1024) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return false }

        // Walk lines backwards, skipping bookkeeping entries (system, cost-state, ...).
        for line in data.split(separator: 0x0A).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            guard type == "user", let message = obj["message"] as? [String: Any] else { return false }
            return text(of: message["content"]).hasPrefix("[Request interrupted by user")
        }
        return false
    }

    /// The conversation topic Claude Code writes as `{"type":"ai-title","aiTitle":…}`; the
    /// same text it puts in the terminal tab title, but available in every terminal. It's
    /// re-written every few turns, so the tail almost always holds the current one.
    public static func title(path: String, tailBytes: Int = 1024 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        let marker = Data(#""type":"ai-title""#.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }
}
