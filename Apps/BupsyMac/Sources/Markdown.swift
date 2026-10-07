import BupsyKit
import SwiftUI

/// A reply: prose as text, code as code.
///
/// Everything between two code blocks (paragraphs, headings, lists) is one native text view, not
/// a SwiftUI `Text` per paragraph. SwiftUI selects within a single `Text` only, so a drag stopped
/// dead at the end of every paragraph and a reply could not be selected and copied whole.
struct FormattedReply: View {
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var model
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            ForEach(ReplySegment.split(markdown)) { segment in
                switch segment.kind {
                case .prose(let blocks):
                    // No `maxWidth: .infinity` here. It made every reply stretch to the full
                    // column whatever it said; the text view hugs short replies instead.
                    SelectableReplyText(text: ReplyText.make(blocks, palette: palette, bots: model.bots),
                                        linkColour: NSColor(palette.primary))
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                }
            }
        }
    }
}

/// A reply cut at its code blocks: each run of prose between them selects as one.
struct ReplySegment: Identifiable {
    enum Kind {
        case prose([MarkdownBlock])
        case code(language: String?, text: String)
    }

    /// By position, not by text: two identical paragraphs used to share an id.
    let id: Int
    let kind: Kind

    static func split(_ markdown: String) -> [ReplySegment] {
        var segments: [ReplySegment] = []
        var prose: [MarkdownBlock] = []
        func flush() {
            guard !prose.isEmpty else { return }
            segments.append(ReplySegment(id: segments.count, kind: .prose(prose)))
            prose = []
        }
        for block in MarkdownBlock.parse(markdown) {
            if case .code(let language, let text) = block {
                flush()
                segments.append(ReplySegment(id: segments.count, kind: .code(language: language, text: text)))
            } else {
                prose.append(block)
            }
        }
        flush()
        return segments
    }
}

/// Builds the attributed text a run of prose blocks is drawn from.
@MainActor
enum ReplyText {
    /// How far each list nesting level steps in: about the width of a marker and its gap.
    static let nestIndent: CGFloat = 18
    /// Where a list item's text starts past its marker, so a wrapped line hangs under the text.
    static let markerWidth: CGFloat = 20

    /// Headings step down from the message size: larger for `#`, the same size for `###` and
    /// deeper, where the weight alone sets them apart.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: ThreadLayout.messageSize + 4
        case 2: ThreadLayout.messageSize + 2
        default: ThreadLayout.messageSize
        }
    }

    static func make(_ blocks: [MarkdownBlock], palette: Palette.Scheme, bots: [Bot]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: ThreadLayout.messageSize)
        let text = NSColor(palette.foreground)
        let muted = NSColor(palette.mutedForeground)

        /// One paragraph. Line breaks inside it become line separators, so the space between
        /// paragraphs is not also added between the lines of one.
        func paragraph(_ content: NSAttributedString, spacingBefore: CGFloat,
                       indent: CGFloat = 0, hanging: CGFloat = 0) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            // Nothing above the first paragraph: the message's name row already spaces it.
            style.paragraphSpacingBefore = result.length == 0 ? 0 : spacingBefore
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            if hanging > 0 {
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)]
                style.defaultTabInterval = hanging
            }
            let start = result.length
            result.append(content)
            result.mutableString.replaceOccurrences(
                of: "\n", with: "\u{2028}", options: [],
                range: NSRange(location: start, length: result.length - start))
            result.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: start, length: result.length - start))
        }

        for block in blocks {
            switch block {
            case .prose(let prose):
                paragraph(inline(prose, font: body, colour: text, bots: bots), spacingBefore: Theme.Space.snug)
            case .heading(let level, let heading):
                let font = NSFont.systemFont(ofSize: headingSize(level), weight: .semibold)
                paragraph(inline(heading, font: font, colour: text, bots: bots),
                          spacingBefore: Theme.Space.snug + (level <= 2 ? Theme.Space.tight : 0))
            case .list(let items):
                for (index, item) in items.enumerated() {
                    let line = NSMutableAttributedString()
                    switch item.marker {
                    case .bullet:
                        // Hollow once nested.
                        line.append(NSAttributedString(
                            string: item.level == 0 ? "\u{2022}" : "\u{25E6}",
                            attributes: [.font: body, .foregroundColor: muted]))
                    case .number(let number):
                        line.append(NSAttributedString(
                            string: "\(number).",
                            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: ThreadLayout.messageSize,
                                                                                weight: .regular),
                                         .foregroundColor: muted]))
                    }
                    line.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                    line.append(inline(item.text, font: body, colour: text, bots: bots))
                    paragraph(line,
                              spacingBefore: index == 0 ? Theme.Space.snug : Theme.Space.tight,
                              indent: CGFloat(min(item.level, 4)) * nestIndent,
                              hanging: markerWidth)
                }
            case .code:
                // Code is its own segment; ReplySegment never puts it here.
                break
            }
        }
        return result
    }

    /// Prose with inline markdown, and every "@Name" of a real bot as its face and name in its
    /// colour, so a mention wraps and selects with the sentence around it like any other word.
    static func inline(_ text: String, font: NSFont, colour: NSColor, bots: [Bot]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in MentionSplitter.split(text, names: bots.map(\.name)) {
            switch piece {
            case .text(let run):
                result.append(markdown(run, font: font, colour: colour))
            case .mention(let name):
                guard let bot = bots.first(where: { $0.name == name }) else {
                    result.append(NSAttributedString(string: "@" + name,
                                                     attributes: [.font: font, .foregroundColor: colour]))
                    continue
                }
                let size = Theme.scaled(14)
                if let face = MentionFaces.image(for: bot, size: size) {
                    let attachment = NSTextAttachment()
                    attachment.image = face
                    attachment.bounds = CGRect(x: 0, y: -3, width: size, height: size)
                    result.append(NSAttributedString(attachment: attachment))
                    result.append(NSAttributedString(string: " ", attributes: [.font: font]))
                } else {
                    result.append(NSAttributedString(string: "@", attributes: [.font: font, .foregroundColor: colour]))
                }
                result.append(NSAttributedString(string: bot.name, attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    .foregroundColor: NSColor(BotFace.colour(of: bot)),
                ]))
            }
        }
        return result
    }

    /// Inline markdown (bold, italic, code, strikethrough, links) as AppKit attributes.
    private static func markdown(_ text: String, font: NSFont, colour: NSColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: colour]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters),
                                             attributes: attributes))
        }
        return result
    }
}

/// Read-only text that selects across every paragraph in it, the way a document does.
///
/// TextKit 1, built by hand, so the height asked for is measured by the same layout that draws.
struct SelectableReplyText: NSViewRepresentable {
    let text: NSAttributedString
    let linkColour: NSColor
    /// The widest a reply grows before wrapping, when the parent proposes no width.
    static let fallbackWidth: CGFloat = 720

    func makeNSView(context: Context) -> ReplyTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: Self.fallbackWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = ReplyTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateNSView(_ view: ReplyTextView, context: Context) {
        view.linkTextAttributes = [
            .foregroundColor: linkColour,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReplyTextView, context: Context) -> CGSize? {
        guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
        // Answer probes the way `Text` does: no width or an unbounded one gets the natural width
        // up to the cap; a zero width gets the narrowest wrap. Answering a zero probe with the
        // full width made the row's stack treat this as fixed and split its space with the
        // spacer, wrapping every reply at half the column.
        let width: CGFloat
        if let offered = proposal.width, offered.isFinite {
            width = max(offered, 1)
        } else {
            width = Self.fallbackWidth
        }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // Hug a short reply rather than claiming the whole width offered.
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

final class ReplyTextView: NSTextView {
    /// Plain text on the clipboard reads the way the reply does: a mention's face becomes "@",
    /// and lines stay lines rather than Unicode line separators.
    override func copy(_ sender: Any?) {
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !selected.isEmpty, let storage = textStorage else { return super.copy(sender) }
        let plain = selected.map { range in
            storage.attributedSubstring(from: range).string
                .replacingOccurrences(of: "\u{FFFC} ", with: "@")
                .replacingOccurrences(of: "\u{FFFC}", with: "@")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\t", with: " ")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    /// Let go of the selection when another message takes it, so a thread never shows several
    /// stale grey highlights at once.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    /// A message never scrolls itself; the thread does.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

struct CodeBlock: View {
    @Environment(\.palette) private var palette
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.tight) {
                if let language {
                    Text(language)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.sidebarMuted)
                }
                Spacer(minLength: 0)
                Button { copy() } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: Theme.scaled(9.5), weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(copied ? palette.success : palette.mutedForeground)
                }
                .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
                .help("Copy this code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, Theme.Space.step)
            .padding(.trailing, Theme.Space.tight)
            .padding(.vertical, Theme.Space.hairline)

            // The indicator shows: a long line that runs off the edge has to look like it does,
            // or the end of a command is hidden with nothing saying so.
            ScrollView(.horizontal, showsIndicators: true) {
                // Fixed on both axes. Code must never wrap (indentation is meaning) and must
                // never truncate (a missing closing brace is a different program). A horizontal
                // scroll view does not claim its content's height, so under vertical pressure it
                // was squeezed and SwiftUI cut the text short, measured on a real reply whose
                // stored text was complete while the screen showed `String...` and no brace.
                Text(text)
                    .font(.system(size: Theme.scaled(12), design: .monospaced))
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.bottom, Theme.Space.step)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Set into the rail's colour so a code block reads as a recess inside a lifted bubble.
        .background(palette.sidebar, in: .rect(cornerRadius: Theme.Radius.control))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
