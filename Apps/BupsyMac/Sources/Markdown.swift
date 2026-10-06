import BupsyKit
import SwiftUI

/// A reply: prose as text, code as code.
struct FormattedReply: View {
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var model
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            // By position, not by text: two identical paragraphs used to share an id.
            ForEach(MarkdownBlock.identified(markdown)) { item in
                switch item.block {
                case .prose(let text):
                    // No `maxWidth: .infinity` here. It made every reply bubble stretch to the
                    // full 560pt whatever it said, so "Hey!" drew a bubble the width of a
                    // paragraph, the single thing that stopped these reading as messages.
                    // A code block still sets the bubble's width, which is what should.
                    inlineText(text)
                        .font(ThreadLayout.messageFont)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        // Wrap, never truncate. Without this a reply of several short lines was
                        // drawn one line each with "...", hiding most of what the bot said.
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.system(size: Self.headingSize(level), weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, level <= 2 ? Theme.Space.tight : 0)
                        .accessibilityAddTraits(.isHeader)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .list(let items):
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            // Hanging indent: a wrapped item lines up under its own text, not
                            // under the marker, which is what makes a list scannable.
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                                marker(item.marker, level: item.level)
                                inlineText(item.text)
                                    .font(ThreadLayout.messageFont)
                                    .foregroundStyle(palette.foreground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, CGFloat(min(item.level, 4)) * Self.nestIndent)
                        }
                    }
                }
            }
        }
    }

    /// How far each nesting level steps in: about the width of a marker and its gap.
    private static let nestIndent: CGFloat = 18

    /// Headings step down from the message size: larger for `#`, the same size for `###` and
    /// deeper, where the weight alone sets them apart.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: ThreadLayout.messageSize + 4
        case 2: ThreadLayout.messageSize + 2
        default: ThreadLayout.messageSize
        }
    }

    /// A bullet, hollow once nested, or the item's number. Numbers share a width so the text of
    /// "9." and "10." lines up.
    @ViewBuilder
    private func marker(_ marker: MarkdownListItem.Marker, level: Int) -> some View {
        switch marker {
        case .bullet:
            Text(verbatim: level == 0 ? "\u{2022}" : "\u{25E6}")
                .font(ThreadLayout.messageFont)
                .foregroundStyle(palette.mutedForeground)
                .accessibilityHidden(true)
        case .number(let number):
            Text(verbatim: "\(number).")
                .font(ThreadLayout.messageFont.monospacedDigit())
                .foregroundStyle(palette.mutedForeground)
                .frame(minWidth: 18, alignment: .trailing)
        }
    }

    /// Prose with every "@Name" of a real bot shown as its face and name in its colour.
    ///
    /// Joined `Text`, not a view per mention, so a mention wraps and selects with the sentence
    /// around it like any other word.
    private func inlineText(_ text: String) -> Text {
        let pieces = MentionSplitter.split(text, names: model.bots.map(\.name))
        return pieces.reduce(Text(verbatim: "")) { result, piece in
            switch piece {
            case .text(let run):
                return result + Text(inline(run))
            case .mention(let name):
                guard let bot = model.bots.first(where: { $0.name == name }) else {
                    return result + Text(verbatim: "@" + name)
                }
                let face = MentionFaces.image(for: bot, size: Theme.scaled(14))
                    .map { Text(Image(nsImage: $0)).baselineOffset(-2) + Text(verbatim: " ") }
                    ?? Text(verbatim: "@")
                return result + face
                    + Text(verbatim: bot.name).fontWeight(.semibold).foregroundColor(BotFace.colour(of: bot))
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
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
