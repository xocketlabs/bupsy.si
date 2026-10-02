import BupsyKit
import UserNotifications

/// Tells you when something happened while you were not looking.
///
/// Without this the always-on half of the product is invisible: a routine fires at 7am, a bot
/// blocks on a decision at 3am, and nothing says so until you next open the window. An agent you
/// have to remember to check is not working unattended.
///
/// Deliberately quiet. Nothing is sent while bupsy is the active app — you can already see it —
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

    func needsApproval(bot: String, tool: String, summary: String) {
        post(
            id: "approval-\(bot)-\(summary.hashValue)",
            title: "\(bot) needs your approval",
            body: summary.isEmpty ? tool : summary,
            sound: true
        )
    }

    func objectiveNeedsYou(bot: String, question: String) {
        post(id: "objective-\(bot)-\(question.hashValue)",
             title: "\(bot) is stuck", body: question, sound: true)
    }

    /// A routine finished. Quiet, because this is information rather than a request.
    func routineFinished(bot: String, routine: String, summary: String?) {
        post(
            id: "routine-\(bot)-\(routine)",
            title: "\(bot) finished \(routine)",
            body: summary ?? "Open bupsy to see what it did.",
            sound: false
        )
    }

    func failed(bot: String, reason: String) {
        post(id: "failed-\(bot)", title: "\(bot) stopped", body: reason, sound: false)
    }

    private func post(id: String, title: String, body: String, sound: Bool) {
        // You are looking at the app; a banner over it is noise.
        guard !NSApp.isActive else { return }

        Task {
            await requestAuthorizationIfNeeded()
            guard authorised else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(240))
            if sound { content.sound = .default }

            // A stable id per cause, so ten tool calls in one run replace each other rather than
            // stacking ten banners.
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
