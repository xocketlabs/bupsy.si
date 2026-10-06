import Foundation
import Testing
@testable import BupsyKit

@Suite("Cron expressions")
struct CronExpressionTests {
    @Test("reads the subset routines actually use")
    func parsesSubset() throws {
        let weekdayMornings = try CronExpression("0 7 * * 1-5")
        #expect(weekdayMornings.minutes == [0])
        #expect(weekdayMornings.hours == [7])
        #expect(weekdayMornings.weekdays == [1, 2, 3, 4, 5])

        let twiceDaily = try CronExpression("0 9,17 * * *")
        #expect(twiceDaily.hours == [9, 17])
        #expect(twiceDaily.weekdays.count == 7)
    }

    /// cron accepts 0 and 7 for Sunday. Normalising at the edge means nothing downstream has to
    /// remember that, including the launchd and systemd translations.
    @Test("normalises both spellings of Sunday")
    func normalisesSunday() throws {
        #expect(try CronExpression("0 8 * * 0").weekdays == [0])
        #expect(try CronExpression("0 8 * * 7").weekdays == [0])
    }

    /// Same decision as the systemd translation: a schedule that quietly fires at the wrong time
    /// is worse than one that refuses to be created.
    @Test("refuses what it cannot represent faithfully")
    func rejectsUnsupported() {
        #expect(throws: CronError.self) { try CronExpression("*/15 * * * *") }
        #expect(throws: CronError.self) { try CronExpression("0 7 * *") }
        #expect(throws: CronError.self) { try CronExpression("99 7 * * *") }
        #expect(throws: CronError.self) { try CronExpression("0 7 * * 9") }
    }

    @Test("matches the right minute and only that minute")
    func matchesMinute() throws {
        let cron = try CronExpression("30 9 * * *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        func moment(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                timeZone: calendar.timeZone, year: 2026, month: 6, day: 15,
                hour: hour, minute: minute))!
        }
        #expect(cron.matches(moment(9, 30), calendar: calendar))
        #expect(!cron.matches(moment(9, 31), calendar: calendar))
        #expect(!cron.matches(moment(10, 30), calendar: calendar))
    }

    @Test("finds the next firing")
    func findsNextFire() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 6, day: 15, hour: 8, minute: 0))!

        let next = try #require(
            CronExpression("0 9 * * 1-5").nextFire(after: monday, calendar: calendar))
        #expect(calendar.component(.hour, from: next) == 9)
        #expect(calendar.component(.day, from: next) == 15)
    }

    /// Seconds into a minute must not push the search past the next minute: from 09:00:23 an
    /// every-minute schedule next fires at 09:01, not 09:02.
    @Test("does not skip the next minute when called mid-minute")
    func nextFireMidMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func moment(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(
                timeZone: calendar.timeZone, year: 2026, month: 6, day: 15,
                hour: hour, minute: minute, second: second))!
        }
        let everyMinute = try CronExpression("* * * * *")
        #expect(everyMinute.nextFire(after: moment(9, 0, 23), calendar: calendar) == moment(9, 1))
        #expect(everyMinute.nextFire(after: moment(9, 0), calendar: calendar) == moment(9, 1))

        let nineOhOne = try CronExpression("1 9 * * *")
        #expect(nineOhOne.nextFire(after: moment(9, 0, 59), calendar: calendar) == moment(9, 1))
    }

    /// Standard cron: when both day fields are restricted, a day matches if either does.
    @Test("ORs day-of-month and day-of-week when both are restricted")
    func daysAreOred() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ d: Int) -> Date {
            calendar.date(from: DateComponents(
                timeZone: calendar.timeZone, year: 2026, month: 6, day: d, hour: 9, minute: 0))!
        }
        // June 2026: the 1st is a Monday, the 15th a Monday, the 13th a Saturday.
        let firstOrMonday = try CronExpression("0 9 13 * 1")
        #expect(firstOrMonday.matches(day(13), calendar: calendar), "the 13th, a Saturday")
        #expect(firstOrMonday.matches(day(15), calendar: calendar), "a Monday that is not the 13th")
        #expect(!firstOrMonday.matches(day(16), calendar: calendar))

        // Only one restricted: the other `*` does not widen it to every day.
        #expect(!(try CronExpression("0 9 13 * *")).matches(day(15), calendar: calendar))
        #expect(!(try CronExpression("0 9 * * 1")).matches(day(13), calendar: calendar))
        #expect(try CronExpression("0 9 * * 1").matches(day(15), calendar: calendar))
    }

    /// launchd expresses "every" by omitting the key rather than with a wildcard.
    @Test("translates to launchd calendar intervals")
    func translatesToLaunchd() throws {
        let intervals = try CronExpression("0 7 * * 1-5").launchdIntervals()
        #expect(intervals.count == 5)
        #expect(intervals.allSatisfy { $0["Hour"] == 7 && $0["Minute"] == 0 })
        #expect(Set(intervals.compactMap { $0["Weekday"] }) == [1, 2, 3, 4, 5])

        let daily = try CronExpression("30 6 * * *").launchdIntervals()
        #expect(daily.count == 1)
        #expect(daily[0]["Weekday"] == nil, "every weekday means the key is omitted")
    }
}

@Suite("Routine scheduler")
struct RoutineSchedulerTests {
    let scheduler = RoutineScheduler()
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 6, day: day,
            hour: hour, minute: minute))!
    }

    @Test("a new routine fires on its minute, not for every slot since the epoch")
    func newRoutineDoesNotBackfill() {
        let routine = Routine(botID: "b", name: "Brief", prompt: "p", cron: "0 7 * * *")
        #expect(scheduler.due(routines: [routine], now: moment(15, 7, 0), calendar: calendar).count == 1)
        #expect(scheduler.due(routines: [routine], now: moment(15, 9, 0), calendar: calendar).isEmpty)
    }

    /// The point of tier 2. A routine whose moment passed while the Mac slept still runs — the
    /// 7am briefing you read at 9am is worth having.
    @Test("a run missed during sleep fires late rather than being lost")
    func missedRunFiresLate() {
        var routine = Routine(botID: "b", name: "Brief", prompt: "p", cron: "0 7 * * *")
        routine.lastFiredAt = moment(14, 7, 0)

        let due = scheduler.due(routines: [routine], now: moment(15, 9, 30), calendar: calendar)
        #expect(due.count == 1)
        #expect(due.first?.isLate == true)
        #expect(due.first?.scheduledFor == moment(15, 7, 0))
    }

    /// And nobody wants eleven briefings because they were away for a fortnight.
    @Test("a fortnight away produces one run, not fourteen")
    func collapsesMissedSlots() {
        var routine = Routine(botID: "b", name: "Brief", prompt: "p", cron: "0 7 * * *")
        routine.lastFiredAt = moment(1, 7, 0)

        let due = scheduler.due(routines: [routine], now: moment(15, 9, 0), calendar: calendar)
        #expect(due.count == 1)
        #expect(due.first?.scheduledFor == moment(15, 7, 0), "the most recent slot, not the oldest")
    }

    @Test("a disabled routine never fires")
    func disabledNeverFires() {
        var routine = Routine(botID: "b", name: "Brief", prompt: "p", cron: "0 7 * * *",
                              enabled: false)
        routine.lastFiredAt = moment(14, 7, 0)
        #expect(scheduler.due(routines: [routine], now: moment(15, 7, 0), calendar: calendar).isEmpty)
    }

    @Test("only launchAgent-tier routines reach launchd, deduplicated")
    func onlyAgentTierGoesToLaunchd() {
        let routines = [
            Routine(botID: "b", name: "a", prompt: "p", cron: "0 7 * * *", tier: .appOpen),
            Routine(botID: "b", name: "b", prompt: "p", cron: "0 7 * * *", tier: .launchAgent),
            Routine(botID: "b", name: "c", prompt: "p", cron: "0 7 * * *", tier: .launchAgent),
            Routine(botID: "b", name: "d", prompt: "p", cron: "0 9 * * *", tier: .machine),
        ]
        let intervals = scheduler.launchdIntervals(for: routines)
        #expect(intervals.count == 1, "two agent routines at the same time share one interval")
        #expect(intervals.first?["Hour"] == 7)
    }
}

@Suite("Tier promises")
struct TierPromiseTests {
    /// Overclaiming here would be the worst lie the product could tell, so the honest sentence
    /// lives with the enum and is asserted rather than left to a view.
    @Test("only a machine survives the Mac sleeping")
    func onlyMachineSurvivesSleep() {
        #expect(!Routine.Tier.appOpen.survivesSleep)
        #expect(!Routine.Tier.launchAgent.survivesSleep)
        #expect(Routine.Tier.machine.survivesSleep)
    }

    @Test("every tier states its limit in words the UI can show")
    func everyTierStatesItsLimit() {
        #expect(Routine.Tier.appOpen.promise.contains("only while Bupsy is open"))
        #expect(Routine.Tier.launchAgent.promise.contains("on wake"))
        #expect(Routine.Tier.machine.promise.contains("asleep, or off"))
    }

    @Test("the LaunchAgent plist launches the app without stealing focus")
    func plistShape() throws {
        let plist = LaunchAgent.plist(
            intervals: [["Hour": 7, "Minute": 0]], appPath: "/Applications/Bupsy.app")
        let arguments = try #require(plist["ProgramArguments"] as? [String])

        #expect(arguments.contains("-gj"), "background, no focus steal")
        #expect(arguments.contains("--run-due-routines"))
        #expect(plist["RunAtLoad"] as? Bool == false, "installing must not fire every routine")
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["Label"] as? String == "si.bupsy.routines")
    }
}

@Suite("Routine storage")
struct RoutineStorageTests {
    @Test("a routine survives being written and read back")
    func roundTrips() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)

        let routine = Routine(
            botID: bot.id, name: "Morning brief", prompt: "What happened overnight?",
            cron: "0 7 * * 1-5", tier: .launchAgent, lastFiredAt: Date(timeIntervalSince1970: 1_000_000))
        try store.save(routine)

        let loaded = try #require(try store.routines().first)
        #expect(loaded.id == routine.id)
        #expect(loaded.name == "Morning brief")
        #expect(loaded.cron == "0 7 * * 1-5")
        #expect(loaded.tier == .launchAgent)
        #expect(loaded.lastFiredAt == routine.lastFiredAt)
    }

    /// Routine fields live in the trigger's config blob, so a new field needs no migration.
    @Test("a routine that has never fired reads back as never fired")
    func neverFiredStaysNil() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        try store.save(Routine(botID: bot.id, name: "x", prompt: "p", cron: "0 7 * * *"))

        #expect(try store.routines().first?.lastFiredAt == nil)
    }

    @Test("deleting a bot takes its routines with it")
    func deletingBotRemovesRoutines() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        try store.save(Routine(botID: bot.id, name: "x", prompt: "p", cron: "0 7 * * *"))

        try store.deleteBot(id: bot.id)
        #expect(try store.routines().isEmpty)
    }
}

@Suite("Schedules in words")
struct CronWordsTests {
    @Test("simple schedules read as words")
    func describesSimpleSchedules() {
        #expect(CronWords.describe("0 2 * * *") == "Every day at 2am")
        #expect(CronWords.describe("30 14 * * 1-5") == "Weekdays at 2:30pm")
        #expect(CronWords.describe("5 9 * * 1") == "Mondays at 9:05am")
        #expect(CronWords.describe("0 9 * * 1,3,5") == "Mondays, Wednesdays and Fridays at 9am")
        #expect(CronWords.describe("0 10 * * 0,6") == "Weekends at 10am")
        #expect(CronWords.describe("0 0 * * *") == "Every day at 12am")
        #expect(CronWords.describe("0 12 * * *") == "Every day at 12pm")
        #expect(CronWords.describe("0 9,17 * * *") == "Every day at 9am and 5pm")
        #expect(CronWords.describe("0 9,13,17 * * *") == "Every day at 9am, 1pm and 5pm")
    }

    @Test("intervals read as words")
    func describesIntervals() {
        #expect(CronWords.describe("0 * * * *") == "Every hour")
        #expect(CronWords.describe("15 * * * 1-5") == "Every hour at 15 minutes past on weekdays")
        #expect(CronWords.describe("0,15,30,45 * * * *") == "Every 15 minutes")
        #expect(CronWords.describe("0 0,4,8,12,16,20 * * *") == "Every 4 hours")
        #expect(CronWords.describe("0 9-18 * * 1-5") == "Every hour from 9am to 6pm on weekdays")
    }

    /// Words that are nearly right are worse than the cron as written.
    @Test("anything else is left to the caller")
    func leavesTheRest() {
        #expect(CronWords.describe("0 12 1 * *") == nil)
        #expect(CronWords.describe("0 9 * 6 *") == nil)
        #expect(CronWords.describe("0,30 9,10 * * *") == nil)
        #expect(CronWords.describe("0 1,3,5,7,9 * * *") == nil)
        #expect(CronWords.describe("nonsense") == nil)
    }

    @Test("a custom time builds a cron that reads back the same")
    func customTime() {
        let nightly = CronWords.Time(hour: 2, minute: 0)
        #expect(CronWords.cron(for: nightly) == "0 2 * * *")
        #expect(CronWords.time(of: "0 2 * * *") == nightly)

        let weekdays = CronWords.Time(hour: 9, minute: 30, weekdays: Set(1...5))
        #expect(CronWords.cron(for: weekdays) == "30 9 * * 1-5")
        #expect(CronWords.time(of: "30 9 * * 1-5") == weekdays)

        let some = CronWords.Time(hour: 18, minute: 5, weekdays: [5, 1])
        #expect(CronWords.cron(for: some) == "5 18 * * 1,5")
        #expect(CronWords.describe(CronWords.cron(for: some)) == "Mondays and Fridays at 6:05pm")

        // All seven days is every day.
        #expect(CronWords.cron(for: CronWords.Time(hour: 7, minute: 0, weekdays: Set(0...6))) == "0 7 * * *")
        // Twice a day is not one time, so it is not opened in the editor.
        #expect(CronWords.time(of: "0 9,17 * * *") == nil)
    }
}
