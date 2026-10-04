import AppKit
import BupsyKit
import Foundation
import Observation

/// Everything the UI reads, and the one place a run is started.
@MainActor
@Observable
final class AppModel {
    var bots: [Bot] = []
    /// The bot whose custom-model sheet is open. Lives here because the menus that open it — the
    /// sidebar's and the bot page's — are in different views, and the sheet is presented once.
    var customModelBot: Bot?
    var selectedBotID: BotID?
    var engineStatus: [EngineID: AuthStatus] = [:]
    var routines: [Routine] = []
    var machines: [MachineRecord] = []
    var connectors: [MCPServer] = []
    /// Whether Executor is on this Mac. Nil until checked — the check asks a login shell, so it
    /// runs off the main thread and the UI says "checking" rather than guessing.
    var executorInstalled: Bool?
    /// True between clicking Install and the installer finishing in Terminal.
    var executorInstalling = false
    var objectives: [Objective] = []
    /// Set when a machine operation failed. Shown rather than logged — a machine that did not
    /// start is money not being spent, or work not being done, and either way the user should know.
    var machineProblem: String?
    /// Shown once. Stored in UserDefaults rather than the database: it is a preference about the
    /// app, not part of the user's data, and it should not travel with a restored database.
    var needsOnboarding = !UserDefaults.standard.bool(forKey: "si.bupsy.onboarded")
    /// Set when persistence could not be opened. The app still works; it just forgets.
    var storageProblem: String?
    /// Whether the database opened at all, which changes what a storage problem means.
    var hasStore: Bool { store != nil }
    /// Set when a schedule could not be installed, so the UI can say a routine will not fire.
    var routineProblem: String?

    private var threads: [BotID: Thread] = [:]
    /// The thread each bot is running in right now — its own, or its thread inside a group. The
    /// approval gate is per bot, so a decision has to find whichever one the bot is actually in.
    private var activeThread: [BotID: Thread] = [:]
    /// Each bot's hidden thread inside each group, keyed "botID|groupID". Holds that engine
    /// session and any approval it raises; the group page shows the approvals, not the thread.
    private var groupSideThreads: [String: Thread] = [:]
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
        loadGroups()
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
        // Removing Executor is a decision, and it must stick: it is never switched back on behind
        // the person's back. Adding it again from its card clears this.
        if server.name == Executor.name {
            UserDefaults.standard.set(true, forKey: Self.executorRemovedKey)
        }
        connectors.removeAll { $0.id == server.id }
        // Leave no bot allowing a connector that no longer exists.
        for index in bots.indices {
            bots[index].toolAllowlist.remove(server.toolPrefix)
            try? store?.save(bots[index].record(sortIndex: index))
        }
        saveConnectors()
    }

    // MARK: - Executor

    private static let executorRemovedKey = "si.bupsy.executor.removed"

    /// Looks for Executor and, if it is there and the person has not turned it down, switches it
    /// on for every bot. Its tools still go through each bot's approval gate like any other.
    func refreshExecutor() {
        Task.detached(priority: .utility) {
            let installed = Executor.isInstalled()
            await MainActor.run { self.applyExecutorCheck(installed: installed) }
        }
    }

    private func applyExecutorCheck(installed: Bool) {
        executorInstalled = installed
        if installed { executorInstalling = false }
        if Executor.shouldAutoAdd(
            installed: installed, existing: connectors,
            removedByPerson: UserDefaults.standard.bool(forKey: Self.executorRemovedKey)) {
            addConnector(Executor.server)
        }
    }

    /// Turns Executor back on after the person removed it.
    func addExecutor() {
        UserDefaults.standard.removeObject(forKey: Self.executorRemovedKey)
        addConnector(Executor.server)
    }

    /// Runs Executor's own installer in Terminal, where the person can watch it, then waits for
    /// `executor` to appear and switches it on.
    ///
    /// A `.command` file rather than scripting Terminal: opening one needs no automation
    /// permission, and what runs is a short readable script in a window the person controls.
    func installExecutor() {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("Install Executor.command")
        let body = "#!/bin/zsh -l\nclear\necho 'Installing Executor (executor.sh) with its own installer…'\necho\n"
            + Executor.installScript + "\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return }
        NSWorkspace.shared.open(script)
        executorInstalling = true

        // Checks every few seconds for ten minutes; npm installs are slow on a cold cache.
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.executorInstalling else { return }
                let found = await Task.detached { Executor.isInstalled() }.value
                if found { self.applyExecutorCheck(installed: true); return }
            }
            self?.executorInstalling = false
        }
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
        let record = MachineRecord(
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
                // The message is read out here and only the String crosses to the main actor.
                // Capturing `self` inside the hop sends a task-isolated reference into a
                // main-actor closure, which Swift 6 rejects — and which this app never compiled
                // in CI to find out until the app build job was added.
                let message = error.localizedDescription
                await MainActor.run { [weak self] in self?.routineProblem = message }
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
                    // "Systems wants to run a command", not "Bash needs approval": the person is
                    // deciding about a bot doing something, and should not have to translate an
                    // engine's tool name to know what.
                    items.append(AttentionItem(
                        id: approval.id, botID: bot.id, botName: bot.name, hue: bot.avatarHue,
                        kind: .approval,
                        title: "\(bot.name) wants to \(ToolNames.action(approval.tool))",
                        detail: approval.summary,
                        detailIsCommand: ToolNames.isCommand(approval.tool)))
                }
            }
        }

        for objective in objectives where objective.lastOutcome?.needsAttention == true {
            guard let bot = bots.first(where: { $0.id.rawValue == objective.botID }) else { continue }
            items.append(AttentionItem(
                id: objective.id, botID: bot.id, botName: bot.name, hue: bot.avatarHue,
                kind: .objective, title: "\(bot.name): \(objective.goal)",
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
            links = BotLinks((try? store.botLinks()) ?? [])
        } catch {
            storageProblem = error.localizedDescription
            bots = Self.starterBots()
        }
    }

    private static func starterBots() -> [Bot] {
        var bots = [
            Bot(name: "Scout", engine: .claude,
                personaPrompt: "You research things and report back plainly. Be concise."),
            Bot(name: "Builder", engine: .claude,
                personaPrompt: "You write and fix code. Explain what you changed and why."),
            Bot(name: "Inbox", engine: .codex,
                personaPrompt: "You triage and summarise. Lead with what needs a decision."),
        ]
        // The first thing anyone sees. Two of these came out as identical ghosts.
        var used: Set<Int> = []
        for index in bots.indices {
            var seed = BotFace.seed(forHue: bots[index].avatarHue)
            while used.contains(BotFace.shapeIndex(forHue: Double(seed) / 360)) {
                seed = (seed + 1) % 360
            }
            bots[index].avatarHue = Double(seed) / 360
            used.insert(BotFace.shapeIndex(forHue: bots[index].avatarHue))
        }
        return bots
    }

    var selectedBot: Bot? { bots.first { $0.id == selectedBotID } }

    /// Returns a thread, hydrating it from storage the first time it is asked for.
    func thread(for botID: BotID) -> Thread {
        if let existing = threads[botID] { return existing }

        let created = Thread(botID: botID)
        if let store {
            do {
                for record in try store.transcript(forBot: botID.rawValue) {
                    created.applyStored(type: record.type, payload: record.payload, at: record.at)
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
        (activeThread[botID] ?? threads[botID])?.entries.contains {
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
        startRun(prompt, bot: bot, thread: thread(for: bot.id), groupID: nil, onFinish: onFinish)
    }

    /// Runs a bot once, in a given thread.
    ///
    /// The thread is a parameter so a bot's turn in a group can use all of the same machinery —
    /// the approval gate, the audit log, usage — while running in a separate, per-group thread
    /// that carries its own engine session and catches its own approvals, and never touches the
    /// bot's one-to-one conversation with you.
    @discardableResult
    func startRun(
        _ prompt: String, bot: Bot, thread: Thread, groupID: String?,
        onFinish: (@MainActor @Sendable (String) -> Void)?
    ) -> Bool {
        // One run per bot at a time, wherever it is. A bot cannot answer in a group while it is
        // still working on something you asked it directly.
        guard running[bot.id] == nil, let adapter = adapters[bot.engine] else { return false }

        thread.entries.append(TranscriptEntry(kind: .userMessage(prompt)))
        thread.isRunning = true
        activeThread[bot.id] = thread

        let conversationID = ensureConversation(for: bot, thread: thread, group: groupID)
        let run = RunRecord(
            botID: bot.id.rawValue,
            conversationID: conversationID,
            host: bot.machineID.map { "cloud:\($0)" } ?? "local",
            groupID: groupID
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
            workingDirectory: workingDirectory(for: bot),
            resume: thread.conversationID,
            model: bot.model,
            autonomy: bot.autonomy,
            mcpConfigPaths: (try? MCPConfig.write(
                connectors,
                including: Self.bupsyMCPBinary.map {
                    MCPConfig.bupsyServer(
                        binary: $0,
                        outbox: OutboxWatcher.directory.path,
                        botID: bot.id.rawValue)
                }
            )).flatMap { $0 }.map { [$0] } ?? [],
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
                activeThread[bot.id] = nil
                Task { [gate = gates[bot.id]] in await gate?.stop() }
                gates[bot.id] = nil
                awake[bot.id]?.release()
                awake[bot.id] = nil
                var finished = run
                finished.status = failed ? "failed" : "finished"
                finished.endedAt = Date()
                // Carried from the stream's usage line, which arrives before `.done`. Without
                // this the columns exist and are never written, which is how the usage panel came
                // to be permanently absent rather than merely empty.
                finished.inputTokens = thread.latestUsage?.inputTokens
                finished.outputTokens = thread.latestUsage?.outputTokens
                finished.costUSD = thread.latestUsage?.costUSD
                try? store?.save(finished)
                if let id = thread.conversationID {
                    try? store?.save(ConversationRecord(
                        id: conversationID, botID: bot.id.rawValue, engine: bot.engine.rawValue,
                        providerConversationID: id.rawValue, lastEventAt: Date(),
                        groupID: groupID))
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
        return true
    }

    /// Writes one event to the append-only log. Storage failures never interrupt a run — a bot
    /// that cannot write its transcript should still finish its work and say so.
    private func persist(_ event: AgentEvent, run: String, seq: Int,
                         asUserMessage: Bool = false, asMessageFrom: Bool = false) {
        guard let store else { return }
        let (type, payload) = EventCodec.encode(event)
        do {
            try store.append([EventRecord(
                runID: run, seq: seq,
                type: asMessageFrom ? "messageFrom" : (asUserMessage ? "userMessage" : type),
                payload: payload)])
        } catch {
            storageProblem = error.localizedDescription
        }
    }

    private func ensureConversation(for bot: Bot, thread: Thread, group: String? = nil) -> String {
        if let store,
           let existing = try? store.conversation(
               forBot: bot.id.rawValue, engine: bot.engine.rawValue, group: group) {
            return existing.id
        }
        let created = ConversationRecord(botID: bot.id.rawValue, engine: bot.engine.rawValue,
                                         groupID: group)
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
        let thread = activeThread[bot.id] ?? thread(for: bot.id)
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

    func addBot(name: String, engine: EngineID, job: String = "", folder: String? = nil,
                shape: BotShape? = nil, colour: Int? = nil) {
        guard !isNameTaken(name) else { return }
        var bot = Bot(
            name: name, engine: engine,
            personaPrompt: job.isEmpty ? nil : job)
        bot.folder = folder
        bot.avatarHue = distinctHue(near: bot.avatarHue)
        bot.avatarShape = shape
        bot.avatarColour = colour
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
        copy.avatarHue = distinctHue(near: copy.avatarHue)

        bots.append(copy)
        try? store?.save(copy.record(sortIndex: bots.count - 1))
        selectedBotID = copy.id
    }

    // MARK: - Group threads

    var groups: [ChatGroup] = []
    private var groupThreads: [String: GroupThread] = [:]

    func loadGroups() {
        guard let store else { return }
        groups = ((try? store.groups()) ?? []).map { record in
            ChatGroup(record: record, members: (try? store.members(ofGroup: record.id)) ?? [])
        }
    }

    func groupThread(for group: ChatGroup) -> GroupThread {
        if let existing = groupThreads[group.id] { return existing }
        let created = GroupThread(groupID: group.id)
        created.messages = (try? store?.messages(inGroup: group.id)) ?? []
        groupThreads[group.id] = created
        return created
    }

    func members(of group: ChatGroup) -> [Bot] {
        group.memberIDs.compactMap { id in bots.first { $0.id == id } }
    }

    @discardableResult
    func createGroup(name: String, members: [Bot], lead: Bot?) -> ChatGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, members.count >= 2 else { return nil }
        let record = GroupRecord(name: trimmed, leadBotID: (lead ?? members.first)?.id.rawValue,
                                 sortIndex: groups.count)
        try? store?.save(record)
        try? store?.setMembers(ofGroup: record.id, to: members.map(\.id.rawValue))
        let group = ChatGroup(record: record, members: members.map(\.id.rawValue))
        groups.append(group)
        return group
    }

    func renameGroup(_ group: ChatGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = trimmed
        try? store?.save(groups[index].record(sortIndex: index))
    }

    /// Deletes the conversation, never the bots in it.
    func deleteGroup(_ group: ChatGroup) {
        try? store?.deleteGroup(id: group.id)
        groups.removeAll { $0.id == group.id }
        groupThreads[group.id] = nil
    }

    func markGroupRead(_ group: ChatGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].lastReadAt = Date()
        try? store?.save(groups[index].record(sortIndex: index))
    }

    func isGroupUnread(_ group: ChatGroup) -> Bool {
        guard selectedGroupID != group.id,
              let last = groupThread(for: group).messages.last(where: { !$0.isFromUser && !$0.isSystem })
        else { return false }
        guard let seen = group.lastReadAt else { return true }
        return last.at > seen
    }

    /// The group page on screen, so a reply arriving there is not marked unread behind you.
    var selectedGroupID: String?

    /// Each bot's hidden thread inside a group: its engine session there, and its approvals.
    private func groupSideThread(_ bot: Bot, in group: ChatGroup) -> Thread {
        let key = "\(bot.id.rawValue)|\(group.id)"
        if let existing = groupSideThreads[key] { return existing }
        let created = Thread(botID: bot.id)
        created.conversationID = (try? store?.conversation(
            forBot: bot.id.rawValue, engine: bot.engine.rawValue, group: group.id))?
            .providerConversationID.map { ConversationID($0) }
        groupSideThreads[key] = created
        return created
    }

    /// Approvals a member is waiting on inside this group, for the group page to show.
    func pendingApprovals(in group: ChatGroup) -> [(Bot, PendingApproval)] {
        members(of: group).compactMap { bot in
            guard let side = groupSideThreads["\(bot.id.rawValue)|\(group.id)"] else { return nil }
            for entry in side.entries.reversed() {
                if case .approval(let approval) = entry.kind, approval.decided == nil {
                    return (bot, approval)
                }
            }
            return nil
        }
    }

    /// Posts your message and lets the bots it addresses answer, one at a time.
    func send(_ text: String, toGroup group: ChatGroup) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        appendGroupMessage(GroupMessageRecord(
            groupID: group.id, author: GroupMessageRecord.userAuthor, authorName: "You",
            text: message), to: group)

        let routing = members(of: group).map { GroupRouting.Member(id: $0.id.rawValue, name: $0.name) }
        let first = GroupRouting.addressees(of: message, members: routing,
                                            lead: group.leadBotID?.rawValue)
        runTurns(in: group, queue: first, taken: 0)
    }

    /// Answers one bot at a time, following hand-offs, until the queue is empty or the ceiling
    /// is reached.
    ///
    /// One at a time on purpose. Bots answering in parallel would each reply without seeing the
    /// others, and the thread would read as several people talking over one another — the thing
    /// a group conversation is supposed to fix, not reproduce.
    private func runTurns(in group: ChatGroup, queue: [GroupRouting.Member], taken: Int) {
        let thread = groupThread(for: group)
        guard let next = queue.first else {
            thread.speaking = nil
            return
        }
        let rest = Array(queue.dropFirst())

        guard taken < GroupRouting.maxBotTurnsPerMessage else {
            thread.speaking = nil
            appendGroupMessage(GroupMessageRecord(
                groupID: group.id, author: GroupMessageRecord.systemAuthor, authorName: "bupsy",
                text: "Stopped after \(GroupRouting.maxBotTurnsPerMessage) replies so the bots "
                    + "don't keep each other going on your quota. Mention one to carry on."),
                to: group)
            return
        }
        guard let bot = bots.first(where: { $0.id.rawValue == next.id }) else {
            runTurns(in: group, queue: rest, taken: taken)
            return
        }

        let routing = members(of: group).map { GroupRouting.Member(id: $0.id.rawValue, name: $0.name) }
        let prompt = GroupRouting.prompt(group: group.name, members: routing, me: next,
                                         recent: missedMessages(by: bot, in: thread))
        thread.speaking = bot.id

        let started = startRun(prompt, bot: bot, thread: groupSideThread(bot, in: group),
                               groupID: group.id) { [weak self] reply in
            guard let self else { return }
            let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty {
                self.appendGroupMessage(GroupMessageRecord(
                    groupID: group.id, author: bot.id.rawValue, authorName: bot.name, text: said),
                    to: group)
            }
            // Joining a group is the permission for its members to hand work to each other:
            // the person chose them, and every hand-off appears in the thread they are reading.
            // Each bot's *actions* still pass through its own approval gate.
            var queue = rest
            for handOff in GroupRouting.handOffs(from: next, reply: said, members: routing)
            where !queue.contains(handOff) {
                queue.append(handOff)
            }
            self.runTurns(in: group, queue: queue, taken: taken + 1)
        }

        if !started {
            // A bot runs one thing at a time. Busy elsewhere is said, not silently skipped.
            appendGroupMessage(GroupMessageRecord(
                groupID: group.id, author: GroupMessageRecord.systemAuthor, authorName: "bupsy",
                text: "\(bot.name) is busy with something else — mention it again once it's free."),
                to: group)
            runTurns(in: group, queue: rest, taken: taken)
        }
    }

    /// What a bot has not seen: everything since it last spoke, capped so a long thread is not
    /// re-sent in full on every turn.
    private func missedMessages(by bot: Bot, in thread: GroupThread) -> [(author: String, text: String)] {
        let visible = thread.messages.filter { !$0.isSystem }
        let since = visible.lastIndex { $0.author == bot.id.rawValue }.map { $0 + 1 } ?? 0
        return visible[since...].suffix(20).map { ($0.isFromUser ? "You" : $0.authorName, $0.text) }
    }

    private func appendGroupMessage(_ message: GroupMessageRecord, to group: ChatGroup) {
        try? store?.append(message)
        groupThread(for: group).messages.append(message)
    }

    // MARK: - Bots talking to each other

    private var outbox: OutboxWatcher?

    /// The helper that lets a bot message another bot, shipped inside the app bundle.
    ///
    /// nil in a build where it is missing, and then the tool simply is not offered — a bot that
    /// cannot find the binary should have no `message_bot` tool at all, rather than one that
    /// fails every time it is called.
    static var bupsyMCPBinary: String? {
        Bundle.main.url(forAuxiliaryExecutable: "bupsy-mcp")?.path
            ?? Bundle.main.url(forResource: "bupsy-mcp", withExtension: nil)?.path
    }

    /// Starts listening for messages bots want to send each other.
    func startOutbox() {
        guard outbox == nil else { return }
        let watcher = OutboxWatcher { [weak self] from, toName, text in
            self?.receive(from: from, toName: toName, text: text)
        }
        watcher.start()
        outbox = watcher
    }

    /// Resolves a dropped message against the roster and hands it to the gate.
    ///
    /// The recipient arrives as a *name*, because that is what the model knows. Resolved case
    /// insensitively and only against an exact match: a bot called "Email" must never receive
    /// something addressed to "Email Agent 3" because a fuzzy match looked close enough.
    private func receive(from senderID: String, toName: String, text: String) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        guard let recipient = bots.first(where: {
            $0.name.compare(toName, options: .caseInsensitive) == .orderedSame
        }) else {
            // No such bot. Reported into the sender's own thread so the failure is visible to
            // whoever reads it, rather than vanishing into a deleted file.
            thread(for: sender.id).entries.append(TranscriptEntry(kind: .failure(
                EngineFailure(kind: .unknown, message: "No bot named “\(toName)” to message."))))
            return
        }
        deliver(from: sender, to: recipient, text: text)
    }

    /// A message one bot wants to send another, waiting on a person.
    struct PendingIntroduction: Identifiable, Equatable {
        let id = UUID()
        let from: Bot
        let to: Bot
        let text: String
    }

    /// First contact between two bots, waiting to be allowed or refused.
    ///
    /// Held in memory rather than written anywhere: an unanswered introduction is a live
    /// question, and a question that survives a restart with nobody around to have asked it is
    /// worse than one that is simply asked again.
    var pendingIntroductions: [PendingIntroduction] = []

    /// Delivers a message from one bot to another, asking the first time.
    ///
    /// One bot messaging another routes around the approval gate: the receiving bot acts on
    /// instructions no human read. So the first message between an ordered pair stops and asks,
    /// and the answer is remembered for that direction only — "Scout may message Builder" says
    /// nothing about whether Builder may message Scout.
    ///
    /// A refusal is remembered too. Re-asking every time trains people to click through the
    /// dialog, which is how a gate stops being one.
    func deliver(from sender: Bot, to recipient: Bot, text: String) {
        // Not a permission question: a bot writing into its own thread feeds its own output back
        // as input, and no human answer makes that safe.
        guard !BotLinks.isSelfMessage(
            from: sender.id.rawValue, to: recipient.id.rawValue) else { return }

        switch links.decision(from: sender.id.rawValue, to: recipient.id.rawValue) {
        case .some(true):
            append(message: text, from: sender, to: recipient)
        case .some(false):
            // Dropped rather than retried. A refused link must not become a loop, and the sender
            // learning it was refused is not information it needs — the person already decided.
            storageProblem = nil
        case .none:
            pendingIntroductions.append(
                PendingIntroduction(from: sender, to: recipient, text: text))
        }
    }

    func decideIntroduction(_ introduction: PendingIntroduction, allow: Bool) {
        pendingIntroductions.removeAll { $0.id == introduction.id }
        links.decide(from: introduction.from.id.rawValue,
                     to: introduction.to.id.rawValue, allowed: allow)
        if let link = links.decisions.last { try? store?.save(link) }

        if allow {
            append(message: introduction.text, from: introduction.from, to: introduction.to)
        }
    }

    /// Every decision made so far. The rules themselves live in `BotLinks`, in the package,
    /// because a permission decision is the part of this product that must be testable.
    private(set) var links = BotLinks()

    private func append(message: String, from sender: Bot, to recipient: Bot) {
        let thread = thread(for: recipient.id)
        thread.entries.append(TranscriptEntry(kind: .messageFrom(
            botID: sender.id.rawValue, botName: sender.name, text: message)))

        // Recorded as a run of its own, with the sending bot as the host.
        //
        // Events belong to runs — the first version of this passed a *conversation* id and every
        // delivery failed a foreign key, silently, until the storage banner surfaced it. Beyond
        // being required, a run is also the honest shape: a message arriving from another bot is
        // something that happened to this bot at a point in time, and the audit log should hold
        // it the same way it holds everything else.
        let run = RunRecord(
            botID: recipient.id.rawValue,
            conversationID: ensureConversation(for: recipient, thread: thread),
            host: "link:\(sender.id.rawValue)",
            status: "finished",
            endedAt: Date())
        try? store?.save(run)

        let joined = [sender.id.rawValue, sender.name, message].joined(separator: "\u{1}")
        persist(.text(joined), run: run.id, seq: 0, asMessageFrom: true)

        // Unread only when you are not already looking at it. Marking the open conversation
        // unread leaves a dot you cannot clear by doing the one thing that clears it.
        if selectedBotID != recipient.id,
           let index = bots.firstIndex(where: { $0.id == recipient.id }) {
            bots[index].lastReadAt = bots[index].lastReadAt
                .map { min($0, Date().addingTimeInterval(-1)) }
        }
    }

    // MARK: - Where a bot works

    /// The folder a run starts in.
    ///
    /// With no folder chosen this used to be `nil`, so the engine inherited the app's own working
    /// directory — and a Mac app launched normally runs in `/`. Every bot without a folder was
    /// pointing its tools at the root of the disk: asked to "list the files", one listed `/` and
    /// said so. Nothing about "this bot only talks" should mean "this bot's shell starts at the
    /// top of your drive".
    ///
    /// So no folder now means a private, empty folder of the bot's own. Contained by default,
    /// and kept between runs, so anything the bot writes for itself is still there next time.
    func workingDirectory(for bot: Bot) -> URL {
        if let chosen = bot.workdir { return URL(fileURLWithPath: chosen) }
        let folder = Self.workspacesDirectory.appendingPathComponent(bot.id.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var workspacesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("si.bupsy", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    // MARK: - Usage

    /// Every bot's usage since a moment, most used first — by tokens, the same unit the bars use,
    /// so the order and the bar lengths can never disagree.
    func usage(since start: Date) -> [BotUsage] {
        ((try? store?.usageByBot(since: start)) ?? []).sorted { $0.sentTokens > $1.sentTokens }
    }

    func usage(for bot: Bot, since start: Date = .distantPast) -> BotUsage? {
        (try? store?.usageByBot(since: start))?.first { $0.botID == bot.id.rawValue }
    }

    // MARK: - Faces

    /// A hue near `hue` whose shape no other bot is wearing.
    ///
    /// Shapes come from a hash, so with a handful of bots two of them landing on the same one is
    /// ordinary bad luck — the three starter bots came out as a clover and two ghosts. A bot's
    /// face must never change on its own, so this only runs when a bot is made or when someone
    /// asks for a new face, and uses the hue column that already exists. The first fourteen bots
    /// are guaranteed distinct; past that, repeats are unavoidable and fine.
    func distinctHue(near hue: Double, excluding bot: BotID? = nil) -> Double {
        // A chosen face counts as taken just as much as a derived one.
        let taken = Set(bots.filter { $0.id != bot }.map(\.effectiveShape))
        let start = BotFace.seed(forHue: hue)
        for step in 0..<360 {
            let candidate = Double((start + step) % 360) / 360
            if !taken.contains(BotFace.derivedShape(forHue: candidate)) { return candidate }
        }
        return hue
    }

    /// Sets the face a bot wears. nil for either part goes back to deriving it.
    ///
    /// The only way a face changes besides Shuffle. A face is how you find a bot in a list, so it
    /// never changes on its own — but it is yours to choose.
    func setAvatar(_ bot: Bot, shape: BotShape?, colour: Int?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].avatarShape = shape
        bots[index].avatarColour = colour
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// A new face, picked for you: a shape nobody else is wearing if one is left, and a colour
    /// different from the current one so the change is always visible.
    func shuffleFace(_ bot: Bot) {
        guard let current = bots.first(where: { $0.id == bot.id }) else { return }
        let taken = Set(bots.filter { $0.id != bot.id }.map(\.effectiveShape))
        let free = BotShape.allCases.filter { $0 != current.effectiveShape && !taken.contains($0) }
        let pool = free.isEmpty ? BotShape.allCases.filter { $0 != current.effectiveShape } : free
        let currentColour = current.avatarColour ?? BotFace.derivedColour(forHue: current.avatarHue)
        let colours = Array(0..<BotShape.palette.count).filter { $0 != currentColour }
        setAvatar(bot, shape: pool.randomElement(), colour: colours.randomElement())
    }

    // MARK: - Naming and pinning

    /// Whether another bot already answers to this name.
    ///
    /// Names stopped being cosmetic when bots could message each other: `message_bot` addresses
    /// its recipient *by name*, because that is what the model knows, and resolves to the first
    /// match. Two bots called "Scout" meant a message could silently reach the wrong one — the
    /// worst way for a gated, attributed channel to misroute. So names are unique, compared the
    /// way the resolver compares them: trimmed and case-insensitive.
    func isNameTaken(_ name: String, except bot: BotID? = nil) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        return bots.contains {
            $0.id != bot && $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Renames a bot. The colour does not follow, on purpose.
    ///
    /// A bot's hue is derived from its name the first time it is created, so a rename would
    /// otherwise change its face — and the face is how you find it in the list. Keeping the
    /// colour means a rename is a rename rather than a new bot wearing the old one's history.
    func rename(_ bot: Bot, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != bot.name, !isNameTaken(trimmed, except: bot.id),
              let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].name = trimmed
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Edits what a bot is for. Takes effect on the next thing you say to it, not retroactively.
    func setJob(_ bot: Bot, _ job: String) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        let trimmed = job.trimmingCharacters(in: .whitespaces)
        bots[index].personaPrompt = trimmed.isEmpty ? nil : trimmed
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Takes a bot out of the sidebar without destroying anything.
    ///
    /// Separate from delete on purpose: a bot you are finished with for now still owns its
    /// history, its routines and its conversation id, and "get this out of my way" must never be
    /// a destructive act dressed up as tidying. Hidden bots are still reachable by search.
    func toggleHidden(_ bot: Bot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].hidden.toggle()
        if bots[index].hidden, selectedBotID == bot.id {
            selectedBotID = bots.first { !$0.hidden }?.id
        }
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// When anything last happened in a bot's thread, for ordering by recency.
    ///
    /// Reliable only since replayed entries kept their stored timestamps; before that every
    /// reloaded thread looked equally recent, stamped with the moment it was loaded.
    func lastActivity(for bot: Bot) -> Date {
        thread(for: bot.id).entries.last?.at ?? .distantPast
    }

    /// Whether a bot has said something since you last looked at it.
    func isUnread(_ bot: Bot) -> Bool {
        // The conversation you are looking at is never unread. `markRead` fires when the
        // selection changes, so a reply arriving in the thread already on screen left a dot that
        // nothing could clear — the one thing that clears it had already happened.
        guard selectedBotID != bot.id else { return false }

        let thread = thread(for: bot.id)
        // Only the bot's own messages count. Your own last message making the row bold would
        // mark everything unread the moment you sent anything.
        guard let latest = thread.entries.last(where: { $0.isFromBot })?.at else { return false }
        guard let seen = bot.lastReadAt else { return true }
        return latest > seen
    }

    /// Called when a thread is opened. Idempotent and cheap.
    func markRead(_ bot: Bot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].lastReadAt = Date()
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Puts a bot back in the unread state so it is still obvious tomorrow.
    ///
    /// Backdated to just before its last message rather than cleared to nil: nil means "never
    /// opened", and a bot you have read and deliberately flagged is a different thing from one
    /// you have never seen.
    func markUnread(_ bot: Bot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        let latest = thread(for: bot.id).entries.last(where: { $0.isFromBot })?.at
        bots[index].lastReadAt = latest.map { $0.addingTimeInterval(-1) } ?? .distantPast
        try? store?.save(bots[index].record(sortIndex: index))
    }

    func togglePin(_ bot: Bot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].pinned.toggle()
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Pinned bots, in the order they appear. Shown above everything else.
    var pinnedBots: [Bot] { bots.filter { $0.pinned && !$0.hidden } }

    // MARK: - Folders

    /// The folders in use, in the order their first bot appears.
    ///
    /// Derived rather than stored. A folder exists exactly as long as something is in it, so
    /// there is no way to end up with an empty folder nobody can see or delete — the failure mode
    /// of every "create a folder, then put things in it" design.
    var folders: [String] {
        var seen: [String] = []
        for bot in bots where !bot.pinned && !bot.hidden {
            if let folder = bot.folder, !folder.isEmpty, !seen.contains(folder) {
                seen.append(folder)
            }
        }
        return seen
    }

    /// Bots with no folder. Shown first, above the named folders, because filing is optional.
    var ungroupedBots: [Bot] {
        bots.filter { ($0.folder ?? "").isEmpty && !$0.pinned && !$0.hidden }
    }

    /// Excludes pinned bots, which are already listed at the top. Showing a bot in both places
    /// is the bug that makes a pinned list feel broken rather than useful.
    func bots(in folder: String) -> [Bot] {
        bots.filter { $0.folder == folder && !$0.pinned && !$0.hidden }
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
        while isNameTaken(candidate) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }

    /// The whole conversation as plain text, for pasting into a ticket or an email.
    /// The engine's own resume handle, for picking a thread up in the CLI directly.
    ///
    /// bupsy should never make that harder — the whole premise is that it drives the user's own
    /// tools rather than replacing them, and a thread you cannot get back out of the app is a
    /// thread the app has taken hostage.
    func copyConversationID(of bot: Bot) {
        guard let id = thread(for: bot.id).conversationID?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    func copyTranscript(of bot: Bot) {
        let thread = thread(for: bot.id)
        var lines = ["\(bot.name) — \(bot.engine.displayName)", ""]

        for entry in thread.entries {
            switch entry.kind {
            case .userMessage(let text): lines.append("You: \(text)")
            case .messageFrom(_, let name, let text): lines.append("\(name): \(text)")
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
