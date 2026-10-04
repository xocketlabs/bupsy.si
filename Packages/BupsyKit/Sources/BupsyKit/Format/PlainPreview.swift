import Foundation

/// One line of plain text from a message, for a list row.
///
/// Replies are markdown, and the sidebar showed it raw — "Created `hello.txt` containing **hi**"
/// with the backticks and asterisks in. This keeps the words and drops the markup.
public enum PlainPreview {
    public static func of(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            // Headings, quotes, list markers.
            while let first = line.first, "#>".contains(first) { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { line.removeFirst(2) }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        var text = lines.joined(separator: " ")
        // Inline markup: links keep their text, emphasis and code lose their marks.
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "~~"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}
