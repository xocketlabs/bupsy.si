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
        // Testing only: pair with a stand-in Mac and open a chat without touching the screen, for
        // screenshots and UI checks on a simulator. Debug builds only; release builds have no
        // such switch, like the Mac's BUPSY_REMOTE_TEST_PORT.
        let environment = ProcessInfo.processInfo.environment
        if let botID = environment["BUPSY_TEST_OPEN_BOT"] { session.open(botID) }
        if !session.isPaired, let link = environment["BUPSY_TEST_PAIR_LINK"].flatMap(PairingLink.init(scanned:)) {
            Task { try? await session.pair(link) }
        }
        #endif
        return true
    }

    /// A bot needs the person while the app is open: show the banner, unless that chat is the
    /// one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let botID = notification.request.content.userInfo[NeedsYouAlerts.botKey] as? String
        let onScreen = await session.openBotID
        return botID != nil && botID == onScreen ? [] : [.banner, .list, .sound]
    }

    /// A tap on a banner opens that bot's chat.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let botID = response.notification.request.content.userInfo[NeedsYouAlerts.botKey] as? String else { return }
        await session.open(botID)
    }
}
