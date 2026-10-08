import SwiftUI
import UserNotifications

@main
struct BupsyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.session)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [session = delegate.session] in
            await session.refreshInBackground()
        }
    }
}

/// Owns the session, so a notification tapped while the app was closed has somewhere to land
/// before any view exists, and answers the notification centre.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let session = AppSession()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // Testing only: pair with stand-in Macs and open a chat or the Macs screen without
        // touching the screen, for screenshots and UI checks on a simulator. Debug builds only;
        // release builds have no such switch, like the Mac's BUPSY_REMOTE_TEST_PORT.
        //   BUPSY_TEST_PAIR_LINK  one or more pairing links, separated by spaces
        //   BUPSY_TEST_OPEN_BOT   a bot's id on its own Mac, opened once the Macs have answered;
        //                         "<id>@<Mac name>" picks one Mac's when two share the id
        //   BUPSY_TEST_SHOW_MACS  any value: open "Your Macs"
        let environment = ProcessInfo.processInfo.environment
        let links = (environment["BUPSY_TEST_PAIR_LINK"] ?? "").split(separator: " ")
            .compactMap { PairingLink(scanned: String($0)) }
        let openBot = environment["BUPSY_TEST_OPEN_BOT"]
        let showMacs = environment["BUPSY_TEST_SHOW_MACS"] != nil
        Task { [session] in
            for link in links where !session.macs.contains(where: { $0.address == link.address && !$0.unpaired }) {
                try? await session.pair(link)
            }
            if !links.isEmpty { await session.refreshAll() }
            if let openBot {
                let parts = openBot.split(separator: "@", maxSplits: 1).map(String.init)
                let bot = session.listed.first { listed in
                    listed.bot.ref.botID == parts[0] && (parts.count == 1 || listed.mac.displayName == parts[1])
                }
                if let bot { session.open(bot.id) }
            }
            if showMacs { session.showingMacs = true }
        }
        #endif
        return true
    }

    /// A bot needs the person while the app is open: show the banner, unless that chat is the
    /// one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let tag = notification.request.content.userInfo[NeedsYouAlerts.botKey] as? String
        let onScreen = await session.openBotID?.description
        return tag != nil && tag == onScreen ? [] : [.banner, .list, .sound]
    }

    /// A tap on a banner opens that bot's chat, on its own Mac.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let tag = response.notification.request.content.userInfo[NeedsYouAlerts.botKey] as? String else { return }
        await MainActor.run {
            if let ref = session.ref(fromNotification: tag) { session.open(ref) }
        }
    }
}
