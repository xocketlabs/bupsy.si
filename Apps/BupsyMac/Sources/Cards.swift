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
            Text(approval.summary)
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
        case .denied: "You declined this"
        case .expired: "Denied — nobody answered in time"
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
        // Pink is the palette's only saturated colour, and this is the one thing in a thread
        // that stops until you answer — so it gets it.
        case nil: palette.primary
        case .allowed: palette.info
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
