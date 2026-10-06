import AppKit
import BupsyKit
import SwiftUI

// The page shell moved to BotPage. These are the pieces a transcript is made of.

struct DaySeparator: View {
    @Environment(\.palette) private var palette
    let date: Date

    var body: some View {
        Text(Theme.daySeparator(date))
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.tight)
    }
}

/// One entry in a transcript.
///
/// Yours sit on the right in a grey bubble. A bot's reply has no bubble at all, just its face,
/// its name and the time, so a long answer reads like a document rather than a stack of balloons.
/// Everything else the bot does (tool lines, cards) sits under its words, indented past the face.
struct Bubble: View {
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var model
    let entry: TranscriptEntry
    let bot: Bot
    /// Whether this entry opens with the bot's face, name and time.
    let showsAvatar: Bool
    /// Reply to this message: who said it, and what. nil where replying makes no sense.
    var onReply: ((_ author: String, _ text: String) -> Void)?

    @State private var hovering = false
    @State private var copied = false

    init(entry: TranscriptEntry, bot: Bot, showsAvatar: Bool,
         onReply: ((_ author: String, _ text: String) -> Void)? = nil) {
        self.entry = entry
        self.bot = bot
        self.showsAvatar = showsAvatar
        self.onReply = onReply
    }

    var body: some View {
        content.onHover { hovering = $0 }
    }

    /// Your message with each real @mention in bold, so who you addressed stands out.
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

    /// Reply and copy, shown beside a message while the pointer is over it.
    ///
    /// Hover rather than always visible: on every message it would be furniture, and it is a thing
    /// you reach for occasionally. Takes up its space even when hidden, so messages do not shift
    /// sideways as the pointer moves down a thread.
    private func replyButton(author: String, text: String) -> some View {
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
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
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
                Spacer(minLength: 96)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    // What this was a reply to, inside the bubble, so the thread reads the way it
                    // was meant: this answer, about that message.
                    if let quote = parts.quote {
                        HStack(alignment: .top, spacing: Theme.Space.tight) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(palette.mutedForeground.opacity(0.5))
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 1) {
                                if let author = parts.author {
                                    Text(author)
                                        .font(Theme.Typography.badge)
                                        .foregroundStyle(palette.foreground)
                                }
                                Text(quote)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(palette.mutedForeground)
                                    .lineLimit(2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(mentionsHighlighted(parts.body))
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 10)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                // Pinned to the bubble's own left edge, so on a short message the actions sit by
                // the words they act on rather than floating mid-thread.
                .overlay(alignment: .leading) {
                    replyButton(author: "You", text: parts.body)
                        .fixedSize()
                        .alignmentGuide(.leading) { $0[.trailing] + Theme.Space.tight }
                }
                .frame(maxWidth: 600, alignment: .trailing)
            }

        case .messageFrom(_, let botName, let text):
            // Attributed above the message rather than inside it, so the attribution cannot be
            // mistaken for part of what was said. Left-aligned like anything this bot was told.
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: Theme.scaled(9)))
                    if let sender = model.bots.first(where: { $0.name == botName }) {
                        BotFace(bot: sender, mood: .idle, size: Theme.scaled(14))
                    }
                    Text("Message from \(botName)")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(palette.mutedForeground)

                HStack(alignment: .center, spacing: Theme.Space.tight) {
                    Text(text)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.vertical, 10)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                        .frame(maxWidth: 600, alignment: .leading)
                    replyButton(author: botName, text: text)
                    Spacer(minLength: 72)
                }
            }
            .padding(.leading, ThreadLayout.gutter)

        case .assistantText(let text):
            botMessage {
                FormattedReply(markdown: text)
            } trailing: {
                replyButton(author: bot.name, text: text)
            }

        case .thinking(let text):
            botAligned { ThinkingAside(text: text, duration: thinkingDuration) }

        // Tool calls are asides, not events. A bot running `ls` is not a message, and giving it
        // the weight of one buries the reply underneath its own working.
        case .tool(let name, let arguments, let result, let failed):
            switch BupsyToolLine(tool: name, argumentsJSON: arguments) {
            case .hidden:
                EmptyView()
            case .messaged(let to, let text):
                // What this bot sent another one, shown as a message with its address on top:
                // the sender's side of "Message from", not a raw tool call.
                botAligned {
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
                        FormattedReply(markdown: text)
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.vertical, 10)
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
                              workingDirectory: model.workingDirectory(for: bot).path,
                              startedAt: entry.at,
                              live: model.thread(for: bot.id).isRunning)
                }
            }

        case .approval(let approval):
            botAligned { ApprovalCard(approval: approval, owner: bot) }

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
            botAligned { FailureNotice(failure: failure, bot: bot, entryID: entry.id) }

        case .finished:
            EmptyView()
        }
    }

    /// How long the bot thought before its reasoning arrived, measured from the message that
    /// started the turn to the moment the reasoning came in. Engines hand reasoning over whole,
    /// so the gap before it is the thinking time; that start is only known when the reasoning
    /// opens a turn. Anywhere else (after a tool line, say) the start is not recorded, and no
    /// duration is shown rather than a guessed one.
    private var thinkingDuration: String? {
        let entries = model.thread(for: bot.id).entries
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return nil }
        switch entries[index - 1].kind {
        case .userMessage, .messageFrom:
            return ChatDuration.whole(entry.at.timeIntervalSince(entries[index - 1].at))
        default:
            return nil
        }
    }

    /// A bot's words: its face, then its name and the time, then what it said. A continuation
    /// keeps the indent without repeating the header.
    private func botMessage<Words: View, Trailing: View>(
        @ViewBuilder _ words: () -> Words,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: ThreadLayout.avatarGap) {
            Group {
                if showsAvatar {
                    BotFace(bot: bot, mood: .idle, size: ThreadLayout.avatar)
                } else {
                    Color.clear.frame(width: ThreadLayout.avatar, height: 1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsAvatar {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                        Text(bot.name)
                            .font(Theme.Typography.body.weight(.medium))
                            .foregroundStyle(palette.foreground)
                        Text(Theme.stamp(entry.at))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                    }
                }
                words()
            }
            .frame(maxWidth: 720, alignment: .leading)
            trailing()
            Spacer(minLength: Theme.Space.section)
        }
    }

    /// Something the bot did rather than said: indented under its words, never given a face.
    private func botAligned<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ThreadLayout.gutter)
    }
}

/// One thing a bot did, as a quiet line: an icon, the verb in plain words, the target in mono.
///
/// Running shows a spinner, failed adds a red word, declined strikes the target through. Click
/// it for the arguments and output. Tool lines are the bot showing its work, so they stay grey.
struct ToolAside: View {
    @Environment(\.palette) private var palette
    let name: String
    let arguments: String
    let result: String?
    let failed: Bool
    /// The bot's folder, so paths inside it read short.
    var workingDirectory: String?
    /// When the call arrived. With `live`, a running line counts up from it.
    var startedAt: Date?
    /// Whether the run this line belongs to is still going. A line left without a result by a
    /// run that ended is not "running for three days", so it shows no time at all.
    var live: Bool
    @State private var expanded = false
    @State private var hovering = false
    /// When the result came in, seen while this line was on screen. Results carry no time of
    /// their own, so a line that arrived already finished (a reopened thread) has none, and
    /// shows no duration rather than a made-up one.
    @State private var finishedAt: Date?

    init(name: String, arguments: String, result: String?, failed: Bool,
         workingDirectory: String? = nil, startedAt: Date? = nil, live: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.failed = failed
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.live = live
    }

    /// Refused by you (or by nobody answering) rather than broken. Drawn as a decision, not an
    /// error: a red "failed" made a "no" the person chose look like something went wrong.
    private var declined: Bool {
        guard failed, let result = result?.lowercased() else { return false }
        return ["declined", "denied", "nobody answered", "not allowed"].contains { result.contains($0) }
    }

    private var running: Bool { result == nil && !failed }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button {
                // A path the bot touched is almost always something you want to look at, and
                // retyping it into Finder is a small, repeated annoyance. Cmd-click reveals it.
                if let path = revealablePath, NSEvent.modifierFlags.contains(.command) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    Group {
                        if running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: Theme.scaled(11)))
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(verb)
                    Text(PathShortener.shorten(summary, workingDirectory: workingDirectory))
                        .strikethrough(declined)
                        .font(ThreadLayout.monoFont)
                        .foregroundStyle(declined ? palette.mutedForeground : palette.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if failed && !declined {
                        Text("failed").foregroundStyle(palette.destructiveText)
                    }
                    timing
                    if revealablePath != nil && hovering {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: Theme.scaled(9)))
                            .help("Cmd-click to show in Finder")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(8), weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .padding(.trailing, Theme.Space.snug)
                .background(hovering ? palette.card : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hovering = $0 }
            .onChange(of: running) { wasRunning, isRunningNow in
                if wasRunning && !isRunningNow && finishedAt == nil { finishedAt = Date() }
            }

            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    Text(arguments)
                        .font(.system(size: Theme.scaled(10.5), design: .monospaced))
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result {
                        Rectangle().fill(palette.border).frame(height: 1)
                        Text(result)
                            .font(.system(size: Theme.scaled(10.5), design: .monospaced))
                            .foregroundStyle(palette.mutedForeground)
                            .textSelection(.enabled)
                            .lineLimit(24)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.step)
                .frame(maxWidth: ThreadLayout.cardMaxWidth, alignment: .leading)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            }
        }
    }

    /// "0.1s" once finished, a ticking "4s" while running, nothing when the time is not known.
    @ViewBuilder
    private var timing: some View {
        if running {
            if live, let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ChatDuration.ticking(context.date.timeIntervalSince(startedAt)))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .monospacedDigit()
                }
            }
        } else if let startedAt, let finishedAt {
            Text(ChatDuration.label(finishedAt.timeIntervalSince(startedAt)))
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .monospacedDigit()
        }
    }

    private var verb: String {
        switch name {
        case "Bash", "shell": return "ran"
        case "Read": return "read"
        case "Write", "Edit", "MultiEdit", "edit": return "edited"
        case "WebFetch", "WebSearch": return "looked up"
        case "Grep", "Glob": return "searched"
        default: return name.hasPrefix("mcp__") ? "used" : name.lowercased()
        }
    }

    private var icon: String {
        if declined { return "hand.raised" }
        switch name {
        case "Bash", "shell": return "terminal"
        case "Read": return "doc.text"
        case "Write", "Edit", "MultiEdit", "edit": return "square.and.pencil"
        case "WebFetch", "WebSearch": return "globe"
        case "Grep", "Glob": return "magnifyingglass"
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

    /// A real file this tool call touched, if there is one. Cmd-click reveals it in Finder.
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

/// The bot's reasoning, collapsed to one line. Opening it shows the text in a grey well.
struct ThinkingAside: View {
    @Environment(\.palette) private var palette
    let text: String
    /// How long it thought, when that is known ("8s").
    var duration: String?
    @State private var expanded = false
    @State private var hovering = false

    init(text: String, duration: String? = nil) {
        self.text = text
        self.duration = duration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "sparkle")
                        .font(.system(size: Theme.scaled(11)))
                        .frame(width: 16, height: 16)
                    Text("Thinking")
                    if let duration {
                        Text(duration)
                            .font(Theme.Typography.caption)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(8), weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .padding(.trailing, Theme.Space.snug)
                .background(hovering ? palette.card : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hovering = $0 }

            if expanded {
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.step)
                    .frame(maxWidth: ThreadLayout.cardMaxWidth, alignment: .leading)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            }
        }
    }
}

/// When a run fails: the bot's dizzy face, what happened in plain words, and how to fix it.
///
/// Amber for things that fix themselves or that you fix (limits, sign-in), red for a run that
/// broke. Never an apology; always the fix.
struct FailureNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let failure: EngineFailure
    var bot: Bot?
    /// The transcript entry this card draws. With a bot, it is what lets the card offer its one
    /// fix: Retry for a run that broke, Check sign-in for an engine that cannot run.
    var entryID: UUID?
    @State private var checking = false
    /// The engine's answer to the last sign-in check: nil before one, true when it can run now.
    @State private var signedInNow: Bool?

    init(failure: EngineFailure, bot: Bot? = nil, entryID: UUID? = nil) {
        self.failure = failure
        self.bot = bot
        self.entryID = entryID
    }

    var body: some View {
        let isDark = colorScheme == .dark
        HStack(alignment: .center, spacing: Theme.Space.step) {
            Group {
                if let bot {
                    BotFace(bot: bot, mood: failure.kind == .cancelled ? .idle : .failed, size: 36)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Theme.scaled(15)))
                        .foregroundStyle(tone)
                        .frame(width: 36, height: 36)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.scaled(13.5), weight: .medium))
                    .foregroundStyle(palette.foreground)
                Text(failure.message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let verdict = signInVerdict {
                    Text(verdict)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(signedInNow == true ? palette.success : palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(.vertical, Theme.Space.step)
        .padding(.leading, Theme.Space.step)
        .padding(.trailing, Theme.Space.gutter)
        .background(isDark ? palette.card : palette.background, in: .rect(cornerRadius: Theme.Radius.base))
        .padding(2)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                    .fill(isDark ? palette.sidebar : palette.background)
                RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                    .fill(tone.opacity(isWarning ? 0.14 : 0.12))
            }
        }
        .frame(maxWidth: ThreadLayout.cardMaxWidth, alignment: .leading)
    }

    /// At most one action, and only one that does exactly what it says.
    @ViewBuilder
    private var action: some View {
        if let bot, let entryID {
            if needsSignIn && signedInNow != true {
                Button {
                    check(bot)
                } label: {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check sign-in")
                    }
                }
                .buttonStyle(ThreadButtonStyle(kind: .secondary))
                .disabled(checking)
                .help("Ask \(bot.engine.displayName) whether it is signed in now")
            } else if isRetryable || signedInNow == true,
                      model.retryPrompt(afterFailure: entryID, for: bot) != nil {
                Button("Retry") { model.retry(afterFailure: entryID, for: bot) }
                    .buttonStyle(ThreadButtonStyle(kind: .secondary))
                    .help("Send your last message to \(bot.name) again")
            }
        }
    }

    /// The engine cannot run at all here, so sending again would fail the same way. These get a
    /// sign-in check instead of a retry.
    private var needsSignIn: Bool {
        switch failure.kind {
        case .notSignedIn, .binaryNotFound: true
        default: false
        }
    }

    /// Failures a second attempt can get past. Not a folder the engine refuses to work in:
    /// that needs the folder changed, and retrying would only fail again.
    private var isRetryable: Bool {
        switch failure.kind {
        case .launchFailed, .protocolError, .nonZeroExit, .rateLimited, .cancelled, .unknown: true
        case .notSignedIn, .binaryNotFound, .untrustedDirectory: false
        }
    }

    /// What the last check found, in words. Nothing before a check.
    private var signInVerdict: String? {
        guard let signedInNow, let bot else { return nil }
        if signedInNow { return "\(bot.engine.displayName) is signed in now." }
        let command = bot.engine == .codex ? "codex login" : "claude"
        return "Still can't run \(bot.engine.displayName). Run \(command) in Terminal and sign in, then check again."
    }

    private func check(_ bot: Bot) {
        checking = true
        Task { @MainActor in
            signedInNow = await model.recheckSignIn(for: bot)
            checking = false
        }
    }

    private var isWarning: Bool {
        switch failure.kind {
        case .notSignedIn, .rateLimited, .binaryNotFound, .untrustedDirectory: true
        default: false
        }
    }

    private var tone: Color {
        if failure.kind == .cancelled { return palette.mutedForeground }
        return isWarning ? palette.warning : palette.destructive
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
    let bot: Bot

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            ThinkingOrbs(hue: bot.avatarHue, dotSize: 6)
            Spacer(minLength: 0)
        }
        .padding(.leading, ThreadLayout.gutter)
    }
}

/// The message box: attach on the left, send on the right, one rounded box.
///
/// While the bot runs, the placeholder says your words will wait, send becomes stop, the border
/// breathes pink, and the bot itself peeks over the top edge so you can see who is busy without
/// looking up.
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

    init(draft: Binding<String>, bot: Bot, isRunning: Bool, replyingTo: Binding<ReplyTarget?>,
         onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        self._draft = draft
        self.bot = bot
        self.isRunning = isRunning
        self._replyingTo = replyingTo
        self.onSend = onSend
        self.onStop = onStop
    }

    private let corner: CGFloat = 14

    var body: some View {
        // One column for the reply bar and the box, so on a wide window the bar sits exactly
        // over the box it belongs to instead of stretching past it.
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            if let target = replyingTo { replyBar(target) }
            field
        }
        .padding(.horizontal, 32)
        .padding(.top, Theme.Space.snug)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: ThreadLayout.columnMaxWidth)
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

    /// What you are replying to, pinned above the box until you send or dismiss it.
    private func replyBar(_ target: ReplyTarget) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: Theme.scaled(10)))
                .foregroundStyle(palette.mutedForeground)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(target.author)")
                    .font(Theme.Typography.badge)
                    .foregroundStyle(palette.foreground)
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
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.snug) {
            // The visible way in. Dropping files on the box always worked, but nothing said so.
            Button(action: pickFiles) {
                Image(systemName: "plus")
                    .font(.system(size: Theme.scaled(14), weight: .regular))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Attach files, or drop them on the message box")

            TextField(isRunning ? "Add more. \(bot.name) reads it when done" : "Message \(bot.name)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ThreadLayout.messageFont)
                .foregroundStyle(palette.foreground)
                .lineLimit(1...8)
                .padding(.vertical, Theme.Space.snug)
                .frame(minHeight: 36)
                .onSubmit(onSend)

            // Pink while there is something to send, a pale pink while there is not, and a grey
            // stop square while the bot runs.
            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: Theme.scaled(isRunning ? 10 : 13), weight: .bold))
                    .foregroundStyle(isRunning ? palette.foreground : Color.white)
                    .frame(width: 36, height: 36)
                    .background(isRunning ? palette.card : palette.primary.opacity(sendEnabled ? 1 : 0.45),
                                in: .rect(cornerRadius: Theme.Radius.control))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help(isRunning ? "Stop \(bot.name)" : "Send")
        }
        .padding(Theme.Space.snug)
        .background(palette.background, in: .rect(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(dropping ? palette.primary : palette.border,
                              lineWidth: dropping ? 1.5 : 1)
        }
        // Paths, not contents. The bot can open the file itself, and pasting a megabyte into a
        // prompt would spend the user's own quota to tell it something it could have read.
        .dropDestination(for: URL.self) { urls, _ in
            let paths = model.attach(urls, to: bot)
            guard !paths.isEmpty else { return false }
            draft = draft.isEmpty ? paths : draft + "\n" + paths
            return true
        } isTargeted: { dropping = $0 }
        .borderBeam(hue: bot.avatarHue, active: isRunning, cornerRadius: corner)
        // Right of centre, just left of the stop button: the bot holding on to the box it is
        // busy behind.
        .overlay(alignment: .topTrailing) {
            if isRunning {
                ThreadComposerPeek(bot: bot)
                    .padding(.trailing, 64)
                    .offset(y: -30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: isRunning)
    }

    private var sendEnabled: Bool {
        isRunning || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// How a tool call reads in the thread when it is one of bupsy's own, or engine plumbing.
///
/// A line like "used mcp__bupsy__message_bot" told the person nothing they could use. bupsy's tools
/// have effects people recognise (a message sent, a bot asked for), so they read as those; the
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
