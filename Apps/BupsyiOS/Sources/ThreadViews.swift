import SwiftUI

/// An entry with what it needs to know about its neighbours, worked out once for the whole chat
/// rather than by each row looking around.
struct ThreadRow: Identifiable, Equatable {
    let entry: Entry
    /// The first entry of its day, which gets a day chip above it.
    let startsDay: Bool
    /// The first bubble in a run from one speaker, which shows the name and a tail corner.
    let startsRun: Bool

    var id: String { entry.id }

    static func rows(_ entries: [Entry], calendar: Calendar = .current) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        rows.reserveCapacity(entries.count)
        var previous: Entry?
        for entry in entries {
            let startsDay = previous.map { !calendar.isDate($0.at, inSameDayAs: entry.at) } ?? true
            // Anything between two bubbles (a tool step, a card) breaks the run, as on the web.
            let startsRun = startsDay || entry.speaker == nil || entry.speaker != previous?.speaker
            rows.append(ThreadRow(entry: entry, startsDay: startsDay, startsRun: startsRun))
            previous = entry
        }
        return rows
    }
}

/// One entry, drawn the way its kind is drawn.
struct EntryView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    let row: ThreadRow
    let bot: Bot
    let chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.startsDay {
                DayChip(date: row.entry.at)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let entry = row.entry
        switch entry.kind {
        case .you(let text):
            MessageBubble(text: text, at: entry.at, mine: true, startsRun: row.startsRun)
        case .bot(let text):
            MessageBubble(text: text, at: entry.at, mine: false, startsRun: row.startsRun,
                          speaker: bot.name, speakerColour: Palette.colour(hex: bot.colour))
        case .from(let author, let text):
            // Another bot, in its own colour when it's one of the person's bots.
            let colour = session.bots(on: chat.ref.macID).first { $0.name == author }.flatMap { Palette.colour(hex: $0.colour) }
            MessageBubble(text: text, at: entry.at, mine: false, startsRun: row.startsRun,
                          speaker: author, speakerColour: colour)
        case .tool(let step):
            QuietLine(lead: step.verb, detail: step.target, tone: step.failed ? .failed : .plain,
                      suffix: step.failed ? "· failed" : nil)
        case .approval(let approval):
            if let decision = approval.decided {
                DecidedLine(approval: approval, decision: decision)
            } else {
                ApprovalCard(approval: approval, botName: bot.name, chat: chat)
            }
        case .question(let question):
            if let answer = question.answer {
                QuietLine(lead: "You answered:", detail: answer, tone: .plain, mono: false)
            } else {
                QuestionCard(question: question, botName: bot.name, chat: chat)
            }
        case .note(let text):
            NoteLine(text: text)
        case .failure(let text):
            NoteLine(text: text, failure: true)
        case .other(let text):
            if let text, !text.isEmpty { NoteLine(text: text) }
        }
    }
}

/// A message, the way a messaging app draws one: yours on the right in a pink tint, a bot's on
/// the left in grey with its name in its colour over the first of a run, the time in the corner.
struct MessageBubble: View {
    @Environment(\.palette) private var palette
    let text: String
    let at: Date
    let mine: Bool
    let startsRun: Bool
    var speaker: String?
    var speakerColour: Color?

    var body: some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: Theme.Size.bubbleInset) }
            bubble
            if !mine { Spacer(minLength: Theme.Size.bubbleInset) }
        }
        .padding(.top, startsRun ? 10 : 2)
    }

    private var time: String { at.formatted(date: .omitted, time: .shortened) }

    /// Invisible, the width of the time: it ends the last line so the real time never covers a word.
    private var trailer: Text {
        Text("\u{2002}\u{2002}\(time)").font(.caption2).foregroundStyle(.clear)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 1) {
            if startsRun, let speaker, !speaker.isEmpty {
                Text(speaker)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(speakerColour ?? palette.mutedForeground)
            }
            if mine {
                Text("\(Text(text))\(trailer)")
            } else {
                MarkdownText(source: text, trailer: trailer)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(time)
                .font(.caption2)
                .foregroundStyle(palette.mutedForeground)
                .offset(y: 2)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .background(mine ? palette.you : palette.card, in: shape)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
    }

    /// Rounded all round, except the top corner on the speaker's side at the start of a run.
    private var shape: UnevenRoundedRectangle {
        let tail = startsRun ? Theme.Radius.tail : Theme.Radius.bubble
        return UnevenRoundedRectangle(
            topLeadingRadius: mine ? Theme.Radius.bubble : tail,
            bottomLeadingRadius: Theme.Radius.bubble,
            bottomTrailingRadius: Theme.Radius.bubble,
            topTrailingRadius: mine ? tail : Theme.Radius.bubble,
            style: .continuous
        )
    }
}

/// The bot is working: three breathing dots where its next words will appear.
struct TypingBubble: View {
    @Environment(\.palette) private var palette

    var body: some View {
        WorkingDots(dot: 6)
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background(palette.card, in: UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.tail, bottomLeadingRadius: Theme.Radius.bubble,
                bottomTrailingRadius: Theme.Radius.bubble, topTrailingRadius: Theme.Radius.bubble,
                style: .continuous))
            .padding(.top, 10)
    }
}

/// A step that happened rather than something said: a tool used, a decision made. One quiet line,
/// so a busy run doesn't bury the conversation.
struct QuietLine: View {
    enum Tone { case plain, failed, allowed, denied }

    @Environment(\.palette) private var palette
    let lead: String
    var detail: String?
    var tone: Tone = .plain
    var suffix: String?
    /// Commands and paths are mono; an answer in words is not.
    var mono = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            Text(lead)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(mono ? .system(size: 12, design: .monospaced) : .footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let suffix { Text(suffix) }
        }
        .font(.footnote)
        .foregroundStyle(tone == .failed ? palette.destructiveText : palette.mutedForeground)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch tone {
        case .allowed: palette.success
        case .denied: palette.destructiveText
        case .failed: palette.destructiveText.opacity(0.55)
        case .plain: palette.mutedForeground.opacity(0.55)
        }
    }
}

/// An approval that's been answered, here or on the Mac.
struct DecidedLine: View {
    let approval: Approval
    let decision: Approval.Decision

    var body: some View {
        switch decision {
        case .allowed:
            QuietLine(lead: "Allowed:", detail: approval.summary, tone: .allowed)
        case .alwaysAllowed:
            QuietLine(lead: "Always allowed:", detail: approval.summary, tone: .allowed)
        case .denied:
            QuietLine(lead: approval.summary.isEmpty ? "Denied" : "Denied:", detail: approval.summary, tone: .denied)
        case .expired:
            QuietLine(lead: "Timed out. Nothing ran.")
        case .other:
            QuietLine(lead: "Answered:", detail: approval.summary)
        }
    }
}

/// Something about the chat rather than in it: a note from Bupsy, or a failure.
struct NoteLine: View {
    @Environment(\.palette) private var palette
    let text: String
    var failure = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(failure ? palette.destructiveText : palette.mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
    }
}

/// "Today", "Yesterday", "Monday", "3 Oct": where a new day starts in a chat.
struct DayChip: View {
    @Environment(\.palette) private var palette
    let date: Date

    var body: some View {
        Text(Self.label(date))
            .font(.caption.weight(.medium))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(palette.card, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
