import Foundation

/// A standing job: a prompt a bot runs on a schedule.
public struct Routine: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var botID: String
    public var name: String
    public var prompt: String
    /// Five-field cron. The shared vocabulary between the Mac scheduler, launchd and systemd —
    /// each of which wants a different format, all of which are generated from this one.
    public var cron: String
    public var enabled: Bool
    /// Where this routine actually runs, which decides what it can promise. PLAN.md §4.
    public var tier: Tier
    public var lastFiredAt: Date?

    public enum Tier: String, Sendable, Codable, CaseIterable {
        /// In the app, while it is open. Free, exact, and silent when the app is closed.
        case appOpen
        /// A LaunchAgent starts bupsy to run it. Free, survives the app being closed, catches up
        /// after sleep — but does not wake the Mac.
        case launchAgent
        /// A systemd timer inside the user's own machine. Costs money, ignores the Mac entirely.
        case machine

        public var label: String {
            switch self {
            case .appOpen: "While Bupsy is open"
            case .launchAgent: "Even when Bupsy is closed"
            case .machine: "On a cloud machine"
            }
        }

        /// What this tier will and will not do, in the words the UI should use. Overclaiming
        /// here would be the worst lie the product could tell, so the honest sentence lives
        /// next to the enum rather than in a view.
        public var promise: String {
            switch self {
            case .appOpen:
                "Runs only while Bupsy is open. Skipped otherwise."
            case .launchAgent:
                "Runs even with Bupsy closed. A run missed while your Mac slept happens on wake."
            case .machine:
                "Runs on time whether your Mac is awake, asleep, or off."
            }
        }

        public var survivesSleep: Bool { self == .machine }
    }

    public init(id: String = UUID().uuidString, botID: String, name: String, prompt: String,
                cron: String, enabled: Bool = true, tier: Tier = .appOpen,
                lastFiredAt: Date? = nil) {
        self.id = id; self.botID = botID; self.name = name; self.prompt = prompt
        self.cron = cron; self.enabled = enabled; self.tier = tier; self.lastFiredAt = lastFiredAt
    }
}

/// Reads the five-field cron subset routines use, and answers when it next fires.
///
/// Deliberately not a general cron implementation. Supported: `*`, a number, comma lists and
/// `a-b` ranges. Step syntax is rejected rather than approximated — the same decision as the
/// systemd translation, for the same reason: a schedule that quietly fires at the wrong time is
/// worse than one that refuses to be created.
public struct CronExpression: Sendable, Equatable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let weekdays: Set<Int>

    public init(_ expression: String) throws {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else {
            throw CronError.malformed("expected five fields, got \(fields.count)")
        }
        guard !expression.contains("/") else {
            throw CronError.malformed("step syntax (*/n) is not supported; use an explicit list")
        }
        minutes = try Self.parse(fields[0], range: 0...59)
        hours = try Self.parse(fields[1], range: 0...23)
        daysOfMonth = try Self.parse(fields[2], range: 1...31)
        months = try Self.parse(fields[3], range: 1...12)
        // cron allows both 0 and 7 for Sunday; normalise to 0.
        weekdays = Set(try Self.parse(fields[4], range: 0...7).map { $0 == 7 ? 0 : $0 })
    }

    static func parse(_ field: String, range: ClosedRange<Int>) throws -> Set<Int> {
        if field == "*" { return Set(range) }
        var values: Set<Int> = []
        for part in field.split(separator: ",") {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] <= bounds[1],
                      range.contains(bounds[0]), range.contains(bounds[1])
                else { throw CronError.malformed("bad range '\(part)'") }
                values.formUnion(bounds[0]...bounds[1])
            } else {
                guard let value = Int(part), range.contains(value) else {
                    throw CronError.malformed("bad value '\(part)'")
                }
                values.insert(value)
            }
        }
        return values
    }

    /// Whether this moment matches. Minute resolution, which is all cron promises.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = parts.minute, let hour = parts.hour, let day = parts.day,
              let month = parts.month, let weekday = parts.weekday
        else { return false }
        // Calendar weekday is 1...7 with Sunday = 1; cron is 0...6 with Sunday = 0.
        return minutes.contains(minute) && hours.contains(hour)
            && daysOfMonth.contains(day) && months.contains(month)
            && weekdays.contains(weekday - 1)
    }

    /// The next firing at or after `date`, searching minute by minute for up to a year.
    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var candidate = calendar.date(bySetting: .second, value: 0, of: date)
            .map({ $0.addingTimeInterval(60) }) else { return nil }
        for _ in 0..<(366 * 24 * 60) {
            if matches(candidate, calendar: calendar) { return candidate }
            candidate.addTimeInterval(60)
        }
        return nil
    }

    /// launchd wants calendar components rather than a cron string. `*` becomes an omitted key,
    /// which is how `StartCalendarInterval` expresses "every".
    public func launchdIntervals() -> [[String: Int]] {
        var entries: [[String: Int]] = []
        let everyMinute = minutes.count == 60
        let everyHour = hours.count == 24
        let everyWeekday = weekdays.count == 7

        for minute in everyMinute ? [nil] : minutes.sorted().map(Optional.init) {
            for hour in everyHour ? [nil] : hours.sorted().map(Optional.init) {
                for weekday in everyWeekday ? [nil] : weekdays.sorted().map(Optional.init) {
                    var entry: [String: Int] = [:]
                    if let minute { entry["Minute"] = minute }
                    if let hour { entry["Hour"] = hour }
                    if let weekday { entry["Weekday"] = weekday }
                    entries.append(entry)
                }
            }
        }
        return entries
    }
}

public enum CronError: Error, Equatable, LocalizedError {
    case malformed(String)
    public var errorDescription: String? {
        if case .malformed(let detail) = self { return "Invalid schedule: \(detail)" }
        return nil
    }
}
