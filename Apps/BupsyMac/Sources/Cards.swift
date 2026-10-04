import BupsyKit
import SwiftUI

/// A tool call waiting on you, as an interactive message.
///
/// The one thing in a thread that must not read as an aside. Everything else a bot does can be
/// skimmed; this one stops until you answer, so it gets a border, a colour and buttons — and it
/// stays in the thread after you decide, because what you allowed is part of the record rather
/// than a dialog that served its purpose and vanished.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let approval: PendingApproval
    /// Whose approval this is. In a bot's own thread that is the selected bot; in a group it is
    /// whichever member asked, which is not the same thing.
    var owner: Bot?
    @State private var showsDetail = false

    private var bot: Bot? { owner ?? model.selectedBot }
    private var pending: Bool { approval.decided == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(Theme.Typography.body.weight(.medium))
                Spacer(minLength: 0)
            }

            if pending {
                Text(approval.reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            // The command in full. An approval you cannot read is not an approval.
            // Paths shortened for reading; Details still shows the full input.
            Text(PathShortener.shorten(approval.summary,
                                       workingDirectory: bot.map { model.workingDirectory(for: $0).path }))
                .font(.system(size: Theme.scaled(13), design: .monospaced))
                .textSelection(.enabled)
                .padding(Theme.Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.sidebar, in: .rect(cornerRadius: Theme.Radius.control))

            if showsDetail {
                Text(approval.inputJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if pending {
                // Full-size, and deliberately the same weight. These were small system chips —
                // undersized for the most consequential decision in the app. They are not styled
                // as primary-and-secondary on purpose: drawing the eye to "Allow" is how a gate
                // turns into a reflex, and this one only works if it is read.
                HStack(spacing: Theme.Space.snug) {
                    Button { decide(true) } label: { ShortcutLabel(text: "Allow", keys: "⇧⌘A") }
                        .buttonStyle(QuietButton(compact: true))
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button { decide(false) } label: { ShortcutLabel(text: "Deny", keys: "⇧⌘D") }
                        .buttonStyle(QuietButton(compact: true))
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    if ToolNames.canAlwaysAllow(approval.tool), let bot {
                        Button("Always allow") {
                            model.decide(approval, allow: true, for: bot, always: true)
                        }
                        .buttonStyle(QuietButton(compact: true))
                        .help("Stop asking before \(bot.name) does this. Undo any time in Permissions.")
                    }
                    Spacer(minLength: 0)
                    // Plain text in the theme rather than `.link`, which drew it in macOS blue.
                    Button(showsDetail ? "Hide details" : "Details") { showsDetail.toggle() }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
        .padding(Theme.Space.step)
        .background(tint.opacity(pending ? 0.12 : 0.06), in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(tint.opacity(pending ? 0.45 : 0.15), lineWidth: 1)
        }
    }

    private func decide(_ allow: Bool) {
        guard let bot else { return }
        model.decide(approval, allow: allow, for: bot)
    }

    private var title: String {
        switch approval.decided {
        // What the bot wants to do, in a person's words, rather than a generic "can I run this?"
        // that reads the same for a file edit and a shell command.
        case nil: "Wants to \(ToolNames.action(approval.tool))"
        case .allowed: "You allowed this"
        case .alwaysAllowed: "You always allow this"
        case .denied: "You declined this"
        case .expired: "Denied — nobody answered in time"
        }
    }

    private var icon: String {
        switch approval.decided {
        case nil: "hand.raised.fill"
        case .allowed, .alwaysAllowed: "checkmark.circle.fill"
        case .denied, .expired: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch approval.decided {
        // Pink is the palette's only saturated colour, and this is the one thing in a thread
        // that stops until you answer — so it gets it.
        case nil: palette.primary
        case .allowed, .alwaysAllowed: palette.info
        case .denied, .expired: palette.mutedForeground
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
                line += " · resets \(resets.formatted(date: .omitted, time: .shortened))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// A bot's multiple-choice question: lettered answers, plus a field for your own.
///
/// One tap answers. Answers are lettered so a long list can be scanned and talked about ("B"),
/// and the free-text field is always there because the bot's options are its guesses, not a
/// limit on what you can say.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let question: BotQuestion
    let bot: Bot
    @State private var custom = ""
    @State private var hovered: Int?

    private var busy: Bool { model.thread(for: bot.id).isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(alignment: .top, spacing: Theme.Space.tight) {
                Text(question.question)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if question.answer == nil {
                    Button { model.answer(question, with: "", for: bot) } label: {
                        Image(systemName: "xmark").font(.system(size: Theme.scaled(10), weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.mutedForeground)
                    .help("Dismiss without answering")
                }
            }

            if let answer = question.answer {
                Label(answer.isEmpty ? "Dismissed" : "You answered: \(answer)",
                      systemImage: answer.isEmpty ? "xmark.circle" : "checkmark.circle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(answer.isEmpty ? palette.mutedForeground : palette.primary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button { model.answer(question, with: option, for: bot) } label: {
                            HStack(spacing: Theme.Space.step) {
                                Text(String(UnicodeScalar(65 + index).map(Character.init) ?? "•"))
                                    .font(.system(size: Theme.scaled(10), weight: .semibold, design: .rounded))
                                    .foregroundStyle(palette.mutedForeground)
                                    .frame(width: 20, height: 20)
                                    .background(palette.sidebar, in: .rect(cornerRadius: 5))
                                Text(option)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.foreground)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.Space.step)
                            .padding(.vertical, Theme.Space.snug)
                            .contentShape(Rectangle())
                            .background(hovered == index ? palette.foreground.opacity(0.06) : .clear)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                        if index < question.options.count - 1 {
                            Rectangle().fill(palette.border).frame(height: 1)
                        }
                    }
                }
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(palette.border))
                .disabled(busy)

                TextField("", text: $custom, prompt: Text("Type your own answer"))
                    .textFieldStyle(BupsyFieldStyle())
                    .disabled(busy)
                    .onSubmit {
                        guard !custom.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        model.answer(question, with: custom, for: bot)
                    }

                if busy {
                    // The bot is still finishing its turn; an answer sent now would be dropped.
                    Text("\(bot.name) is finishing up — answer in a moment.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
        .padding(Theme.Space.step)
        .background(palette.card.opacity(0.6), in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
    }
}
