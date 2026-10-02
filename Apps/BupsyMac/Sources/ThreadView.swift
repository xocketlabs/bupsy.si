import BupsyKit
import SwiftUI

// The page shell moved to BotPage. These are the pieces a transcript is made of.

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Theme.daySeparator(date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.tight)
    }
}

struct Bubble: View {
    @Environment(\.palette) private var palette
    let entry: TranscriptEntry
    let bot: Bot
    let showsAvatar: Bool

    var body: some View {
        switch entry.kind {
        case .userMessage(let text):
            HStack {
                Spacer(minLength: 72)
                Text(text)
                    .font(Theme.Typography.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.snug)
                    .background(palette.primary, in: .rect(cornerRadius: Theme.Radius.bubble))
                    .foregroundStyle(palette.onPrimary)
                    .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .trailing)
            }

        case .assistantText(let text):
            botAligned {
                // Cards sit above the background, which is where this palette's depth comes
                // from — a reply looks like an object on a surface rather than text on a page.
                FormattedReply(markdown: text)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.snug)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
            }

        case .thinking(let text):
            botAligned { ThinkingAside(text: text) }

        // Tool calls are asides, not events. A bot running `ls` is not a message, and giving it
        // the weight of one buries the reply underneath its own working.
        case .tool(let name, let arguments, let result, let failed):
            botAligned {
                ToolAside(name: name, arguments: arguments, result: result, failed: failed)
            }

        case .approval(let approval):
            botAligned { ApprovalCard(approval: approval) }

        case .limits(let limits):
            botAligned { LimitsGauge(limits: limits) }

        case .failure(let failure):
            botAligned { FailureNotice(failure: failure) }

        case .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private func botAligned<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Space.tight) {
            // A fixed gutter so bubbles stay aligned whether or not this one shows a face.
            Group {
                if showsAvatar {
                    BotFace(hue: bot.avatarHue, mood: .idle, size: Theme.Size.bubbleAvatar)
                } else {
                    Color.clear.frame(width: Theme.Size.bubbleAvatar, height: 1)
                }
            }
            content()
                .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .leading)
            Spacer(minLength: 48)
        }
    }

}

/// A compact line rather than a card. Expands when you want the detail.
struct ToolAside: View {
    let name: String
    let arguments: String
    let result: String?
    let failed: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(failed ? .orange : .secondary)
                    Text(verb)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if result == nil && !failed {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(arguments)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    if let result {
                        Divider()
                        Text(result)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(24)
                    }
                }
                .padding(Theme.Space.snug)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: Theme.Radius.control))
            }
        }
        .padding(.leading, 2)
    }

    private var verb: String {
        if failed { return "failed" }
        switch name {
        case "Bash", "shell": return "ran"
        case "Read": return "read"
        case "Write", "Edit", "MultiEdit", "edit": return "edited"
        case "WebFetch", "WebSearch": return "looked up"
        default: return name.hasPrefix("mcp__") ? "used" : name.lowercased()
        }
    }

    private var icon: String {
        if failed { return "exclamationmark.triangle" }
        switch name {
        case "Bash", "shell": return "chevron.right"
        case "Read": return "doc.text"
        case "Write", "Edit", "MultiEdit", "edit": return "pencil"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.adjustable"
        }
    }

    private var summary: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return name
    }
}

struct ThinkingAside: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button { expanded.toggle() } label: {
                Label("Thinking", systemImage: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(Theme.Space.snug)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: Theme.Radius.control))
            }
        }
    }
}

struct FailureNotice: View {
    let failure: EngineFailure

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.tight) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.Space.snug)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.card))
    }

    private var title: String {
        switch failure.kind {
        case .notSignedIn: "Not signed in"
        case .rateLimited: "You've hit your usage limit"
        case .binaryNotFound: "Engine not found on this Mac"
        case .launchFailed: "Could not start the engine"
        case .protocolError: "Unexpected engine behaviour"
        case .nonZeroExit: "The engine exited with an error"
        case .cancelled: "Stopped"
        case .unknown: "Something went wrong"
        }
    }
}

struct TypingIndicator: View {
    @Environment(\.palette) private var palette
    let bot: Bot

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Color.clear.frame(width: Theme.Size.bubbleAvatar, height: 1)
            ThinkingOrbs(hue: bot.avatarHue, dotSize: 6)
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.snug)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
            Spacer(minLength: 0)
        }
    }
}

struct Composer: View {
    @Environment(\.palette) private var palette
    @Binding var draft: String
    let bot: Bot
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.snug) {
            TextField("Message \(bot.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .lineLimit(1...8)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.step)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.base)
                        .strokeBorder(palette.border)
                }
                .borderBeam(hue: bot.avatarHue, active: isRunning, cornerRadius: Theme.Radius.base)
                .onSubmit(onSend)

            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(sendEnabled ? palette.primary : palette.secondary,
                                in: .rect(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.step)
        .frame(maxWidth: Theme.Size.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(palette.background)
    }

    private var sendEnabled: Bool {
        isRunning || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
