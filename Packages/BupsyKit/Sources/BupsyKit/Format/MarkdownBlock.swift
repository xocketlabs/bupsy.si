import Foundation

/// One line of a list: its marker, how deeply it is nested, and its text without the marker.
public struct MarkdownListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        /// The number to show. Renumbered from the list's first number, so a model that writes
        /// "1." on every line still reads 1, 2, 3, the way any markdown renderer shows it.
        case number(Int)
    }

    public var marker: Marker
    /// 0 for a top-level item, 1 for one nested under it, and so on.
    public var level: Int
    public var text: String

    public init(marker: Marker, level: Int = 0, text: String) {
        self.marker = marker
        self.level = level
        self.text = text
    }

    public static func bullet(_ text: String, level: Int = 0) -> MarkdownListItem {
        MarkdownListItem(marker: .bullet, level: level, text: text)
    }

    public static func number(_ number: Int, _ text: String, level: Int = 0) -> MarkdownListItem {
        MarkdownListItem(marker: .number(number), level: level, text: text)
    }
}

/// Splits a reply into prose, headings, lists and code.
///
/// SwiftUI's markdown is inline-only, so a fenced code block arrives as run-together prose with
/// its newlines collapsed. For agents whose whole job is writing code, that is the single worst
/// rendering bug in the app: a diff or a shell command becomes unreadable at exactly the moment
/// you need to read it carefully.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String?, text: String)
    /// A `#`, `##` or `###` line, without its hashes. Deeper headings keep their level; the
    /// renderer decides how small to go.
    case heading(level: Int, text: String)
    /// A run of list lines, bulleted, numbered or a mix of the two, with their nesting.
    ///
    /// Lists are a block, not prose. SwiftUI's markdown is inline-only, so a bulleted list
    /// arrived as lines starting with a literal "- ", and every list a model wrote (which is
    /// most of them) rendered as raw hyphens. Measured on a real reply before this existed.
    case list([MarkdownListItem])

    /// A flat bulleted list. Shorthand for the most common list there is.
    public static func bullets(_ items: [String]) -> MarkdownBlock {
        .list(items.map { MarkdownListItem.bullet($0) })
    }

    /// A block with an id for `ForEach`.
    ///
    /// The id is the block's position, not a hash of its text: two identical paragraphs (a
    /// repeated "Done." or an empty-looking line) gave two blocks one id, and SwiftUI drew one
    /// of them twice and dropped the other.
    public struct Identified: Identifiable, Equatable, Sendable {
        public let id: Int
        public let block: MarkdownBlock
    }

    public static func identified(_ markdown: String) -> [Identified] {
        parse(markdown).enumerated().map { Identified(id: $0.offset, block: $0.element) }
    }

    /// The item if this line is a list line, with how far it is indented, nil otherwise.
    ///
    /// `-`, `*` and `•` followed by a space are bullets; up to three digits then `.` or `)` and
    /// a space are numbers. A hyphen with no space after it is a dash or a negative number in a
    /// sentence, not a list, and must stay prose.
    static func listLine(_ line: String) -> (indent: Int, marker: MarkdownListItem.Marker, text: String)? {
        var indent = 0
        for character in line {
            if character == " " { indent += 1 } else if character == "\t" { indent += 4 } else { break }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
            let item = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : (indent: indent, marker: .bullet, text: item)
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let item = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : (indent: indent, marker: .number(number), text: item)
    }

    /// The item text if this line is a bullet, nil otherwise.
    static func bulletItem(_ line: String) -> String? {
        guard let parsed = listLine(line), parsed.marker == .bullet else { return nil }
        return parsed.text
    }

    /// The level and text if this line is an ATX heading ("## Setup"), nil otherwise.
    static func headingLine(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // "#hashtag" and "#1" are not headings: a heading's hashes are followed by a space.
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of hashes ("## Setup ##") is decoration, not text.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level: hashes.count, text: text)
    }

    /// Parses fences, headings and lists. Deliberately no more than that: it is what engines
    /// emit, and a fuller markdown parser would be a lot of surface for very little fidelity.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            // Prose is split into its own paragraphs, headings and list runs here, so a reply
            // that mixes them keeps them in order rather than having every list hoisted to the end.
            var paragraph: [String] = []
            var items: [MarkdownListItem] = []
            // The indents of the open nesting levels, outermost first.
            var indents: [Int] = []
            // The last number shown at each level, so numbered items count on from it.
            var counters: [Int: Int] = [:]

            func flushParagraph() {
                let text = paragraph.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(.prose(text)) }
                paragraph.removeAll()
            }
            func flushItems() {
                if !items.isEmpty { blocks.append(.list(items)) }
                items.removeAll()
                indents.removeAll()
                counters.removeAll()
            }

            for line in prose {
                if let heading = headingLine(line) {
                    flushParagraph()
                    flushItems()
                    blocks.append(.heading(level: heading.level, text: heading.text))
                } else if let parsed = listLine(line) {
                    flushParagraph()
                    // Deeper than the open level opens a new one; shallower closes back to the
                    // level it lines up with. Relative, so 2, 3 and 4 space indents all nest.
                    while let last = indents.last, parsed.indent < last { indents.removeLast() }
                    if indents.isEmpty || parsed.indent > indents[indents.count - 1] {
                        indents.append(parsed.indent)
                    }
                    let level = indents.count - 1
                    for deeper in counters.keys where deeper > level { counters[deeper] = nil }
                    switch parsed.marker {
                    case .number(let written):
                        let shown = counters[level].map { $0 + 1 } ?? written
                        counters[level] = shown
                        items.append(MarkdownListItem(marker: .number(shown), level: level, text: parsed.text))
                    case .bullet:
                        counters[level] = nil
                        items.append(MarkdownListItem(marker: .bullet, level: level, text: parsed.text))
                    }
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
