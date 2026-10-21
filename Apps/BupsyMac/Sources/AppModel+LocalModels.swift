import BupsyKit
import Foundation

/// The local engine's models, read live from Ollama and LM Studio.
///
/// `EngineAdapter.models` is a fixed list for Claude and Codex. A local model's list is whatever
/// the person has installed, so the app asks for it (a quick localhost GET to each runtime) at
/// launch with the engine check, whenever the engines are checked again, and from the model menu's
/// "Check for models", and keeps the answer in `localModels` for every menu to read.
extension AppModel {
    /// Asks Ollama and LM Studio what they have now. Takes about a second and a half at most,
    /// when neither is running.
    func refreshLocalModels() async {
        let runtime = await LocalAdapter().discover()
        localModels = runtime.options
        // A local bot made while nothing was installed has no model, and can't run without one.
        // Once there is a model, it starts on the first, which the person can change.
        if let first = localModels.first?.id {
            for bot in bots where bot.engine == .local && bot.model == nil && bot.remote == nil {
                setModel(bot, first)
            }
        }
        // The status follows the list, so a model pulled since the last check shows as ready.
        // Only once codex is known to be there: without it, nothing local can run anyway.
        switch engineStatus[.local] {
        case .signedIn?, .notReady?: engineStatus[.local] = runtime.status
        default: break
        }
    }

    /// The line under a local bot's model menu and in Settings: which models suit a bot.
    static let localModelAdvice = "Codex's local mode is built around gpt-oss:20b, which wants "
        + "about 16 GB of free memory. On a lighter Mac, a smaller model that handles tools well, "
        + "like qwen3:8b, works."

    /// Where to get a runtime, for the Settings button when none is set up.
    static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!
}
