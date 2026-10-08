import Foundation

/// One line of plain text from a message, for a list row.
///
/// Replies are markdown, and the sidebar showed it raw — "Created `hello.txt` containing **hi**"
/// with the backticks and asterisks in. This keeps the words and drops the markup.
public enum PlainPreview {
    /// About as much text as one preview line can show, and then some. Every caller shows a
    /// single truncated line, and the sidebar works this out for every bot each time it redraws,
    /// so a bot whose last reply ran to pages flattened all of them to show one line.
    public static let enough = 280

    public static func of(_ markdown: String, limit: Int = enough) -> String {
        var lines: [String] = []
        var inFence = false
        var gathered = 0
        // Only the start is ever read, so only the start is split into lines: splitting all of a
        // long reply first cost as much as flattening it.
        for raw in markdown.prefix(limit >= Int.max / 8 ? Int.max : limit * 8).split(separator: "\n", omittingEmptySubsequences: false) {
            if gathered >= limit { break }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            // Headings, quotes, list markers.
            while let first = line.first, "#>".contains(first) { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { line.removeFirst(2) }
            let kept = line.trimmingCharacters(in: .whitespaces)
            lines.append(kept)
            gathered += kept.count + 1
        }
        var text = lines.joined(separator: " ")
        // Inline markup: links keep their text, emphasis and code lose their marks.
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "~~"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}
