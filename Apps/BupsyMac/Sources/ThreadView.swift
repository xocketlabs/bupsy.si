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
/// Messages sit in bubbles, the way a messaging app's do, so each one reads as its own: yours on
/// the right in a pink tint, a bot's on the left in grey beside its face, its name in its colour
/// at the top of the first in a run and the time in the corner of each. Everything else the bot
/// does (tool lines, cards) sits under its words, outside the bubbles, indented past the face.
///
/// A row never reads the whole thread: what it needs from its neighbours comes in `context`,
/// built once for every row by `ThreadRowContext.rows(for:isRunning:)`.
struct Bubble: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    let entry: TranscriptEntry
    let bot: Bot
    /// Whether this entry opens with the bot's face, name and time.
    let showsAvatar: Bool
    /// What this row knows about the rows around it. Nil falls back to what the row can know
    /// alone, cheaply: whether the bot is running, and no thinking time.
    var context: ThreadRowContext?
    /// Reply to this message: who said it, and what. nil where replying makes no sense.
    var onReply: ((_ author: String, _ text: String) -> Void)?
    /// Puts queued messages back in the message box. nil where there is no box to put them in.
    var onEditQueued: ((String) -> Void)?

    @State private var hovering = false
    @State private var copied = false
    /// Which hover action has keyboard focus, so tabbing to one shows both.
    @FocusState private var focusedAction: Int?
    /// The tool call's arguments, parsed once rather than on every redraw.
    @State private var toolMemo = ToolCallMemo()

    init(entry: TranscriptEntry, bot: Bot, showsAvatar: Bool, context: ThreadRowContext? = nil,
         onReply: ((_ author: String, _ text: String) -> Void)? = nil,
         onEditQueued: ((String) -> Void)? = nil) {
        self.entry = entry
        self.bot = bot
        self.showsAvatar = showsAvatar
        self.context = context
        self.onReply = onReply
        self.onEditQueued = onEditQueued
    }

    private var row: ThreadRowContext {
        context ?? ThreadRowContext(isRunning: model.thread(for: bot.id).isRunning)
    }

    /// Hides Reply and Copy a moment after the pointer leaves, not the instant it does.
    @State private var hideActions: Task<Void, Never>?

    var body: some View {
        content
            // The whole row, gaps and all. Hover only counted over drawn content, so the
            // pointer crossing the gap from the words to Reply and Copy hid them on the way,
            // and hidden they take no clicks: they could be seen but never reached.
            .contentShape(.rect)
            .onHover { inside in
                hideActions?.cancel()
                if inside {
                    hovering = true
                } else {
                    // A short grace, so a quick move across an edge doesn't flicker them away.
                    hideActions = Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        if !Task.isCancelled { hovering = false }
                    }
                }
            }
    }

    /// Your message with each real @mention in bold, so who you addressed stands out.
    private func mentionsHighlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for piece in MentionSplitter.split(text, names: model.bots.map(\.name)) {
            switch piece {
            case .text(let run): result += AttributedString(run)
            case .mention(let name):
                var tag = AttributedString("@" + name)
                tag.font = ThreadLayout.messageFont.weight(.bold)
                result += tag
            }
        }
        return result
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
    }

    /// Reply and copy, shown beside a message while the pointer is over it or while one of them
    /// has keyboard focus.
    ///
    /// Hover rather than always visible: on every message it would be furniture, and it is a thing
    /// you reach for occasionally. Takes up its space even when hidden, so messages do not shift
    /// sideways as the pointer moves down a thread. VoiceOver gets the same two as actions on the
    /// message itself, so these are hidden from it.
    private func replyButton(author: String, text: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if onReply != nil {
                hoverAction("arrowshape.turn.up.left", label: "Reply", help: "Reply to this message", tag: 0) {
                    onReply?(author, text)
                }
            }
            hoverAction(copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy",
                        help: "Copy this message", tag: 1) {
                copy(text)
            }
        }
        .opacity(hovering || focusedAction != nil ? 1 : 0)
        // Hidden means gone: faded out they still took clicks, so a click beside a message
        // could copy it or start a reply with nothing on screen to say so.
        .allowsHitTesting(hovering || focusedAction != nil)
        .accessibilityHidden(true)
    }

    private func hoverAction(_ symbol: String, label: String, help: String, tag: Int,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(11)))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($focusedAction, equals: tag)
        .help(help)
        .accessibilityLabel(label)
    }

    /// Reply and Copy as VoiceOver actions on a whole message.
    private func messageActions<Content: View>(_ content: Content, author: String, text: String) -> some View {
        content
            .accessibilityAction(named: Text("Copy")) { copy(text) }
            .modifier(ReplyAccessibilityAction(enabled: onReply != nil) { onReply?(author, text) })
    }

    /// Your bubbles: the brand pink, light enough that text on it reads as plainly as on grey.
    private var yourBubbleFill: Color {
        palette.primary.opacity(colorScheme == .dark ? 0.26 : 0.14)
    }

    /// The time in a bubble's bottom corner.
    private func stamp(_ date: Date) -> some View {
        Text(Theme.stamp(date))
            .font(.system(size: Theme.scaled(10.5)))
            .monospacedDigit()
            .foregroundStyle(palette.mutedForeground)
    }

    /// Your words in their bubble, with what they reply to on top when they reply to something,
    /// and the time in the corner.
    private func userBubble(quote: String?, author: String?, body: String) -> some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            // What this was a reply to, inside the bubble, so the thread reads the way it was
            // meant: this answer, about that message.
            if let quote {
                HStack(alignment: .top, spacing: Theme.Space.tight) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.mutedForeground.opacity(0.5))
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        if let author {
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
            Text(mentionsHighlighted(body))
                .font(ThreadLayout.messageFont)
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
            stamp(entry.at)
        }
        .padding(.horizontal, ThreadLayout.bubblePadding.width)
        .padding(.vertical, ThreadLayout.bubblePadding.height)
        .background(yourBubbleFill, in: ChatBubbleShape(tail: .trailing))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .userMessage(let text):
            let parts = Reply.split(text)
            VStack(alignment: .trailing, spacing: Theme.Space.tight) {
                HStack(alignment: .center, spacing: Theme.Space.tight) {
                    Spacer(minLength: 96)
                    messageActions(userBubble(quote: parts.quote, author: parts.author, body: parts.body),
                                   author: "You", text: parts.body)
                    // Pinned to the bubble's own left edge, so on a short message the actions sit
                    // by the words they act on rather than floating mid-thread.
                    .overlay(alignment: .leading) {
                        replyButton(author: "You", text: parts.body)
                            .fixedSize()
                            .alignmentGuide(.leading) { $0[.trailing] + Theme.Space.tight }
                    }
                    .frame(maxWidth: 600, alignment: .trailing)
                }
                // Room for the tail, which is drawn past the bubble's edge.
                .padding(.trailing, ChatBubbleShape.tailWidth)
                // Under the last message still waiting for the bot, right-aligned with it: the
                // message is in, and will be read, just not yet.
                // While it waits: send it now, stopping the bot to read it, or take it back.
                if row.showsQueuedNote {
                    HStack(spacing: Theme.Space.tight) {
                        Text("Queued. \(bot.name) reads this when it's done.")
                            .foregroundStyle(palette.mutedForeground)
                        if let onEditQueued {
                            Button("Edit") {
                                if let text = model.takeBackQueued(bot) { onEditQueued(text) }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.mutedForeground)
                            .underline()
                            .help("Take this back to change it")
                        }
                        Button {
                            model.sendQueuedNow(bot)
                        } label: {
                            Label("Send now", systemImage: "arrow.up.circle.fill")
                                .foregroundStyle(palette.primary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop \(bot.name) and send this now")
                    }
                    .font(Theme.Typography.caption.weight(.medium))
                    .padding(.trailing, Theme.Space.tight)
                }
            }

        case .messageFrom(_, let botName, let text):
            // Attributed above the message rather than inside it, so the attribution cannot be
            // mistaken for part of what was said. Left-aligned like anything this bot was told.
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: Theme.scaled(9)))
                        .accessibilityHidden(true)
                    if let sender = model.bots.first(where: { $0.name == botName }) {
                        BotFace(bot: sender, mood: .idle, size: Theme.scaled(14))
                            .accessibilityHidden(true)
                    }
                    Text("Message from \(botName)")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(palette.mutedForeground)

                HStack(alignment: .center, spacing: Theme.Space.tight) {
                    messageActions(
                        Text(text)
                            .font(ThreadLayout.messageFont)
                            .foregroundStyle(palette.foreground)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.vertical, Theme.Space.compact)
                            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                            .frame(maxWidth: 600, alignment: .leading),
                        author: botName, text: text)
                    replyButton(author: botName, text: text)
                    Spacer(minLength: 72)
                }
            }
            .padding(.leading, ThreadLayout.gutter)

        case .assistantText(let text):
            botMessage(actionText: text) {
                FormattedReply(markdown: text)
                    // Commands in a reply run in this bot's folder, when that folder is here.
                    .environment(\.commandDirectory,
                                 bot.machineID == nil ? model.workingDirectory(for: bot) : nil)
            } trailing: {
                replyButton(author: bot.name, text: text)
            }

        case .thinking(let text):
            botAligned { ThinkingAside(text: text, duration: row.thinkingDuration) }

        // Tool calls are asides, not events. A bot running `ls` is not a message, and giving it
        // the weight of one buries the reply underneath its own working.
        case .tool(let name, let arguments, let result, let failed):
            let info = toolMemo.info(tool: name, arguments: arguments)
            switch info.line {
            case .hidden:
                EmptyView()
            case .messaged(let to, let text):
                // What this bot sent another one, shown as a message with its address on top:
                // the sender's side of "Message from", not a raw tool call.
                botAligned {
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        HStack(spacing: Theme.Space.xs) {
                            Text("Messaged")
                            if let recipient = model.bots.first(where: { $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                                BotFace(bot: recipient, mood: .idle, size: Theme.scaled(14))
                                    .accessibilityHidden(true)
                            }
                            Text(to).fontWeight(.medium)
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        FormattedReply(markdown: text)
                            .padding(.horizontal, Theme.Space.gutter)
                            .padding(.vertical, Theme.Space.compact)
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
                              live: row.isRunning,
                              info: info)
                }
            }

        case .approval(let approval):
            botAligned {
                ApprovalCard(approval: approval, owner: bot, showsShortcuts: row.bindsApprovalShortcuts)
            }

        case .question(let question):
            botAligned { QuestionCard(question: question, bot: bot) }

        case .note(let text):
            // The queued note is drawn under the message it is about, when the row context
            // says where that is.
            if !row.isQueuedNote {
                Text(ThreadRowContext.holdsQueuedNote(entry.kind)
                     ? "Queued. \(bot.name) reads this when it's done." : text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity,
                           alignment: ThreadRowContext.holdsQueuedNote(entry.kind) ? .trailing : .center)
                    .padding(.vertical, Theme.Space.hairline)
            }

        case .failure(let failure):
            if FailureNotice.isRosterNote(failure) {
                // Not a run that broke: bupsy telling you a message had nowhere to go. A note,
                // with nothing to retry.
                Text(failure.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.hairline)
            } else {
                botAligned { FailureNotice(failure: failure, bot: bot, entryID: entry.id) }
            }

        case .finished:
            EmptyView()
        }
    }

    /// A bot's words: its face, then its name and the time, then what it said. A continuation
    /// keeps the indent without repeating the header.
    private func botMessage<Words: View, Trailing: View>(
        actionText: String,
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
            // The name beside it says who this is. Read aloud, the face only said "idle".
            .accessibilityHidden(true)
            messageActions(
                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        // Who is speaking, once per run, in their colour, as a group chat does.
                        if showsAvatar {
                            Text(bot.name)
                                .font(Theme.Typography.caption.weight(.semibold))
                                .foregroundStyle(BotFace.colour(of: bot))
                        }
                        words()
                    }
                    stamp(entry.at)
                }
                .padding(.horizontal, ThreadLayout.bubblePadding.width)
                .padding(.vertical, ThreadLayout.bubblePadding.height)
                // The fill before the width limit: a limit applied first would stretch every
                // bubble to it, and a "Hi" would sit in a box the width of a paragraph.
                .background(palette.card, in: ChatBubbleShape(tail: showsAvatar ? .leading : .none))
                .frame(maxWidth: 720, alignment: .leading)
                .accessibilityElement(children: .combine),
                author: bot.name, text: actionText)
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

/// Adds a VoiceOver "Reply" action only where replying is offered.
private struct ReplyAccessibilityAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: Text("Reply"), action)
        } else {
            content
        }
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
    /// The arguments, read once. Worked out here when the caller has not already.
    let info: ToolCallInfo
    @State private var expanded = false
    @State private var hovering = false
    /// When the result came in, seen while this line was on screen. Results carry no time of
    /// their own, so a line that arrived already finished (a reopened thread) has none, and
    /// shows no duration rather than a made-up one.
    @State private var finishedAt: Date?
    /// A real file this tool call touched, if there is one. Cmd-click reveals it in Finder.
    /// Checked on disk once when the line appears, never while drawing.
    @State private var revealablePath: String?

    init(name: String, arguments: String, result: String?, failed: Bool,
         workingDirectory: String? = nil, startedAt: Date? = nil, live: Bool = false,
         info: ToolCallInfo? = nil) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.failed = failed
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.live = live
        self.info = info ?? ToolCallInfo(tool: name, argumentsJSON: arguments)
    }

    /// Refused by you (or by nobody answering) rather than broken. Drawn as a decision, not an
    /// error: a red "failed" made a "no" the person chose look like something went wrong.
    private var declined: Bool {
        guard failed, let result = result?.lowercased() else { return false }
        return ["declined", "denied", "nobody answered", "not allowed", "stopped before"]
            .contains { result.contains($0) }
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
                .padding(.vertical, Theme.Space.xs)
                .padding(.leading, Theme.Space.tight)
                .padding(.trailing, Theme.Space.snug)
                .background(hovering ? palette.card : .clear, in: .rect(cornerRadius: Theme.Radius.sm))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .padding(.leading, -Theme.Space.tight)
            .onHover { hovering = $0 }
            .onChange(of: running) { wasRunning, isRunningNow in
                if wasRunning && !isRunningNow && finishedAt == nil { finishedAt = Date() }
            }
            .task(id: info.pathCandidates) {
                let candidates = info.pathCandidates
                revealablePath = candidates.first { FileManager.default.fileExists(atPath: $0) }
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

    private var summary: String { info.summary }
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
                .padding(.vertical, Theme.Space.xs)
                .padding(.leading, Theme.Space.tight)
                .padding(.trailing, Theme.Space.snug)
                .background(hovering ? palette.card : .clear, in: .rect(cornerRadius: Theme.Radius.sm))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .padding(.leading, -Theme.Space.tight)
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
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Theme.scaled(15)))
                        .foregroundStyle(tone)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
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
                if let hint {
                    Text(hint)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
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
        .padding(Theme.Space.hairline)
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
            } else if failure.kind == .untrustedDirectory {
                // Retrying in the same folder fails the same way. A different folder is the fix.
                Button("Choose folder") { model.chooseWorkdir(for: bot) }
                    .buttonStyle(ThreadButtonStyle(kind: .secondary))
                    .help("Pick the folder \(bot.name) works in")
            } else if isRetryable || signedInNow == true,
                      model.retryPrompt(afterFailure: entryID, for: bot) != nil {
                Button("Retry") { model.retry(afterFailure: entryID, for: bot) }
                    .buttonStyle(ThreadButtonStyle(kind: .secondary))
                    .help("Send your last message to \(bot.name) again")
            }
        }
    }

    /// One line on what to do when there is no button for it, or on why the button is the fix.
    private var hint: String? {
        switch failure.kind {
        case .untrustedDirectory:
            let engine = bot?.engine.displayName ?? "This engine"
            return "\(engine) only works inside a git repository, so its changes can be undone. Choose a folder that is one, or run git init in this one."
        case .rateLimited:
            // A retry now would hit the same limit, so there is no button: only when to come back.
            guard let resets = resetTime else { return "Try again later." }
            let calendar = Calendar.current
            let when = calendar.isDateInToday(resets)
                ? resets.formatted(date: .omitted, time: .shortened)
                : resets.formatted(.dateTime.weekday(.wide).hour().minute())
            return "Your limit resets at \(when). Try again then."
        default:
            return nil
        }
    }

    /// When the window that ran out resets, from the engine's last report for this bot.
    private var resetTime: Date? {
        guard let bot, let limits = model.thread(for: bot.id).latestLimits else { return nil }
        guard let resets = limits.tightest?.window.resetsAt, resets > Date() else { return nil }
        return resets
    }

    /// Not a run failing but bupsy reporting that a bot's message or request had nowhere to go
    /// ("No bot named ..."). Drawn as a note: there is no run to retry.
    static func isRosterNote(_ failure: EngineFailure) -> Bool {
        guard failure.kind == .unknown else { return false }
        return failure.message.hasPrefix("No bot named") || failure.message.contains("but there already is one")
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
    /// that needs the folder changed, and retrying would only fail again. Not a usage limit
    /// either, until it resets.
    private var isRetryable: Bool {
        switch failure.kind {
        case .launchFailed, .protocolError, .nonZeroExit, .cancelled, .unknown: true
        // A limit is not past until it resets, so a retry now fails the same way.
        case .notSignedIn, .binaryNotFound, .untrustedDirectory, .rateLimited: false
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

/// The message box: attach on the left, send on the right, one rounded box.
///
/// While the bot runs, the placeholder says your words will wait, a stop button joins send, the
/// border breathes pink, and the bot itself peeks over the top edge so you can see who is busy
/// without looking up.
///
/// Cmd Return only ever sends: while the bot runs, what you send waits for it. Stopping is its
/// own button and its own shortcut, Cmd period, so adding a follow-up can never end the run.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropping = false
    @FocusState private var focused: Bool
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

    private let corner: CGFloat = Theme.Radius.xl

    var body: some View {
        // One column for the reply bar and the box, so on a wide window the bar sits exactly
        // over the box it belongs to instead of stretching past it.
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            if let target = replyingTo { replyBar(target) }
            field
        }
        // Reply means "I'm about to type": put the cursor in the box rather than leaving the
        // person to click it after choosing Reply.
        .onChange(of: replyingTo) { _, target in
            if target != nil { focused = true }
        }
        .padding(.horizontal, Theme.Space.pageSide)
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
                    .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Don't reply to this (Esc)")
            .accessibilityLabel("Cancel reply")
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
                    .frame(width: Theme.Size.controlMd, height: Theme.Size.controlMd)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Attach files, or drop them on the message box")
            .accessibilityLabel("Attach files")

            TextField(isRunning ? "Add more. \(bot.name) reads it when done" : "Message \(bot.name)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ThreadLayout.messageFont)
                .foregroundStyle(palette.foreground)
                .lineLimit(1...8)
                .padding(.vertical, Theme.Space.snug)
                .frame(minHeight: Theme.Size.controlMd)
                .focused($focused)
                .onSubmit(send)
                // Esc lets go of the message you were replying to, the way it closes anything
                // else you opened. Left alone when there is nothing to cancel.
                .onKeyPress(.escape) {
                    guard replyingTo != nil else { return .ignored }
                    replyingTo = nil
                    return .handled
                }

            // A grey stop square while the bot runs, with its own shortcut.
            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: Theme.scaled(10), weight: .bold))
                        .foregroundStyle(palette.foreground)
                        .frame(width: Theme.Size.controlMd, height: Theme.Size.controlMd)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop \(bot.name) (Cmd .)")
                .accessibilityLabel("Stop \(bot.name)")
            }

            // Pink while there is something to send, a pale pink while there is not. While the
            // bot runs it shows only once you have typed something, which then waits for it.
            if !isRunning || sendEnabled {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Theme.scaled(13), weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: Theme.Size.controlMd, height: Theme.Size.controlMd)
                        .background(palette.primary.opacity(sendEnabled ? 1 : 0.45),
                                    in: .rect(cornerRadius: Theme.Radius.control))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .keyboardShortcut(.return, modifiers: .command)
                .help(isRunning ? "Send. \(bot.name) reads it when done (Cmd Return), "
                      + "or now, stopping it (Shift Cmd Return)" : "Send (Cmd Return)")
                .accessibilityLabel(isRunning ? "Send. \(bot.name) reads it when done" : "Send")
                // Send now: queue it and stop the bot so it reads it at once.
                .background {
                    Button("Send now") {
                        guard isRunning, sendEnabled else { return }
                        send()
                        model.sendQueuedNow(bot)
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .hidden()
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(Theme.Space.snug)
        .background(palette.background, in: .rect(cornerRadius: corner))
        .overlay {
            // The border says where your typing goes: darker while the box has focus, pink
            // while a file is over it.
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(dropping ? palette.primary
                                       : (focused ? palette.mutedForeground.opacity(0.7) : palette.border),
                              lineWidth: dropping || focused ? 1.5 : 1)
        }
        // Paths, not contents. The bot can open the file itself, and pasting a megabyte into a
        // prompt would spend the user's own quota to tell it something it could have read.
        .dropDestination(for: URL.self) { urls, _ in
            let paths = model.attach(urls, to: bot)
            guard !paths.isEmpty else { return false }
            draft = draft.isEmpty ? paths : draft + "\n" + paths
            return true
        } isTargeted: { dropping = $0 }
        // Always applied, shown by `active`: swapping the modifier in and out changed the box's
        // identity and took focus out of the field at every run start and end.
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
        // Under Reduce Motion the peek simply appears and goes, with no slide.
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: isRunning)
    }

    /// Sends only real words. A draft of spaces and newlines stays put.
    private func send() {
        guard sendEnabled else { return }
        onSend()
    }

    private var sendEnabled: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// How a tool call reads in the thread when it is one of bupsy's own, or engine plumbing.
///
/// A line like "used mcp__bupsy__message_bot" told the person nothing they could use. bupsy's tools
/// have effects people recognise (a message sent, a bot asked for), so they read as those; the
/// ones whose effect already shows as a card or a note are not repeated; and the engine's
/// ToolSearch, which only loads tool definitions, is not shown at all.
enum BupsyToolLine: Equatable, Sendable {
    case hidden
    case messaged(to: String, text: String)
    case note(String)
    case raw

    init(tool: String, argumentsJSON: String) {
        self.init(tool: tool, arguments: ToolCallInfo.object(argumentsJSON) ?? [:])
    }

    /// From arguments already parsed, so a row that needs more than the line reads them once.
    init(tool: String, arguments: [String: Any]) {
        switch tool {
        // The note bupsy writes when it applies the move says what moved, and what did not.
        case "ToolSearch", "mcp__bupsy__ask_person", "mcp__bupsy__update_me", "mcp__bupsy__move_bots":
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
