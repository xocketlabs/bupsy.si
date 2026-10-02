import BupsyKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @State private var draft = ""
    @State private var showsProfile = false

    private var thread: Thread { model.thread(for: bot.id) }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(bot: bot, showsProfile: $showsProfile)
            Divider()
            Transcript(thread: thread, bot: bot)
            Composer(
                draft: $draft,
                bot: bot,
                isRunning: thread.isRunning,
                onSend: send,
                onStop: { model.stop(bot.id) }
            )
        }
        .inspector(isPresented: $showsProfile) {
            BotProfile(bot: bot)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        model.send(prompt, to: bot)
    }
}

/// The header is the way into everything about a bot — the same gesture as tapping a name in
/// Messages. Settings that used to hide in toolbars and right-click menus live one click away,
/// on a surface you can see.
struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @Binding var showsProfile: Bool

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Button { showsProfile.toggle() } label: {
                HStack(spacing: Theme.Space.snug) {
                    BotFace(hue: bot.avatarHue, mood: mood, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(bot.name).font(.headline)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if let limits = model.thread(for: bot.id).latestLimits {
                LimitsGauge(limits: limits)
            }

            Button { showsProfile.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Everything about \(bot.name)")
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.snug)
    }

    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    /// Says what the bot is doing, or — when idle — the one thing it cannot do, since that is
    /// the fact most worth knowing before you ask it for something overnight.
    private var status: String {
        if model.isWaitingForApproval(bot.id) { return "Waiting for you" }
        if model.isRunning(bot.id) { return "Working…" }
        var parts = [bot.engine.displayName]
        if let model = bot.model { parts.append(model) }
        parts.append(bot.machineID == nil ? "on this Mac" : "on a cloud machine")
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if model.isWaitingForApproval(bot.id) { return .orange }
        return .secondary
    }
}

struct Transcript: View {
    let thread: Thread
    let bot: Bot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.snug) {
                    if thread.entries.isEmpty {
                        EmptyThread(bot: bot).padding(.top, 72)
                    }
                    ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
                        if showsDaySeparator(at: index) {
                            DaySeparator(date: entry.at)
                        }
                        Bubble(
                            entry: entry,
                            bot: bot,
                            showsAvatar: showsAvatar(at: index)
                        )
                        .id(entry.id)
                    }
                    if thread.isRunning {
                        TypingIndicator(bot: bot)
                    }
                }
                .padding(.horizontal, Theme.Space.wide)
                .padding(.vertical, Theme.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: thread.entries.count) {
                guard let last = thread.entries.last else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func showsDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            thread.entries[index].at, inSameDayAs: thread.entries[index - 1].at)
    }

    /// An avatar on every consecutive bot message is noise. One at the start of a run of them
    /// reads as a person speaking, which is the whole metaphor.
    private func showsAvatar(at index: Int) -> Bool {
        guard thread.entries[index].isFromBot else { return false }
        guard index > 0 else { return true }
        return !thread.entries[index - 1].isFromBot
    }
}

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
    let entry: TranscriptEntry
    let bot: Bot
    let showsAvatar: Bool

    var body: some View {
        switch entry.kind {
        case .userMessage(let text):
            HStack {
                Spacer(minLength: 72)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.snug)
                    .background(.tint, in: .rect(cornerRadius: Theme.Radius.bubble))
                    .foregroundStyle(.white)
                    .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .trailing)
            }

        case .assistantText(let text):
            botAligned {
                Text(markdown(text))
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.snug)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.bubble))
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

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
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
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: Theme.Radius.chip))
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
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: Theme.Radius.chip))
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
    let bot: Bot

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Color.clear.frame(width: Theme.Size.bubbleAvatar, height: 1)
            ThinkingOrbs(hue: bot.avatarHue, dotSize: 6)
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.snug)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.bubble))
            Spacer(minLength: 0)
        }
    }
}

struct EmptyThread: View {
    let bot: Bot

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            BotFace(hue: bot.avatarHue, mood: .idle, size: 64)
            Text(bot.name).font(.title3.weight(.semibold))
            if let job = bot.personaPrompt {
                Text(job)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Text("Runs \(bot.engine.displayName) under your own sign-in · asks before it acts")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Composer: View {
    @Binding var draft: String
    let bot: Bot
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.snug) {
            TextField("Message \(bot.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.snug)
                .background(.quaternary.opacity(0.4), in: .capsule)
                .borderBeam(hue: bot.avatarHue, active: isRunning, cornerRadius: 22)
                .onSubmit(onSend)

            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(sendEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.snug)
        .background(.bar)
    }

    private var sendEnabled: Bool {
        isRunning || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
