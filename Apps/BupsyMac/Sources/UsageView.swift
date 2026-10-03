import BupsyKit
import SwiftUI

/// What each bot has used: runs, tokens, and what that would cost at API rates.
///
/// The dollar figure is the one that needs care. It is the engine's own `total_cost_usd` — what
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

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SectionHeader(
                    icon: "chart.bar",
                    title: "Usage",
                    badge: nil,
                    subtitle: "What each bot has used, under your own sign-in."
                ) {
                    Picker("", selection: $period) {
                        ForEach(UsagePeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                if rows.isEmpty {
                    EmptyRow(text: "Nothing yet \(period.phrase). Usage appears after a bot's first run.") {}
                } else {
                    totals(rows)
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(rows, id: \.botID) { usage in
                            if let bot = model.bots.first(where: { $0.id.rawValue == usage.botID }) {
                                UsageRow(bot: bot, usage: usage,
                                         share: share(of: usage, in: rows))
                            }
                        }
                    }
                }

                Text("The dollar figures are what this usage would cost on Anthropic's API, as "
                     + "the engine itself reports it. On a Claude subscription you don't pay per "
                     + "token — this shows scale, not a bill. Codex reports no figure, so its bots "
                     + "show tokens only.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: Theme.Size.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func totals(_ rows: [BotUsage]) -> some View {
        let costed = rows.compactMap(\.costUSD)
        return HStack(spacing: Theme.Space.snug) {
            StatTile(label: "Runs", value: "\(rows.map(\.runs).reduce(0, +))")
            StatTile(label: "Tokens sent",
                     value: UsageFormat.tokens(rows.map(\.sentTokens).reduce(0, +)))
            StatTile(label: "Tokens received",
                     value: UsageFormat.tokens(rows.map(\.receivedTokens).reduce(0, +)))
            StatTile(label: "API-equivalent",
                     value: costed.isEmpty ? "—" : UsageFormat.dollars(costed.reduce(0, +)))
        }
    }

    /// The bar's length: this bot's share of tokens sent.
    ///
    /// Always tokens, never cost. The first version used cost where it was known and tokens where
    /// it was not, so one bot's bar was a share of dollars and the next a share of tokens — bars
    /// that added up to more than 100% and compared nothing. Tokens are the one unit every engine
    /// reports; the dollar figure stays as the number at the end of the row.
    private func share(of usage: BotUsage, in rows: [BotUsage]) -> Double {
        let total = Double(rows.map(\.sentTokens).reduce(0, +))
        return total > 0 ? Double(usage.sentTokens) / total : 0
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

    /// Cents below a dollar, whole dollars above a hundred — enough precision to compare bots,
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
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            Text(value)
                .font(.system(size: Theme.scaled(20), weight: .semibold))
                .foregroundStyle(palette.foreground)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.gutter)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
    }
}

private struct UsageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    let usage: BotUsage
    let share: Double

    var body: some View {
        Button {
            model.selectedBotID = bot.id
        } label: {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: bot, mood: .idle, size: Theme.scaled(32))
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    HStack {
                        Text(bot.name)
                            .font(Theme.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(palette.foreground)
                        Text(bot.engine.displayName)
                            .font(Theme.Typography.badge)
                            .foregroundStyle(palette.mutedForeground)
                        Spacer(minLength: Theme.Space.snug)
                        Text(usage.costUSD.map(UsageFormat.dollars) ?? "—")
                            .font(Theme.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(palette.foreground)
                            .monospacedDigit()
                    }
                    // A bar, because "which bot is using the most" is a comparison, and bars
                    // compare at a glance where a column of numbers has to be read.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.secondary)
                            Capsule()
                                .fill(BotShape.palette[
                                    (bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue))
                                        % BotShape.palette.count])
                                .frame(width: max(4, geometry.size.width * min(max(share, 0), 1)))
                        }
                    }
                    .frame(height: 5)
                    Text("\(usage.runs) \(usage.runs == 1 ? "run" : "runs") · "
                         + "\(UsageFormat.tokens(usage.sentTokens)) sent · "
                         + "\(UsageFormat.tokens(usage.receivedTokens)) received")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(Theme.Space.gutter)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(bot.name)")
    }
}
