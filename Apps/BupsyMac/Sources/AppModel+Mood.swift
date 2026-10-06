import BupsyKit
import Foundation

/// One answer to "how is this bot doing", for every face and every count in the app.
///
/// Before this, the sidebar asked whether a bot had an approval in its own thread, while the menu
/// bar asked whether it had anything in Waiting on you, so a group approval waved in one place and
/// not the other, and a stuck goal did the reverse. Every view now asks `mood(for:)`.
extension AppModel {
    /// How long a bot shows its "done" face after a run goes well.
    static let doneMoodDuration: TimeInterval = 8

    /// The mood a bot's face should show right now.
    ///
    /// In order: it needs you (an undecided approval anywhere it runs, a goal that needs
    /// attention, a question you have not answered), it is working, its last run failed, it just
    /// finished, it is asleep (bots paused, every routine off, or its machine stopped), otherwise
    /// idle.
    func mood(for bot: Bot) -> BotMood {
        // Read so a view showing this mood redraws when a "done" face should end.
        _ = moodTick

        if hasPendingDecision(bot) { return .waitingForYou }
        if isRunning(bot.id) { return .working }
        if lastFailedAt[bot.id] != nil { return .failed }
        if let finished = lastFinishedAt[bot.id],
           Date().timeIntervalSince(finished) < Self.doneMoodDuration {
            return .done
        }
        if isAsleep(bot) { return .sleeping }
        return .idle
    }

    /// True when the bot is blocked on you. The same test as the waving face.
    func needsYou(_ bot: Bot) -> Bool {
        mood(for: bot) == .waitingForYou
    }

    /// An undecided approval with this id, wherever this bot raised it: its own thread, the
    /// thread it is running in, or one of its group side threads.
    func pendingApproval(id: String, for botID: BotID) -> PendingApproval? {
        for thread in approvalThreads(for: botID) {
            for entry in thread.entries {
                if case .approval(let approval) = entry.kind, approval.id == id {
                    return approval
                }
            }
        }
        return nil
    }

    /// When the bot's next enabled routine fires, if it has one.
    func nextRoutineDate(for bot: Bot, after now: Date = Date()) -> Date? {
        routines
            .filter { $0.botID == bot.id.rawValue && $0.enabled }
            .compactMap { routine in
                (try? CronExpression(routine.cron)).flatMap { $0.nextFire(after: now) }
            }
            .min()
    }

    /// Called by a run as it ends, when it still owned the bot (a stopped run is neither).
    func recordRunEnded(_ botID: BotID, failed: Bool) {
        if failed {
            lastFailedAt[botID] = Date()
            lastFinishedAt[botID] = nil
            return
        }
        lastFailedAt[botID] = nil
        lastFinishedAt[botID] = Date()
        // Once the done face has had its moment, nudge every view reading moods to redraw.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.doneMoodDuration + 0.2))
            self?.moodTick &+= 1
        }
    }

    // MARK: - Parts

    private func hasPendingDecision(_ bot: Bot) -> Bool {
        for thread in approvalThreads(for: bot.id) {
            for entry in thread.entries {
                switch entry.kind {
                case .approval(let approval) where approval.decided == nil:
                    return true
                case .question(let question) where question.answer == nil:
                    return true
                default:
                    continue
                }
            }
        }
        return objectives.contains {
            $0.botID == bot.id.rawValue && $0.lastOutcome?.needsAttention == true
        }
    }

    private func isAsleep(_ bot: Bot) -> Bool {
        // Paused, nothing starts on its own, so every bot not doing something naps.
        if isPaused { return true }
        if let machineID = bot.machineID,
           let machine = machines.first(where: { $0.id == machineID }),
           ["stopped", "archived", "paused"].contains(machine.state) {
            return true
        }
        let own = routines.filter { $0.botID == bot.id.rawValue }
        return !own.isEmpty && own.allSatisfy { !$0.enabled }
    }
}
