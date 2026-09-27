/// How well a typed query fits a line, the way a palette is searched: every character of the
/// query, in order, anywhere in the line, ignoring case. "nt" finds "New Terminal".
enum FuzzyMatch {
    /// nil when the query does not fit. Higher is better: a character that starts a word or
    /// follows the previous match counts for more, and the line's own first word most, so "nt"
    /// ranks "New Terminal" above "Increase Font Size" and "work" puts "Workspace helm" first.
    static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let hay = Array(text.lowercased())
        var score = 0
        var at = 0
        var previous: Int?
        for character in needle {
            guard let found = hay[at...].firstIndex(of: character) else { return nil }
            score += 1
            if found == 0 { score += 2 }
            if found == 0 || !hay[found - 1].isLetter && !hay[found - 1].isNumber { score += 4 }
            if let previous, found == previous + 1 { score += 3 }
            previous = found
            at = found + 1
        }
        return score
    }

    /// `items` that fit `query`, best first; ties keep their order.
    static func rank<Item>(_ items: [Item], by query: String, text: (Item) -> String) -> [Item] {
        items.enumerated()
            .compactMap { index, item in score(query, in: text(item)).map { (index, $0, item) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }
}
