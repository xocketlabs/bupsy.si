import AppKit
import Sparkle
import SwiftUI

/// Updates.
///
/// **Distribution is GitHub Releases only for now**, so there is no appcast feed and Sparkle's
/// automatic checking stays off. "Check for Updates" opens the releases page instead.
///
/// That is a deliberate choice rather than an omission: Sparkle polling a feed URL that does not
/// resolve fails quietly in the background forever, and a broken update channel is worse than an
/// honest absence of one. The machinery is all here — `scripts/appcast.sh` produces a signed
/// feed, and the release workflow signs every build — so switching on is a feed URL and a host.
///
/// When it is switched on, Sparkle verifies each update against an EdDSA key baked into the app.
/// For something that runs agent CLIs under the user's own credentials, that signature is the
/// difference between an update channel and an attack surface: a compromised download host, or
/// anyone able to intercept the feed, still cannot push a modified build.
@MainActor
final class Updater: ObservableObject {
    /// Where people get builds while there is no feed.
    static let releasesURL = URL(string: "https://github.com/xocketlabs/bupsy.si/releases/latest")!

    private let controller: SPUStandardUpdaterController?

    /// True once an appcast feed exists in the bundle.
    let hasFeed: Bool

    init() {
        hasFeed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .isEmpty == false

        guard hasFeed else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Daily is plenty for a desktop app and keeps the network quiet.
        controller.updater.updateCheckInterval = 60 * 60 * 24
        // Never without being asked. bupsy promises not to phone home, and a usage ping dressed
        // as an update check would make that promise false.
        controller.updater.sendsSystemProfile = false
        self.controller = controller
    }

    func checkForUpdates() {
        if let controller {
            controller.updater.checkForUpdates()
        } else {
            NSWorkspace.shared.open(Self.releasesURL)
        }
    }
}

struct UpdaterCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // Named for what it actually does. "Check for Updates…" that opens a web page would
            // be a small lie, and the whole product is built on not telling those.
            Button(updater.hasFeed ? "Check for Updates…" : "Releases on GitHub…") {
                updater.checkForUpdates()
            }
        }
    }
}
