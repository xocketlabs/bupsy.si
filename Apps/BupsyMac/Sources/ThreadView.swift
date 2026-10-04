import AppKit
import BupsyKit
import SwiftUI

// The page shell moved to BotPage. These are the pieces a transcript is made of.

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Theme.daySeparator(date))
            .font(Theme.Typography.badge)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.tight)
    }
}

struct Bubble: View {
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var model
    let entry: TranscriptEntry
    let bot: Bot
    let showsAvatar: Bool
    /// Reply to this message: who said it, and what. nil where replying makes no sense.
    var onReply: ((_ author: String, _ text: String) -> Void)?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        content.onHover { hovering = $0 }
    }

    /// Your message with each real @mention in bold, so who you addressed stands out — on the pink
    /// bubble a bot's own colour would not read, so weight does the work.
    private func mentionsHighlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for piece in MentionSplitter.split(text, names: model.bots.map(\.name)) {
            switch piece {
            case .text(let run): result += AttributedString(run)
            case .mention(let name):
                var tag = AttributedString("@" + name)
                tag.font = Theme.Typography.body.weight(.bold)
                result += tag
            }
        }
        return result
    }

    /// The reply arrow, shown beside a message while the pointer is over it.
    ///
    /// Hover rather than always visible: on every message it would be furniture, and it is a thing
    /// you reach for occasionally. Takes up its space even when hidden, so bubbles do not shift
    /// sideways as the pointer moves down a thread.
    private func replyButton(author: String, text: String) -> some View {
        // Reply and copy, side by side: the two things people reach for on a single message.
        HStack(spacing: 4) {
            hoverAction("arrowshape.turn.up.left", help: "Reply to this message") {
                onReply?(author, text)
            }
            .opacity(onReply != nil ? 1 : 0)
            .disabled(onReply == nil)
            hoverAction(copied ? "checkmark" : "doc.on.doc", help: "Copy this message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
        }
        .opacity(hovering ? 1 : 0)
        .disabled(!hovering)
    }

    private func hoverAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(11)))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 26, height: 26)
                .background(palette.card, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }


    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .userMessage(let text):
            let parts = Reply.split(text)
            HStack(alignment: .center, spacing: Theme.Space.tight) {
                Spacer(minLength: 72)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    // What this was a reply to, inside the bubble, so the thread reads the way it
                    // was meant: this answer, about that message.
                    if let quote = parts.quote {
                        HStack(alignment: .top, spacing: Theme.Space.tight) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(palette.onPrimary.opacity(0.5))
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 1) {
                                if let author = parts.author {
                                    Text(author)
                                        .font(Theme.Typography.badge)
                                        .opacity(0.85)
                                }
                                Text(quote)
                                    .font(Theme.Typography.caption)
                                    .lineLimit(2)
                                    .opacity(0.8)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(mentionsHighlighted(parts.body))
                        .font(Theme.Typography.body)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.snug)
                .background(palette.primary, in: .rect(cornerRadius: Theme.Radius.bubble))
                .foregroundStyle(palette.onPrimary)
                // Pinned to the bubble's own left edge. In the row they sat outside the bubble's
                // 560pt maximum frame, so on a short message they floated mid-thread, far from
                // the words they act on.
                .overlay(alignment: .leading) {
                    replyButton(author: "You", text: parts.body)
                        .fixedSize()
                        .alignmentGuide(.leading) { $0[.trailing] + Theme.Space.tight }
                }
                .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .trailing)
            }

        case .messageFrom(_, let botName, let text):
            // Attributed above the bubble rather than inside it, so the attribution cannot be
            // mistaken for part of what was said. Left-aligned like anything this bot was told.
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: Theme.scaled(9)))
                    Text("Message from \(botName)")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(palette.mutedForeground)
                .padding(.leading, Theme.Size.bubbleAvatar + Theme.Space.tight)

                HStack {
                    Color.clear.frame(width: Theme.Size.bubbleAvatar, height: 1)
                    Text(text)
                        .font(Theme.Typography.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.step)
                        .padding(.vertical, Theme.Space.snug)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                                .strokeBorder(palette.border))
                        .foregroundStyle(palette.foreground)
                        .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .leading)
                    replyButton(author: botName, text: text)
                    Spacer(minLength: 72)
                }
            }

        case .assistantText(let text):
            botAligned {
                HStack(alignment: .center, spacing: Theme.Space.tight) {
                    // Cards sit above the background, which is where this palette's depth comes
                    // from — a reply looks like an object on a surface rather than text on a page.
                    FormattedReply(markdown: text)
                        .padding(.horizontal, Theme.Space.step)
                        .padding(.vertical, Theme.Space.snug)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                    replyButton(author: bot.name, text: text)
                }
            }

        case .thinking(let text):
            botAligned { ThinkingAside(text: text) }

        // Tool calls are asides, not events. A bot running `ls` is not a message, and giving it
        // the weight of one buries the reply underneath its own working.
        case .tool(let name, let arguments, let result, let failed):
            switch BupsyToolLine(tool: name, argumentsJSON: arguments) {
            case .hidden:
                EmptyView()
            case .messaged(let to, let text):
                // What this bot sent another one, shown as a message with its address on top —
                // the sender's side of "Message from", not a raw tool call.
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    HStack(spacing: 4) {
                        Text("Messaged")
                        if let recipient = model.bots.first(where: { $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                            BotFace(bot: recipient, mood: .idle, size: Theme.scaled(14))
                        }
                        Text(to).fontWeight(.medium)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.leading, Theme.Size.bubbleAvatar + Theme.Space.tight)
                    botAligned {
                        FormattedReply(markdown: text)
                            .padding(.horizontal, Theme.Space.step)
                            .padding(.vertical, Theme.Space.snug)
                            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                            .opacity(failed ? 0.5 : 1)
                    }
                }
            case .note(let text):
                Text(text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity)
            case .raw:
                botAligned {
                    ToolAside(name: name, arguments: arguments, result: result, failed: failed,
                              workingDirectory: model.workingDirectory(for: bot).path)
                }
            }

        case .approval(let approval):
            botAligned { ApprovalCard(approval: approval) }

        case .question(let question):
            botAligned { QuestionCard(question: question, bot: bot) }

        case .note(let text):
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

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
                    BotFace(bot: bot, mood: .idle, size: Theme.Size.bubbleAvatar)
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
    /// The bot's folder, so paths inside it read short.
    var workingDirectory: String? = nil
    @State private var expanded = false

    /// Refused by you (or by nobody answering) rather than broken. Drawn as a decision, not an
    /// error: an orange "failed" made a "no" the person chose look like something went wrong.
    private var declined: Bool {
        guard failed, let result = result?.lowercased() else { return false }
        return ["declined", "denied", "nobody answered", "not allowed"].contains { result.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button {
                // A path the bot touched is almost always something you want to look at, and
                // retyping it into Finder is a small, repeated annoyance.
                if let path = revealablePath, NSEvent.modifierFlags.contains(.command) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: icon)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(failed && !declined ? .orange : .secondary)
                    Text(verb)
                        .foregroundStyle(.secondary)
                    Text(PathShortener.shorten(summary, workingDirectory: workingDirectory))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if revealablePath != nil {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: Theme.scaled(9)))
                            .foregroundStyle(.tertiary)
                    }
                    if result == nil && !failed {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(Theme.Typography.caption)
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
        if declined { return "declined" }
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
        if declined { return "hand.raised.slash" }
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

    /// A real file this tool call touched, if there is one. ⌘-click reveals it in Finder.
    private var revealablePath: String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["file_path", "path", "notebook_path"] {
            if let value = object[key] as? String,
               FileManager.default.fileExists(atPath: value) { return value }
        }
        return nil
    }
}

struct ThinkingAside: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button { expanded.toggle() } label: {
                Label("Thinking", systemImage: "sparkle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(Theme.Typography.body)
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
                    .font(Theme.Typography.body)
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
        case .untrustedDirectory: "This folder isn't a git repository"
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
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var dropping = false
    @Binding var draft: String
    let bot: Bot
    let isRunning: Bool
    @Binding var replyingTo: ReplyTarget?
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        // One column for the reply bar and the field, so on a wide window the bar sits exactly
        // over the box it belongs to instead of stretching past it.
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            if let target = replyingTo { replyBar(target) }
            field
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.step)
        .frame(maxWidth: Theme.Size.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    /// Picks files and adds their paths to the message, the same as dropping them.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files for \(bot.name) to look at"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let paths = model.attach(panel.urls, to: bot)
        guard !paths.isEmpty else { return }
        draft = draft.isEmpty ? paths : draft + "\n" + paths
    }

    /// What you are replying to, pinned above the field until you send or dismiss it.
    private func replyBar(_ target: ReplyTarget) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: Theme.scaled(10)))
                .foregroundStyle(palette.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(target.author)")
                    .font(Theme.Typography.badge)
                    .foregroundStyle(palette.primary)
                Text(target.text.replacingOccurrences(of: "\n", with: " "))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.snug)
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.scaled(9), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Don't reply to this")
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.tight)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(palette.primary)
                .frame(width: 2)
                .padding(.vertical, Theme.Space.tight)
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.snug) {
            // The visible way in. Dropping files on the field always worked, but nothing said so.
            Button(action: pickFiles) {
                Image(systemName: "plus")
                    .font(.system(size: Theme.scaled(13), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 34, height: 34)
                    .background(palette.card, in: .circle)
                    .overlay(Circle().strokeBorder(palette.border))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Attach files — or drop them on the message box")
            .padding(.bottom, 5)

            TextField("Message \(bot.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .lineLimit(1...8)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.step)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.base)
                        .strokeBorder(dropping ? palette.primary : palette.border,
                                      lineWidth: dropping ? 1.5 : 1)
                }
                // Paths, not contents. The bot can open the file itself, and pasting a megabyte
                // into a prompt would spend the user's own quota to tell it something it could
                // have read.
                .dropDestination(for: URL.self) { urls, _ in
                    let paths = model.attach(urls, to: bot)
                    guard !paths.isEmpty else { return false }
                    draft = draft.isEmpty ? paths : draft + "\n" + paths
                    return true
                } isTargeted: { dropping = $0 }
                .borderBeam(hue: bot.avatarHue, active: isRunning, cornerRadius: Theme.Radius.base)
                .onSubmit(onSend)

            // A circle like the + beside the field, and visible even when there is nothing to
            // send: its "off" colour used to match the window, so the button simply vanished.
            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: Theme.scaled(13), weight: .bold))
                    .foregroundStyle(sendEnabled ? palette.onPrimary : palette.mutedForeground)
                    .frame(width: 34, height: 34)
                    .background(sendEnabled ? palette.primary : palette.card, in: .circle)
                    .overlay(Circle().strokeBorder(sendEnabled ? .clear : palette.border))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 5)
            .disabled(!sendEnabled)
            .keyboardShortcut(.return, modifiers: .command)
        }

        .background(palette.background)
    }

    private var sendEnabled: Bool {
        isRunning || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// How a tool call reads in the thread when it is one of bupsy's own, or engine plumbing.
///
/// A line like "used mcp__bupsy__message_bot" told the person nothing they could use. bupsy's tools
/// have effects people recognise — a message sent, a bot asked for — so they read as those; the
/// ones whose effect already shows as a card or a note are not repeated; and the engine's
/// ToolSearch, which only loads tool definitions, is not shown at all.
enum BupsyToolLine {
    case hidden
    case messaged(to: String, text: String)
    case note(String)
    case raw

    init(tool: String, argumentsJSON: String) {
        let arguments = (argumentsJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch tool {
        case "ToolSearch", "mcp__bupsy__ask_person", "mcp__bupsy__update_me":
            self = .hidden
        case "mcp__bupsy__message_bot":
            self = .messaged(to: arguments["to"] as? String ?? "a bot", text: arguments["text"] as? String ?? "")
        case "mcp__bupsy__create_bot":
            self = .note("Asked you to create \(arguments["name"] as? String ?? "a bot")")
        case "mcp__bupsy__list_bots":
            self = .note("Looked at who else is on the roster")
        default:
            self = .raw
        }
    }
}
