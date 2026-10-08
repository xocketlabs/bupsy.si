import BackgroundTasks
import UserNotifications

/// A local notification when a bot newly needs the person: "Lead needs you".
///
/// This is version one's honest stand-in for push, not push. The phone only learns something when
/// it looks: every few seconds while the app is open, and now and then in the background when iOS
/// grants a refresh, which may be rarely or never. Real push needs the Mac to reach Apple's push
/// service, which is milestone two.
@MainActor
final class NeedsYouAlerts {
    /// Carries the bot's id in a notification, so a tap opens the right chat.
    nonisolated static let botKey = "bot"
    private static let knownKey = "alerts.waiting"

    /// The bots that needed the person at the last look. Saved, so a relaunch or a background
    /// refresh never announces the same wait twice. Nil before the first look, which only takes
    /// note: bots already waiting then are on the list in front of the person, not news.
    private var known: Set<String>? = UserDefaults.standard.stringArray(forKey: knownKey).map(Set.init)

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Notifies for each bot that needs the person now and didn't at the last look.
    ///
    /// - Parameter openBotID: the chat on screen, which gets no banner: the person is looking at it.
    func update(_ bots: [Bot], waiting: Int, client: RemoteClient, quietFor openBotID: String?) async {
        let centre = UNUserNotificationCenter.current()
        let now = Set(bots.filter(\.needsYou).map(\.id))
        let fresh = known.map { now.subtracting($0) } ?? []
        // Answered here, on the Mac or elsewhere: a banner left behind would offer something done.
        let settled = (known ?? []).subtracting(now)
        if !settled.isEmpty { centre.removeDeliveredNotifications(withIdentifiers: settled.map(Self.identifier)) }
        known = now
        UserDefaults.standard.set(Array(now), forKey: Self.knownKey)
        try? await centre.setBadgeCount(waiting)

        for bot in bots where fresh.contains(bot.id) && bot.id != openBotID {
            await post(for: bot, client: client)
        }
    }

    /// Takes a bot's banner away once its chat is open.
    func clear(_ botID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(botID)])
    }

    /// Back to a clean slate, for a phone that no longer has a Mac.
    func reset() {
        known = nil
        UserDefaults.standard.removeObject(forKey: Self.knownKey)
        let centre = UNUserNotificationCenter.current()
        centre.removeAllDeliveredNotifications()
        centre.setBadgeCount(0)
    }

    private func post(for bot: Bot, client: RemoteClient) async {
        let entries = (try? await client.thread(bot.id).entries) ?? []
        let content = UNMutableNotificationContent()
        content.title = "\(bot.name) needs you"
        content.body = Self.describe(entries)
        content.sound = .default
        content.threadIdentifier = bot.id
        content.userInfo = [Self.botKey: bot.id]
        // One per bot, so a newer wait replaces an older banner rather than stacking up.
        let request = UNNotificationRequest(identifier: Self.identifier(bot.id), content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func identifier(_ botID: String) -> String { "needs-\(botID)" }

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

/// Asks iOS for a look at the Mac while the app is closed.
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
