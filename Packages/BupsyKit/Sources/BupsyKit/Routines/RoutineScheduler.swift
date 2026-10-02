import Foundation

/// Works out which routines are due, and never fires one twice.
///
/// Intentionally a pure decision-maker rather than something that runs anything: it is given a
/// clock and a list of routines, and answers which should run. That makes "did this fire when it
/// should have?" a testable question rather than one you answer by waiting until 7am.
public struct RoutineScheduler: Sendable {

    public struct Due: Sendable, Equatable {
        public let routine: Routine
        /// The scheduled moment this run is *for*, which is not the same as now — a routine that
        /// fires late after sleep is still that morning's briefing, and recording the slot it
        /// filled is what stops it running twice.
        public let scheduledFor: Date
        public let isLate: Bool
    }

    public init() {}

    /// Routines that should run now.
    ///
    /// A routine whose moment passed while the Mac slept is returned **once**, marked late, rather
    /// than silently skipped — the 7am briefing you read at 9am is still worth having. It is not
    /// returned once per missed slot: nobody wants eleven briefings because they were away.
    public func due(
        routines: [Routine],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Due] {
        routines.compactMap { routine in
            guard routine.enabled, let cron = try? CronExpression(routine.cron) else { return nil }

            // Never fired: due only if this exact minute matches. A brand-new routine should not
            // immediately fire for every slot since the epoch.
            guard let last = routine.lastFiredAt else {
                return cron.matches(now, calendar: calendar)
                    ? Due(routine: routine, scheduledFor: now, isLate: false)
                    : nil
            }

            guard let next = cron.nextFire(after: last, calendar: calendar), next <= now
            else { return nil }

            // Collapse every slot missed since `last` into the most recent one.
            var mostRecent = next
            while let following = cron.nextFire(after: mostRecent, calendar: calendar),
                  following <= now {
                mostRecent = following
            }

            return Due(
                routine: routine,
                scheduledFor: mostRecent,
                isLate: now.timeIntervalSince(mostRecent) > 90
            )
        }
    }

    /// The launchd intervals covering every routine that should run with the app closed.
    public func launchdIntervals(for routines: [Routine]) -> [[String: Int]] {
        var seen: Set<String> = []
        var intervals: [[String: Int]] = []
        for routine in routines
        where routine.enabled && routine.tier == .launchAgent {
            guard let cron = try? CronExpression(routine.cron) else { continue }
            for interval in cron.launchdIntervals() {
                let key = interval.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                if seen.insert(key).inserted { intervals.append(interval) }
            }
        }
        return intervals
    }
}
