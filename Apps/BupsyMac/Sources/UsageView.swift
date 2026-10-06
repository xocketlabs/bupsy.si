import BupsyKit
import SwiftUI

/// What each bot has used: runs, tokens, and what that would cost at API rates.
///
/// The dollar figure is the one that needs care. It is the engine's own `total_cost_usd`: what
/// the same work would cost on Anthropic's pay-as-you-go API. On a Claude subscription nobody pays
/// per token, so it is labelled as a value, never as a bill, and the page says so at the top. It is
/// still worth seeing: it is the clearest measure of which bot is doing the most, and of what the
/// subscription is saving.
struct UsageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var period = UsagePeriod.month

    var body: some View {
        let rows = model.usage(since: period.start)

        SetupPageScroll {
            SetupPageHeader(title: "Usage", description: "What your bots spent of your plan") {
                UsagePeriodPicker(period: $period)
            }

            if rows.isEmpty {
                EmptyState(
                    title: period == .all ? "Nothing yet" : "Nothing \(period.phrase)",
                    message: "Usage shows up here after a bot's first run.")
                    .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
            } else {
                totals(rows)

                VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                    SetupSectionHeader(
                        icon: "face.smiling",
                        title: "By bot",
                        description: "Bars share one scale, so you can compare bots at a glance")
                    VStack(spacing: Theme.Space.step) {
                        ForEach(rows, id: \.botID) { usage in
                            if let bot = model.bots.first(where: { $0.id.rawValue == usage.botID }) {
                                UsageRow(bot: bot, usage: usage,
                                         share: share(of: usage, in: rows),
                                         working: model.isRunning(bot.id))
                            }
                        }
                    }
                }
            }

            SetupFootnote(text: "Dollar figures are the API price, shown for scale. You pay your "
                          + "plan, not this. Codex runs show no dollar figure.")
        }
    }

    private func totals(_ rows: [BotUsage]) -> some View {
        let costed = rows.compactMap(\.costUSD)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.step)],
                         spacing: Theme.Space.step) {
            StatTile(icon: "play.fill", label: "Runs", value: "\(rows.map(\.runs).reduce(0, +))")
            StatTile(icon: "arrow.up", label: "Tokens sent",
                     value: UsageFormat.tokens(rows.map(\.sentTokens).reduce(0, +)))
            StatTile(icon: "arrow.down.to.line", label: "Tokens received",
                     value: UsageFormat.tokens(rows.map(\.receivedTokens).reduce(0, +)))
            StatTile(icon: "creditcard.fill", label: "API-equivalent",
                     value: costed.isEmpty ? "None" : UsageFormat.dollars(costed.reduce(0, +)))
        }
    }

    /// The bar's length: this bot's tokens sent, against the busiest bot's.
    ///
    /// Always tokens, never cost. An earlier version used cost where it was known and tokens
    /// where it was not, so one bot's bar measured dollars and the next tokens, and the bars
    /// compared nothing. Tokens are the one unit every engine reports; the dollar figure stays as
    /// the number at the end of the row. Scaled to the busiest bot so the top bar runs full and
    /// every other bar reads against it.
    private func share(of usage: BotUsage, in rows: [BotUsage]) -> Double {
        let top = Double(rows.map(\.sentTokens).max() ?? 0)
        return top > 0 ? Double(usage.sentTokens) / top : 0
    }
}

/// 7 days, 30 days, All time: a quiet segmented control that matches the cards beside it.
private struct UsagePeriodPicker: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Binding var period: UsagePeriod

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsagePeriod.allCases, id: \.self) { option in
                let selected = option == period
                Button { period = option } label: {
                    Text(option.label)
                        .font(.system(size: Theme.scaled(13)))
                        .foregroundStyle(selected ? palette.foreground : palette.mutedForeground)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(selected ? (colorScheme == .dark ? palette.cardHover : palette.background)
                                             : Color.clear,
                                    in: .rect(cornerRadius: Theme.Radius.control))
                        .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear, radius: 1, y: 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
        .fixedSize()
    }
}

enum UsagePeriod: CaseIterable {
    case week, month, all

    var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }

    var phrase: String {
        switch self {
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        case .all: "yet"
        }
    }

    var start: Date {
        switch self {
        case .week: Date().addingTimeInterval(-7 * 86_400)
        case .month: Date().addingTimeInterval(-30 * 86_400)
        case .all: .distantPast
        }
    }
}

enum UsageFormat {
    static func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }

    /// Cents below a dollar, whole dollars above a hundred, enough precision to compare bots,
    /// not so much that it reads like an invoice.
    static func dollars(_ value: Double) -> String {
        switch value {
        case ..<0.01: value == 0 ? "$0" : "<$0.01"
        case ..<100: String(format: "$%.2f", value)
        default: String(format: "$%.0f", value)
        }
    }
}

private struct StatTile: View {
    @Environment(\.palette) private var palette
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(12), weight: .semibold))
                    .foregroundStyle(palette.foreground)
                Text(label)
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: Theme.scaled(26), weight: .medium))
                .tracking(-0.5)
                .foregroundStyle(palette.foreground)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.gutter)
        .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// One bot's share: its face, its name and figure over a bar in its own colour, and the counts.
private struct UsageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    let usage: BotUsage
    let share: Double
    let working: Bool
    @State private var hovering = false

    init(bot: Bot, usage: BotUsage, share: Double, working: Bool) {
        self.bot = bot
        self.usage = usage
        self.share = share
        self.working = working
    }

    var body: some View {
        Button {
            model.selectedBotID = bot.id
        } label: {
            HStack(spacing: Theme.Space.gutter) {
                BotFace(bot: bot, mood: working ? .working : .idle, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(bot.name)
                            .font(Theme.Typography.body)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.snug)
                        Text(usage.costUSD.map(UsageFormat.dollars) ?? "Tokens only")
                            .font(Theme.Typography.body)
                            .foregroundStyle(palette.mutedForeground)
                            .monospacedDigit()
                    }
                    // A bar, because "which bot is using the most" is a comparison, and bars
                    // compare at a glance where a column of numbers has to be read.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.foreground.opacity(0.08))
                            Capsule()
                                .fill(BotFace.colour(of: bot))
                                .frame(width: max(6, geometry.size.width * min(max(share, 0), 1)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(usage.runs) \(usage.runs == 1 ? "run" : "runs"), "
                         + "\(UsageFormat.tokens(usage.sentTokens)) sent, "
                         + "\(UsageFormat.tokens(usage.receivedTokens)) received")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, Theme.Space.step)
            .padding(.trailing, Theme.Space.gutter)
            .background(hovering ? palette.cardHover : palette.card,
                        in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(bot.name)")
        .onHover { hovering = $0 }
    }
}
