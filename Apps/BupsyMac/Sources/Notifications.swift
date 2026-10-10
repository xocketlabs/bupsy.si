import BupsyKit
import UserNotifications

/// Tells you when something happened while you were not looking.
///
/// Without this the always-on half of the product is invisible: a routine fires at 7am, a bot
/// blocks on a decision at 3am, and nothing says so until you next open the window. An agent you
/// have to remember to check is not working unattended.
///
/// Deliberately quiet. Nothing is sent while Bupsy is the active app (you can already see it),
/// and a finished run only notifies when it did something worth reporting.
@MainActor
final class Notifier {
    private var authorised = false

    /// Asked for on first use rather than at launch. A permission prompt before the app has done
    /// anything is the one people deny.
    func requestAuthorizationIfNeeded() async {
        guard !authorised else { return }
        let centre = UNUserNotificationCenter.current()
        authorised = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// - Parameter approvalID: the gate request's id, when the caller has it. With it, Allow and
    ///   Deny on the banner answer exactly that request; without it they match on bot, tool and
    ///   summary, which is what the banner showed.
    /// - Parameter botID: carried in the banner so a press finds the bot by id, not by a name
    ///   that may have changed since, and so a click can open the right bot.
    func needsApproval(bot: String, tool: String, summary: String, approvalID: String? = nil,
                       botID: BotID? = nil) {
        // A bot's question with set answers comes through here too, as "a question". Allow and
        // Deny mean nothing for it, so it gets a plain banner that opens the app.
        let isToolRequest = tool != "a question"
        var info: [String: String] = [:]
        if isToolRequest {
            info = [ApprovalNotificationActions.botKey: bot,
                    ApprovalNotificationActions.toolKey: tool,
                    ApprovalNotificationActions.summaryKey: summary]
            if let approvalID { info[ApprovalNotificationActions.approvalKey] = approvalID }
        }
        // Allow from a banner only when the banner shows the whole request. A long command is cut
        // off in the banner, and what comes after the cut (`… && rm -rf ~`) is exactly the part
        // that matters; those banners offer Review, which opens the full card, and Deny.
        let category = ApprovalNotificationActions.showsWhole(summary)
            ? ApprovalNotificationActions.category : ApprovalNotificationActions.reviewCategory
        // One banner per request, so answering it in the app can take exactly that banner away.
        post(
            id: approvalID.map { Self.approvalIdentifier($0) } ?? "approval-\(bot)-\(summary.hashValue)",
            title: "\(bot) needs you",
            body: summary.isEmpty ? "Wants to use \(tool)" : summary,
            sound: true,
            category: isToolRequest ? category : nil,
            info: info,
            botID: botID
        )
    }

    /// The notification identifier for one approval request.
    static func approvalIdentifier(_ approvalID: String) -> String { "approval-\(approvalID)" }

    /// Takes away the banner for a request that was answered, or that can no longer be answered,
    /// so Allow on a stale banner is never offered.
    func clearApproval(_ approvalID: String) {
        let ids = [Self.approvalIdentifier(approvalID)]
        let centre = UNUserNotificationCenter.current()
        centre.removeDeliveredNotifications(withIdentifiers: ids)
        centre.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func objectiveNeedsYou(bot: String, question: String, botID: BotID? = nil) {
        post(id: "objective-\(bot)-\(question.hashValue)",
             title: "\(bot) needs you", body: question, sound: true, botID: botID)
    }

    /// A routine finished. Quiet, because this is information rather than a request.
    func routineFinished(bot: String, routine: String, summary: String?, botID: BotID? = nil) {
        post(
            id: "routine-\(bot)-\(routine)",
            title: "\(bot) finished \(routine)",
            body: summary ?? "Open Bupsy to see what it did.",
            sound: false,
            botID: botID
        )
    }

    /// Something a bot decided the person should know, sent with notify_person.
    func fromBot(title: String, text: String, botID: BotID) {
        post(id: "bot-\(botID.rawValue)-\(text.hashValue)", title: title, body: text, sound: true, botID: botID)
    }

    func failed(bot: String, reason: String, botID: BotID? = nil) {
        post(id: "failed-\(bot)", title: "\(bot) stopped", body: reason, sound: false, botID: botID)
    }

    /// The most of a body a banner is given. Past this it is cut.
    static let bodyLimit = 240

    private func post(id: String, title: String, body: String, sound: Bool,
                      category: String? = nil, info: [String: String] = [:],
                      botID: BotID? = nil) {
        // You are looking at the app; a banner over it is noise.
        guard !NSApp.isActive else { return }
        #if DEBUG
        // A demo take posts nothing to the real Notification Centre.
        if DemoMode.isOn { return }
        #endif
        var info = info
        // Every banner says which bot it is about, so a click can open that bot.
        if let botID { info[ApprovalNotificationActions.botIDKey] = botID.rawValue }

        Task {
            await requestAuthorizationIfNeeded()
            guard authorised else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(Self.bodyLimit))
            if sound { content.sound = .default }
            if let category { content.categoryIdentifier = category }
            if !info.isEmpty { content.userInfo = info }

            // A stable id per cause, so ten tool calls in one run replace each other rather than
            // stacking ten banners.
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

/// Allow and Deny on an approval banner, answered without opening the window.
///
/// The buttons call `AppModel.decide`, the same path the in-app approval card, the attention
/// inbox and the menu bar use, so a decision made from a banner is recorded, audited and shown
/// in the thread exactly like one made anywhere else. If the request was already answered or
/// timed out by the time the button is pressed, nothing matches and nothing happens.
@MainActor
final class ApprovalNotificationActions: NSObject, UNUserNotificationCenterDelegate {
    static let category = "bupsy.approval"
    /// For a request too long to read in a banner: Review and Deny, no Allow.
    static let reviewCategory = "bupsy.approval.review"
    static let allowAction = "bupsy.approval.allow"
    static let denyAction = "bupsy.approval.deny"
    static let reviewAction = "bupsy.approval.review"

    /// Whether a banner shows this request whole, so Allow can be offered beside it. Well under
    /// `Notifier.bodyLimit`, where the body is cut outright, because a banner that is not expanded shows only a couple of lines of
    /// its body, and a line break can push the rest out of sight even in a short command.
    static func showsWhole(_ summary: String) -> Bool {
        summary.count <= 80 && !summary.contains(where: \.isNewline)
    }
    static let botKey = "bot"
    static let toolKey = "tool"
    static let summaryKey = "summary"
    static let approvalKey = "approval"
    static let botIDKey = "botID"

    private weak var model: AppModel?
    /// A press that arrived before the model was attached, as at a launch the banner caused.
    private var waiting: [(action: String, info: [String: String])] = []

    override init() {
        super.init()
        // Set as early as possible: a press on a banner that launched the app is delivered to
        // whichever delegate is set when it finishes launching.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Registers the category and starts answering. Registering needs no permission, so this is
    /// safe at launch; the permission prompt still waits for the first notification.
    func attach(to model: AppModel) {
        self.model = model
        // Allow lets a bot run something on this Mac, so it asks for the Mac to be unlocked first:
        // a banner on a locked or unattended screen should not be one click from running it.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Review…", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.category, actions: [allow, deny],
                                              intentIdentifiers: [], options: [])
        let reviewCategory = UNNotificationCategory(identifier: Self.reviewCategory, actions: [review, deny],
                                                    intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, reviewCategory])
        let pending = waiting
        waiting = []
        for item in pending { handle(action: item.action, info: item.info) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Copied out as plain strings here, so nothing that is not Sendable crosses to the main
        // actor.
        let action = response.actionIdentifier
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        Task { @MainActor in
            self.handle(action: action, info: info)
        }
        completionHandler()
    }

    private func handle(action: String, info: [String: String]) {
        if action == UNNotificationDefaultActionIdentifier || action == Self.reviewAction {
            openBot(info: info)
            return
        }
        guard action == Self.allowAction || action == Self.denyAction else { return }
        guard let model else {
            waiting.append((action: action, info: info))
            return
        }
        // By id: a bot renamed after the banner went out is still the same bot. The name is only
        // a fallback for a banner posted before ids were included.
        let byID = info[Self.botIDKey].flatMap { id in model.bots.first { $0.id.rawValue == id } }
        let byName = info[Self.botKey].flatMap { name in model.bots.first { $0.name == name } }
        guard let bot = byID ?? (info[Self.botIDKey] == nil ? byName : nil),
              let approval = Self.pending(for: bot, info: info, in: model)
        else { return }
        model.decide(approval, allow: action == Self.allowAction, for: bot)
    }

    /// A click on the banner itself: the window comes forward (reopened if it was closed) on the
    /// bot the banner was about. Every banner carries the bot's id; the name is the fallback for
    /// one posted before ids were included.
    private func openBot(info: [String: String]) {
        guard let model else {
            waiting.append((action: UNNotificationDefaultActionIdentifier, info: info))
            return
        }
        let byID = info[Self.botIDKey].flatMap { id in model.bots.first { $0.id.rawValue == id } }
        let byName = info[Self.botKey].flatMap { name in model.bots.first { $0.name == name } }
        model.showMainWindow()
        if let bot = byID ?? (info[Self.botIDKey] == nil ? byName : nil) {
            model.open(bot.id)
        }
    }

    /// The undecided request the banner was about: by id when it carried one, otherwise the one
    /// with the same tool and summary, in the bot's own thread or its thread inside a group.
    private static func pending(for bot: Bot, info: [String: String], in model: AppModel) -> PendingApproval? {
        var candidates: [PendingApproval] = []
        for entry in model.thread(for: bot.id).entries {
            if case .approval(let approval) = entry.kind, approval.decided == nil {
                candidates.append(approval)
            }
        }
        for group in model.groups {
            for (member, approval) in model.pendingApprovals(in: group) where member.id == bot.id {
                candidates.append(approval)
            }
        }
        if let id = info[approvalKey] {
            return candidates.first { $0.id == id }
        }
        let tool = info[toolKey] ?? ""
        let summary = info[summaryKey] ?? ""
        return candidates.first { $0.tool == tool && $0.summary == summary }
    }
}

#if canImport(AppKit)
import AppKit
#endif
