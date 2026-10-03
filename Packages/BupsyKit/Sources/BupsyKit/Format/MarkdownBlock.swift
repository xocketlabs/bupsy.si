import Foundation

/// Splits a reply into prose and code.
///
/// SwiftUI's markdown is inline-only, so a fenced code block arrives as run-together prose with
/// its newlines collapsed. For agents whose whole job is writing code, that is the single worst
/// rendering bug in the app — a diff or a shell command becomes unreadable at exactly the moment
/// you need to read it carefully.
public enum MarkdownBlock: Identifiable, Equatable {
    case prose(String)
    case code(language: String?, text: String)
    /// A run of bulleted lines, each item's text without its marker.
    ///
    /// Lists are a block, not prose. SwiftUI's markdown is inline-only, so a bulleted list
    /// arrived as lines starting with a literal "- ", and every list a model wrote — which is
    /// most of them — rendered as raw hyphens. Measured on a real reply before this existed.
    case bullets([String])

    public var id: String {
        switch self {
        case .prose(let text): "p\(text.hashValue)"
        case .code(let language, let text): "c\(language ?? "")\(text.hashValue)"
        case .bullets(let items): "b\(items.joined(separator: "\u{1}").hashValue)"
        }
    }

    /// The item text if this line is a bullet, nil otherwise.
    ///
    /// `-`, `*` and `•` followed by a space. A hyphen with no space after it is a dash or a
    /// negative number in a sentence, not a list, and must stay prose.
    static func bulletItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
            let item = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    /// Parses triple-backtick fences. Deliberately only fences: that is what engines emit, and a
    /// fuller markdown parser would be a lot of surface for very little more fidelity.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            // Prose is split into its own paragraphs and bullet runs here, so a reply that mixes
            // the two keeps them in order rather than having every list hoisted to the end.
            var paragraph: [String] = []
            var items: [String] = []

            func flushParagraph() {
                let text = paragraph.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(.prose(text)) }
                paragraph.removeAll()
            }
            func flushItems() {
                if !items.isEmpty { blocks.append(.bullets(items)) }
                items.removeAll()
            }

            for line in prose {
                if let item = bulletItem(line) {
                    flushParagraph()
                    items.append(item)
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line ends a paragraph but not a list: models routinely put one
                    // between items, and splitting there would break one list into several.
                    flushParagraph()
                } else {
                    flushItems()
                    paragraph.append(line)
                }
            }
            flushParagraph()
            flushItems()
            prose.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(
                        language: language,
                        text: code.joined(separator: "\n")))
                    code.removeAll()
                    language = nil
                    inCode = false
                } else {
                    flushProse()
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        // An unclosed fence is normal mid-stream: the block is still arriving. Show it as code
        // rather than holding it back, so a long answer renders as it lands.
        if inCode, !code.isEmpty {
            blocks.append(.code(language: language, text: code.joined(separator: "\n")))
        }
        flushProse()
        return blocks
    }
}

