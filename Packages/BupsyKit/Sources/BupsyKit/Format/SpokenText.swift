import Foundation

/// A reply as it should sound when read aloud.
///
/// The words, in order, without the marks that only mean something on screen: no asterisks, no
/// backticks, no hashes. Code is named rather than read, since a voice spelling out `git push
/// origin main` symbol by symbol helps nobody, and a table is described rather than recited
/// cell by cell. What a person would say if they read the reply to you.
public enum SpokenText {
    public static func from(_ markdown: String) -> String {
        var parts: [String] = []
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .prose(let text), .heading(_, let text):
                let plain = PlainPreview.of(text, limit: .max)
                if !plain.isEmpty { parts.append(sentence(plain)) }
            case .list(let items):
                for item in items {
                    let plain = PlainPreview.of(item.text, limit: .max)
                    if !plain.isEmpty { parts.append(sentence(plain)) }
                }
            case .code:
                parts.append("There's some code here, on screen.")
            case .table(_, let rows):
                parts.append(rows.count == 1 ? "There's a table with one row, on screen."
                                             : "There's a table with \(rows.count) rows, on screen.")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Ends with a full stop when it ends with nothing, so the voice pauses between items
    /// rather than running them together.
    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?:;…".contains(last) ? text : text + "."
    }
}
