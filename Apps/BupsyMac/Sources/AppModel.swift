import BupsyKit
import Foundation
import Observation

/// Everything the UI reads, and the one place a run is started.
@MainActor
@Observable
final class AppModel {
    var bots: [Bot] = []
    var selectedBotID: BotID?
    var engineStatus: [EngineID: AuthStatus] = [:]
    /// Set when persistence could not be opened. The app still works; it just forgets.
    var storageProblem: String?

    private var threads: [BotID: Thread] = [:]
    private var running: [BotID: Task<Void, Never>] = [:]
    private var gates: [BotID: ApprovalGate] = [:]
    private var awake: [BotID: PowerAssertion] = [:]
    private let store: Store?

    private let host: any ExecutionHost = LocalHost()
    private let adapters: [EngineID: any EngineAdapter] = [
        .claude: ClaudeAdapter(),
        .codex: CodexAdapter(),
    ]

    init(store: Store? = nil) {
        if let store {
            self.store = store
        } else {
            // A broken database must not be a broken app. Falling back to memory loses history
            // but keeps every bot usable, and says so rather than failing silently.
            do {
                self.store = try Store(url: try Store.defaultURL())
            } catch {
                self.store = nil
                self.storageProblem = error.localizedDescription
            }
        }
        loadBots()
        selectedBotID = bots.first?.id
    }

    private func loadBots() {
        guard let store else {
            bots = Self.starterBots()
            return
        }
        do {
            let records = try store.bots()
            if records.isEmpty {
                bots = Self.starterBots()
                for (index, bot) in bots.enumerated() {
                    try store.save(bot.record(sortIndex: index))
                }
            } else {
                bots = records.map(Bot.init(record:))
            }
        } catch {
            storageProblem = error.localizedDescription
            bots = Self.starterBots()
        }
    }

    private static func starterBots() -> [Bot] {
        [
            Bot(name: "Scout", engine: .claude,
                personaPrompt: "You research things and report back plainly. Be concise."),
            Bot(name: "Builder", engine: .claude,
                personaPrompt: "You write and fix code. Explain what you changed and why."),
            Bot(name: "Inbox", engine: .codex,
                personaPrompt: "You triage and summarise. Lead with what needs a decision."),
        ]
    }

    var selectedBot: Bot? { bots.first { $0.id == selectedBotID } }

    /// Returns a thread, hydrating it from storage the first time it is asked for.
    func thread(for botID: BotID) -> Thread {
        if let existing = threads[botID] { return existing }

        let created = Thread(botID: botID)
        if let store {
            do {
                for record in try store.transcript(forBot: botID.rawValue) {
                    created.applyStored(type: record.type, payload: record.payload)
                }
                created.conversationID = try store.conversation(forBot: botID.rawValue)
                    .flatMap { record in record.providerConversationID.map { ConversationID($0) } }
            } catch {
                storageProblem = error.localizedDescription
            }
        }
        threads[botID] = created
        return created
    }

    func isRunning(_ botID: BotID) -> Bool { running[botID] != nil }

    func refreshEngineStatus() async {
        for (id, adapter) in adapters {
            let status = await adapter.authStatus(on: host)
            engineStatus[id] = status
            try? store?.save(EngineLinkRecord(
                machineID: nil,
                engine: id.rawValue,
                status: Self.statusName(status),
                method: {
                    if case .signedIn(let method) = status { return method.rawValue }
                    return nil
                }()
            ))
        }
    }

    private static func statusName(_ status: AuthStatus) -> String {
        switch status {
        case .signedIn: "signedIn"
        case .signedInWithoutModelAccess: "noModelAccess"
        case .signedOut: "signedOut"
        case .unknown: "unknown"
        }
    }

    func send(_ prompt: String, to bot: Bot) {
        guard running[bot.id] == nil, let adapter = adapters[bot.engine] else { return }

        let thread = thread(for: bot.id)
        thread.entries.append(TranscriptEntry(kind: .userMessage(prompt)))
        thread.isRunning = true

        let conversationID = ensureConversation(for: bot, thread: thread)
        let run = RunRecord(
            botID: bot.id.rawValue,
            conversationID: conversationID,
            host: bot.machineID.map { "cloud:\($0)" } ?? "local"
        )
        try? store?.save(run)
        persist(.text(prompt), run: run.id, seq: 0, asUserMessage: true)

        // A fresh gate per run: the hook script and settings are written to a temporary
        // directory, and the engine is told about them with `--settings`. An engine started
        // without this runs ungated, which is only ever correct for an auth probe.
        var gateSettings: String?
        if let gate = try? ApprovalGate.temporary() {
            gates[bot.id] = gate
            gateSettings = try? GateInstaller.install(gateDirectory: gate.directory).path
            watchGate(gate, bot: bot, thread: thread, run: run.id)
        }

        let request = RunRequest(
            prompt: bot.personaPrompt.map { "\($0)\n\n\(prompt)" } ?? prompt,
            resume: thread.conversationID,
            model: bot.model,
            autonomy: bot.autonomy,
            gateSettingsPath: gateSettings
        )

        // Hold the Mac awake for the duration, if this bot asks for it. An agent run killed at
        // minute three of ten leaves a half-finished task and a truncated transcript, which is
        // worse than one that never started.
        if bot.keepAwake == .whileWorking {
            let assertion = PowerAssertion(reason: "bupsy: \(bot.name) is working")
            if assertion.acquire() { awake[bot.id] = assertion }
        }

        running[bot.id] = Task { [host, store] in
            var seq = 1
            var failed = false
            defer {
                thread.isRunning = false
                running[bot.id] = nil
                Task { [gate = gates[bot.id]] in await gate?.stop() }
                gates[bot.id] = nil
                awake[bot.id]?.release()
                awake[bot.id] = nil
                var finished = run
                finished.status = failed ? "failed" : "finished"
                finished.endedAt = Date()
                try? store?.save(finished)
                if let id = thread.conversationID {
                    try? store?.save(ConversationRecord(
                        id: conversationID, botID: bot.id.rawValue,
                        providerConversationID: id.rawValue, lastEventAt: Date()))
                }
            }
            do {
                for try await output in try await host.spawn(adapter.invocation(for: request)) {
                    if Task.isCancelled { return }
                    for event in adapter.normalise(output) {
                        thread.apply(event)
                        if case .failed = event { failed = true }
                        persist(event, run: run.id, seq: seq)
                        seq += 1
                    }
                }
            } catch {
                failed = true
                let failure = AgentEvent.failed(EngineFailure(
                    kind: .launchFailed, message: error.localizedDescription))
                thread.apply(failure)
                persist(failure, run: run.id, seq: seq)
            }
        }
    }

    /// Writes one event to the append-only log. Storage failures never interrupt a run — a bot
    /// that cannot write its transcript should still finish its work and say so.
    private func persist(_ event: AgentEvent, run: String, seq: Int, asUserMessage: Bool = false) {
        guard let store else { return }
        let (type, payload) = EventCodec.encode(event)
        do {
            try store.append([EventRecord(
                runID: run, seq: seq,
                type: asUserMessage ? "userMessage" : type,
                payload: payload)])
        } catch {
            storageProblem = error.localizedDescription
        }
    }

    private func ensureConversation(for bot: Bot, thread: Thread) -> String {
        if let store, let existing = try? store.conversation(forBot: bot.id.rawValue) {
            return existing.id
        }
        let created = ConversationRecord(botID: bot.id.rawValue)
        try? store?.save(created)
        return created.id
    }

    /// Applies policy to each gated tool call, and raises a card only when a human is needed.
    ///
    /// Every call passes through here, including auto-allowed ones, so the audit trail records
    /// what ran and under which rule — a bot on `.auto` still leaves a complete account of itself.
    private func watchGate(_ gate: ApprovalGate, bot: Bot, thread: Thread, run: String) {
        Task { [weak self] in
            for await request in await gate.requests() {
                guard let self else { return }
                let outcome = AutonomyPolicy.decide(
                    tool: request.tool,
                    autonomy: bot.autonomy,
                    allowlist: bot.toolAllowlist
                )
                switch outcome {
                case .allow(let rule):
                    try? await gate.decide(request.id, .allow(reason: rule))
                    self.recordDecision(run: run, request: request,
                                        decision: "allowed", rule: rule)
                case .ask(let reason):
                    thread.raiseApproval(PendingApproval(
                        id: request.id, tool: request.tool, summary: request.summary,
                        inputJSON: request.inputJSON, reason: reason))
                }
            }
        }
    }

    /// The user's answer on an approval card.
    func decide(_ approval: PendingApproval, allow: Bool, for bot: Bot) {
        guard let gate = gates[bot.id] else { return }
        let thread = thread(for: bot.id)
        thread.resolveApproval(id: approval.id, as: allow ? .allowed : .denied)
        Task {
            try? await gate.decide(
                approval.id,
                allow ? .allow(reason: "you approved it") : .deny(reason: "you declined it"))
        }
        recordDecision(run: nil, requestID: approval.id, tool: approval.tool,
                       inputJSON: approval.inputJSON,
                       decision: allow ? "allowed" : "denied", rule: "decided by you")
    }

    private func recordDecision(run: String?, request: GateRequest, decision: String, rule: String) {
        recordDecision(run: run, requestID: request.id, tool: request.tool,
                       inputJSON: request.inputJSON, decision: decision, rule: rule)
    }

    /// Decisions are part of the audit trail, not UI state. They go into the same append-only
    /// log as everything else the agent did.
    private func recordDecision(run: String?, requestID: String, tool: String,
                                inputJSON: String, decision: String, rule: String) {
        guard let store, let run else { return }
        let payload = [
            "tool": tool, "decision": decision, "rule": rule, "input": inputJSON,
        ]
        let encoded = (try? String(
            data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8)) ?? "{}"
        try? store.append([EventRecord(
            runID: run, seq: Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000,
            type: "approval", payload: encoded)])
    }

    func stop(_ botID: BotID) {
        running[botID]?.cancel()
        running[botID] = nil
        Task { [gate = gates[botID]] in await gate?.stop() }
        gates[botID] = nil
        awake[botID]?.release()
        awake[botID] = nil
        thread(for: botID).isRunning = false
    }

    /// Stops every run and closes every gate. The thing you reach for when a bot is doing
    /// something you did not expect.
    func stopEverything() {
        for id in running.keys { stop(id) }
    }

    func addBot(name: String, engine: EngineID) {
        let bot = Bot(name: name, engine: engine)
        bots.append(bot)
        try? store?.save(bot.record(sortIndex: bots.count - 1))
        selectedBotID = bot.id
    }

    func deleteBot(_ bot: Bot) {
        bots.removeAll { $0.id == bot.id }
        threads[bot.id] = nil
        try? store?.deleteBot(id: bot.id.rawValue)
        if selectedBotID == bot.id { selectedBotID = bots.first?.id }
    }
}
