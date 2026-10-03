import AppKit
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
    var routines: [Routine] = []
    var machines: [MachineRecord] = []
    var connectors: [MCPServer] = []
    var objectives: [Objective] = []
    /// Set when a machine operation failed. Shown rather than logged — a machine that did not
    /// start is money not being spent, or work not being done, and either way the user should know.
    var machineProblem: String?
    /// Shown once. Stored in UserDefaults rather than the database: it is a preference about the
    /// app, not part of the user's data, and it should not travel with a restored database.
    var needsOnboarding = !UserDefaults.standard.bool(forKey: "si.bupsy.onboarded")
    /// Set when persistence could not be opened. The app still works; it just forgets.
    var storageProblem: String?
    /// Set when a schedule could not be installed, so the UI can say a routine will not fire.
    var routineProblem: String?

    private var threads: [BotID: Thread] = [:]
    private var running: [BotID: Task<Void, Never>] = [:]
    private var gates: [BotID: ApprovalGate] = [:]
    private var awake: [BotID: PowerAssertion] = [:]
    private var routineTimer: Task<Void, Never>?
    private let keychain = KeychainStore()
    private let notifier = Notifier()
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
        // `self.store`, not `store` — the initialiser parameter shadows the property, and is nil
        // in normal use. Written as `store?` this silently loaded zero routines on every launch,
        // with `try?` swallowing the nothing that happened. Routines then never fired, and no
        // error appeared anywhere.
        routines = (try? self.store?.routines()) ?? []
        selectedBotID = bots.first?.id
        // Sync at launch, not only when a routine changes. Otherwise an agent removed by hand,
        // or a database restored onto a different Mac, leaves routines that quietly never fire.
        machines = (try? self.store?.machines()) ?? []
        connectors = Self.loadConnectors()
        objectives = (try? self.store?.objectives()) ?? []
        syncLaunchAgent()
    }

    // MARK: - Connectors
    //
    // Stored in UserDefaults rather than the database: a connector definition is a command and a
    // list of environment variable *names*, which is configuration rather than the user's data,
    // and keeping it out of the database keeps the "no credential columns" rule trivially true.

    private static let connectorsKey = "si.bupsy.connectors"

    private static func loadConnectors() -> [MCPServer] {
        guard let data = UserDefaults.standard.data(forKey: connectorsKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    private func saveConnectors() {
        if let data = try? JSONEncoder().encode(connectors) {
            UserDefaults.standard.set(data, forKey: Self.connectorsKey)
        }
    }

    func addConnector(_ server: MCPServer) {
        guard !connectors.contains(where: { $0.name == server.name }) else { return }
        connectors.append(server)
        saveConnectors()
    }

    func removeConnector(_ server: MCPServer) {
        connectors.removeAll { $0.id == server.id }
        // Leave no bot allowing a connector that no longer exists.
        for index in bots.indices {
            bots[index].toolAllowlist.remove(server.toolPrefix)
            try? store?.save(bots[index].record(sortIndex: index))
        }
        saveConnectors()
    }

    /// The engine's last report for a connector, if any run has produced one. Nil means we have
    /// not seen it come up yet — honestly different from "it failed".
    func liveStatus(of server: MCPServer) -> ConnectorState? {
        threads.values
            .flatMap(\.connectorStates)
            .last { $0.name == server.name }
    }

    func setConnectorEnabled(_ server: MCPServer, _ enabled: Bool) {
        guard let index = connectors.firstIndex(where: { $0.id == server.id }) else { return }
        connectors[index].enabled = enabled
        saveConnectors()
    }

    /// Whether a bot may use a connector without being asked each time.
    func setConnectorAllowed(_ bot: Bot, _ server: MCPServer, _ allowed: Bool) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        if allowed {
            bots[index].toolAllowlist.insert(server.toolPrefix)
        } else {
            bots[index].toolAllowlist.remove(server.toolPrefix)
        }
        try? store?.save(bots[index].record(sortIndex: index))
    }

    // MARK: - Machines
    //
    // Machines are rented on the *user's* boat.dev account with the *user's* key. bupsy holds no
    // compute key of its own, and the UI says so, because a surprise charge from a company
    // someone did not knowingly sign up with would be worse than any bug in here.

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "si.bupsy.onboarded")
        needsOnboarding = false
    }

    var hasComputeKey: Bool { keychain.has(.boatAPIKey) }

    func setComputeKey(_ key: String) {
        do {
            try keychain.set(key, for: .boatAPIKey)
            machineProblem = nil
        } catch {
            machineProblem = error.localizedDescription
        }
    }

    private func api() -> BoatAPI? {
        keychain.get(.boatAPIKey).map { BoatAPI(apiKey: $0) }
    }

    func createMachine(name: String, size: MachineSize, alwaysOn: Bool) {
        guard let api = api() else {
            machineProblem = "Add your boat.dev key first."
            return
        }

        // Recorded locally before the call, so a machine created remotely is never invisible
        // here — an orphan on someone's bill that bupsy does not know about is the worst
        // possible outcome of a failed create.
        var record = MachineRecord(
            name: name, state: "creating", size: size.rawValue,
            ttlSeconds: alwaysOn ? nil : 3600)
        machines.append(record)
        try? store?.save(record)

        Task { [record] in
            do {
                let options = alwaysOn
                    ? CreateOptions.alwaysOn(size: size)
                    : CreateOptions(size: size, ttlSeconds: 3600)
                let sandbox = try await api.create(options)
                var updated = record
                updated.providerID = sandbox.id
                updated.state = sandbox.state ?? "running"
                updated.lastActiveAt = Date()
                self.replace(updated)
            } catch {
                var failed = record
                failed.state = "failed"
                self.replace(failed)
                self.machineProblem = error.localizedDescription
            }
        }
    }

    func toggleMachine(_ machine: MachineRecord) {
        guard let api = api(), let providerID = machine.providerID else {
            machineProblem = "This machine was never created on boat.dev."
            return
        }
        let wantsRunning = machine.state != "running"
        Task {
            do {
                let sandbox = wantsRunning
                    ? try await api.resume(providerID)
                    : try await api.stop(providerID)
                var updated = machine
                updated.state = sandbox.state ?? (wantsRunning ? "running" : "archived")
                updated.lastActiveAt = Date()
                self.replace(updated)
            } catch {
                self.machineProblem = error.localizedDescription
            }
        }
    }

    /// Removes it here and on boat. Bots assigned to it become machine-less, which is an
    /// ordinary state — they go back to running on this Mac rather than breaking.
    func deleteMachine(_ machine: MachineRecord) {
        machines.removeAll { $0.id == machine.id }
        for index in bots.indices where bots[index].machineID == machine.id {
            bots[index].machineID = nil
            try? store?.save(bots[index].record(sortIndex: index))
        }
        try? store?.deleteMachine(id: machine.id)
    }

    func assign(_ bot: Bot, to machineID: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].machineID = machineID
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Moves a bot to another engine.
    ///
    /// The thread is swapped rather than lost. Resume handles are engine-specific — a Claude
    /// session id means nothing to Codex — so each engine keeps its own conversation, and
    /// switching back returns to where that engine left off. The visible transcript is reloaded
    /// to match, because showing a Claude transcript while talking to Codex would be a lie.
    func setEngine(_ bot: Bot, _ engine: EngineID) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }), bot.engine != engine
        else { return }

        bots[index].engine = engine
        // A model name from one engine is meaningless to the other.
        bots[index].model = nil
        try? store?.save(bots[index].record(sortIndex: index))

        threads[bot.id] = nil
        _ = thread(for: bot.id)
    }

    func setModel(_ bot: Bot, _ model: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].model = model
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// The models the bot's current engine offers.
    func models(for bot: Bot) -> [ModelOption] {
        adapters[bot.engine]?.models ?? []
    }

    func setAutonomy(_ bot: Bot, _ level: Autonomy) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].autonomy = level
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Picks the folder a bot works in.
    func chooseWorkdir(for bot: Bot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "\(bot.name) will be able to read and work in this folder."
        if let current = bot.workdir { panel.directoryURL = URL(fileURLWithPath: current) }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setWorkdir(bot, url.path)
    }

    func setWorkdir(_ bot: Bot, _ path: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].workdir = path
        try? store?.save(bots[index].record(sortIndex: index))
    }

    func setKeepAwake(_ bot: Bot, _ setting: KeepAwake) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].keepAwake = setting
        try? store?.save(bots[index].record(sortIndex: index))
    }

    private func replace(_ machine: MachineRecord) {
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        }
        try? store?.save(machine)
    }

    // MARK: - Routines

    func addRoutine(to bot: Bot, name: String, prompt: String, cron: String,
                    tier: Routine.Tier) {
        // A tier the bot cannot honour is downgraded rather than silently failing later.
        let effective = (tier == .machine && bot.machineID == nil) ? .appOpen : tier
        let routine = Routine(
            botID: bot.id.rawValue, name: name, prompt: prompt, cron: cron, tier: effective)
        routines.append(routine)
        try? store?.save(routine)
        syncLaunchAgent()
    }

    func deleteRoutine(_ routine: Routine) {
        routines.removeAll { $0.id == routine.id }
        try? store?.deleteRoutine(id: routine.id)
        syncLaunchAgent()
    }

    func setRoutineEnabled(_ routine: Routine, _ enabled: Bool) {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[index].enabled = enabled
        try? store?.save(routines[index])
        syncLaunchAgent()
    }

    /// Keeps launchd in step with whatever routines currently want to run with the app closed.
    ///
    /// Rewritten from scratch each time rather than patched: one agent describing the current
    /// truth is far easier to reason about than a set of incremental edits, and launchd is a
    /// user-visible resource we should leave tidy.
    private func syncLaunchAgent() {
        let objectiveRoutines = objectives.map {
            Routine(id: $0.id, botID: $0.botID, name: "check", prompt: "",
                    cron: $0.checkCron, enabled: $0.enabled, tier: $0.tier)
        }
        let intervals = RoutineScheduler().launchdIntervals(for: routines + objectiveRoutines)
        let appPath = Bundle.main.bundlePath
        Task.detached { [weak self] in
            do {
                if intervals.isEmpty {
                    try LaunchAgent.uninstall()
                } else {
                    try LaunchAgent.install(intervals: intervals, appPath: appPath)
                }
            } catch {
                // Never swallowed: a routine that silently never fires is this feature's worst
                // failure, so the reason reaches the user rather than a debug log.
                FileHandle.standardError.write(Data("bupsy: launch agent — \(error)\n".utf8))
                await MainActor.run { self?.routineProblem = error.localizedDescription }
            }
        }
    }

    /// Runs whatever is due. Called at launch — including when launchd started us for exactly
    /// this reason — and on a timer while the app is open.
    func runDueRoutines(now: Date = Date()) {
        for objective in dueObjectives(now: now) {
            checkObjective(objective)
        }
        for due in RoutineScheduler().due(routines: routines, now: now) {
            guard let bot = bots.first(where: { $0.id.rawValue == due.routine.botID })
            else { continue }

            // Record the slot before running, not after. A crash mid-run must not cause the
            // routine to fire again on the next launch.
            if let index = routines.firstIndex(where: { $0.id == due.routine.id }) {
                routines[index].lastFiredAt = due.scheduledFor
                try? store?.save(routines[index])
            }

            let note = due.isLate
                ? "\n\n(Running late — this was scheduled for "
                    + due.scheduledFor.formatted(date: .omitted, time: .shortened) + ".)"
                : ""
            let name = due.routine.name
            send(due.routine.prompt + note, to: bot) { [weak self] reply in
                // Unattended work that finishes silently may as well not have run.
                self?.notifier.routineFinished(
                    bot: bot.name, routine: name,
                    summary: reply.split(separator: "\n").first.map(String.init))
            }
        }
    }

    // MARK: - Objectives

    func addObjective(to bot: Bot, goal: String, doneWhen: String, cron: String,
                      tier: Routine.Tier) {
        let effective = (tier == .machine && bot.machineID == nil) ? .appOpen : tier
        let objective = Objective(
            botID: bot.id.rawValue, goal: goal, doneWhen: doneWhen,
            checkCron: cron, tier: effective)
        objectives.append(objective)
        try? store?.save(objective)
        syncLaunchAgent()
    }

    func deleteObjective(_ objective: Objective) {
        objectives.removeAll { $0.id == objective.id }
        try? store?.deleteObjective(id: objective.id)
        syncLaunchAgent()
    }

    func setObjectiveEnabled(_ objective: Objective, _ enabled: Bool) {
        guard let index = objectives.firstIndex(where: { $0.id == objective.id }) else { return }
        objectives[index].enabled = enabled
        try? store?.save(objectives[index])
        syncLaunchAgent()
    }

    /// The user editing what a bot has learned. The real safeguard against notes drifting
    /// somewhere unhelpful is that they are plain text a person can read and correct.
    func setObjectiveNotes(_ objective: Objective, _ notes: String) {
        guard let index = objectives.firstIndex(where: { $0.id == objective.id }) else { return }
        objectives[index].notes = notes
        try? store?.save(objectives[index])
    }

    /// Runs one check now.
    func checkObjective(_ objective: Objective) {
        guard let bot = bots.first(where: { $0.id.rawValue == objective.botID }) else { return }

        // Recorded before the run, so a crash mid-check cannot cause it to repeat immediately.
        if let index = objectives.firstIndex(where: { $0.id == objective.id }) {
            objectives[index].lastCheckedAt = Date()
            try? store?.save(objectives[index])
        }

        send(ObjectiveCheck.prompt(for: objective), to: bot) { [weak self] reply in
            guard let self,
                  let index = self.objectives.firstIndex(where: { $0.id == objective.id })
            else { return }

            let outcome = ObjectiveCheck.outcome(from: reply)
            if case .needsYou(let question) = outcome {
                self.notifier.objectiveNeedsYou(bot: bot.name, question: question)
            }
            self.objectives[index].lastOutcome = outcome
            self.objectives[index].notes = ObjectiveCheck.updatedNotes(
                self.objectives[index].notes,
                adding: ObjectiveCheck.learnings(from: reply))
            try? self.store?.save(self.objectives[index])
        }
    }

    /// Objectives whose check time has passed, using the same scheduler as routines so late and
    /// collapsed runs behave identically.
    private func dueObjectives(now: Date) -> [Objective] {
        let asRoutines = objectives.map {
            Routine(id: $0.id, botID: $0.botID, name: "check", prompt: "",
                    cron: $0.checkCron, enabled: $0.enabled, tier: $0.tier,
                    lastFiredAt: $0.lastCheckedAt)
        }
        let dueIDs = Set(RoutineScheduler().due(routines: asRoutines, now: now).map(\.routine.id))
        return objectives.filter { dueIDs.contains($0.id) }
    }

    /// Everything waiting on a person, in one place.
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        for bot in bots {
            for entry in threads[bot.id]?.entries ?? [] {
                if case .approval(let approval) = entry.kind, approval.decided == nil {
                    items.append(AttentionItem(
                        id: approval.id, botName: bot.name, hue: bot.avatarHue,
                        kind: .approval, title: "\(approval.tool) needs approval",
                        detail: approval.summary))
                }
            }
        }

        for objective in objectives where objective.lastOutcome?.needsAttention == true {
            guard let bot = bots.first(where: { $0.id.rawValue == objective.botID }) else { continue }
            items.append(AttentionItem(
                id: objective.id, botName: bot.name, hue: bot.avatarHue,
                kind: .objective, title: objective.goal,
                detail: detail(for: objective.lastOutcome)))
        }

        return items
    }

    private func detail(for outcome: ObjectiveOutcome?) -> String {
        switch outcome {
        case .needsYou(let question): question
        case .failed(let reason): "Check failed: \(reason)"
        case .unclear: "The bot's answer could not be read, so nobody knows if this is handled."
        default: ""
        }
    }

    /// Ticks while the app is open so `appOpen`-tier routines fire on their minute.
    func startRoutineTimer() {
        guard routineTimer == nil else { return }
        routineTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.runDueRoutines()
            }
        }
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
                let engine = bots.first { $0.id == botID }?.engine ?? .claude
                created.conversationID = try store
                    .conversation(forBot: botID.rawValue, engine: engine.rawValue)
                    .flatMap { record in record.providerConversationID.map { ConversationID($0) } }
            } catch {
                storageProblem = error.localizedDescription
            }
        }
        threads[botID] = created
        return created
    }

    func isRunning(_ botID: BotID) -> Bool { running[botID] != nil }

    func recentRuns(for bot: Bot) -> [RunSummary] {
        (try? store?.recentRuns(forBot: bot.id.rawValue, limit: 20)) ?? []
    }

    /// True when a bot is blocked on a decision from you, which the roster shows differently
    /// from merely working — it is the state that needs a human.
    func isWaitingForApproval(_ botID: BotID) -> Bool {
        threads[botID]?.entries.contains {
            if case .approval(let approval) = $0.kind { return approval.decided == nil }
            return false
        } ?? false
    }

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
        send(prompt, to: bot, onFinish: nil)
    }

    func send(
        _ prompt: String, to bot: Bot,
        onFinish: (@MainActor @Sendable (String) -> Void)?
    ) {
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
            workingDirectory: bot.workdir.map { URL(fileURLWithPath: $0) },
            resume: thread.conversationID,
            model: bot.model,
            autonomy: bot.autonomy,
            mcpConfigPaths: (try? MCPConfig.write(connectors)).flatMap { $0 }.map { [$0] } ?? [],
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
            var reply = ""
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
                        id: conversationID, botID: bot.id.rawValue, engine: bot.engine.rawValue,
                        providerConversationID: id.rawValue, lastEventAt: Date()))
                }
                onFinish?(reply)
            }
            do {
                for try await output in try await host.spawn(adapter.invocation(for: request)) {
                    if Task.isCancelled { return }
                    for event in adapter.normalise(output) {
                        thread.apply(event)
                        if case .failed = event { failed = true }
                        if case .text(let chunk) = event { reply += chunk }
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
        if let store,
           let existing = try? store.conversation(
               forBot: bot.id.rawValue, engine: bot.engine.rawValue) {
            return existing.id
        }
        let created = ConversationRecord(botID: bot.id.rawValue, engine: bot.engine.rawValue)
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
                    // The whole point of a gate that waits is that someone finds out it is
                    // waiting. A run blocked at 3am with nothing said is a run that never ran.
                    self.notifier.needsApproval(
                        bot: bot.name, tool: request.tool, summary: request.summary)
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

    func addBot(name: String, engine: EngineID, job: String = "", folder: String? = nil) {
        var bot = Bot(
            name: name, engine: engine,
            personaPrompt: job.isEmpty ? nil : job)
        bot.folder = folder
        bots.append(bot)
        try? store?.save(bot.record(sortIndex: bots.count - 1))
        selectedBotID = bot.id
    }

    /// Clones a bot's setup, not its history.
    ///
    /// Everything that took effort to get right — the job description, engine, model, folder,
    /// trust level, allowed apps — carries over. The conversation does not: a copy of someone
    /// else's transcript is confusing, and the point of duplicating is a fresh start with the
    /// same settings.
    func duplicate(_ bot: Bot) {
        var copy = Bot(name: nextName(basedOn: bot.name), engine: bot.engine,
                       model: bot.model, machineID: bot.machineID,
                       personaPrompt: bot.personaPrompt)
        copy.autonomy = bot.autonomy
        copy.keepAwake = bot.keepAwake
        copy.workdir = bot.workdir
        copy.toolAllowlist = bot.toolAllowlist
        copy.folder = bot.folder

        bots.append(copy)
        try? store?.save(copy.record(sortIndex: bots.count - 1))
        selectedBotID = copy.id
    }

    // MARK: - Folders

    /// The folders in use, in the order their first bot appears.
    ///
    /// Derived rather than stored. A folder exists exactly as long as something is in it, so
    /// there is no way to end up with an empty folder nobody can see or delete — the failure mode
    /// of every "create a folder, then put things in it" design.
    var folders: [String] {
        var seen: [String] = []
        for bot in bots {
            if let folder = bot.folder, !folder.isEmpty, !seen.contains(folder) {
                seen.append(folder)
            }
        }
        return seen
    }

    /// Bots with no folder. Shown first, above the named folders, because filing is optional.
    var ungroupedBots: [Bot] {
        bots.filter { ($0.folder ?? "").isEmpty }
    }

    func bots(in folder: String) -> [Bot] {
        bots.filter { $0.folder == folder }
    }

    func setFolder(_ bot: Bot, _ folder: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespaces)
        bots[index].folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistOrder()
    }

    /// Renames a folder everywhere at once, since the folder *is* the string on each bot.
    func renameFolder(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { return }
        for index in bots.indices where bots[index].folder == old {
            bots[index].folder = trimmed
        }
        persistOrder()
    }

    /// Empties a folder rather than deleting its bots. Deleting a container should never delete
    /// the things inside it — that is how people lose work they did not mean to.
    func dissolveFolder(_ folder: String) {
        for index in bots.indices where bots[index].folder == folder {
            bots[index].folder = nil
        }
        persistOrder()
    }

    /// Writes every bot back with its current position, which is what both folder membership and
    /// ordering depend on.
    private func persistOrder() {
        for (index, bot) in bots.enumerated() {
            try? store?.save(bot.record(sortIndex: index))
        }
    }

    private func nextName(basedOn name: String) -> String {
        let base = name.replacingOccurrences(
            of: #" \d+$"#, with: "", options: .regularExpression)
        var candidate = "\(base) 2"
        var number = 2
        while bots.contains(where: { $0.name == candidate }) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }

    /// The whole conversation as plain text, for pasting into a ticket or an email.
    func copyTranscript(of bot: Bot) {
        let thread = thread(for: bot.id)
        var lines = ["\(bot.name) — \(bot.engine.displayName)", ""]

        for entry in thread.entries {
            switch entry.kind {
            case .userMessage(let text): lines.append("You: \(text)")
            case .assistantText(let text): lines.append("\(bot.name): \(text)")
            case .tool(let name, let arguments, _, _): lines.append("  [\(name)] \(arguments)")
            case .approval(let approval):
                let decision = switch approval.decided {
                case .allowed: "allowed"
                case .denied: "denied"
                case .expired: "denied, nobody answered"
                case nil: "waiting"
                }
                lines.append("  [approval: \(approval.summary) — \(decision)]")
            case .failure(let failure): lines.append("  [failed: \(failure.message)]")
            default: continue
            }
            lines.append("")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Files dropped onto the composer. Paths rather than contents: the bot can read them
    /// itself, and pasting a megabyte of file into a prompt wastes the user's own quota.
    func attach(_ urls: [URL], to bot: Bot) -> String {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return "" }
        return paths.count == 1
            ? paths[0]
            : paths.map { "- \($0)" }.joined(separator: "\n")
    }

    func deleteBot(_ bot: Bot) {
        bots.removeAll { $0.id == bot.id }
        threads[bot.id] = nil
        try? store?.deleteBot(id: bot.id.rawValue)
        if selectedBotID == bot.id { selectedBotID = bots.first?.id }
    }
}
