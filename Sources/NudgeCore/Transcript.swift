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

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }
}
