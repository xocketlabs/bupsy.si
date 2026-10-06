import BupsyKit
import SwiftUI

/// What a bot is doing right now, shown under the thread while it works.
///
/// Its own mascot, small and sweating, then a status that breathes ("Searching the web",
/// "Editing hello.txt") and a timer that counts up. Hidden the moment an approval card appears,
/// so nobody sees "working" and "needs you" at once.
struct AgentThinking: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bot: Bot
    let thread: Thread

    var body: some View {
        HStack(spacing: Theme.Space.compact) {
            BotFace(bot: bot, mood: .working, size: 22)
            // The breath and the clock run on separate timelines, so Reduce Motion can still the
            // one without freezing the other: the time is information, not motion.
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // 2.2s in and out, eased, the same breath as the composer's border.
                let breath = 0.5 - 0.5 * cos((t.truncatingRemainder(dividingBy: 2.2) / 2.2) * 2 * .pi)
                Text(status)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .opacity(reduceMotion ? 1 : 0.55 + 0.45 * breath)
                    .lineLimit(1)
            }
            if let started {
                if reduceMotion {
                    // Whole seconds, once a second: still counting, nothing flickering.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        elapsedText(ChatDuration.ticking(timeline.date.timeIntervalSince(started)))
                    }
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 10)) { timeline in
                        elapsedText(elapsed(since: started, now: timeline.date))
                    }
                }
            }
        }
        .padding(.leading, ThreadLayout.gutter)
        .padding(.vertical, Theme.Space.hairline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bot.name) is \(status.lowercased())")
    }

    private func elapsedText(_ value: String) -> some View {
        Text(value)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .monospacedDigit()
    }

    /// When this run began: the last thing you (or another bot) said.
    private var started: Date? {
        thread.entries.last { if case .userMessage = $0.kind { true } else if case .messageFrom = $0.kind { true } else { false } }?.at
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        return seconds < 60 ? String(format: "%.1fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    /// The bot's latest in-progress step, in words. The same words the top bar badge shows.
    private var status: String { ChatLiveStatus.text(for: thread.entries) }
}
