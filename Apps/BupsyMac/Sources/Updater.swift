import Sparkle
import SwiftUI

/// Auto-updates.
///
/// Sparkle verifies every update against an EdDSA public key baked into the app, so a compromised
/// download host — or anyone who can intercept the feed — still cannot push a modified build. For
/// an app that runs agent CLIs with the user's credentials, that signature is the difference
/// between an update channel and an attack surface.
///
/// Checks are **not** automatic on first launch. An app that phones home before the user has
/// agreed to anything contradicts the thing bupsy says about itself, so the first check happens
/// after they have had a chance to turn it off.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        // Daily is plenty for a desktop app and keeps the network quiet.
        controller.updater.updateCheckInterval = 60 * 60 * 24
        // Never without being asked. bupsy promises not to phone home, and a silent usage ping
        // dressed as an update check would make that promise false.
        controller.updater.sendsSystemProfile = false
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
}

struct UpdaterCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
            Toggle("Check Automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
        }
    }
}
