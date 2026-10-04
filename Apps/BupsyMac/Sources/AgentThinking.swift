import BupsyKit
import SwiftUI

/// What a bot is doing right now, shown under the thread while it works.
///
/// A 3×3 dot grid crossed by a diagonal wave, a label that says what the bot is actually doing —
/// "Searching the web", "Editing hello.txt" — with a highlight sweeping across it, and how long
/// it has been at it. Three static dots said "busy"; this says busy with what, and for how long.
struct AgentThinking: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bot: Bot
    let thread: Thread

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 9) {
                DotWave(time: reduceMotion ? 0 : t, colour: BotFace.colour(of: bot))
                ShimmerText(text: status, time: reduceMotion ? nil : t)
                if let started {
                    Text(elapsed(since: started, now: timeline.date))
                        .font(.system(size: Theme.scaled(11), design: .monospaced))
                        .foregroundStyle(palette.mutedForeground.opacity(0.8))
                        .monospacedDigit()
                }
            }
        }
        .padding(.leading, Theme.Size.bubbleAvatar + Theme.Space.tight)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bot.name) is \(status.lowercased())")
    }

    /// When this run began: the last thing you (or another bot) said.
    private var started: Date? {
        thread.entries.last { if case .userMessage = $0.kind { true } else if case .messageFrom = $0.kind { true } else { false } }?.at
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        return seconds < 60 ? String(format: "%.1fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    /// The bot's latest action, in words, or "Thinking" between actions.
    private var status: String {
        guard let last = thread.entries.last else { return "Thinking" }
        guard case .tool(let name, let arguments, let result, _) = last.kind, result == nil else { return "Thinking" }
        let detail = Self.subject(arguments)
        switch name {
        case "Bash", "shell": return "Running a command"
        case "Read": return detail.map { "Reading \($0)" } ?? "Reading"
        case "Write", "Edit", "MultiEdit", "edit": return detail.map { "Editing \($0)" } ?? "Editing"
        case "WebSearch", "WebFetch": return "Searching the web"
        case "Grep", "Glob": return "Searching files"
        case "Task": return "Working on a sub-task"
        case "mcp__bupsy__message_bot": return "Messaging a bot"
        case "mcp__bupsy__ask_person": return "Asking you"
        default:
            if name.hasPrefix("mcp__") {
                let server = name.dropFirst(5).split(separator: "_").first.map(String.init) ?? "an app"
                return "Using \(server.capitalized)"
            }
            return "Working"
        }
    }

    /// A file name worth showing, if the call names one.
    private static func subject(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (object["file_path"] ?? object["path"]) as? String else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// A 3×3 grid; a bright band sweeps from top-left to bottom-right with a fading trail, rests,
/// and goes again.
struct DotWave: View {
    let time: TimeInterval
    let colour: Color
    var dot: CGFloat = 3.5
    var gap: CGFloat = 2.5

    var body: some View {
        let period = 1.6
        let phase = time.truncatingRemainder(dividingBy: period) / period
        // The front moves along the diagonal 0…4 over the first 70% of the period, then rests.
        let front = phase < 0.7 ? phase / 0.7 * 5.5 - 1 : 9
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let distance = front - Double(row + column)
                        let lit = distance >= 0 && distance < 2.2 ? 1 - distance / 2.2 : 0
                        Circle()
                            .fill(colour.opacity(0.22 + 0.78 * lit))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .frame(width: dot * 3 + gap * 2, height: dot * 3 + gap * 2)
    }
}

/// Muted text with a soft highlight travelling across it.
struct ShimmerText: View {
    @Environment(\.palette) private var palette
    let text: String
    /// Nil holds it still.
    let time: TimeInterval?

    var body: some View {
        let label = Text(text)
            .font(.system(size: Theme.scaled(12.5), weight: .medium))
        label
            .foregroundStyle(palette.mutedForeground)
            .overlay {
                if let time {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let progress = (time.truncatingRemainder(dividingBy: 2.2)) / 2.2
                        let x = -width * 0.5 + progress * width * 2
                        LinearGradient(colors: [.clear, palette.foreground, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.45)
                            .offset(x: x)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
            .lineLimit(1)
    }
}
