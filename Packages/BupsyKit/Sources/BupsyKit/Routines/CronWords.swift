import Foundation

/// Simple cron schedules in plain words, and the cron the routine sheet's "Custom time" builds.
///
/// Only the shapes people actually pick are put into words: one or a few times a day, every N
/// hours or minutes, or every hour between two times, on every day, weekdays, weekends or named
/// days. Anything else returns nil and the caller shows the cron as written, which is better than
/// words that are nearly right.
public enum CronWords {
    /// A time on some days: what the custom-time editor shows and edits.
    public struct Time: Sendable, Equatable {
        public var hour: Int
        public var minute: Int
        /// cron weekdays, Sunday = 0. Empty means every day.
        public var weekdays: Set<Int>

        public init(hour: Int, minute: Int, weekdays: Set<Int> = []) {
            self.hour = hour; self.minute = minute; self.weekdays = weekdays
        }
    }

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "Every day at 2am", "Weekdays at 9am", "Every 4 hours". nil when the schedule is not one of
    /// the simple shapes, or cannot be read at all.
    public static func describe(_ cron: String) -> String? {
        let fields = cron.split(separator: " ").map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let expression = try? CronExpression(cron) else { return nil }
        let days = Days(expression.weekdays)
        let minutes = expression.minutes.sorted()
        let hours = expression.hours.sorted()
        guard let firstMinute = minutes.first, let firstHour = hours.first else { return nil }

        // All day long: every hour, or every few minutes.
        if hours.count == 24 {
            if minutes.count == 1 {
                let base = firstMinute == 0 ? "Every hour" : "Every hour at \(firstMinute) minutes past"
                return base + days.suffix
            }
            if let step = step(minutes, period: 60) {
                return (step == 1 ? "Every minute" : "Every \(step) minutes") + days.suffix
            }
            return nil
        }

        guard minutes.count == 1 else { return nil }

        // Every few hours, on the hour.
        if firstMinute == 0, let step = step(hours, period: 24) {
            return "Every \(step) hours" + days.suffix
        }
        // Every hour between two times, on the hour.
        if firstMinute == 0, hours.count >= 3, let last = hours.last, last - firstHour == hours.count - 1 {
            return "Every hour from \(time(hour: firstHour, minute: 0)) to \(time(hour: last, minute: 0))"
                + days.suffix
        }
        // A few set times.
        if hours.count <= 4 {
            let times = hours.map { time(hour: $0, minute: firstMinute) }
            return days.lead + " at " + list(times)
        }
        return nil
    }

    /// The cron for one time on some days. No days, or all seven, is every day.
    public static func cron(for time: Time) -> String {
        let days = time.weekdays.filter { (0...6).contains($0) }
        let weekday: String
        if days.isEmpty || days.count == 7 {
            weekday = "*"
        } else if days == Set(1...5) {
            weekday = "1-5"
        } else {
            weekday = days.sorted().map(String.init).joined(separator: ",")
        }
        let hour = min(max(time.hour, 0), 23)
        let minute = min(max(time.minute, 0), 59)
        return "\(minute) \(hour) * * \(weekday)"
    }

    /// The time and days of a cron that runs once on the days it runs, for opening it in the
    /// custom-time editor. nil for anything else, which keeps its own entry instead.
    public static func time(of cron: String) -> Time? {
        let fields = cron.split(separator: " ").map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let expression = try? CronExpression(cron),
              expression.minutes.count == 1, expression.hours.count == 1,
              let minute = expression.minutes.first, let hour = expression.hours.first
        else { return nil }
        let weekdays = expression.weekdays.count == 7 ? Set<Int>() : expression.weekdays
        return Time(hour: hour, minute: minute, weekdays: weekdays)
    }

    /// "2am", "2:30pm", "12pm".
    static func time(hour: Int, minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let half = hour < 12 ? "am" : "pm"
        if minute == 0 { return "\(twelve)\(half)" }
        let padded = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(twelve):\(padded)\(half)"
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The gap between evenly spaced values that start within the first gap and fill the period,
    /// such as minutes 0, 15, 30 and 45 (15) or hours 0, 4, 8, 12, 16 and 20 (4).
    static func step(_ values: [Int], period: Int) -> Int? {
        guard values.count > 1 else { return nil }
        let gap = values[1] - values[0]
        guard gap >= 1, period % gap == 0, values[0] < gap else { return nil }
        let expected = Array(stride(from: values[0], to: period, by: gap))
        return expected == values ? gap : nil
    }

    /// Which days a schedule runs on, as words that lead a time or follow an interval.
    enum Days {
        case every
        case weekdays
        case weekends
        case named([Int])

        init(_ weekdays: Set<Int>) {
            if weekdays.count == 7 {
                self = .every
            } else if weekdays == Set(1...5) {
                self = .weekdays
            } else if weekdays == [0, 6] {
                self = .weekends
            } else {
                self = .named(weekdays.sorted())
            }
        }

        private static func plural(_ days: [Int]) -> String {
            CronWords.list(days.map { CronWords.dayNames[$0] + "s" })
        }

        /// Before a time: "Every day at 2am", "Mondays at 9am".
        var lead: String {
            switch self {
            case .every: "Every day"
            case .weekdays: "Weekdays"
            case .weekends: "Weekends"
            case .named(let days): Self.plural(days)
            }
        }

        /// After an interval: "Every hour on weekdays".
        var suffix: String {
            switch self {
            case .every: ""
            case .weekdays: " on weekdays"
            case .weekends: " on weekends"
            case .named(let days): " on " + Self.plural(days)
            }
        }
    }
}
