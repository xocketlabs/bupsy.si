import BupsyKit
import Foundation

/// What the welcome flow needs from the model to make the person's first bot.
///
/// Everything here goes through the same calls the bot creator uses (`addBot`, `setAutonomy`),
/// so a bot made during onboarding is an ordinary bot in every way.
extension AppModel {
    /// Names offered for the first bot, in order. The first one nobody is using wins, so the
    /// field never starts on a name that would be refused.
    static let onboardingNameIdeas = [
        "Scout", "Pip", "Juno", "Milo", "Nova", "Ziggy", "Biscuit", "Pixel", "Mochi", "Otto",
    ]

    /// A name for the first bot that no other bot answers to.
    func onboardingSuggestedName() -> String {
        if let free = Self.onboardingNameIdeas.first(where: { !isNameTaken($0) }) { return free }
        var counter = 2
        while isNameTaken("Buddy \(counter)") { counter += 1 }
        return "Buddy \(counter)"
    }

    /// The engines that are signed in and able to run, in the app's usual order.
    var onboardingReadyEngines: [EngineID] {
        EngineID.supported.filter { engineStatus[$0]?.isUsable == true }
    }

    /// The engine a first bot runs on: the one picked if it can run, otherwise the first that
    /// can, otherwise Claude Code, the same default the bot creator starts from. A bot made
    /// before anything is signed in still exists; it simply asks for a sign-in when it first runs.
    func onboardingEngine(preferring picked: EngineID?) -> EngineID {
        let ready = onboardingReadyEngines
        if let picked, ready.contains(picked) { return picked }
        return ready.first ?? .claude
    }

    /// Makes the first bot for real and finishes onboarding.
    ///
    /// Called only from the last step, so going Back and forth through the flow never leaves a
    /// half-made bot behind. Returns the new bot's id, or nil when the name was taken in the
    /// meantime (the caller sends the person back to pick another).
    @discardableResult
    func createOnboardingBot(name: String, engine: EngineID, shape: BotShape, colour: Int,
                             trust: Autonomy, section: String?) -> BotID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isNameTaken(trimmed) else { return nil }
        let folder = section?.trimmingCharacters(in: .whitespaces)
        addBot(name: trimmed, engine: engine, folder: (folder?.isEmpty ?? true) ? nil : folder,
               shape: shape, colour: colour)
        guard let bot = bots.first(where: { $0.name == trimmed }) else { return nil }
        if bot.autonomy != trust { setAutonomy(bot, trust) }
        completeOnboarding()
        // addBot already selected it; set again so the root view opens its chat even if
        // something else moved the selection in between.
        selectedBotID = bot.id
        return bot.id
    }

    /// Opens the Apps page once the welcome sheet is gone. Set a moment later so it lands after
    /// the root view has opened the new bot's chat.
    func openAppsAfterOnboarding() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.pendingDestination = .connectors
        }
    }
}
