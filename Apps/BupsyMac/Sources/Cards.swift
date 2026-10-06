import BupsyKit
import SwiftUI

/// A tool call waiting on you, as an interactive message.
///
/// The one thing in a thread that must not read as an aside, and the only pink card in the app.
/// The asking bot's face and name lead, then what it wants in plain words, why, and the command
/// verbatim. It stays in the thread after you decide, settled into grey, because what you allowed
/// is part of the record rather than a dialog that served its purpose and vanished.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let approval: PendingApproval
    /// Whose approval this is. In a bot's own thread that is the selected bot; in a group it is
    /// whichever member asked, which is not the same thing.
    var owner: Bot?
    /// False where several cards share a screen, so one Shift Cmd A cannot answer the wrong one.
    var showsShortcuts = true
    @State private var showsDetail = false

    init(approval: PendingApproval, owner: Bot? = nil, showsShortcuts: Bool = true) {
        self.approval = approval
        self.owner = owner
        self.showsShortcuts = showsShortcuts
    }

    private var bot: Bot? { owner ?? model.selectedBot }
    private var pending: Bool { approval.decided == nil }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ThreadNestedCard(base: lipBase, wash: pending ? palette.primary.opacity(isDark ? 0.22 : 0.16) : nil) {
            head

            if pending && !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The command in full. An approval you cannot read is not an approval.
            // Paths shortened for reading; Details still shows the full input.
            Text(PathShortener.shorten(approval.summary,
                                       workingDirectory: bot.map { model.workingDirectory(for: $0).path }))
                .font(ThreadLayout.monoFont)
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isDark ? palette.background : palette.card,
                            in: .rect(cornerRadius: Theme.Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border)
                }

            if showsDetail {
                Text(approval.inputJSON)
                    .font(.system(size: Theme.scaled(10.5), design: .monospaced))
                    .foregroundStyle(palette.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            footer
        }
    }

    private var lipBase: Color {
        if pending { return isDark ? palette.sidebar : palette.background }
        return isDark ? palette.sidebar : palette.card
    }

    /// "Scout wants to run a command": who first, in full weight, then what, quieter.
    private var head: some View {
        HStack(spacing: Theme.Space.step) {
            if let bot {
                BotFace(bot: bot, mood: pending ? .waitingForYou : .idle, size: ThreadLayout.avatar)
            }
            (Text(bot?.name ?? "Your bot")
                .fontWeight(.medium)
                .foregroundColor(palette.foreground)
             + Text(" wants to \(ToolNames.action(approval.tool))")
                .foregroundColor(palette.mutedForeground))
                .font(ThreadLayout.messageFont)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.snug)
            // Plain text in the theme rather than `.link`, which drew it in macOS blue.
            Button(showsDetail ? "Hide details" : "Details") { showsDetail.toggle() }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if pending {
            HStack(spacing: 4) {
                allowButton
                denyButton
                if ToolNames.canAlwaysAllow(approval.tool), let bot {
                    Button("Always allow") {
                        model.decide(approval, allow: true, for: bot, always: true)
                    }
                    .buttonStyle(ThreadButtonStyle(kind: .ghost))
                    .help("Stop asking before \(bot.name) does this. Undo any time in Permissions.")
                }
                Spacer(minLength: Theme.Space.snug)
                // Shell commands are asked every time: their risk is in the command, not the
                // tool, so "always allow" is never offered for them. Saying so stops the hunt
                // for a missing button.
                Text(ToolNames.canAlwaysAllow(approval.tool)
                     ? (showsShortcuts ? "Shift Cmd A to allow" : "")
                     : "Shell commands are never auto-allowed")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: resultIcon)
                    .font(.system(size: Theme.scaled(12), weight: .semibold))
                    .foregroundStyle(resultTint)
                Text(resultText)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var allowButton: some View {
        let button = Button("Allow") { decide(true) }
            .buttonStyle(ThreadButtonStyle(kind: .primary))
        if showsShortcuts {
            button
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Allow (Shift Cmd A)")
        } else {
            button
        }
    }

    @ViewBuilder
    private var denyButton: some View {
        let button = Button("Deny") { decide(false) }
            .buttonStyle(ThreadButtonStyle(kind: .ghostDestructive))
        if showsShortcuts {
            button
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Deny (Shift Cmd D)")
        } else {
            button
        }
    }

    private func decide(_ allow: Bool) {
        guard let bot else { return }
        model.decide(approval, allow: allow, for: bot)
    }

    private var resultText: String {
        switch approval.decided {
        case nil: ""
        case .allowed: "You allowed this"
        case .alwaysAllowed: "You always allow this"
        case .denied: "You declined this"
        // Settled and grey, not red: nobody declined anything, it just was not answered.
        case .expired: "Timed out. Nothing ran."
        }
    }

    private var resultIcon: String {
        switch approval.decided {
        case nil: "hand.raised.fill"
        case .allowed, .alwaysAllowed: "checkmark"
        case .denied: "xmark"
        case .expired: "clock"
        }
    }

    private var resultTint: Color {
        switch approval.decided {
        case nil: palette.primary
        case .allowed, .alwaysAllowed: palette.success
        case .denied: palette.destructiveText
        case .expired: palette.mutedForeground
        }
    }
}

/// A button label that shows its keyboard shortcut. The shortcuts existed and were invisible,
/// which is the same as not existing for anyone who did not read the source.
struct ShortcutLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    let keys: String

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Text(text)
            Text(keys)
                .font(Theme.Typography.badge)
                .foregroundStyle(palette.mutedForeground)
        }
    }
}

/// How much of your own subscription you have used, read from the engine's own report.
///
/// Small and in the header rather than in the thread: it is context, not an event. Protecting
/// someone's quota protects their account, which protects us.
struct LimitsGauge: View {
    @Environment(\.palette) private var palette
    let limits: RateLimit

    var body: some View {
        if let tightest = limits.tightest {
            let percent = Int(tightest.window.utilization * 100)
            HStack(spacing: 5) {
                Circle()
                    .trim(from: 0, to: max(0.02, tightest.window.utilization))
                    .stroke(colour(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: 12)
                Text("\(percent)%")
                    .font(Theme.Typography.badge.monospacedDigit())
                    .foregroundStyle(colour(percent))
            }
            .help(tooltip)
        }
    }

    private func colour(_ percent: Int) -> Color {
        switch percent {
        case ..<60: palette.mutedForeground
        case ..<85: palette.primary
        default: palette.destructive
        }
    }

    private var tooltip: String {
        var lines = ["Your subscription usage, as the engine reports it:"]
        for (name, window) in limits.windows.sorted(by: { $0.key < $1.key }) {
            var line = "  \(name.replacingOccurrences(of: "_", with: " ")): "
                + "\(Int(window.utilization * 100))%"
            if let resets = window.resetsAt {
                line += ", resets \(resets.formatted(date: .omitted, time: .shortened))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// A bot's multiple-choice question: lettered answers, plus a field for your own.
///
/// One click answers. Answers are lettered so a long list can be scanned and talked about ("B"),
/// and the free-text field is always there because the bot's options are its guesses, not a
/// limit on what you can say. Plain grey, never pink: pink is for permissions.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let question: BotQuestion
    let bot: Bot
    @State private var custom = ""
    @State private var hovered: Int?

    init(question: BotQuestion, bot: Bot) {
        self.question = question
        self.bot = bot
    }

    private var busy: Bool { model.thread(for: bot.id).isRunning }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ThreadNestedCard(base: isDark ? palette.sidebar : palette.card) {
            HStack(alignment: .center, spacing: Theme.Space.step) {
                BotFace(bot: bot, mood: question.answer == nil ? .waitingForYou : .idle,
                        size: ThreadLayout.avatar)
                Text(question.question)
                    .font(ThreadLayout.messageFont.weight(.medium))
                    .foregroundStyle(palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if question.answer == nil {
                    Button { model.answer(question, with: "", for: bot) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Theme.scaled(10), weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.mutedForeground)
                    .help("Dismiss without answering")
                }
            }

            if let answer = question.answer {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: answer.isEmpty ? "xmark" : "checkmark")
                        .font(.system(size: Theme.scaled(11), weight: .semibold))
                        .foregroundStyle(answer.isEmpty ? palette.mutedForeground : palette.success)
                    Text(answer.isEmpty ? "Dismissed" : "You answered: \(answer)")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: Theme.Space.tight) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button { model.answer(question, with: option, for: bot) } label: {
                            HStack(spacing: Theme.Space.step) {
                                Text(String(UnicodeScalar(65 + index).map(Character.init) ?? "*"))
                                    .font(.system(size: Theme.scaled(10.5), weight: .medium))
                                    .foregroundStyle(palette.mutedForeground)
                                    .frame(width: 24, height: 24)
                                    .background(palette.card, in: .rect(cornerRadius: 6))
                                Text(option)
                                    .font(.system(size: Theme.scaled(13.5)))
                                    .foregroundStyle(palette.foreground)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.Space.step)
                            .padding(.vertical, Theme.Space.snug)
                            .frame(minHeight: Theme.Size.control)
                            .background(hovered == index ? palette.cardHover : (isDark ? palette.card : palette.background),
                                        in: .rect(cornerRadius: Theme.Radius.base))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                    }
                }
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)

                TextField("", text: $custom, prompt: Text("Type your own answer"))
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.scaled(13.5)))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, Theme.Space.step)
                    .frame(height: Theme.Size.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.base)
                            .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .disabled(busy)
                    .onSubmit {
                        guard !custom.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        model.answer(question, with: custom, for: bot)
                    }
            }
        } footer: {
            if question.answer == nil {
                // While the bot is still finishing its turn an answer sent now would be dropped,
                // so the line says to wait rather than letting the click vanish.
                Text(busy ? "\(bot.name) is finishing up. Answer in a moment."
                          : question.options.isEmpty
                            ? "Type your answer. \(bot.name) waits until you do."
                            : "One click answers. \(bot.name) waits until you do.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
        }
    }
}
