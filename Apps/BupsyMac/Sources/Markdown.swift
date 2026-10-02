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
                    Text(inline(text))
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
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
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.bottom, Theme.Space.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
