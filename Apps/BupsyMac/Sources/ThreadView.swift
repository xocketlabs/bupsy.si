import BupsyKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @State private var draft = ""
    @State private var showsRoutines = false

    private var thread: Thread { model.thread(for: bot.id) }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptList(thread: thread, bot: bot)
            Divider()
            Composer(
                draft: $draft,
                isRunning: thread.isRunning,
                hue: bot.avatarHue,
                onSend: send,
                onStop: { model.stop(bot.id) }
            )
        }
        .navigationTitle(bot.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                if let limits = thread.latestLimits { LimitsGauge(limits: limits) }
            }
            ToolbarItem {
                Button { showsRoutines = true } label: {
                    Label("Routines", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Jobs \(bot.name) does on a schedule")
            }
        }
        .sheet(isPresented: $showsRoutines) { RoutinesSheet(bot: bot) }
    }

    /// Says plainly what the bot can and cannot do unattended, rather than hiding it in settings.
    private var subtitle: String {
        var parts = [bot.engine.displayName, bot.scheduleTier.label]
        if let caveat = bot.scheduleTier.caveat { parts.append(caveat) }
        return parts.joined(separator: " · ")
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        model.send(prompt, to: bot)
    }
}

struct TranscriptList: View {
    let thread: Thread
    let bot: Bot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if thread.entries.isEmpty {
                        EmptyThread(bot: bot)
                            .padding(.top, 60)
                    }
                    ForEach(thread.entries) { entry in
                        EntryView(entry: entry, hue: bot.avatarHue, bot: bot)
                            .id(entry.id)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: thread.entries.count) {
                guard let last = thread.entries.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct EmptyThread: View {
    let bot: Bot

    var body: some View {
        VStack(spacing: 8) {
            BotFace(hue: bot.avatarHue, mood: .idle, size: 52)
            Text(bot.name).font(.headline)
            Text("Runs \(bot.engine.displayName) on this Mac, under your own sign-in.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Starts fully gated — nothing outside a read runs without asking.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EntryView: View {
    let entry: TranscriptEntry
    let hue: Double
    let bot: Bot

    var body: some View {
        switch entry.kind {
        case .userMessage(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.14), in: .rect(cornerRadius: 12))
            }

        case .assistantText(let text):
            Text(markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)

        case .thinking(let text):
            DisclosureGroup {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640, alignment: .leading)

        case .tool(let name, let arguments, let result, let failed):
            ToolChip(name: name, arguments: arguments, result: result, failed: failed)

        case .approval(let approval):
            ApprovalCard(approval: approval)

        case .limits(let limits):
            LimitsGauge(limits: limits)

        case .failure(let failure):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: failure.kind)).fontWeight(.medium)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(10)
            .frame(maxWidth: 640, alignment: .leading)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))

        case .finished(let outcome):
            if let summary = outcome.summary, !summary.isEmpty {
                EmptyView()
            } else {
                EmptyView()
            }
        }
    }

    /// Engine failures are the errors users will actually hit, so each gets a sentence they can
    /// act on instead of a raw message.
    private func title(for kind: EngineFailure.Kind) -> String {
        switch kind {
        case .notSignedIn: "Not signed in"
        case .rateLimited: "Rate limited"
        case .binaryNotFound: "Engine not found on this Mac"
        case .launchFailed: "Could not start the engine"
        case .protocolError: "Unexpected engine behaviour"
        case .nonZeroExit: "The engine exited with an error"
        case .cancelled: "Stopped"
        case .unknown: "Something went wrong"
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A tool call waiting on the user.
///
/// Deliberately a card in the transcript rather than a modal: a modal interrupts whatever you
/// were doing and loses the context of what the bot was in the middle of. It stays visible after
/// a decision because what you allowed is part of the record, not a dialog that served its
/// purpose and went away.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    @State private var showsDetail = false

    private var bot: Bot? { model.selectedBot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.medium)
                    Text(approval.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // The command itself, in full. An approval you cannot read is not an approval.
            Text(approval.summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.5), in: .rect(cornerRadius: 6))

            if showsDetail {
                Text(approval.inputJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if approval.decided == nil {
                HStack(spacing: 8) {
                    Button("Allow") { decide(true) }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("Deny") { decide(false) }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button(showsDetail ? "Less" : "Details") { showsDetail.toggle() }
                        .buttonStyle(.link)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(approval.decided == nil ? 0.5 : 0.2), lineWidth: 1)
        }
    }

    private func decide(_ allow: Bool) {
        guard let bot else { return }
        model.decide(approval, allow: allow, for: bot)
    }

    private var title: String {
        switch approval.decided {
        case nil: "\(approval.tool) needs your approval"
        case .allowed: "\(approval.tool) — you allowed this"
        case .denied: "\(approval.tool) — you declined this"
        case .expired: "\(approval.tool) — denied, nobody answered"
        }
    }

    private var icon: String {
        switch approval.decided {
        case nil: "hand.raised.fill"
        case .allowed: "checkmark.circle.fill"
        case .denied, .expired: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch approval.decided {
        case nil: .orange
        case .allowed: .green
        case .denied, .expired: .secondary
        }
    }
}

/// A tool call and its result, collapsed. Expanded on demand, because the arguments are the part
/// that matters when something has gone wrong.
struct ToolChip: View {
    let name: String
    let arguments: String
    let result: String?
    let failed: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(failed ? .orange : .secondary)
                    Text(name).fontWeight(.medium)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if result == nil && !failed {
                        ProgressView().controlSize(.small)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(arguments)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if let result {
                    Divider()
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(20)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 640, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private var icon: String {
        if failed { return "exclamationmark.triangle" }
        switch name {
        case "shell", "Bash": return "terminal"
        case "edit", "Edit", "Write": return "pencil"
        case "Read": return "doc.text"
        default: return "wrench.and.screwdriver"
        }
    }

    private var summary: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "description"] {
            if let value = object[key] as? String { return value }
        }
        return ""
    }
}

/// Subscription headroom, read from the engine's own report rather than estimated.
/// Protecting the user's quota protects their account, which protects us.
struct LimitsGauge: View {
    let limits: RateLimit

    var body: some View {
        if let tightest = limits.tightest {
            let percent = Int(tightest.window.utilization * 100)
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("\(percent)%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(percent >= 80 ? .orange : .secondary)
            .help(tooltip)
        }
    }

    private var tooltip: String {
        var lines = ["Your subscription usage, reported by the engine:"]
        for (name, window) in limits.windows.sorted(by: { $0.key < $1.key }) {
            let label = name.replacingOccurrences(of: "_", with: " ")
            var line = "  \(label): \(Int(window.utilization * 100))%"
            if let resets = window.resetsAt {
                line += " · resets \(resets.formatted(date: .omitted, time: .shortened))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

struct Composer: View {
    @Binding var draft: String
    let isRunning: Bool
    let hue: Double
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                .borderBeam(hue: hue, active: isRunning)
                .onSubmit(onSend)

            Button(isRunning ? "Stop" : "Send", action: isRunning ? onStop : onSend)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isRunning && draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }
}
