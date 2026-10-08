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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bot: Bot
    /// The last turn's usage, if any run has reported one.
    let usage: Usage?
    let limits: RateLimit?
    @State private var expanded = false

    /// The context window, when it is known. The engine's own figure first; failing that, Claude
    /// Code models carry a 200k window unless the model ID asks for 1M. Other engines do not say,
    /// and a guessed size would be a confident wrong number, so their card shows only the plan
    /// limits.
    static func contextCapacity(for bot: Bot, reported: Int? = nil) -> Int? {
        if let reported, reported > 0 { return reported }
        guard bot.engine == .claude else { return nil }
        return (bot.model ?? "").lowercased().contains("1m") ? 1_000_000 : 200_000
    }

    /// The last call's context, never the run's totals, which count it once per step.
    private var context: ContextUse? { usage?.context }

    private var capacity: Int? { Self.contextCapacity(for: bot, reported: context?.window) }

    private struct Segment: Identifiable { let id: String; let tokens: Int; let colour: Color }

    private var segments: [Segment] {
        guard let context else { return [] }
        let cached = context.cachedTokens
        let input = context.newTokens
        let reply = context.replyTokens
        return [
            Segment(id: "Reused from earlier", tokens: cached, colour: palette.info),
            Segment(id: "New this turn", tokens: input, colour: palette.primary),
            Segment(id: "Reply", tokens: reply, colour: palette.success),
        ].filter { $0.tokens > 0 }
    }

    private var used: Int { segments.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if context != nil, let capacity { contextMeter(capacity) }
            if context != nil, capacity != nil, let limits, !limits.windows.isEmpty {
                Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, Theme.Space.step)
            }
            if let limits, !limits.windows.isEmpty { plan(limits) }
        }
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func contextMeter(_ capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.tight) {
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
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help(expanded ? "Hide the breakdown" : "Show the breakdown")

            GeometryReader { proxy in
                // Never wider than the track: a context past its window (or a wrong window
                // size) fills the bar rather than running off the card.
                let scale = proxy.size.width / CGFloat(max(capacity, used))
                HStack(spacing: 1.5) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.colour)
                            .frame(width: max(2, CGFloat(segment.tokens) * scale))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 6)

            if expanded {
                VStack(spacing: Theme.Space.tight) {
                    ForEach(segments) { segment in
                        breakdownRow(segment.id, segment.tokens, of: capacity, colour: segment.colour)
                    }
                    breakdownRow("Free", max(0, capacity - used), of: capacity,
                                 colour: palette.foreground.opacity(0.15))
                }
                .padding(.top, Theme.Space.hairline)
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.step)
    }

    private func breakdownRow(_ label: String, _ tokens: Int, of capacity: Int, colour: Color) -> some View {
        HStack(spacing: Theme.Space.snug) {
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
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Text("\(bot.engine.displayName) plan limits")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            ForEach(limits.windows.sorted { $0.key < $1.key }, id: \.key) { name, window in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.tight) {
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
        .padding(Theme.Space.step)
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
