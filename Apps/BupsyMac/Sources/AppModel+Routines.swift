import BupsyKit
import Foundation

/// Routine actions and read-outs the routine detail page needs, on top of what AppModel already
/// does for routines (add, update, delete, enable, and the scheduler in `runDueRoutines`).
extension AppModel {
    /// The bot a routine belongs to, if it still exists.
    func bot(for routine: Routine) -> Bot? {
        bots.first { $0.id.rawValue == routine.botID }
    }

    /// Runs a routine now, through the same path the scheduler takes for a due routine:
    /// `send(_:to:onFinish:)` with the routine's instruction, and a "finished" notification when
    /// the run ends (which, like every notification, stays quiet while bupsy is the active app).
    ///
    /// One deliberate difference from `runDueRoutines`: `lastFiredAt` is left alone. That field
    /// records which scheduled slot was filled; a run by hand fills none, so the next scheduled
    /// run still happens on time.
    func runRoutineNow(_ routine: Routine) {
        guard let bot = self.bot(for: routine) else { return }
        let name = routine.name
        let botName = bot.name
        let botID = bot.id
        // A fresh Notifier rather than AppModel's own, which is private to AppModel.swift. It is
        // stateless apart from caching whether permission was granted, so the result is the same.
        let notifier = Notifier()
        send(routine.prompt, to: bot) { reply in
            notifier.routineFinished(
                bot: botName, routine: name,
                summary: reply.split(separator: "\n").first.map(String.init), botID: botID)
        }
    }

    /// This routine's runs, newest first.
    ///
    /// Runs carry no routine id (a run's `triggerID` is never set for routines, and RunSummary
    /// does not expose it), so a run counts as this routine's when the message it started with
    /// is the routine's instruction. Scheduled runs send exactly that, plus a "running late"
    /// note when late; "Run now" sends it unchanged. Only the bot's recent runs are searched.
    func runs(of routine: Routine) -> [RunSummary] {
        guard let bot = self.bot(for: routine) else { return [] }
        return RoutineRunStats.attributed(recentRuns(for: bot), to: routine)
    }
}

/// The numbers on a routine's page, worked out from its runs. Pure, so it is cheap to reason about.
struct RoutineRunStats {
    let runsThisWeek: Int
    /// How many times the schedule fires this calendar week. nil when the schedule can't be read.
    let scheduledThisWeek: Int?
    let averageDuration: TimeInterval?
    /// How many runs the average is taken over.
    let timedRuns: Int
    let latest: RunSummary?

    init(runs: [RunSummary], cron: String, now: Date = Date(), calendar: Calendar = .current) {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        if let week {
            runsThisWeek = runs.filter { week.contains($0.startedAt) }.count
            scheduledThisWeek = Self.slots(cron: cron, in: week, calendar: calendar)
        } else {
            runsThisWeek = 0
            scheduledThisWeek = nil
        }
        let durations = runs.compactMap(\.duration).filter { $0 >= 0 }
        timedRuns = durations.count
        averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
        latest = runs.first
    }

    /// Runs that began with the routine's instruction. See `AppModel.runs(of:)`.
    static func attributed(_ runs: [RunSummary], to routine: Routine) -> [RunSummary] {
        let instruction = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return [] }
        return runs.filter { run in
            guard let prompt = run.prompt else { return false }
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(instruction)
        }
    }

    /// Scheduled firings inside an interval, counted day by day from the parsed fields rather than
    /// minute by minute, so a weekly schedule costs seven checks and not ten thousand.
    static func slots(cron: String, in interval: DateInterval, calendar: Calendar) -> Int? {
        guard let expression = try? CronExpression(cron) else { return nil }
        let perDay = expression.hours.count * expression.minutes.count
        var count = 0
        var day = calendar.startOfDay(for: interval.start)
        var guardDays = 0
        while day < interval.end && guardDays < 400 {
            let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
            if let dayOfMonth = parts.day, let month = parts.month, let weekday = parts.weekday,
               expression.daysOfMonth.contains(dayOfMonth),
               expression.months.contains(month),
               expression.weekdays.contains(weekday - 1) {
                count += perDay
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardDays += 1
        }
        return count
    }

    /// "38s", "4m 12s", "1h 5m".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// When a run started, in words: "Today, 2:00 AM", "Yesterday, 9:00 AM", "Monday 5 October, 7:00 AM".
    static func whenLabel(_ date: Date) -> String {
        Theme.daySeparator(date) + ", " + date.formatted(date: .omitted, time: .shortened)
    }

    /// When the next run is, as a phrase: "today at 2:00 AM", "tomorrow at 9:00 AM", "Monday at 9:00 AM".
    static func nextLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        if let week = calendar.date(byAdding: .day, value: 6, to: Date()), date < week {
            return date.formatted(.dateTime.weekday(.wide)) + " at \(time)"
        }
        return date.formatted(.dateTime.day().month(.wide)) + " at \(time)"
    }
}
