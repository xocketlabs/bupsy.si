import BupsyKit
import SwiftUI

/// A reply: prose as text, code as code.
struct FormattedReply: View {
    @Environment(\.palette) private var palette
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            ForEach(MarkdownBlock.parse(markdown)) { block in
                switch block {
                case .prose(let text):
                    // No `maxWidth: .infinity` here. It made every reply bubble stretch to the
                    // full 560pt whatever it said, so "Hey!" drew a bubble the width of a
                    // paragraph — the single thing that stopped these reading as messages.
                    // A code block still sets the bubble's width, which is what should.
                    Text(inline(text))
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            // Hanging indent: a wrapped item lines up under its own text, not
                            // under the bullet, which is what makes a list scannable.
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                                Text("•")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.mutedForeground)
                                Text(inline(item))
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.foreground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
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
                Button(copied ? "Copied" : "Copy") { copy() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(copied ? palette.info : palette.mutedForeground)
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.tight)

            ScrollView(.horizontal, showsIndicators: false) {
                // Fixed on both axes. Code must never wrap (indentation is meaning) and must
                // never truncate (a missing closing brace is a different program). A horizontal
                // scroll view does not claim its content's height, so under vertical pressure it
                // was squeezed and SwiftUI cut the text with "…" — measured on a real reply whose
                // stored text was complete while the screen showed `String…` and no brace.
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
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
