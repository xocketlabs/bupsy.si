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
    @State private var showsDetail = false

    private var bot: Bot? { model.selectedBot }
    private var pending: Bool { approval.decided == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }

            if pending {
                Text(approval.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The command in full. An approval you cannot read is not an approval.
            Text(approval.summary)
                .font(.system(.callout, design: .monospaced))
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
                HStack(spacing: Theme.Space.tight) {
                    Button("Allow") { decide(true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("Deny") { decide(false) }
                        .controlSize(.small)
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button(showsDetail ? "Less" : "Details") { showsDetail.toggle() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    Spacer(minLength: 0)
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
        case nil: "Can I run this?"
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
                    .font(.caption2.monospacedDigit())
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
