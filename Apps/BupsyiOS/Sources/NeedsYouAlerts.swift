import BackgroundTasks
import UserNotifications

/// A local notification when a bot newly needs the person: "Lead needs you", or "Lead needs you on
/// Mac mini" once there's more than one Mac to tell apart.
///
/// This is version one's honest stand-in for push, not push. The phone only learns something when
/// it looks: every few seconds while the app is open, and now and then in the background when iOS
/// grants a refresh, which may be rarely or never. Real push needs the Mac to reach Apple's push
/// service, which is milestone two.
@MainActor
final class NeedsYouAlerts {
    /// Carries the bot's `macID:botID` in a notification, so a tap opens the right Mac's chat.
    nonisolated static let botKey = "bot"
    /// The one-Mac version's list of waiting bots, by bare bot id.
    private nonisolated static let legacyKey = "alerts.waiting"
    private nonisolated static let knownKey = "alerts.waitingByMac"

    /// For each Mac, the bots that needed the person at its last look. Saved, so a relaunch or a
    /// background refresh never announces the same wait twice. A Mac with no entry hasn't been
    /// looked at yet, and its first look only takes note: bots already waiting then are on the
    /// list in front of the person, not news.
    ///
    /// Kept per Mac because each Mac is looked at on its own schedule: one Mac's look must never
    /// take another's waiting bots for answered.
    private var known: [String: Set<String>] =
        (UserDefaults.standard.dictionary(forKey: knownKey) as? [String: [String]] ?? [:]).mapValues(Set.init)

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Notifies for each of one Mac's bots that needs the person now and didn't at its last look.
    ///
    /// - Parameters:
    ///   - showMac: whether to say which Mac, which is only worth saying when there's more than one.
    ///   - waiting: the total across every Mac, for the app's badge.
    ///   - openBotID: the chat on screen, which gets no banner: the person is looking at it.
    func update(_ bots: [Bot], on mac: PairedMac, client: RemoteClient, showMac: Bool,
                waiting: Int, quietFor openBotID: BotRef?) async {
        let centre = UNUserNotificationCenter.current()
        let now = Set(bots.filter(\.needsYou).map(\.ref.description))
        let before = known[mac.id]
        let fresh = before.map { now.subtracting($0) } ?? []
        // Answered here, on the Mac or elsewhere: a banner left behind would offer something done.
        let settled = (before ?? []).subtracting(now)
        if !settled.isEmpty { centre.removeDeliveredNotifications(withIdentifiers: settled.map(Self.identifier)) }
        known[mac.id] = now
        save()
        try? await centre.setBadgeCount(waiting)

        for bot in bots where fresh.contains(bot.ref.description) && bot.ref != openBotID {
            await post(for: bot, on: showMac ? mac.displayName : nil, client: client)
        }
    }

    /// Takes a bot's banner away once its chat is open.
    func clear(_ ref: BotRef) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(ref.description)])
    }

    /// Forgets one Mac's waits and takes its banners away, for a Mac that's gone from this phone.
    func forget(_ macID: String) {
        let gone = known.removeValue(forKey: macID) ?? []
        save()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.map(Self.identifier))
    }

    /// Back to a clean slate, for a phone that no longer has any Mac.
    func reset() {
        known = [:]
        save()
        let centre = UNUserNotificationCenter.current()
        centre.removeAllDeliveredNotifications()
        centre.setBadgeCount(0)
    }

    /// Files the one-Mac version's waiting bots under the Mac they were on, so the first look
    /// after the update doesn't announce them all again.
    nonisolated static func adoptLegacyWaits(for macID: String, in defaults: UserDefaults) {
        guard let ids = defaults.stringArray(forKey: legacyKey) else { return }
        var known = defaults.dictionary(forKey: knownKey) as? [String: [String]] ?? [:]
        known[macID] = ids.map { BotRef(macID: macID, botID: $0).description }
        defaults.set(known, forKey: knownKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private func save() {
        UserDefaults.standard.set(known.mapValues(Array.init), forKey: Self.knownKey)
    }

    private func post(for bot: Bot, on macName: String?, client: RemoteClient) async {
        let entries = (try? await client.thread(bot.ref.botID).entries) ?? []
        let content = UNMutableNotificationContent()
        content.title = Self.title(bot.name, on: macName)
        content.body = Self.describe(entries)
        content.sound = .default
        content.threadIdentifier = bot.ref.description
        content.userInfo = [Self.botKey: bot.ref.description]
        // One per bot, so a newer wait replaces an older banner rather than stacking up.
        let request = UNNotificationRequest(identifier: Self.identifier(bot.ref.description), content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private nonisolated static func identifier(_ ref: String) -> String { "needs-\(ref)" }

    /// "Lead needs you", or "Lead needs you on Mac mini".
    nonisolated static func title(_ botName: String, on macName: String?) -> String {
        let name = botName.isEmpty ? "A bot" : botName
        return macName.map { "\(name) needs you on \($0)" } ?? "\(name) needs you"
    }

    /// What the bot is waiting for, from its latest open approval or question:
    /// "Wants to run a command: npm test".
    nonisolated static func describe(_ entries: [Entry]) -> String {
        for entry in entries.reversed() {
            switch entry.kind {
            case .approval(let approval) where approval.decided == nil:
                let line = approval.summary.split(separator: "\n").first.map(String.init) ?? ""
                return line.isEmpty ? "Wants to \(approval.action)" : "Wants to \(approval.action): \(line)"
            case .question(let question) where question.answer == nil:
                return question.question.isEmpty ? "Has a question for you" : question.question
            default:
                continue
            }
        }
        return "Waiting on you"
    }
}

/// Asks iOS for a look at the Macs while the app is closed.
enum BackgroundRefresh {
    static let identifier = "si.bupsy.ios.refresh"

    /// No sooner than fifteen minutes from now. iOS decides when, and whether: it learns how
    /// often the person opens the app, and gives a rarely used one few turns or none.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
