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

    /// The engine a first bot runs on: the one picked if it can run, otherwise
    /// `defaultNewBotEngine`, the same default every other way of making a bot uses. A bot made
    /// before anything is signed in still exists; it simply asks for a sign-in when it first runs.
    func onboardingEngine(preferring picked: EngineID?) -> EngineID {
        if let picked, onboardingReadyEngines.contains(picked) { return picked }
        return defaultNewBotEngine
    }

    /// The command that installs an engine's CLI, shown with a copy button when it is missing.
    static func installCommand(for engine: EngineID) -> String {
        switch engine {
        // A local model runs through Codex's local mode, so Codex is what to install first.
        case .codex, .local: return "npm install -g @openai/codex"
        default: return "npm install -g @anthropic-ai/claude-code"
        }
    }

    /// The command to run once in Terminal to sign an installed engine in. For a local model,
    /// which has no sign-in, the command that gets a first model.
    static func signInCommand(for engine: EngineID) -> String {
        switch engine {
        case .codex: return "codex login"
        case .local: return "ollama pull qwen3:8b"
        default: return "claude"
        }
    }

    /// The tooltip for an engine's status line: the full line, plus the CLI's own words when the
    /// check failed, which are too raw to show in the row itself.
    static func engineStatusHelp(_ status: AuthStatus?, path: String? = nil) -> String {
        let line = accountStatusLine(status, path: path)
        if case .unknown(let message)? = status {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { return "\(line)\n\n\(detail)" }
        }
        return line
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
