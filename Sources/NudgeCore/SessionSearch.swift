import Foundation

/// Filtering and ordering for the switcher (⌘⇧J). Works on any `Session`, so other
/// agents feeding the same log would show up without changes here.
public enum SessionSearch {
    /// Matches when every word of the query appears somewhere in the session's tab
    /// title, project, project path or id, ignoring case and accents.
    public static func matches(_ s: Session, query: String, title: String?) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, s.project, s.projectDir ?? s.cwd, s.id]
            .compactMap { $0 }
            .joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Unseen attention first, longest waiting at the top, then everything else by most
    /// recent use: the latest of the user's last jump to it, their last prompt in it and
    /// its last hook event. Headless sessions go last; nobody is waiting on them.
    public static func rank(
        _ sessions: [Session], query: String,
        title: (Session) -> String?, isSeen: (Session) -> Bool, lastFocused: [String: Date]
    ) -> [Session] {
        func group(_ s: Session) -> Int {
            if s.headless { return 2 }
            return s.needsAttention && !isSeen(s) ? 0 : 1
        }
        func recency(_ s: Session) -> Date {
            [lastFocused[s.id], s.turnStartedAt, s.lastEventAt].compactMap { $0 }.max() ?? s.since
        }
        return sessions
            .filter { matches($0, query: query, title: title($0)) }
            .sorted { a, b in
                let (ga, gb) = (group(a), group(b))
                if ga != gb { return ga < gb }
                if ga == 0 { return a.since < b.since }
                return recency(a) > recency(b)
            }
    }
}
