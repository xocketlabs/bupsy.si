import BupsyKit
import Foundation
import Observation

/// Everything the UI reads, and the one place a run is started.
///
/// State is in memory for now. GRDB persistence is M2 — see docs/03-decisions.md #11. Keeping it
/// in memory first means the event-folding and streaming get proven before a schema is committed to.
@MainActor
@Observable
final class AppModel {
    var bots: [Bot] = []
    var selectedBotID: BotID?
    var engineStatus: [EngineID: AuthStatus] = [:]

    private var threads: [BotID: Thread] = [:]
    private var running: [BotID: Task<Void, Never>] = [:]

    private let host: any ExecutionHost = LocalHost()
    private let adapters: [EngineID: any EngineAdapter] = [
        .claude: ClaudeAdapter(),
        .codex: CodexAdapter(),
    ]

    init() {
        bots = [
            Bot(name: "Scout", engine: .claude,
                personaPrompt: "You research things and report back plainly. Be concise."),
            Bot(name: "Builder", engine: .claude,
                personaPrompt: "You write and fix code. Explain what you changed and why."),
            Bot(name: "Inbox", engine: .codex,
                personaPrompt: "You triage and summarise. Lead with what needs a decision."),
        ]
        selectedBotID = bots.first?.id
    }

    var selectedBot: Bot? {
        bots.first { $0.id == selectedBotID }
    }

    func thread(for botID: BotID) -> Thread {
        if let existing = threads[botID] { return existing }
        let created = Thread(botID: botID)
        threads[botID] = created
        return created
    }

    func isRunning(_ botID: BotID) -> Bool { running[botID] != nil }

    /// Checks each engine once at launch.
    ///
    /// Note this asks the adapter, which for Codex means a real turn rather than a status
    /// command — because "logged in" and "can actually run" turned out to be different
    /// questions. See docs/01-spikes.md spike 6b.
    func refreshEngineStatus() async {
        for (id, adapter) in adapters {
            engineStatus[id] = await adapter.authStatus(on: host)
        }
    }

    func send(_ prompt: String, to bot: Bot) {
        guard running[bot.id] == nil, let adapter = adapters[bot.engine] else { return }

        let thread = thread(for: bot.id)
        thread.entries.append(TranscriptEntry(kind: .userMessage(prompt)))
        thread.isRunning = true

        let request = RunRequest(
            prompt: bot.personaPrompt.map { "\($0)\n\n\(prompt)" } ?? prompt,
            workingDirectory: nil,
            resume: thread.conversationID,
            model: bot.model,
            autonomy: bot.autonomy
        )

        running[bot.id] = Task { [host] in
            defer {
                thread.isRunning = false
                running[bot.id] = nil
            }
            do {
                let stream = try await host.spawn(adapter.invocation(for: request))
                for try await output in stream {
                    if Task.isCancelled { return }
                    for event in adapter.normalise(output) {
                        thread.apply(event)
                    }
                }
            } catch {
                thread.apply(.failed(EngineFailure(
                    kind: .launchFailed, message: error.localizedDescription)))
            }
        }
    }

    func stop(_ botID: BotID) {
        running[botID]?.cancel()
        running[botID] = nil
        thread(for: botID).isRunning = false
    }

    func addBot(name: String, engine: EngineID) {
        let bot = Bot(name: name, engine: engine)
        bots.append(bot)
        selectedBotID = bot.id
    }
}
