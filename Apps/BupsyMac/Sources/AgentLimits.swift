import BupsyKit
import SwiftUI

/// How much room a bot has left: the context window it last used, and your plan's usage limits.
///
/// One card, two halves. The context bar is split by where the tokens went: what the engine
/// reused from earlier turns, what was new, and the reply, so "why is this turn so big" has an
/// answer at a glance. Click it to see the numbers. Below, each plan limit as a bar with when it
/// resets, which is the question people actually have about a limit.
struct AgentLimitsCard: View {
    @Environment(\.palette) private var palette
    let bot: Bot
    /// The last turn's usage, if any run has reported one.
    let usage: Usage?
    let limits: RateLimit?
    @State private var expanded = false

    /// The context window, when it is known. Claude Code models carry a 200k window unless the
    /// model ID asks for 1M. Other engines do not say, and a guessed size would be a confident
    /// wrong number, so their card shows only the plan limits.
    static func contextCapacity(for bot: Bot) -> Int? {
        guard bot.engine == .claude else { return nil }
        return (bot.model ?? "").lowercased().contains("1m") ? 1_000_000 : 200_000
    }

    private var capacity: Int? { Self.contextCapacity(for: bot) }

    private struct Segment: Identifiable { let id: String; let tokens: Int; let colour: Color }

    private var segments: [Segment] {
        guard let usage else { return [] }
        let cached = usage.cachedInputTokens ?? 0
        let input = max(0, (usage.inputTokens ?? 0) - cached)
        let reply = usage.outputTokens ?? 0
        return [
            Segment(id: "Reused from earlier", tokens: cached, colour: palette.info),
            Segment(id: "New this turn", tokens: input, colour: palette.primary),
            Segment(id: "Reply", tokens: reply, colour: palette.success),
        ].filter { $0.tokens > 0 }
    }

    private var used: Int { segments.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usage != nil, let capacity { context(capacity) }
            if usage != nil, capacity != nil, let limits, !limits.windows.isEmpty {
                Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, 12)
            }
            if let limits, !limits.windows.isEmpty { plan(limits) }
        }
        .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func context(_ capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Context window").foregroundStyle(palette.mutedForeground)
                    Spacer(minLength: 0)
                    Text("\(Self.compact(used)) / \(Self.compact(capacity))")
                        .foregroundStyle(palette.mutedForeground)
                    Text("(\(percent(used, of: capacity))%)")
                        .fontWeight(.semibold).foregroundStyle(palette.foreground)
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(9), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(Theme.Typography.caption)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.colour)
                            .frame(width: max(2, proxy.size.width * CGFloat(segment.tokens) / CGFloat(capacity)))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 6)

            if expanded {
                VStack(spacing: 7) {
                    ForEach(segments) { segment in
                        breakdownRow(segment.id, segment.tokens, of: capacity, colour: segment.colour)
                    }
                    breakdownRow("Free", max(0, capacity - used), of: capacity,
                                 colour: palette.foreground.opacity(0.15))
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(12)
    }

    private func breakdownRow(_ label: String, _ tokens: Int, of capacity: Int, colour: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 8, height: 8)
            Text(label).foregroundStyle(palette.foreground)
            Spacer(minLength: 0)
            Text(Self.compact(tokens)).foregroundStyle(palette.mutedForeground).monospacedDigit()
            Text(String(format: "%.1f%%", Double(tokens) / Double(capacity) * 100))
                .foregroundStyle(palette.foreground).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .font(Theme.Typography.caption)
    }

    private func plan(_ limits: RateLimit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(bot.engine.displayName) plan limits")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            ForEach(limits.windows.sorted { $0.key < $1.key }, id: \.key) { name, window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(Self.label(name)).fontWeight(.semibold).foregroundStyle(palette.foreground)
                        Spacer(minLength: 0)
                        if let reset = window.resetsAt {
                            Text(Self.resets(reset)).foregroundStyle(palette.mutedForeground)
                        }
                        Text("\(LimitScale.percent(window.utilization))%")
                            .fontWeight(.semibold)
                            .foregroundStyle(LimitScale.tone(window.utilization, palette) ?? palette.foreground)
                            .monospacedDigit()
                    }
                    .font(Theme.Typography.caption)
                    GeometryReader { proxy in
                        Capsule().fill(palette.foreground.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Self.tone(window.utilization, palette))
                                    .frame(width: max(4, proxy.size.width * min(1, window.utilization)))
                            }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(12)
    }

    /// The bar's fill. See `LimitScale`.
    static func tone(_ utilization: Double, _ palette: Palette.Scheme) -> Color {
        LimitScale.fill(utilization, palette)
    }

    private func percent(_ part: Int, of whole: Int) -> Int { Int((Double(part) / Double(whole) * 100).rounded()) }

    static func label(_ name: String) -> String { LimitScale.label(name) }

    /// "Resets in 2 hr 46 min" within a day, "Resets Tue 3:00 PM" beyond.
    static func resets(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting" }
        if seconds < 86_400 {
            let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "Resets in \(hours) hr \(minutes) min" : "Resets in \(minutes) min"
        }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: value % 1_000_000 == 0 ? "\(value / 1_000_000)M" : String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}

/// One scale for every plan-limit readout: the topbar badge, the limits card and any gauge.
///
/// Neutral under 70%, amber from 70% to 85%, red above. Pink is kept for "needs you", so a limit
/// that is barely used never wears it. One name per window, wherever it is shown.
enum LimitScale {
    enum Level: Equatable { case normal, high, critical }

    static func level(_ utilization: Double) -> Level {
        switch utilization {
        case let value where value > 0.85: .critical
        case 0.7...: .high
        default: .normal
        }
    }

    /// The colour for text and badges, or nil to stay in the neutral style.
    static func tone(_ utilization: Double, _ palette: Palette.Scheme) -> Color? {
        switch level(utilization) {
        case .critical: return palette.destructive
        case .high: return palette.warning
        case .normal: return nil
        }
    }

    /// The colour a bar fills with: neutral until it is worth noticing.
    static func fill(_ utilization: Double, _ palette: Palette.Scheme) -> Color {
        tone(utilization, palette) ?? palette.mutedForeground
    }

    /// Whole percent, rounded the same way everywhere.
    static func percent(_ utilization: Double) -> Int { Int((utilization * 100).rounded()) }

    /// Engine window names are snake_case and internal. These are not.
    static func label(_ name: String) -> String {
        switch name {
        case "five_hour": "5-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "38% of 5-hour limit", for a badge.
    static func badge(name: String, utilization: Double) -> String {
        let window = label(name)
        let lowered: String = window.prefix(1).lowercased() + String(window.dropFirst())
        return "\(percent(utilization))% of \(lowered)"
    }
}
