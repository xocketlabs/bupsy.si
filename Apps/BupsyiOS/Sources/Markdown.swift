import SwiftUI

/// A bot's reply, split into the few kinds of block a phone draws differently.
///
/// `AttributedString(markdown:)` handles everything inline (bold, italics, code spans, links) but
/// flattens blocks: a list loses its bullets and a code block its line breaks. So this splits the
/// blocks out first, simply, and hands each one's text to the inline parser.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case code(String)
    case list([ListItem])
    case quote(String)
    /// Kept as its rows, shown in mono so the columns still line up.
    case table([String])
    case rule

    struct ListItem: Equatable {
        /// "•" for a bullet, or the item's own number: "3."
        let marker: String
        let text: String
        /// 0 at the margin, 1 for a nested item, and so on.
        let depth: Int
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
            } else if let fence = fence(trimmed) {
                var body: [String] = []
                i += 1
                while i < lines.count, !closes(lines[i], fence) {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                i += 1 // past the closing fence, or the end if the bot never closed it
            } else if let heading = heading(trimmed) {
                blocks.append(.heading(heading))
                i += 1
            } else if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
            } else if trimmed.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count, let quoted = quote(lines[i]) {
                    body.append(quoted)
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|") {
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    // The |---|---| line under the header only draws a rule on a web page.
                    if !row.allSatisfy({ "|-: ".contains($0) }) { rows.append(row) }
                    i += 1
                }
                blocks.append(.table(rows))
            } else if listItem(lines[i]) != nil {
                var items: [ListItem] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                    } else if startsBlock(lines[i]) {
                        break
                    } else if let last = items.popLast() {
                        // A wrapped line belongs to the item above it.
                        let more = lines[i].trimmingCharacters(in: .whitespaces)
                        items.append(ListItem(marker: last.marker, text: last.text + " " + more, depth: last.depth))
                    }
                    i += 1
                }
                blocks.append(.list(items))
            } else {
                var body: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      body.isEmpty || !startsBlock(lines[i]) {
                    body.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.paragraph(body.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// Bold, italics, code spans and links, with the line breaks the bot wrote kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - Recognising a block from its first line

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed)
            || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || listItem(line) != nil
    }

    /// The opening run of ``` or ~~~, which the closing fence must match.
    private static func fence(_ trimmed: String) -> String? {
        for mark in ["`", "~"] {
            let run = trimmed.prefix { String($0) == mark }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func closes(_ line: String, _ fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first }
    }

    private static func heading(_ trimmed: String) -> String? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quote(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let rest = trimmed.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        let depth = min(indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2, 3)
        if let bullet = rest.first, "-*+•".contains(bullet), rest.dropFirst().first == " " {
            return ListItem(marker: "•", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let after = rest.dropFirst(digits.count)
        if (1...9).contains(digits.count), let mark = after.first, mark == "." || mark == ")",
           after.dropFirst().first == " " {
            return ListItem(marker: "\(digits).", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces),
                            depth: depth)
        }
        return nil
    }
}

/// A bot's reply, drawn block by block.
struct MarkdownText: View {
    @Environment(\.palette) private var palette
    let source: String
    /// Text the size of the bubble's time, drawn invisibly at the end of the last paragraph, so
    /// the real time can sit in the bubble's corner without ever covering a word.
    var trailer: Text?

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, last: index == blocks.count - 1)
            }
            if let trailer, !Self.endsInParagraph(blocks) {
                trailer
            }
        }
        .tint(palette.primary)
    }

    private static func endsInParagraph(_ blocks: [MarkdownBlock]) -> Bool {
        if case .paragraph = blocks.last { return true }
        return false
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, last: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            if last, let trailer {
                Text("\(Text(MarkdownBlock.inline(text)))\(trailer)")
            } else {
                Text(MarkdownBlock.inline(text))
            }
        case .heading(let text):
            Text(MarkdownBlock.inline(text)).fontWeight(.bold)
        case .code(let code):
            Preformatted(text: code)
        case .table(let rows):
            Preformatted(text: rows.joined(separator: "\n"))
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(palette.mutedForeground).monospacedDigit()
                        Text(MarkdownBlock.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                Capsule().fill(palette.cardHover).frame(width: 3)
                Text(MarkdownBlock.inline(text)).foregroundStyle(palette.mutedForeground)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }
}

/// Code, kept exactly as written: mono, unwrapped, scrolling sideways rather than breaking lines.
struct Preformatted: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(palette.recess, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
