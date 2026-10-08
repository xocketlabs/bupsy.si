import AppKit
import SwiftUI
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
    var selectedBotID: BotID? {
        // Leaving a bot is as much "having read it" as opening it. Marking only on open missed
        // the bot shown at launch — selected by default, never opened — so it lit up as unread
        // the moment you moved to another bot, having been on screen the whole time.
        didSet {
            // Opening a bot is seeing what went wrong with its last run, so the face stops
            // showing the failure once you have looked at it.
            if let current = selectedBotID, current != oldValue { lastFailedAt[current] = nil }
            guard let previous = oldValue, previous != selectedBotID,
                  let bot = bots.first(where: { $0.id == previous }) else { return }
            markRead(bot)
        }
    }
    var engineStatus: [EngineID: AuthStatus] = [:]
    /// Where each engine's CLI was found on this Mac, once checked. Nil when not found yet.
    var engineBinaryPaths: [EngineID: String] = [:]
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
    /// Set when a sign-in or sign-out window could not be opened, so the UI can say so rather
    /// than the click doing nothing. Cleared at the start of each attempt.
    var accountProblem: String?
    /// Shown once. Stored in UserDefaults rather than the database: it is a preference about the
    /// app, not part of the user's data, and it should not travel with a restored database.
    /// Light, dark, or whatever macOS is set to. Saved per home.
    enum Appearance: String, CaseIterable { case system, light, dark
        var label: String { switch self { case .system: "Auto"; case .light: "Light"; case .dark: "Dark" } }
        var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    }
    var appearance = Appearance(rawValue: AppHome.defaults.string(forKey: "si.bupsy.appearance") ?? "") ?? .system {
        didSet { AppHome.defaults.set(appearance.rawValue, forKey: "si.bupsy.appearance") }
    }

    /// A page the model wants the window to show next (set from flows outside the window, such
    /// as onboarding's "Connect apps first"). The root view moves there and clears it.
    var pendingDestination: NavRail.Destination?
    /// A page to show, set through `open(_:)` (AppModel+Navigation.swift). The root view moves
    /// there and clears it; its id makes a repeat request for the same page still count.
    var navigationRequest: NavigationRequest?
    /// Set by `startChat(searchFirst:)`, the Cmd N command: the root view opens the palette.
    var startChatRequest: StartChatRequest?
    /// Set by File › Continue a Claude Code Chat; the window opens the sheet and clears it.
    var claudeChatsRequest: UUID?
    /// Set by `showMainWindow()`: the menu bar icon reopens the main window if it was closed.
    var windowRequest: UUID?

    // Hooks for the debug tour (TourMode); nil in normal use.
    var tourDestination: NavRail.Destination?
    var tourPalette: Bool?
    var tourDetails: DetailTab?
    var tourSheet: String?
    /// Text put in the open bot's message box, to picture the slash command menu.
    var tourDraft: String?

    var needsOnboarding = !AppHome.defaults.bool(forKey: "si.bupsy.onboarded")

    /// Starts a bot on a fresh chat, with its own hand-off notes, once its chat gets long. See
    /// `AppModel+FreshChat`.
    var freshensLongChats = AppHome.defaults.bool(forKey: "si.bupsy.freshensLongChats") {
        didSet { AppHome.defaults.set(freshensLongChats, forKey: "si.bupsy.freshensLongChats") }
    }
    /// Bots to move to a fresh chat as soon as they are free.
    @ObservationIgnored var freshChatDue: Set<BotID> = []
    /// Bots writing their hand-off notes right now, whose own long chat must not ask for another.
    var writingHandoff: Set<BotID> = []
    /// Bots on their way to another Mac, with that Mac's name. See `AppModel+MoveBots`.
    var moving: [BotID: String] = [:]
    /// Bots whose notes are written and whose move is being sent: nothing new may start in them,
    /// or it would be work done here that never reaches the other Mac.
    @ObservationIgnored var sealedForMove: Set<BotID> = []
    /// A move waiting for the person to confirm it, shown by the sidebar.
    var moveRequest: MoveRequest?
    /// How the last move went, shown by the sidebar until dismissed.
    var moveOutcome: MoveOutcome?
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
    /// When each bot last finished a run that went well. Drives the short "done" face, which
    /// `mood(for:)` (AppModel+Mood.swift) shows for a few seconds after a run ends.
    var lastFinishedAt: [BotID: Date] = [:]
    /// When each bot's most recent run failed. Cleared when it runs again or you open it.
    var lastFailedAt: [BotID: Date] = [:]
    /// Bumped when a "done" face should go back to rest, so views that read `mood(for:)`
    /// redraw without a timer of their own.
    var moodTick = 0
    private var running: [BotID: Task<Void, Never>] = [:]
    /// Which run owns a bot's slot right now. A stopped run's task still finishes later, and its
    /// cleanup must not wipe the state of a run started after it (stop, then a quick send).
    private var runTokens: [BotID: UUID] = [:]
    private var gates: [BotID: ApprovalGate] = [:]
    private var awake: [BotID: PowerAssertion] = [:]
    private var routineTimer: Task<Void, Never>?
    private let keychain = KeychainStore()
    private let notifier = Notifier()
    /// Internal rather than private so the model's extensions in other files can write to it.
    let store: Store?

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
        loadSections()
        loadGroups()
        // Quitting stops every run. Left alone, an engine and the commands it started carry on
        // after the app has gone, with no gate answering and nothing on screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopEverything() }
        }
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
        prefetchConnectorEnv()
        objectives = (try? self.store?.objectives()) ?? []
        folderWatches = (try? self.store?.folderWatches()) ?? []
        syncLaunchAgent()
    }

    // MARK: - Connectors
    //
    // Stored in UserDefaults rather than the database: a connector definition is a command and a
    // list of environment variable *names*, which is configuration rather than the user's data,
    // and keeping it out of the database keeps the "no credential columns" rule trivially true.

    private static let connectorsKey = "si.bupsy.connectors"

    private static func loadConnectors() -> [MCPServer] {
        guard let data = AppHome.defaults.data(forKey: connectorsKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    private func saveConnectors() {
        if let data = try? JSONEncoder().encode(connectors) {
            AppHome.defaults.set(data, forKey: Self.connectorsKey)
        }
        prefetchConnectorEnv()
    }

    /// Asks the login shell for the variables connectors need, off the main thread, so the
    /// "missing" check on the Connectors page answers from memory instead of waiting on a shell.
    /// Values stay in memory only; nothing here logs or saves them.
    private func prefetchConnectorEnv() {
        let servers = connectors
        guard servers.contains(where: { !$0.requiredEnvNames.isEmpty }) else {
            missingConnectorEnv = [:]
            return
        }
        envCheck += 1
        let check = envCheck
        Task.detached(priority: .utility) { [weak self] in
            var missing: [String: [String]] = [:]
            for server in servers { missing[server.name] = server.missingEnv() }
            await MainActor.run {
                // A newer check (a connector edited meanwhile) wins over this one.
                guard let self, self.envCheck == check else { return }
                self.missingConnectorEnv = missing
            }
        }
    }

    /// The variables each connector still needs, by server name: names only, never values.
    /// Filled by `prefetchConnectorEnv`, so the Connectors page never waits on a login shell.
    private(set) var missingConnectorEnv: [String: [String]] = [:]

    /// What you typed and have not sent, per bot and per group, so leaving a page keeps it. In
    /// memory only. Not observed: only a page appearing reads it, never a view body.
    @ObservationIgnored var botDrafts: [BotID: String] = [:]
    @ObservationIgnored var groupDrafts: [String: String] = [:]
    private var envCheck = 0

    func addConnector(_ server: MCPServer) {
        guard !connectors.contains(where: { $0.name == server.name }) else { return }
        connectors.append(server)
        saveConnectors()
    }

    /// Whether another server already uses this name. Names key the engine's config, so two
    /// servers with one name would silently become one.
    func connectorNameTaken(_ name: String, except id: String? = nil) -> Bool {
        connectors.contains { $0.name == name && $0.id != id }
    }

    /// Saves an edited server in place of the one with the same id.
    ///
    /// Always-allow rules match on the name, so they are kept when the name is unchanged and
    /// taken back when it changes: a rule for the old name would otherwise point at nothing, and
    /// quietly carrying it over would allow a server the person never allowed.
    func updateConnector(_ server: MCPServer) {
        guard let index = connectors.firstIndex(where: { $0.id == server.id }),
              !connectorNameTaken(server.name, except: server.id)
        else { return }
        let previous = connectors[index]
        connectors[index] = server
        if previous.name != server.name {
            for botIndex in bots.indices
            where bots[botIndex].toolAllowlist.contains(previous.toolPrefix) {
                bots[botIndex].toolAllowlist.remove(previous.toolPrefix)
                try? store?.save(bots[botIndex].record(sortIndex: botIndex))
            }
        }
        saveConnectors()
    }

    func removeConnector(_ server: MCPServer) {
        // Removing Executor is a decision, and it must stick: it is never switched back on behind
        // the person's back. Adding it again from its card clears this.
        if server.name == Executor.name {
            AppHome.defaults.set(true, forKey: Self.executorRemovedKey)
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
            removedByPerson: AppHome.defaults.bool(forKey: Self.executorRemovedKey)) {
            addConnector(Executor.server)
        }
    }

    /// Turns Executor back on after the person removed it.
    func addExecutor() {
        AppHome.defaults.removeObject(forKey: Self.executorRemovedKey)
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
        AppHome.defaults.set(true, forKey: "si.bupsy.onboarded")
        needsOnboarding = false
    }

    /// Bumped whenever the key is saved or removed. The Keychain is not observable, so views that
    /// read `hasComputeKey` or `computeKeySuffix` depend on this to redraw.
    private var computeKeyRevision = 0

    /// Where the last four characters of the key are kept, to show it masked. Only those four:
    /// the full key never leaves the Keychain.
    private static let computeKeySuffixKey = "si.bupsy.boat.keySuffix"

    var hasComputeKey: Bool {
        _ = computeKeyRevision
        return keychain.has(.boatAPIKey)
    }

    /// The key's last four characters, for "bd_live_••••3f9a". Nil for a key saved before these
    /// were kept, or when there is no key.
    var computeKeySuffix: String? {
        _ = computeKeyRevision
        return AppHome.defaults.string(forKey: Self.computeKeySuffixKey)
    }

    /// Machines with a start or stop in flight, by record id, so their rows can show it.
    private(set) var machinesInFlight: Set<String> = []

    func setComputeKey(_ key: String) {
        do {
            try keychain.set(key, for: .boatAPIKey)
            AppHome.defaults.set(String(key.suffix(4)), forKey: Self.computeKeySuffixKey)
            machineProblem = nil
        } catch {
            machineProblem = error.localizedDescription
        }
        computeKeyRevision += 1
    }

    /// Checks a key with boat.dev before saving it, using the cheapest call there is (listing
    /// machines, which creates and bills nothing). Returns what went wrong, or nil once saved.
    /// A key boat refuses is never saved, so "Connected" always means a key that worked.
    func validateAndSaveComputeKey(_ key: String) async -> String? {
        machineProblem = nil
        do {
            try await BoatAPI(apiKey: key).checkKey()
        } catch let error as BoatError where error.isAuthFailure {
            return "boat.dev didn\u{2019}t accept that key. Check it and try again."
        } catch {
            return "Couldn\u{2019}t reach boat.dev to check the key. \(error.localizedDescription)"
        }
        setComputeKey(key)
        return machineProblem
    }

    /// Forgets the key. Machines stay listed, and stay on boat.dev, until a key is added again.
    func removeComputeKey() {
        do {
            try keychain.remove(.boatAPIKey)
            AppHome.defaults.removeObject(forKey: Self.computeKeySuffixKey)
            machineProblem = nil
        } catch {
            machineProblem = error.localizedDescription
        }
        computeKeyRevision += 1
    }

    private func api() -> BoatAPI? {
        keychain.get(.boatAPIKey).map { BoatAPI(apiKey: $0) }
    }

    func createMachine(name: String, size: MachineSize, alwaysOn: Bool) {
        machineProblem = nil
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
                self.machineProblem = nil
            } catch {
                var failed = record
                failed.state = "failed"
                self.replace(failed)
                self.machineProblem = error.localizedDescription
            }
        }
    }

    /// Tries again to create a machine whose create failed, keeping its name, size and
    /// availability. Its record stays the same, so nothing on the page jumps around.
    func retryMachine(_ machine: MachineRecord) {
        machineProblem = nil
        guard machine.providerID == nil, !machinesInFlight.contains(machine.id) else { return }
        guard let api = api() else {
            machineProblem = "Add your boat.dev key first."
            return
        }
        let size = MachineSize(rawValue: machine.size) ?? .small
        var creating = machine
        creating.state = "creating"
        replace(creating)
        machinesInFlight.insert(machine.id)

        Task { [creating] in
            defer { self.machinesInFlight.remove(creating.id) }
            do {
                let options = creating.ttlSeconds == nil
                    ? CreateOptions.alwaysOn(size: size)
                    : CreateOptions(size: size, ttlSeconds: creating.ttlSeconds)
                let sandbox = try await api.create(options)
                var updated = creating
                updated.providerID = sandbox.id
                updated.state = sandbox.state ?? "running"
                updated.lastActiveAt = Date()
                self.replace(updated)
                self.machineProblem = nil
            } catch {
                var failed = creating
                failed.state = "failed"
                self.replace(failed)
                self.machineProblem = error.localizedDescription
            }
        }
    }

    func toggleMachine(_ machine: MachineRecord) {
        machineProblem = nil
        guard !machinesInFlight.contains(machine.id) else { return }
        guard let api = api(), let providerID = machine.providerID else {
            machineProblem = "This machine was never created on boat.dev."
            return
        }
        let wantsRunning = machine.state != "running"
        machinesInFlight.insert(machine.id)
        Task {
            defer { self.machinesInFlight.remove(machine.id) }
            do {
                let sandbox = wantsRunning
                    ? try await api.resume(providerID)
                    : try await api.stop(providerID)
                var updated = machine
                updated.state = sandbox.state ?? (wantsRunning ? "running" : "archived")
                updated.lastActiveAt = Date()
                self.replace(updated)
                self.machineProblem = nil
            } catch {
                self.machineProblem = error.localizedDescription
            }
        }
    }

    /// Stops the machine on boat.dev, then forgets it here. Returns false, keeps the record and
    /// sets `machineProblem` if boat could not be reached: forgetting a machine that is still
    /// running would leave it billing with nothing in Bupsy to stop it from.
    ///
    /// A force stop rather than a delete, because boat's API as this client knows it has no
    /// delete endpoint. A stopped machine stops using compute; removing it from the account
    /// entirely is done on boat.dev.
    func destroyMachine(_ machine: MachineRecord) async -> Bool {
        machineProblem = nil
        if let providerID = machine.providerID {
            guard let api = api() else {
                machineProblem = "Add your boat.dev key first, so \(machine.name) can be stopped there."
                return false
            }
            do {
                _ = try await api.stop(providerID, force: true)
            } catch {
                let status = (error as? BoatError)?.status
                let alreadyStopped = ["stopped", "archived", "archiving"].contains(machine.state)
                // Gone on boat, or already stopped there: nothing is running, so it is safe to
                // forget. Anything else might still be billing.
                guard status == 404 || (status == 409 && alreadyStopped) else {
                    machineProblem = "\(machine.name) couldn't be stopped on boat.dev, so it was kept here. \(error.localizedDescription)"
                    return false
                }
            }
        }
        forgetMachine(machine)
        machineProblem = nil
        return true
    }

    /// Kept for callers that cannot wait. Stops the machine on boat first, like `destroyMachine`.
    func deleteMachine(_ machine: MachineRecord) {
        Task { _ = await destroyMachine(machine) }
    }

    /// Removes the record here. Bots assigned to it become machine-less, which is an
    /// ordinary state: they go back to running on this Mac rather than breaking.
    private func forgetMachine(_ machine: MachineRecord) {
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
    /// Not while it runs: the run belongs to the old engine's conversation, and swapping the
    /// visible thread under it would hide the very work in progress.
    func setEngine(_ bot: Bot, _ engine: EngineID) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }), bot.engine != engine,
              running[bot.id] == nil
        else { return }
        let previous = bots[index].engine

        bots[index].engine = engine
        // A model name from one engine is meaningless to the other.
        bots[index].model = nil
        try? store?.save(bots[index].record(sortIndex: index))

        threads[bot.id] = nil
        // Said in the new thread, so the old conversation disappearing never reads as lost.
        thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
            "Switched to \(engine.displayName). Your \(previous.displayName) conversation comes "
                + "back if you switch back.")))
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

    // MARK: - Folder watches

    var folderWatches: [FolderWatch] = []
    private var watchers: [String: FolderWatcher] = [:]
    /// When each bot last finished a run — changes it made itself should not set it off again.
    private var lastRunEnded: [BotID: Date] = [:]

    func startFolderWatches() {
        for watch in folderWatches { syncWatcher(watch) }
    }

    func addFolderWatch(to bot: Bot, name: String, prompt: String, path: String,
                        fileTypes: [String] = []) {
        let watch = FolderWatch(botID: bot.id.rawValue, name: name, prompt: prompt, path: path,
                                fileTypes: fileTypes)
        folderWatches.append(watch)
        try? store?.save(watch)
        syncWatcher(watch)
    }

    /// Saves changes to a folder watch: its folder, what to do, which files, or its name. A new
    /// folder starts being watched straight away, which is also how a missing one is fixed.
    func updateFolderWatch(_ watch: FolderWatch, name: String, prompt: String, path: String,
                           fileTypes: [String]) {
        guard let index = folderWatches.firstIndex(where: { $0.id == watch.id }) else { return }
        folderWatches[index].name = name
        folderWatches[index].prompt = prompt
        folderWatches[index].path = path
        folderWatches[index].fileTypes = fileTypes
        try? store?.save(folderWatches[index])
        syncWatcher(folderWatches[index])
    }

    /// Points a watch at another folder, keeping everything else.
    func moveFolderWatch(_ watch: FolderWatch, to path: String) {
        guard let current = folderWatches.first(where: { $0.id == watch.id }) else { return }
        updateFolderWatch(current, name: current.name, prompt: current.prompt, path: path,
                          fileTypes: current.fileTypes)
    }

    func setFolderWatchEnabled(_ watch: FolderWatch, _ enabled: Bool) {
        guard let index = folderWatches.firstIndex(where: { $0.id == watch.id }) else { return }
        folderWatches[index].enabled = enabled
        try? store?.save(folderWatches[index])
        syncWatcher(folderWatches[index])
    }

    func deleteFolderWatch(_ watch: FolderWatch) {
        watchers.removeValue(forKey: watch.id)?.stop()
        folderWatches.removeAll { $0.id == watch.id }
        try? store?.deleteTrigger(id: watch.id)
    }

    func syncWatcher(_ watch: FolderWatch) {
        watchers.removeValue(forKey: watch.id)?.stop()
        guard watch.enabled, FileManager.default.fileExists(atPath: watch.path) else { return }
        watchers[watch.id] = FolderWatcher(path: watch.path) { [weak self] changed in
            self?.folderChanged(watch.id, changed)
        }
    }

    /// Changes that arrived while a watch's bot was busy, by watch id, with when the first one
    /// came. Kept, not dropped, and handed over once the bot is free.
    private var heldWatchChanges: [String: (paths: Set<String>, since: Date)] = [:]

    private func folderChanged(_ id: String, _ changed: [String]) {
        // Paused: a change is let go rather than kept for later, the same as a skipped routine.
        guard !isPaused else { return }
        guard let watch = folderWatches.first(where: { $0.id == id }), watch.enabled,
              let bot = bots.first(where: { $0.id.rawValue == watch.botID }) else { return }
        let wanted = changed.filter { watch.matches($0) }
        guard !wanted.isEmpty else { return }
        // Busy: keep the changes and run once it is free. What the bot wrote itself in the
        // meantime is taken out then, so it does not set itself off.
        if running[bot.id] != nil {
            if var held = heldWatchChanges[id] {
                held.paths.formUnion(wanted)
                heldWatchChanges[id] = held
            } else {
                heldWatchChanges[id] = (Set(wanted), Date())
                waitingForBot[bot.id, default: []].append { [weak self] in
                    self?.releaseHeldWatchChanges(id, bot: bot)
                }
            }
            return
        }
        // Its own last writes land a few seconds after a run ends; those are not news.
        if let ended = lastRunEnded[bot.id], Date().timeIntervalSince(ended) < 8 { return }
        runFolderWatch(watch, bot: bot, changed: wanted)
    }

    /// Runs a watch for the changes held while its bot was busy, less the files the bot itself
    /// wrote meanwhile (as far as its recorded tool calls say).
    private func releaseHeldWatchChanges(_ id: String, bot: Bot) {
        guard let held = heldWatchChanges.removeValue(forKey: id) else {
            botBecameFree(bot)
            return
        }
        if running[bot.id] != nil {
            // Something else claimed the bot first. Wait again.
            heldWatchChanges[id] = held
            waitingForBot[bot.id, default: []].append { [weak self] in
                self?.releaseHeldWatchChanges(id, bot: bot)
            }
            return
        }
        // Events reach the watcher a few seconds after the write, so look back a little further.
        let since = held.since.addingTimeInterval(-60)
        let ownWrites = Set(filesWritten(by: bot)
            .filter { $0.at >= since }
            .map { ($0.path as NSString).standardizingPath })
        let remaining = held.paths.filter { !ownWrites.contains(($0 as NSString).standardizingPath) }
        guard let watch = folderWatches.first(where: { $0.id == id }), watch.enabled,
              !remaining.isEmpty, runFolderWatch(watch, bot: bot, changed: Array(remaining))
        else {
            // Nothing ran, so whatever waits behind this goes now.
            botBecameFree(bot)
            return
        }
    }

    @discardableResult
    private func runFolderWatch(_ watch: FolderWatch, bot: Bot, changed: [String]) -> Bool {
        let name = watch.name
        return sendTriggered(watch.prompt(for: changed), to: bot, triggerID: watch.id,
                             automatic: true) { [weak self] reply in
            self?.notifier.routineFinished(bot: bot.name, routine: name,
                                           summary: reply.split(separator: "\n").first.map(String.init),
                                           botID: bot.id)
        }
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

    /// Saves changes to an existing routine — its name, instruction, schedule or where it runs.
    func updateRoutine(_ routine: Routine, name: String, prompt: String, cron: String, tier: Routine.Tier) {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }),
              let bot = bots.first(where: { $0.id.rawValue == routine.botID }) else { return }
        routines[index].name = name
        routines[index].prompt = prompt
        routines[index].cron = cron
        routines[index].tier = (tier == .machine && bot.machineID == nil) ? .appOpen : tier
        try? store?.save(routines[index])
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
    func syncLaunchAgent() {
        // A throwaway home must not install, change or remove the real background scheduler.
        guard !AppHome.isSandboxed else { return }
        let objectiveRoutines = objectives.map {
            Routine(id: $0.id, botID: $0.botID, name: "check", prompt: "",
                    cron: $0.checkCron, enabled: $0.enabled, tier: $0.tier)
        }
        // Paused: launchd has nothing to wake the app for, so the agent comes out until resume.
        let intervals = isPaused
            ? []
            : RoutineScheduler().launchdIntervals(for: routines + objectiveRoutines)
        let appPath = Bundle.main.bundlePath
        Task.detached { [weak self] in
            do {
                if intervals.isEmpty {
                    try LaunchAgent.uninstall()
                } else {
                    try LaunchAgent.install(intervals: intervals, appPath: appPath)
                }
                // Worked this time, so an earlier failure no longer describes anything.
                await MainActor.run { [weak self] in self?.routineProblem = nil }
            } catch {
                // Never swallowed: a routine that silently never fires is this feature's worst
                // failure, so the reason reaches the user rather than a debug log.
                FileHandle.standardError.write(Data("bupsy: launch agent: \(error)\n".utf8))
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
        // Paused: each slot that comes round is marked as filled without running, so nothing
        // piles up to fire in a burst on resume, and no "finished" notification is posted.
        if isPaused {
            skipDueWork(now: now)
            return
        }
        for objective in dueObjectives(now: now) {
            checkObjective(objective, automatic: true)
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
                ? "\n\n(Running late. This was scheduled for "
                    + due.scheduledFor.formatted(date: .omitted, time: .shortened) + ".)"
                : ""
            let name = due.routine.name
            sendTriggered(due.routine.prompt + note, to: bot, triggerID: due.routine.id,
                          automatic: true) { [weak self] reply in
                // Unattended work that finishes silently may as well not have run.
                self?.notifier.routineFinished(
                    bot: bot.name, routine: name,
                    summary: reply.split(separator: "\n").first.map(String.init),
                    botID: bot.id)
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

    /// Rewrites a goal in place, keeping what the bot has learned and when it last checked.
    /// A cron of nil keeps the current schedule.
    func updateObjective(_ objective: Objective, goal: String, doneWhen: String, cron: String? = nil) {
        guard let index = objectives.firstIndex(where: { $0.id == objective.id }) else { return }
        objectives[index].goal = goal
        objectives[index].doneWhen = doneWhen
        if let cron { objectives[index].checkCron = cron }
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

    /// Runs one check now. `automatic` is true when the schedule started it rather than a person,
    /// so a pause holds it.
    func checkObjective(_ objective: Objective, automatic: Bool = false) {
        if automatic && isPaused { return }
        guard let bot = bots.first(where: { $0.id.rawValue == objective.botID }) else { return }

        // Recorded before the run, so a crash mid-check cannot cause it to repeat immediately.
        if let index = objectives.firstIndex(where: { $0.id == objective.id }) {
            objectives[index].lastCheckedAt = Date()
            try? store?.save(objectives[index])
        }

        checkingObjectives.insert(objective.id)
        let started = sendTriggered(ObjectiveCheck.prompt(for: objective), to: bot,
                                    triggerID: objective.id, automatic: automatic) { [weak self] reply in
            self?.checkingObjectives.remove(objective.id)
            guard let self,
                  let index = self.objectives.firstIndex(where: { $0.id == objective.id })
            else { return }

            let outcome = ObjectiveCheck.outcome(from: reply)
            if case .needsYou(let question) = outcome {
                self.notifier.objectiveNeedsYou(bot: bot.name, question: question, botID: bot.id)
            }
            self.objectives[index].lastOutcome = outcome
            self.objectives[index].notes = ObjectiveCheck.updatedNotes(
                self.objectives[index].notes,
                adding: ObjectiveCheck.learnings(from: reply))
            try? self.store?.save(self.objectives[index])
        }
        if !started { checkingObjectives.remove(objective.id) }
    }

    /// Goals with a check under way or waiting for their bot, so "Check now" can say so.
    var checkingObjectives: Set<String> = []

    func isChecking(_ objective: Objective) -> Bool { checkingObjectives.contains(objective.id) }

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

    /// Everything waiting on a person, in one place. The inbox lists exactly these, and the
    /// sidebar and menu bar counts are this array's count, so the three never disagree.
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        for bot in bots {
            // Its own thread and, while it runs somewhere else, that thread too. Group side
            // threads are listed per group below, so they can name the group.
            var own: [Thread] = []
            if let thread = threads[bot.id] { own.append(thread) }
            if let active = activeThread[bot.id], !own.contains(where: { $0 === active }),
               !groupSideThreads.values.contains(where: { $0 === active }) {
                own.append(active)
            }
            for thread in own {
                for entry in thread.entries {
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
                    if case .question(let question) = entry.kind, question.answer == nil {
                        items.append(AttentionItem(
                            id: question.id, botID: bot.id, botName: bot.name, hue: bot.avatarHue,
                            kind: .question,
                            title: "\(bot.name) asked you something",
                            detail: question.question))
                    }
                }
            }
        }

        // Bots on the person's other Macs that are waiting on them. Their Mac says so; the details
        // are in their chat, which this opens.
        for bot in linked.remoteBots {
            guard let remote = bot.remote, remote.online, remote.needsYou else { continue }
            items.append(AttentionItem(
                id: "remote|\(bot.id.rawValue)", botID: bot.id, botName: bot.name, hue: bot.avatarHue,
                kind: .remote(remote.macName),
                title: "\(bot.name) needs you on \(remote.macName)",
                detail: remote.preview ?? ""))
        }

        for group in groups {
            for bot in members(of: group) {
                guard let side = groupSideThreads["\(bot.id.rawValue)|\(group.id)"] else { continue }
                for entry in side.entries {
                    if case .approval(let approval) = entry.kind, approval.decided == nil {
                        var item = AttentionItem(
                            id: approval.id, botID: bot.id, botName: bot.name, hue: bot.avatarHue,
                            kind: .groupApproval(group.id),
                            title: "\(bot.name) wants to \(ToolNames.action(approval.tool))",
                            detail: approval.summary,
                            detailIsCommand: ToolNames.isCommand(approval.tool))
                        item.groupName = group.name
                        items.append(item)
                    }
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

        // A group that hit its turn limit stops and waits for you to say something.
        for group in groups where groupThread(for: group).isWaitingOnYou {
            let face = group.leadBotID.flatMap { id in bots.first { $0.id == id } }
                ?? members(of: group).first
            guard let face else { continue }
            var item = AttentionItem(
                id: "paused-\(group.id)", botID: face.id, botName: face.name, hue: face.avatarHue,
                kind: .pausedGroup(group.id),
                title: "\(group.name) paused after \(group.turnLimit) turns",
                detail: "Say something in the group to keep it going.")
            item.groupName = group.name
            items.append(item)
        }

        return items
    }

    /// Clears a stuck goal from Waiting on you without running it again. The next check sets
    /// its outcome afresh.
    func markObjectiveHandled(_ objective: Objective) {
        guard let index = objectives.firstIndex(where: { $0.id == objective.id }) else { return }
        objectives[index].lastOutcome = nil
        try? store?.save(objectives[index])
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
            bots = seedBots()
            return
        }
        do {
            let records = try store.bots()
            if records.isEmpty {
                bots = seedBots()
                for (index, bot) in bots.enumerated() {
                    try store.save(bot.record(sortIndex: index))
                }
            } else {
                bots = records.map(Bot.init(record:))
            }
            links = BotLinks((try? store.botLinks()) ?? [])
        } catch {
            storageProblem = error.localizedDescription
            bots = seedBots()
        }
    }

    /// The bots an empty roster starts with. None on a fresh install: onboarding makes the
    /// person's first bot, and starters made before it contradicted "your first bot" and hid
    /// the empty roster. Someone who already finished onboarding still gets the starters.
    private func seedBots() -> [Bot] {
        needsOnboarding ? [] : Self.starterBots()
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
        // The first thing anyone sees: three different characters in three different colours,
        // matching the designs (Scout the pink Bup, Builder the blue cat, Inbox the amber bear).
        let faces: [(BotShape, Int)] = [(.bup, 0), (.cat, 2), (.bear, 6)]
        for (index, face) in zip(bots.indices, faces) {
            bots[index].avatarShape = face.0
            bots[index].avatarColour = face.1
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
                // The meter as it was when the app last saw this conversation, until the next turn.
                created.latestUsage = rememberedContext(botID, conversation: created.conversationID)
                    .map { Usage(context: $0) }
            } catch {
                storageProblem = error.localizedDescription
            }
        }
        threads[botID] = created
        return created
    }

    func isRunning(_ botID: BotID) -> Bool {
        running[botID] != nil || (linked.ref(botID)?.running ?? false)
    }

    /// What a running bot is doing right now ("Reading 3 files"), read from the thread it is
    /// actually running in, which inside a group is not its own chat.
    func liveStatus(for bot: Bot) -> String {
        ChatLiveStatus.text(for: (activeThread[bot.id] ?? thread(for: bot.id)).entries)
    }

    func hasRuns(_ bot: Bot) -> Bool {
        (try? store?.hasRuns(forBot: bot.id.rawValue)) ?? false
    }

    func recentRuns(for bot: Bot) -> [RunSummary] {
        (try? store?.recentRuns(forBot: bot.id.rawValue, limit: 20)) ?? []
    }

    /// True when a bot is blocked on a decision from you, which the roster shows differently
    /// from merely working — it is the state that needs a human.
    ///
    /// Older and narrower than `needsYou(_:)` (AppModel+Mood.swift), which also counts group
    /// approvals, questions and stuck goals. Kept until every caller has moved over.
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
            // Where the CLI was found, for the sign-in rows. Resolved the way runs resolve it,
            // off the main thread because the fallback asks a login shell.
            if case .notInstalled = status {
                engineBinaryPaths[id] = nil
            } else {
                let binary = adapter.binaryName
                engineBinaryPaths[id] = await Task.detached { try? BinaryResolver.resolve(binary).path }.value
            }
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
        case .notInstalled: "notInstalled"
        case .unknown: "unknown"
        }
    }

    /// `shown` is what the chat shows in place of the prompt: the `/prompts:name args` a person
    /// typed, where the engine is sent the prompt it stands for.
    func send(_ prompt: String, to bot: Bot, shown: String? = nil) {
        // A bot on another Mac is sent to there; that Mac queues and runs it.
        if bot.remote != nil { linked.send(prompt, to: bot); return }
        send(prompt, to: bot, shown: shown, onFinish: nil)
    }

    func send(
        _ prompt: String, to bot: Bot, shown: String? = nil,
        onFinish: (@MainActor @Sendable (String) -> Void)?
    ) {
        // Leaving for another Mac: said, not dropped silently, so it can be sent again there.
        if sealedForMove.contains(bot.id) {
            let thread = thread(for: bot.id)
            thread.entries.append(TranscriptEntry(kind: .userMessage(shown ?? prompt)))
            thread.entries.append(TranscriptEntry(kind: .note(
                "Not sent: \(bot.name) is moving to \(moving[bot.id] ?? "another Mac"). Send it there once it arrives.")))
            return
        }
        // Busy: keep it rather than drop it. It shows in the thread now and goes to the bot, with
        // anything else typed meanwhile, the moment the current run ends.
        if running[bot.id] != nil {
            let thread = thread(for: bot.id)
            let entry = TranscriptEntry(kind: .userMessage(shown ?? prompt))
            thread.entries.append(entry)
            queued[bot.id, default: []].append(prompt)
            queuedEntries[bot.id, default: []].append(entry.id)
            if queuedNote[bot.id] == nil {
                let note = TranscriptEntry(kind: .note("Queued. \(bot.name) reads this when it's done."))
                queuedNote[bot.id] = note.id
                thread.entries.append(note)
            }
            return
        }
        startRun(prompt, bot: bot, thread: thread(for: bot.id), groupID: nil, onFinish: onFinish, shown: shown)
    }

    /// A run something other than you started: a routine, a goal check or a folder watch.
    ///
    /// Tagged with the id of what started it, so that thing's history finds it. Never merged with
    /// messages typed while the bot is busy: it waits its turn as a run of its own, after them,
    /// and keeps its finish handler, so its notification still arrives. Returns false only when
    /// it could neither start nor wait, so the caller can undo anything it marked as in flight.
    ///
    /// `automatic` marks work nobody started by hand (a schedule, a goal check, a folder watch).
    /// While paused that is let go: refused here, and dropped if it was waiting for its bot.
    @discardableResult
    func sendTriggered(
        _ prompt: String, to bot: Bot, triggerID: String, automatic: Bool = false,
        onFinish: (@MainActor @Sendable (String) -> Void)?
    ) -> Bool {
        if automatic && isPaused { return false }
        if running[bot.id] != nil {
            waitingForBot[bot.id, default: []].append { [weak self] in
                guard let self else { return }
                let waited = self.sendTriggered(prompt, to: bot, triggerID: triggerID,
                                                automatic: automatic, onFinish: onFinish)
                // Nothing started and nothing to wait for: let whatever is queued behind it go.
                if !waited || self.running[bot.id] == nil { self.botBecameFree(bot) }
            }
            return true
        }
        return startRun(prompt, bot: bot, thread: thread(for: bot.id), groupID: nil,
                        onFinish: onFinish, triggerID: triggerID)
    }

    /// Messages typed while a bot was busy, waiting to go to it together.
    private var queued: [BotID: [String]] = [:]
    private var queuedNote: [BotID: UUID] = [:]
    /// The thread rows of those messages, so Edit can take them back out.
    private var queuedEntries: [BotID: [UUID]] = [:]
    /// Work waiting for a bot that was busy elsewhere — a group turn, say. Run in order as it frees.
    var waitingForBot: [BotID: [@MainActor () -> Void]] = [:]

    func queuedCount(for bot: Bot) -> Int { queued[bot.id]?.count ?? 0 }

    /// Stops what the bot is doing so what you queued goes now, instead of after it finishes.
    ///
    /// Stopping already sends the queue on: the run's cleanup frees the bot and the queued
    /// messages start the next run, resuming the same conversation, so the bot reads them with
    /// everything it had done so far.
    func sendQueuedNow(_ bot: Bot) {
        guard running[bot.id] != nil, queuedCount(for: bot) > 0 else { return }
        thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
            "You sent this now. \(bot.name) stopped what it was doing to read it.")))
        stop(bot.id)
    }

    /// Takes queued messages back out of the thread and the queue, and returns their text for
    /// the message box, so a message sent too soon can be changed rather than chased.
    func takeBackQueued(_ bot: Bot) -> String? {
        guard let messages = queued.removeValue(forKey: bot.id), !messages.isEmpty else { return nil }
        let ids = Set(queuedEntries.removeValue(forKey: bot.id) ?? [])
            .union(queuedNote.removeValue(forKey: bot.id).map { [$0] } ?? [])
        thread(for: bot.id).entries.removeAll { ids.contains($0.id) }
        return messages.joined(separator: "\n\n")
    }

    /// Called when a bot's run ends: queued messages first, then anything else that waited for it.
    func botBecameFree(_ bot: Bot) {
        guard running[bot.id] == nil else { return }
        // A hand-off that was stopped never finished; nothing is being written any more.
        writingHandoff.remove(bot.id)
        // Before anything queued, so what was waiting goes to the fresh chat, not the long one.
        if freshChatDue.remove(bot.id) != nil, writeHandoff(bot) { return }
        if let messages = queued.removeValue(forKey: bot.id), let prompt = QueuedMessages.prompt(messages) {
            queuedEntries[bot.id] = nil
            let thread = thread(for: bot.id)
            if let note = queuedNote.removeValue(forKey: bot.id) {
                thread.entries.removeAll { $0.id == note }
            }
            _ = startRun(prompt, bot: bot, thread: thread, groupID: nil, onFinish: nil,
                         alreadyShown: true, separateMessages: messages)
            return
        }
        if var pending = waitingForBot[bot.id], !pending.isEmpty {
            let next = pending.removeFirst()
            waitingForBot[bot.id] = pending.isEmpty ? nil : pending
            next()
        }
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
        onFinish: (@MainActor @Sendable (String) -> Void)?,
        from sender: Bot? = nil, shown: String? = nil, hidesPrompt: Bool = false,
        alreadyShown: Bool = false, separateMessages: [String]? = nil,
        triggerID: String? = nil
    ) -> Bool {
        // The bot as it is now, not as it was when this run was asked for: a message queued
        // behind a run, or a turn waiting in a group, must use the trust level, folder and job
        // you have set since. Gone means deleted while it waited, so nothing runs.
        guard let bot = bots.first(where: { $0.id == bot.id }) else { return false }
        // One run per bot at a time, wherever it is. A bot cannot answer in a group while it is
        // still working on something you asked it directly.
        guard running[bot.id] == nil, let adapter = adapters[bot.engine] else { return false }
        // On its way to another Mac: a routine or another bot's message must not start work here
        // that the move would then cut off.
        guard !sealedForMove.contains(bot.id) else { return false }

        // A run another bot started reads as that bot's message, showing what it actually wrote
        // (`shown`) rather than bupsy's framing around it — never as something the person said.
        // From the person, `shown` is the short command they typed for a longer prompt.
        // A prompt bupsy wrote on the person's behalf — a new bot's "introduce yourself" — is not
        // shown as something they said. The bot's reply is the first thing in the thread.
        if hidesPrompt || alreadyShown {
        } else if let sender {
            thread.entries.append(TranscriptEntry(kind: .messageFrom(
                botID: sender.id.rawValue, botName: sender.name, text: shown ?? prompt)))
        } else {
            thread.entries.append(TranscriptEntry(kind: .userMessage(shown ?? prompt)))
        }
        thread.isRunning = true
        activeThread[bot.id] = thread
        lastFailedAt[bot.id] = nil

        let conversationID = ensureConversation(for: bot, thread: thread, group: groupID)
        var run = RunRecord(
            botID: bot.id.rawValue,
            conversationID: conversationID,
            // The routine, goal or folder watch that started it, so its page finds it by id.
            triggerID: triggerID,
            host: bot.machineID.map { "cloud:\($0)" } ?? "local",
            groupID: groupID
        )
        do {
            try store?.save(run)
        } catch {
            // Seen once on a fresh install and never reproduced: the run would not save, and every
            // event after it failed its foreign key. Rather than leave the thread unrecorded,
            // re-create what the run hangs off and try once more; only then say so.
            let fresh = ConversationRecord(botID: bot.id.rawValue, engine: bot.engine.rawValue,
                                           groupID: groupID)
            try? store?.save(bot.record(sortIndex: bots.firstIndex { $0.id == bot.id } ?? 0))
            try? store?.save(fresh)
            run.conversationID = fresh.id
            do { try store?.save(run) } catch {
                storageProblem = "This conversation couldn't be saved: \(error.localizedDescription)"
            }
        }
        if hidesPrompt {
        } else if let separateMessages {
            // Queued messages are stored as the person typed them, so a reloaded thread shows
            // each one — not the joined prompt bupsy wrote for the bot.
            for (index, message) in separateMessages.enumerated() {
                persist(.text(message), run: run.id, seq: index - separateMessages.count,
                        asUserMessage: true)
            }
        } else if let sender {
            let joined = [sender.id.rawValue, sender.name, shown ?? prompt].joined(separator: "\u{1}")
            persist(.text(joined), run: run.id, seq: 0, asMessageFrom: true)
        } else {
            persist(.text(shown ?? prompt), run: run.id, seq: 0, asUserMessage: true)
        }

        // A fresh gate per run: the hook script and settings are written to a temporary
        // directory, and the engine is told about them with `--settings`. An engine started
        // without this runs ungated, which is only ever correct for an auth probe.
        var gateSettings: String?
        let runGate = try? ApprovalGate.temporary()
        if let gate = runGate {
            gates[bot.id] = gate
            gateRuns[bot.id] = run.id
            gateSettings = try? GateInstaller.install(gateDirectory: gate.directory).path
            watchGate(gate, bot: bot, thread: thread, run: run.id)
        }
        // Claude takes its approvals from the gate. Without one it would fall back on the
        // person's own Claude Code permissions and run whatever those allow, unasked, so a
        // gate that could not be set up fails the run instead.
        let ungated = bot.engine == .claude && gateSettings == nil

        // Claude Code runs a slash command only from the very start of the prompt, so one goes
        // alone: no job in front of it, and a fresh chat's notes wait for the next message.
        let isCommand = bot.engine == .claude && SlashInput.looksLikeCommand(prompt)
        // The first turn of a fresh chat carries the notes the bot left itself at the end of the
        // last one; not a group's turn, which has its own conversation.
        let carried = groupID == nil && thread.conversationID == nil && !isCommand
            ? takeHandoffNotes(bot.id).map { "\(Self.handoffHeading)\n\n\($0)\n\n---\n\n\(prompt)" } : nil
        let request = RunRequest(
            prompt: isCommand ? prompt : bot.personaPrompt.map { "\($0)\n\n\(carried ?? prompt)" } ?? carried ?? prompt,
            workingDirectory: workingDirectory(for: bot),
            resume: thread.conversationID,
            model: bot.model,
            autonomy: bot.autonomy,
            // In the run's own gate folder, never a shared path: two runs starting together
            // would otherwise read each other's config, and with it the other bot's identity.
            mcpConfigPaths: (try? runGate.map { gate in try MCPConfig.write(
                connectors, to: gate.directory,
                including: Self.bupsyMCPBinary.map {
                    MCPConfig.bupsyServer(
                        binary: $0,
                        outbox: OutboxWatcher.directory.path,
                        botID: bot.id.rawValue,
                        roster: writeRoster())
                }
            ) }).flatMap { $0 }.flatMap { $0 }.map { [$0] } ?? [],
            gateSettingsPath: gateSettings,
            onlyGivenApps: bot.onlyBupsyApps,
            // The browser is the one on this Mac; a cloud machine has none to reach.
            useBrowser: bot.useBrowser && bot.machineID == nil,
            // A conversation copied from Claude Code forks on its first message here.
            forkSession: bot.engine == .claude && thread.conversationID != nil && shouldFork(bot.id)
        )

        // Hold the Mac awake for the duration, if this bot asks for it. An agent run killed at
        // minute three of ten leaves a half-finished task and a truncated transcript, which is
        // worse than one that never started.
        if bot.keepAwake == .whileWorking {
            let assertion = PowerAssertion(reason: "Bupsy: \(bot.name) is working")
            if assertion.acquire() { awake[bot.id] = assertion }
        }

        // Only an engine that reads the MCP config needs connector keys. Codex does not, and its
        // shell would otherwise have them in reach for nothing.
        let connectorEnvNames = bot.engine == .claude
            ? Array(Set(connectors.filter(\.enabled).flatMap(\.requiredEnvNames))) : []
        let token = UUID()
        runTokens[bot.id] = token
        let outboxToken = UUID().uuidString
        outboxTokens[outboxToken] = bot.id
        running[bot.id] = Task { [host, store] in
            var seq = 1
            var failed = false
            var reply = ""
            // What this run itself reported. The thread's `latestUsage` still holds the last
            // run's figures until a new line arrives, so a run stopped or failed before then
            // would otherwise be charged the previous run's tokens and cost.
            var runUsage: Usage?
            defer {
                // This run's own gate always closes. The bot's shared state is only cleared if
                // this run still owns it: after Stop, a new run may already be in the slot.
                Task { await runGate?.stop() }
                // A run that was stopped no longer owns the slot, and is neither done nor failed.
                let ownsSlot = runTokens[bot.id] == token
                if ownsSlot {
                    // Finished, failed or crashed: nothing can answer these any more, so the
                    // cards settle instead of offering an Allow that does nothing.
                    expirePendingApprovals(for: bot.id)
                    // Nor will a result arrive for a step still open, which must not tick on
                    // through the next run.
                    thread.settleOpenTools(stopped: failed)
                    thread.isRunning = false
                    running[bot.id] = nil
                    runTokens[bot.id] = nil
                    activeThread[bot.id] = nil
                    gates[bot.id] = nil
                    gateRuns[bot.id] = nil
                    awake[bot.id]?.release()
                    awake[bot.id] = nil
                }
                var finished = run
                finished.status = failed ? "failed" : "finished"
                finished.endedAt = Date()
                // Carried from the stream's usage line, which arrives before `.done`. Without
                // this the columns exist and are never written, which is how the usage panel came
                // to be permanently absent rather than merely empty.
                finished.inputTokens = runUsage?.inputTokens
                finished.outputTokens = runUsage?.outputTokens
                finished.costUSD = runUsage?.costUSD
                try? store?.save(finished)
                if !failed, groupID == nil, needsFreshChat(bot, thread: thread) { freshChatDue.insert(bot.id) }
                if let id = thread.conversationID {
                    try? store?.save(ConversationRecord(
                        id: conversationID, botID: bot.id.rawValue, engine: bot.engine.rawValue,
                        providerConversationID: id.rawValue, lastEventAt: Date(),
                        groupID: groupID))
                }
                lastRunEnded[bot.id] = Date()
                if groupID == nil {
                    writeChatSnapshot(bot)
                    settleContext(bot, thread: thread)
                }
                writeRoster()
                if ownsSlot { recordRunEnded(bot.id, failed: failed) }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    self?.outboxTokens[outboxToken] = nil
                }
                // Stopped, by you or by Pause: not finished, so its half-written reply is not
                // posted to a group or handed on, read as a goal's answer or announced as done.
                // Decided by what `stop` recorded, not by whether it is still paused, so a quick
                // resume cannot let the reply through.
                if let byPause = stoppedRuns.removeValue(forKey: token) {
                    if let triggerID { checkingObjectives.remove(triggerID) }
                    if let groupID, let group = groupThreads[groupID], group.speaking == bot.id {
                        group.speaking = nil
                        // Stopping a bot mid-turn ends the conversation there, rather than
                        // handing on to whoever was next.
                        groupChains[groupID] = nil
                    }
                    // After Pause, what is queued behind it waits for `resumeAll`.
                    if !byPause { Task { @MainActor [weak self] in self?.botBecameFree(bot) } }
                } else {
                    onFinish?(reply)
                    // Read aloud when asked to, and only the chat on screen: a roster of bots
                    // finishing at once must not all talk over each other.
                    if VoiceOutput.readsReplies, groupID == nil, selectedBotID == bot.id,
                       !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VoiceOutput.shared.speak(reply)
                    }
                    // Next tick, so whatever onFinish started (a group hand-off) claims the bot
                    // first.
                    Task { @MainActor [weak self] in self?.botBecameFree(bot) }
                }
            }
            do {
                // Connector variables set in the person's shell profile, which an app opened from
                // Finder does not inherit. Passed in the engine's environment only, so the
                // `${NAME}` references in the MCP config resolve; never written anywhere.
                if ungated {
                    throw GateUnavailable()
                }
                var invocation = adapter.invocation(for: request)
                invocation.environment["BUPSY_RUN_TOKEN"] = outboxToken
                if !connectorEnvNames.isEmpty {
                    let values = await Task.detached {
                        LoginShellEnvironment.resolved(connectorEnvNames)
                    }.value
                    for (name, value) in values where invocation.environment[name] == nil {
                        invocation.environment[name] = value
                    }
                }
                for try await output in try await host.spawn(invocation) {
                    if Task.isCancelled { return }
                    for event in adapter.normalise(output) {
                        thread.apply(event)
                        if case .failed = event { failed = true }
                        // The copy exists once Claude reports a session of its own: later runs
                        // continue that copy, never fork the original again.
                        if case .started(let id) = event, request.forkSession,
                           id.rawValue != request.resume?.rawValue {
                            forked(bot.id)
                        }
                        if case .text(let chunk) = event { reply += chunk }
                        // Claude sends a usage line; Codex reports it only on `.done`.
                        if case .usage(let usage) = event { runUsage = usage }
                        if case .done(let outcome) = event, let usage = outcome.usage { runUsage = usage }
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
            // Taken before `requests()` starts the poll, so an expiry is never missed.
            let expiries = await gate.expirations()
            Task { [weak self] in
                for await id in expiries {
                    // The hook script waited its full time and denied the call itself.
                    self?.expireApproval(id: id, in: thread, run: run)
                }
            }
            for await request in await gate.requests() {
                guard let self else { return }
                // Read fresh for every call: lowering a bot's trust, or taking a tool off its
                // list, applies to the run already going, not just the next one. A bot deleted
                // mid-run gets nothing more.
                guard let live = self.bots.first(where: { $0.id == bot.id }) else {
                    try? await gate.decide(request.id, .deny(reason: "The bot was deleted."))
                    continue
                }
                let outcome = AutonomyPolicy.decide(
                    tool: request.tool,
                    autonomy: live.autonomy,
                    allowlist: live.toolAllowlist
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
                        bot: bot.name, tool: request.tool, summary: request.summary,
                        approvalID: request.id, botID: bot.id)
                }
            }
        }
    }

    /// The user's answer on an approval card.
    func decide(_ approval: PendingApproval, allow: Bool, for bot: Bot, always: Bool = false) {
        // Decided on the bot's own Mac, by its own gate.
        if bot.remote != nil { linked.decide(approval, allow: allow, for: bot); return }
        // The banner for this request goes either way: it has been answered, or it can't be.
        notifier.clearApproval(approval.id)
        let thread = self.threadHolding(approvalID: approval.id, for: bot.id)
            ?? activeThread[bot.id] ?? self.thread(for: bot.id)
        // Only a request still waiting, on a gate still open, can be answered. Anything else
        // settles as expired: a late Allow must never read as if it took effect.
        // The script may have given up a moment ago, before the poll noticed: its marker is
        // checked directly so an Allow in that gap is not shown as taking effect.
        let scriptGaveUp = gates[bot.id].map {
            FileManager.default.fileExists(
                atPath: $0.directory.appendingPathComponent("expired/\(approval.id)").path)
        } ?? false
        guard Self.isUndecided(approval.id, in: thread), !scriptGaveUp, let gate = gates[bot.id] else {
            if Self.isUndecided(approval.id, in: thread) {
                thread.resolveApproval(id: approval.id, as: .expired)
            }
            return
        }
        // "Always" is recorded before the answer goes back, so a second call already queued for
        // the same tool in this run is allowed rather than asked again.
        if allow, always, ToolNames.canAlwaysAllow(approval.tool),
           let index = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[index].toolAllowlist.insert(approval.tool)
            try? store?.save(bots[index].record(sortIndex: index))
        }
        thread.resolveApproval(id: approval.id,
                               as: allow ? (always && ToolNames.canAlwaysAllow(approval.tool) ? .alwaysAllowed : .allowed) : .denied)
        Task {
            try? await gate.decide(
                approval.id,
                allow ? .allow(reason: "you approved it") : .deny(reason: "you declined it"))
        }
        recordDecision(run: gateRuns[bot.id], requestID: approval.id, tool: approval.tool,
                       inputJSON: approval.inputJSON,
                       decision: allow ? "allowed" : "denied",
                       rule: always && allow ? "you said always allow" : "decided by you")
    }

    // MARK: - Permissions

    /// Stops a bot using a tool without asking.
    func disallow(_ tool: String, for bot: Bot) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].toolAllowlist.remove(tool)
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Every remembered decision about one bot messaging another.
    var linkDecisions: [BotLinkRecord] { links.decisions }

    /// Forgets a decision, so the next message between the two asks again.
    func forgetLink(from sender: String, to recipient: String) {
        links.forget(from: sender, to: recipient)
        try? store?.deleteLink(from: sender, to: recipient)
    }

    /// Each run's secret for the outbox, and the bot it belongs to. Kept a little after the run
    /// ends, since a request written just before exit is picked up on the next poll.
    private var outboxTokens: [String: BotID] = [:]

    /// The run each open gate belongs to, so a decision you make lands in that run's audit log.
    private var gateRuns: [BotID: String] = [:]

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
        if linked.isRemote(botID) { linked.stop(botID); return }
        // Before the slot is cleared, while the thread the run was in is still known.
        expirePendingApprovals(for: botID)
        let current = activeThread[botID] ?? thread(for: botID)
        // Marked before ownership goes, so the run's cleanup knows it was stopped, not finished.
        if let token = runTokens[botID] { stoppedRuns[token] = stoppedRuns[token] ?? false }
        current.settleOpenTools(stopped: true)
        running[botID]?.cancel()
        running[botID] = nil
        // Releases ownership, so the cancelled run's cleanup leaves a newer run alone.
        runTokens[botID] = nil
        activeThread[botID] = nil
        Task { [gate = gates[botID]] in await gate?.stop() }
        gates[botID] = nil
        gateRuns[botID] = nil
        awake[botID]?.release()
        awake[botID] = nil
        current.isRunning = false
        thread(for: botID).isRunning = false
    }

    // MARK: - Approvals that can no longer be answered

    /// Every thread a bot's approvals can be in: its own, the one it is running in, and its side
    /// threads inside groups.
    func approvalThreads(for botID: BotID) -> [Thread] {
        var found: [Thread] = []
        func add(_ thread: Thread?) {
            guard let thread, !found.contains(where: { $0 === thread }) else { return }
            found.append(thread)
        }
        add(threads[botID])
        add(activeThread[botID])
        let prefix = "\(botID.rawValue)|"
        for (key, side) in groupSideThreads where key.hasPrefix(prefix) { add(side) }
        return found
    }

    private func threadHolding(approvalID: String, for botID: BotID) -> Thread? {
        approvalThreads(for: botID).first { thread in
            thread.entries.contains {
                if case .approval(let approval) = $0.kind { return approval.id == approvalID }
                return false
            }
        }
    }

    private static func isUndecided(_ approvalID: String, in thread: Thread) -> Bool {
        thread.entries.contains {
            if case .approval(let approval) = $0.kind {
                return approval.id == approvalID && approval.decided == nil
            }
            return false
        }
    }

    /// Settles every approval the bot is still waiting on as expired. Called when its run ends
    /// in any way, because the gate that would have carried the answer is gone with it.
    private func expirePendingApprovals(for botID: BotID) {
        for thread in approvalThreads(for: botID) {
            let waiting: [String] = thread.entries.compactMap {
                if case .approval(let approval) = $0.kind, approval.decided == nil { return approval.id }
                return nil
            }
            for id in waiting {
                thread.resolveApproval(id: id, as: .expired)
                notifier.clearApproval(id)
            }
        }
    }

    /// One request the gate's script gave up on, after waiting its full time.
    private func expireApproval(id: String, in thread: Thread, run: String) {
        notifier.clearApproval(id)
        guard Self.isUndecided(id, in: thread) else { return }
        thread.resolveApproval(id: id, as: .expired)
        for entry in thread.entries {
            if case .approval(let approval) = entry.kind, approval.id == id {
                recordDecision(run: run, requestID: id, tool: approval.tool,
                               inputJSON: approval.inputJSON, decision: "denied",
                               rule: "nobody answered in time")
                break
            }
        }
    }

    /// Stops every run and closes every gate. The thing you reach for when a bot is doing
    /// something you did not expect.
    func stopEverything() {
        for id in running.keys { stop(id) }
    }

    // MARK: - Pause

    private static let pausedKey = "si.bupsy.paused"

    /// Paused: what was running stops, and nothing starts on its own until resume. Routines,
    /// goal checks, folder watches and bots handing work to each other are held; a message you
    /// send, or "Run now", still goes, so a paused app is never a dead one. Saved per home, so it
    /// survives a relaunch.
    private(set) var isPaused = AppHome.defaults.bool(forKey: "si.bupsy.paused") {
        didSet { AppHome.defaults.set(isPaused, forKey: Self.pausedKey) }
    }

    /// Stops every run and holds everything automatic until `resumeAll()`.
    func pauseAll() {
        guard !isPaused else { return }
        isPaused = true
        // Changes kept for a busy bot are let go, like any other automatic work while paused.
        heldWatchChanges.removeAll()
        // A check dropped while it waited for its bot never reports back, so none stays "Checking…".
        checkingObjectives.removeAll()
        for token in runTokens.values { stoppedRuns[token] = true }
        stopEverything()
        // A stopped turn never reports back, so no group is left showing a bot mid-reply.
        for thread in groupThreads.values { thread.speaking = nil }
        groupChains.removeAll()
        syncLaunchAgent()
    }

    /// Lets automatic work start again. Whatever fell due while paused is marked as filled
    /// first, so resuming starts from the next slot instead of firing a run of late routines.
    func resumeAll() {
        guard isPaused else { return }
        skipDueWork(now: Date())
        isPaused = false
        syncLaunchAgent()
        // Messages typed to a bot that Pause stopped mid-run were kept for now.
        for bot in bots where running[bot.id] == nil { botBecameFree(bot) }
    }

    /// Runs that were stopped, by token, until each one's cleanup has seen it. True when Pause
    /// stopped it.
    private var stoppedRuns: [UUID: Bool] = [:]

    func togglePause() {
        if isPaused { resumeAll() } else { pauseAll() }
    }

    /// Records every due routine slot and goal check as handled without running it. Nothing is
    /// sent and nothing is notified: a skipped run is not a run.
    private func skipDueWork(now: Date) {
        for objective in dueObjectives(now: now) {
            guard let index = objectives.firstIndex(where: { $0.id == objective.id }) else { continue }
            objectives[index].lastCheckedAt = now
            try? store?.save(objectives[index])
        }
        for due in RoutineScheduler().due(routines: routines, now: now) {
            guard let index = routines.firstIndex(where: { $0.id == due.routine.id }) else { continue }
            routines[index].lastFiredAt = due.scheduledFor
            try? store?.save(routines[index])
        }
    }

    func addBot(name: String, engine: EngineID, job: String = "", folder: String? = nil,
                shape: BotShape? = nil, colour: Int? = nil) {
        guard !isNameTaken(name) else { return }
        var bot = Bot(
            name: name, engine: engine,
            personaPrompt: job.isEmpty ? nil : job)
        bot.folder = folder
        if let folder { noteSection(folder) }
        bot.avatarHue = distinctHue(near: bot.avatarHue)
        bot.avatarShape = shape
        bot.avatarColour = colour
        bots.append(bot)
        try? store?.save(bot.record(sortIndex: bots.count - 1))
        // Opened, not just selected: selecting no longer moves the window off a page that is
        // not a chat (see RootView.followSelection), and a bot you just made is one you want.
        open(bot.id)
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
        // The face and role someone picked are part of the setup, not the history.
        copy.avatarShape = bot.avatarShape
        copy.avatarColour = bot.avatarColour
        copy.role = bot.role
        copy.onlyBupsyApps = bot.onlyBupsyApps
        copy.useBrowser = bot.useBrowser
        copy.sharedWithDevices = bot.sharedWithDevices

        bots.append(copy)
        try? store?.save(copy.record(sortIndex: bots.count - 1))
        open(copy.id)
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
    func createGroup(name: String, members: [Bot], lead: Bot?,
                     turnLimit: Int = GroupRouting.defaultTurnLimit) -> ChatGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, members.count >= 2 else { return nil }
        let record = GroupRecord(name: trimmed, leadBotID: (lead ?? members.first)?.id.rawValue,
                                 sortIndex: groups.count,
                                 turnLimit: GroupRouting.effectiveTurnLimit(turnLimit))
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

    /// How many bot turns the group takes, with nobody speaking, before it checks with you.
    /// Applies from the next turn, including to a chain already running.
    func setTurnLimit(_ limit: Int, for group: ChatGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].turnLimit = GroupRouting.effectiveTurnLimit(limit)
        try? store?.save(groups[index].record(sortIndex: index))
    }

    /// Deletes the conversation, never the bots in it.
    func deleteGroup(_ group: ChatGroup) {
        // A member answering in it stops: its reply has nowhere to go.
        for (botID, thread) in activeThread
        where groupSideThreads["\(botID.rawValue)|\(group.id)"] === thread {
            stop(botID)
        }
        groupChains[group.id] = nil
        try? store?.deleteGroup(id: group.id)
        groups.removeAll { $0.id == group.id }
        groupThreads[group.id] = nil
        // Its side threads go too, so an approval nobody can reach no longer makes a bot wave.
        for key in Array(groupSideThreads.keys) where key.hasSuffix("|\(group.id)") {
            groupSideThreads[key] = nil
        }
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
        // Joins the conversation already going, if there is one. You spoke, so the bots get
        // their full allowance of turns again.
        var chain = groupChains[group.id] ?? GroupChain(queue: [], taken: 0)
        for member in first where !chain.queue.contains(member) { chain.queue.append(member) }
        chain.taken = 0
        groupChains[group.id] = chain
        runTurns(in: group)
    }

    /// A group's conversation in progress: who is still to answer, and how many turns the bots
    /// have taken since you last spoke.
    ///
    /// One per group. A second message while bots are still answering joins this chain rather
    /// than starting another beside it, and a bot that was busy elsewhere rejoins it when free.
    /// Separate chains talked over each other and each got the full turn limit, so the limit,
    /// which is there to protect your quota, could be passed.
    private struct GroupChain {
        var queue: [GroupRouting.Member]
        var taken: Int
    }
    private var groupChains: [String: GroupChain] = [:]

    /// Answers one bot at a time, following hand-offs, until the queue is empty or the ceiling
    /// is reached.
    ///
    /// One at a time on purpose. Bots answering in parallel would each reply without seeing the
    /// others, and the thread would read as several people talking over one another — the thing
    /// a group conversation is supposed to fix, not reproduce.
    private func runTurns(in group: ChatGroup) {
        let thread = groupThread(for: group)
        // Deleted while a turn was out: nothing more is said in it.
        guard let group = groups.first(where: { $0.id == group.id }) else {
            groupChains[group.id] = nil
            groupThreads[group.id] = nil
            return
        }
        // A turn is under way. It carries the chain on when it finishes.
        guard thread.speaking == nil else { return }
        // Paused: bots do not hand work on to each other. The first turn is your own message,
        // which still goes; the ones after it wait for you.
        guard var chain = groupChains[group.id], let next = chain.queue.first,
              !(isPaused && chain.taken > 0) else {
            groupChains[group.id] = nil
            return
        }

        // The group's own limit, read fresh so a change made mid-chain applies to the next turn.
        guard !GroupRouting.shouldPause(afterTaking: chain.taken, limit: group.turnLimit) else {
            // Pause rather than run on: the bots don't keep each other going on your quota. The
            // note makes the group read as waiting on you until you say something.
            groupChains[group.id] = nil
            // Once is enough: a late turn from a bot that was busy elsewhere can arrive here too.
            if thread.messages.last?.isPauseNote != true {
                appendGroupMessage(GroupMessageRecord(
                    groupID: group.id, author: GroupMessageRecord.systemAuthor, authorName: "Bupsy",
                    text: GroupMessageRecord.pauseNote(after: GroupRouting.effectiveTurnLimit(group.turnLimit))),
                    to: group)
            }
            return
        }
        chain.queue.removeFirst()
        groupChains[group.id] = chain
        guard let bot = bots.first(where: { $0.id.rawValue == next.id }) else {
            runTurns(in: group)
            return
        }

        let routing = members(of: group).map { GroupRouting.Member(id: $0.id.rawValue, name: $0.name) }
        let prompt = GroupRouting.prompt(group: group.name, members: routing, me: next,
                                         recent: missedMessages(by: bot, in: thread))
        thread.speaking = bot.id

        let started = startRun(prompt, bot: bot, thread: groupSideThread(bot, in: group),
                               groupID: group.id) { [weak self] reply in
            guard let self, self.groups.contains(where: { $0.id == group.id }) else { return }
            let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty {
                self.appendGroupMessage(GroupMessageRecord(
                    groupID: group.id, author: bot.id.rawValue, authorName: bot.name, text: said),
                    to: group)
            }
            // Joining a group is the permission for its members to hand work to each other:
            // the person chose them, and every hand-off appears in the thread they are reading.
            // Each bot's *actions* still pass through its own approval gate.
            var chain = self.groupChains[group.id] ?? GroupChain(queue: [], taken: 0)
            for handOff in GroupRouting.handOffs(from: next, reply: said, members: routing)
            where !chain.queue.contains(handOff) {
                chain.queue.append(handOff)
            }
            chain.taken += 1
            self.groupChains[group.id] = chain
            thread.speaking = nil
            self.runTurns(in: group)
        }

        if !started {
            // A bot runs one thing at a time. Busy elsewhere, it waits and answers here as soon as
            // it is free — said in the thread, so silence never reads as being ignored. It rejoins
            // this group's chain, so its late turn counts against the same limit.
            thread.speaking = nil
            appendGroupMessage(GroupMessageRecord(
                groupID: group.id, author: GroupMessageRecord.systemAuthor, authorName: "Bupsy",
                text: "\(bot.name) is finishing something in another chat. It'll reply here next."),
                to: group)
            let takenThen = chain.taken
            waitingForBot[bot.id, default: []].append { [weak self] in
                guard let self else { return }
                var chain = self.groupChains[group.id] ?? GroupChain(queue: [], taken: takenThen)
                if !chain.queue.contains(next) { chain.queue.insert(next, at: 0) }
                self.groupChains[group.id] = chain
                self.runTurns(in: group)
                // Nothing started (paused, the limit reached, the group deleted, another turn
                // under way): whatever else waits for this bot goes now.
                if self.running[bot.id] == nil { self.botBecameFree(bot) }
            }
            runTurns(in: group)
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

    /// Using Bupsy from the person's other devices, over Tailscale. See `RemoteAccess`.
    @ObservationIgnored lazy var remote = RemoteAccess(model: self)
    /// The person's other Macs, whose shared bots show here. See `LinkedMacs`.
    @ObservationIgnored lazy var linked = LinkedMacs(model: self)

    /// Starts listening for messages bots want to send each other.
    func startOutbox() {
        guard outbox == nil else { return }
        let watcher = OutboxWatcher(sender: { [weak self] token in
            self?.outboxTokens[token]?.rawValue
        }) { [weak self] request in
            switch request {
            case .message(let from, let toName, let text):
                self?.receive(from: from, toName: toName, text: text)
            case .createBot(let from, let name, let job, let role):
                self?.receiveCreation(from: from, name: name, job: job, role: role)
            case .question(let from, let question, let options):
                self?.receiveQuestion(from: from, question: question, options: options)
            case .updateMe(let from, let name, let role, let job):
                self?.receiveUpdate(from: from, name: name, role: role, job: job)
            case .moveBots(let from, let names, let section):
                self?.receiveMove(from: from, names: names, section: section)
            case .manageBot(let from, let change):
                self?.receiveManage(from: from, change: change)
            case .addRoutine(let from, let bot, let name, let message, let cron, let whenClosed):
                self?.receiveRoutine(from: from, botName: bot, name: name, message: message,
                                     cron: cron, whenClosed: whenClosed)
            case .removeRoutine(let from, let bot, let name):
                self?.receiveRoutineRemoval(from: from, botName: bot, name: name)
            case .stopBot(let from, let bot):
                self?.receiveStop(from: from, botName: bot)
            case .notify(let from, let title, let text):
                self?.receiveNotify(from: from, title: title, text: text)
            }
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

    // MARK: - One-click bots, and bots setting themselves up

    /// Makes a bot at once and lets it ask what it is for, instead of a form.
    ///
    /// The bot starts as "New bot", greets the person knowing who else is on the roster, and once
    /// told its job sets its own name and role with update_me — the job itself still waits for
    /// the person's yes. Returns the new bot's id so the caller can open it.
    @discardableResult
    func quickCreateBot(engine: EngineID? = nil) -> BotID? {
        var name = "New bot"
        var counter = 2
        while isNameTaken(name) { name = "New bot \(counter)"; counter += 1 }
        addBot(name: name, engine: engine ?? defaultNewBotEngine)
        guard let bot = bots.first(where: { $0.name == name }) else { return nil }
        greet(bot)
        return bot.id
    }

    /// The engine a new bot starts on, wherever it is made: the first engine that is signed in
    /// and able to run, or Claude Code when both are (or neither is). A bot made before any
    /// sign-in still exists; it asks for one when it first runs.
    var defaultNewBotEngine: EngineID {
        let ready = EngineID.supported.filter { engineStatus[$0]?.isUsable == true }
        if ready.isEmpty || ready.contains(.claude) { return .claude }
        return ready[0]
    }

    /// A new bot's first words, run in its own chat with the prompt hidden.
    ///
    /// With no job it says hi and asks what it is for, then sets its own job with update_me
    /// (which still waits for the person's yes). With a job, one the person just picked, the job
    /// is saved and the bot says hi and confirms it in its own words. A bot still called
    /// "New bot" also names itself; one the person named keeps its name.
    func greet(_ bot: Bot, job: String? = nil) {
        let trimmedJob = job?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedJob.isEmpty, bot.personaPrompt != trimmedJob { setJob(bot, trimmedJob) }
        guard let current = bots.first(where: { $0.id == bot.id }) else { return }

        let others = bots.filter { $0.id != current.id && !$0.hidden }.map { other -> String in
            other.personaPrompt.map { "\(other.name) (\($0))" } ?? other.name
        }
        let roster = others.isEmpty ? "You are the first bot." : "The other bots are: \(others.joined(separator: "; "))."
        let unnamed = current.name.hasPrefix("New bot")
        let intro = "You have just been created in Bupsy, the person's roster of AI bots. \(roster) "
            + "Greet the person, not the other bots (they cannot see this), in two short sentences. "
        let prompt: String
        if trimmedJob.isEmpty {
            prompt = intro
                + "Ask what job they want you for. If the roster already covers something, say so. "
                + (unnamed
                    ? "Once they tell you, use the update_me tool to set a short name, a one- or two-word role tag, and your job."
                    : "Your name is \(current.name); keep it. Once they tell you, use the update_me tool to set a one- or two-word role tag and your job.")
        } else {
            prompt = intro
                + "The person made you for this job: \(trimmedJob). Say hi and confirm the job in "
                + "your own words. If the roster already covers part of it, say so. "
                + (unnamed
                    ? "Use the update_me tool to set a short name and a one- or two-word role tag that fit the job. "
                    : "Your name is \(current.name); keep it. Use the update_me tool to set a one- or two-word role tag that fits the job. ")
                + "Your job is already saved, so don't change it."
        }
        _ = startRun(prompt, bot: current, thread: thread(for: current.id), groupID: nil,
                     onFinish: nil, hidesPrompt: true)
    }

    /// A job a bot proposed for itself, waiting on the person.
    struct PendingJobChange: Identifiable, Equatable {
        let id = UUID()
        let bot: Bot
        let job: String
    }

    var pendingJobChanges: [PendingJobChange] = []

    private func receiveUpdate(from senderID: String, name: String?, role: String?, job: String?) {
        guard let bot = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        let thread = thread(for: bot.id)
        if let name {
            if isNameTaken(name, except: bot.id) {
                thread.entries.append(TranscriptEntry(kind: .note("Couldn't rename to “\(name)”. Another bot has that name.")))
            } else if name != bot.name {
                let old = bot.name
                rename(bot, to: name)
                thread.entries.append(TranscriptEntry(kind: .note("\(old) named itself \(name)")))
            }
        }
        if let role, let current = bots.first(where: { $0.id == bot.id }), role != current.role {
            setRole(current, role)
            thread.entries.append(TranscriptEntry(kind: .note("Role set to \(role)")))
        }
        if let job, let current = bots.first(where: { $0.id == bot.id }), job != current.personaPrompt {
            pendingJobChanges.removeAll { $0.bot.id == bot.id }
            pendingJobChanges.append(PendingJobChange(bot: current, job: job))
        }
    }

    /// Files bots into a section a bot named, making it if it is new.
    ///
    /// Applied at once, like a bot's own name: a section is a sidebar label, and moving a bot
    /// changes nothing about what it can do. What moved, and any name that matched no bot, is
    /// noted in the asking bot's chat so the person sees who reorganised their sidebar.
    func receiveMove(from senderID: String, names: [String], section: String?) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        let trimmed = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "Unassigned" is what the sidebar calls no section, so a bot that reads it back and
        // asks for it means no section rather than a new one by that name.
        let wantsNone = trimmed.isEmpty || trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame
        // An existing section by any capitalisation, so "frontier & co" joins "Frontier & Co"
        // rather than starting a second one beside it.
        let target: String? = wantsNone ? nil
            : allSections.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
                ?? String(trimmed.prefix(40))

        var moved: [String] = []
        var missing: [String] = []
        for name in names {
            // Exact names only, as for messages: a near miss must not move the wrong bot.
            guard let bot = bots.first(where: {
                $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
            }) else {
                missing.append(name)
                continue
            }
            if bot.folder != target { setFolder(bot, target) }
            if !moved.contains(bot.name) { moved.append(bot.name) }
        }
        if let target { addSection(target) }

        let thread = thread(for: sender.id)
        if !moved.isEmpty {
            let list = ListFormatter.localizedString(byJoining: moved)
            thread.entries.append(TranscriptEntry(kind: .note(target.map { "Moved \(list) to \($0)" }
                ?? "Took \(list) out of their sections")))
        }
        if !missing.isEmpty {
            let list = missing.map { "“\($0)”" }.joined(separator: ", ")
            thread.entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                kind: .unknown, message: "No bot named \(list) to move."))))
        }
    }

    // MARK: - Bots managing bots

    /// Applies what one bot asked to change about another: job, role, model, a fresh chat, and a
    /// message to start it off.
    ///
    /// The approval gate has already decided by the asking bot's trust (manage_bot is not one of
    /// the tools bupsy waves through), so what arrives here is applied. Each change is noted in
    /// the changed bot's chat, naming who made it, and summed up in the asker's; anything that
    /// could not be done (no such bot, a model its engine does not offer) is said in the asker's.
    func receiveManage(from senderID: String, change: BotChange) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        let senderThread = thread(for: sender.id)
        func refuse(_ message: String) {
            senderThread.entries.append(TranscriptEntry(kind: .failure(EngineFailure(kind: .unknown, message: message))))
        }
        // Exact names only, as for messages: a near miss must not rewrite the wrong bot.
        guard let target = bots.first(where: {
            $0.name.caseInsensitiveCompare(change.bot.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }) else {
            refuse("No bot named “\(change.bot)” to change.")
            return
        }
        let isSelf = target.id == sender.id
        let by = isSelf ? "" : " by \(sender.name)"
        var done: [String] = []

        // A model belongs to an engine: with an engine switch, it is set after the switch.
        if change.engine == nil, let model = change.model {
            if let option = Self.modelOption(named: model, in: models(for: target)) {
                if option.id != target.model {
                    setModel(target, option.id)
                    done.append("model \(option.label)")
                }
            } else {
                let offered = models(for: target).map { $0.id ?? "default" }.joined(separator: ", ")
                refuse("\(target.engine.displayName) has no model “\(model)” for \(target.name). It offers: \(offered).")
            }
        }
        if let role = change.role, let current = bots.first(where: { $0.id == target.id }), role != current.role {
            setRole(current, role)
            done.append("role \(role)")
        }
        if let job = change.job, let current = bots.first(where: { $0.id == target.id }), job != current.personaPrompt {
            setJob(current, job)
            done.append("job")
        }
        if !done.isEmpty {
            let list = ListFormatter.localizedString(byJoining: done)
            thread(for: target.id).entries.append(TranscriptEntry(kind: .note("New \(list)\(by)")))
            if !isSelf {
                senderThread.entries.append(TranscriptEntry(kind: .note("Gave \(target.name) a new \(list)")))
            }
        }

        var engine: EngineID?
        if let name = change.engine {
            if let wanted = EngineID(rawValue: name), EngineID.supported.contains(wanted) {
                if wanted != target.engine { engine = wanted }
            } else {
                refuse("There's no engine “\(name)”. Use claude or codex.")
            }
        }
        // The model of a new engine is set with it below.
        let modelAfterSwitch = engine != nil ? change.model : nil
        if engine == nil, change.engine != nil, let model = change.model,
           let option = Self.modelOption(named: model, in: models(for: target)), option.id != target.model {
            setModel(target, option.id)
            thread(for: target.id).entries.append(TranscriptEntry(kind: .note("New model \(option.label)\(by)")))
        }

        guard engine != nil || change.freshChat || change.message != nil else {
            writeRoster()
            return
        }
        // A fresh chat must not land in the middle of a turn, and a message meant for the fresh
        // chat must not arrive in the old one: both wait for the bot to finish.
        let rest: @MainActor () -> Void = { [weak self] in
            guard let self, var current = self.bots.first(where: { $0.id == target.id }) else { return }
            if let engine {
                // Switching engines notes itself in the bot's chat.
                self.setEngine(current, engine)
                if let model = modelAfterSwitch, let updated = self.bots.first(where: { $0.id == target.id }) {
                    if let option = Self.modelOption(named: model, in: self.models(for: updated)) {
                        self.setModel(updated, option.id)
                    } else {
                        refuse("\(engine.displayName) has no model “\(model)” for \(updated.name), so it uses the default.")
                    }
                }
                current = self.bots.first(where: { $0.id == target.id }) ?? current
                if !isSelf { senderThread.entries.append(TranscriptEntry(kind: .note("Switched \(current.name) to \(engine.displayName)"))) }
            }
            if change.freshChat {
                self.startFreshChat(current, note: "Fresh chat\(by). Earlier messages stay here, but \(current.name) no longer has them in mind.")
                if !isSelf { senderThread.entries.append(TranscriptEntry(kind: .note("Started a fresh chat for \(current.name)"))) }
            }
            if let message = change.message {
                if isSelf {
                    self.continueOwnFreshChat(current, notes: message)
                } else if let from = self.bots.first(where: { $0.id == sender.id }) {
                    self.deliver(from: from, to: current, text: message)
                }
            }
            self.writeRoster()
            // Whatever else was waiting on this bot gets its turn.
            if self.running[current.id] == nil { self.botBecameFree(current) }
        }
        if running[target.id] == nil {
            rest()
        } else {
            waitingForBot[target.id, default: []].append(rest)
            if !isSelf {
                senderThread.entries.append(TranscriptEntry(kind: .note(
                    "\(target.name) is working. The rest waits until it finishes.")))
            }
        }
    }

    /// The model a bot named, by id or by label, any capitalisation; "default" is the CLI's own.
    nonisolated static func modelOption(named name: String, in options: [ModelOption]) -> ModelOption? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if wanted.caseInsensitiveCompare("default") == .orderedSame { return options.first { $0.id == nil } }
        return options.first { $0.id?.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? options.first { $0.label.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Starts the bot on a new conversation with its engine.
    ///
    /// Its history stays in the chat and in the store; only the engine session is left behind, so
    /// the next run starts with no earlier turns to send. That is what makes it cheaper: a long
    /// chat resends its whole context every turn. The new conversation record is the newest, so
    /// it is the one the next run (and a relaunch) picks up.
    func startFreshChat(_ bot: Bot, note: String) {
        let fresh = ConversationRecord(botID: bot.id.rawValue, engine: bot.engine.rawValue)
        try? store?.save(fresh)
        let thread = thread(for: bot.id)
        thread.conversationID = nil
        thread.latestUsage = nil
        // A copied Claude Code chat waiting to fork has nothing left to fork.
        forked(bot.id)
        thread.entries.append(TranscriptEntry(kind: .note(note)))
    }

    /// A bot that started its own fresh chat picks up from the notes it left itself.
    ///
    /// Counted with bot-to-bot hand-offs, so a bot that keeps restarting itself stops after a few
    /// and waits for the person rather than looping on their subscription.
    private func continueOwnFreshChat(_ bot: Bot, notes: String) {
        let key = "\(bot.id.rawValue)>\(bot.id.rawValue)"
        let recent = (autoRuns[key] ?? []).filter { $0 > Date().addingTimeInterval(-600) }
        guard !isPaused, running[bot.id] == nil, recent.count < Self.autoRunsPerPair else {
            thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
                "\(bot.name) left itself notes for the fresh chat but restarted a lot, so it's waiting for you:\n\n\(notes)")))
            return
        }
        autoRuns[key] = recent + [Date()]
        let prompt = "You started this fresh chat yourself to save context. Your notes from the "
            + "previous chat:\n\n\(notes)\n\nCarry on from there."
        // Shown as the bot's own message, never as something the person said.
        _ = startRun(prompt, bot: bot, thread: thread(for: bot.id), groupID: nil, onFinish: nil,
                     from: bot, shown: "Notes from the previous chat:\n\n\(notes)")
    }

    func decideJobChange(_ change: PendingJobChange, allow: Bool) {
        pendingJobChanges.removeAll { $0.id == change.id }
        guard let current = bots.first(where: { $0.id == change.bot.id }) else { return }
        if allow { setJob(current, change.job) }
        thread(for: current.id).entries.append(TranscriptEntry(kind: .note(
            allow ? "Job saved" : "You kept its previous job")))
    }

    // MARK: - Questions with set answers

    private func receiveQuestion(from senderID: String, question: String, options: [String]) {
        guard let bot = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        // A question with no words cannot be shown as a card, but the bot is still waiting. Say
        // so where the person will look, so a reply is what unblocks it.
        guard !question.isEmpty else {
            thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
                "\(bot.name) asked you something but the question was empty. Reply to tell it what to do.")))
            notifier.needsApproval(bot: bot.name, tool: "a question",
                                   summary: "Asked you something. Reply to tell it what to do.",
                                   botID: bot.id)
            return
        }
        thread(for: bot.id).entries.append(TranscriptEntry(kind: .question(BotQuestion(
            id: UUID().uuidString, question: question, options: options))))
        notifier.needsApproval(bot: bot.name, tool: "a question", summary: question, botID: bot.id)
    }

    /// Sends the person's answer as their next message — what the bot stopped to wait for.
    /// An empty answer dismisses the question without sending anything.
    func answer(_ question: BotQuestion, with answer: String, for bot: Bot) {
        if bot.remote != nil { linked.answer(question, with: answer, for: bot); return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        thread(for: bot.id).answerQuestion(id: question.id, with: text)
        guard !text.isEmpty else { return }
        send(text, to: bot)
    }

    // MARK: - Bots creating bots

    /// A bot asking for a new bot, waiting on a person.
    struct PendingCreation: Identifiable, Equatable {
        let id = UUID()
        let from: Bot
        let name: String
        let job: String
        var role: String?
    }

    /// Held in memory for the same reason introductions are: an unanswered request is a live
    /// question, and one that outlived a restart would be asked with nobody around who asked it.
    var pendingCreations: [PendingCreation] = []

    private func receiveCreation(from senderID: String, name: String, job: String, role: String?) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Said in the asking bot's thread rather than asked of the person: there is nothing to
        // decide when the name is taken, and the bot should message the existing one instead.
        guard !isNameTaken(name) else {
            thread(for: sender.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                kind: .unknown,
                message: "\(sender.name) asked for a bot called “\(name)”, but there already is one."))))
            return
        }
        guard !pendingCreations.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        pendingCreations.append(PendingCreation(from: sender, name: name, job: job, role: role))
    }

    /// Creates the bot if the person said yes.
    ///
    /// Every creation asks — unlike messaging, nothing is remembered — because each new bot is a
    /// standing thing on the person's subscription, and they should see every one arrive. Once
    /// made, the creator and the new bot may message each other without a second question: the
    /// person just approved the two of them working together.
    func decideCreation(_ creation: PendingCreation, allow: Bool) {
        pendingCreations.removeAll { $0.id == creation.id }
        guard allow else {
            thread(for: creation.from.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                kind: .unknown, message: "You said no to creating “\(creation.name)”."))))
            return
        }
        let selected = selectedBotID
        let request = navigationRequest
        addBot(name: creation.name, engine: creation.from.engine, job: creation.job,
               folder: creation.from.folder)
        // addBot opens the new bot; a request from the background should not pull you away.
        // Both put back in the same turn, so the root view never sees the open request.
        selectedBotID = selected
        navigationRequest = request
        guard var created = bots.first(where: { $0.name == creation.name }) else { return }
        if let role = creation.role {
            setRole(created, role)
            created = bots.first(where: { $0.id == created.id }) ?? created
        }

        for (from, to) in [(creation.from, created), (created, creation.from)] {
            links.decide(from: from.id.rawValue, to: to.id.rawValue, allowed: true)
            if let link = links.decisions.last { try? store?.save(link) }
        }
        // Its first run is the creator's brief, and it genuinely introduces itself — no hello
        // written by bupsy and attributed to a bot that never said it.
        _ = startRun(
            creation.job + "\n\n(You were just created by \(creation.from.name) for the job above. "
                + "Introduce yourself to the person in one or two sentences, then say hello to "
                + "\(creation.from.name) with the message_bot tool. Don't start the work until asked.)",
            bot: created, thread: thread(for: created.id), groupID: nil, onFinish: nil,
            from: creation.from, shown: creation.job)
    }

    /// Writes the roster `list_bots` reads, every bot included; bupsy-mcp leaves out the asker.
    ///
    /// What the sidebar already shows (names, sections, jobs, models), whether each is working,
    /// and its routines. Nothing from any conversation: `read_chat` has its own files. Rewritten
    /// whenever a run starts or ends and when a bot changes another, so a bot checking on the
    /// others mid-turn sees who is working now.
    @discardableResult
    func writeRoster() -> String? {
        let ago = RelativeDateTimeFormatter()
        let entries = bots.filter { !$0.hidden && $0.remote == nil }.map { bot -> [String: Any] in
            var entry: [String: Any] = [
                "id": bot.id.rawValue, "name": bot.name, "job": bot.personaPrompt ?? "",
                "section": bot.folder ?? "", "engine": bot.engine.rawValue,
                // What manage_bot can set: the model now and the ones its engine offers.
                "model": bot.model ?? "default",
                "models": models(for: bot).map { $0.id ?? "default" }.joined(separator: ", "),
                "working": running[bot.id] != nil,
                "queued": queued[bot.id]?.count ?? 0,
                "routines": routines.filter { $0.botID == bot.id.rawValue }.map {
                    ["name": $0.name, "schedule": "\(Schedule.describe($0.cron)) (\($0.cron))",
                     "message": $0.prompt, "enabled": $0.enabled] as [String: Any]
                },
            ]
            if let ended = lastRunEnded[bot.id] { entry["lastActive"] = ago.localizedString(for: ended, relativeTo: Date()) }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return nil }
        let url = OutboxWatcher.rosterFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil ? url.path : nil
    }

    /// Where `read_chat` finds each bot's latest messages, beside the roster.
    static var chatsDirectory: URL {
        OutboxWatcher.rosterFile.deletingLastPathComponent().appendingPathComponent("chats", isDirectory: true)
    }

    /// Saves a bot's latest messages for `read_chat`: what was said, by whom, and when. Tool calls
    /// and bupsy's own notes are left out, and long messages are cut, so another bot reads the
    /// conversation rather than the work.
    func writeChatSnapshot(_ bot: Bot) {
        guard let thread = threads[bot.id] else { return }
        let time = Date.FormatStyle(date: .abbreviated, time: .shortened)
        var messages: [[String: String]] = []
        for entry in thread.entries.suffix(400) {
            let who: String, text: String
            switch entry.kind {
            case .userMessage(let said): who = "Person"; text = said
            case .assistantText(let said): who = bot.name; text = said
            case .messageFrom(_, let name, let said): who = "\(name) (bot)"; text = said
            default: continue
            }
            let cut = text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
            messages.append(["who": who, "text": cut, "at": entry.at.formatted(time)])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: Array(messages.suffix(40))) else { return }
        let dir = Self.chatsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(bot.id.rawValue).json"), options: .atomic)
    }

    // MARK: - Bots scheduling, stopping and notifying

    /// A bot named by another, exactly (any capitalisation); otherwise the asker is told.
    private func namedBot(_ name: String, for sender: Bot, doing action: String) -> Bot? {
        if let bot = bots.first(where: {
            $0.remote == nil && $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }) { return bot }
        thread(for: sender.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
            kind: .unknown, message: "No bot named “\(name)” to \(action)."))))
        return nil
    }

    /// Schedules a message to a bot, as its Routines section does. A routine of the same name on
    /// that bot is replaced, so a bot fixing a schedule doesn't leave the old one running too.
    func receiveRoutine(from senderID: String, botName: String, name: String, message: String,
                        cron: String, whenClosed: Bool) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }),
              let target = namedBot(botName, for: sender, doing: "schedule") else { return }
        let senderThread = thread(for: sender.id)
        let next: Date?
        do {
            next = try CronExpression(cron).nextFire(after: Date())
        } catch {
            senderThread.entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                kind: .unknown, message: "Couldn't schedule “\(name)”: \(error.localizedDescription)"))))
            return
        }
        let tier: Routine.Tier = whenClosed ? .launchAgent : .appOpen
        let words = Schedule.describe(cron)
        if let existing = routines.first(where: {
            $0.botID == target.id.rawValue && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            updateRoutine(existing, name: name, prompt: message, cron: cron, tier: tier)
        } else {
            addRoutine(to: target, name: name, prompt: message, cron: cron, tier: tier)
        }
        let when = next.map { ", next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        let by = target.id == sender.id ? "" : " by \(sender.name)"
        thread(for: target.id).entries.append(TranscriptEntry(kind: .note(
            "Routine “\(name)”: \(words)\(when)\(by)")))
        if target.id != sender.id {
            senderThread.entries.append(TranscriptEntry(kind: .note("Scheduled “\(name)” for \(target.name): \(words)\(when)")))
        }
        writeRoster()
    }

    func receiveRoutineRemoval(from senderID: String, botName: String, name: String) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }),
              let target = namedBot(botName, for: sender, doing: "change") else { return }
        guard let routine = routines.first(where: {
            $0.botID == target.id.rawValue && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            thread(for: sender.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                kind: .unknown, message: "\(target.name) has no routine called “\(name)”."))))
            return
        }
        deleteRoutine(routine)
        let by = target.id == sender.id ? "" : " by \(sender.name)"
        thread(for: target.id).entries.append(TranscriptEntry(kind: .note("Removed routine “\(routine.name)”\(by)")))
        writeRoster()
    }

    func receiveStop(from senderID: String, botName: String) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }),
              let target = namedBot(botName, for: sender, doing: "stop") else { return }
        // Its own turn ends when it stops talking; stopping itself would cut off its reply.
        guard target.id != sender.id, running[target.id] != nil else { return }
        stop(target.id)
        thread(for: target.id).entries.append(TranscriptEntry(kind: .note("Stopped by \(sender.name)")))
        thread(for: sender.id).entries.append(TranscriptEntry(kind: .note("Stopped \(target.name)")))
    }

    func receiveNotify(from senderID: String, title: String?, text: String) {
        guard let sender = bots.first(where: { $0.id.rawValue == senderID }) else { return }
        notifier.fromBot(title: title ?? sender.name, text: text, botID: sender.id)
        thread(for: sender.id).entries.append(TranscriptEntry(kind: .note("Notified you: \(text)")))
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
            handOver(text, from: sender, to: recipient)
        case .some(false):
            // Dropped rather than retried. A refused link must not become a loop, and the sender
            // learning it was refused is not information it needs — the person already decided.
            break
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
            handOver(introduction.text, from: introduction.from, to: introduction.to)
        }
    }

    /// When each bot last started work because another bot messaged it, per ordered pair.
    private var autoRuns: [String: [Date]] = [:]

    /// Automatic turns one bot may set off in another within ten minutes.
    ///
    /// Without a ceiling two bots that each end by messaging the other would talk forever, on the
    /// person's own subscription, with nobody watching. Five is plenty for a real hand-off and few
    /// enough that a loop stops quickly; the message is still delivered, just not acted on.
    static let autoRunsPerPair = 5

    /// Delivers a message and, if the recipient is free, has it act on it.
    ///
    /// A message that only sat in the recipient's thread until the person happened to open it
    /// meant bots could not hand work to each other at all. Now an allowed message starts the
    /// recipient working, told plainly who it is from — unless it is already busy, or this pair
    /// has hit its ceiling, in which case the message waits in its thread for the person.
    private func handOver(_ text: String, from sender: Bot, to recipient: Bot) {
        let key = "\(sender.id.rawValue)>\(recipient.id.rawValue)"
        let recent = (autoRuns[key] ?? []).filter { $0 > Date().addingTimeInterval(-600) }
        guard !isPaused, running[recipient.id] == nil, recent.count < Self.autoRunsPerPair else {
            append(message: text, from: sender, to: recipient)
            if isPaused {
                thread(for: recipient.id).entries.append(TranscriptEntry(kind: .note(
                    "Bots are paused, so this one is waiting for you.")))
            } else if recent.count >= Self.autoRunsPerPair {
                thread(for: recipient.id).entries.append(TranscriptEntry(kind: .note(
                    "\(sender.name) and \(recipient.name) have handed work back and forth a lot. "
                        + "This one is waiting for you.")))
            }
            return
        }
        autoRuns[key] = recent + [Date()]
        let prompt = "Message from \(sender.name), another bot on this roster:\n\n\(text)\n\n"
            + "Act on it if it's within your job. If \(sender.name) needs an answer, reply with the "
            + "message_bot tool; otherwise just say what you did."
        _ = startRun(prompt, bot: recipient, thread: thread(for: recipient.id), groupID: nil,
                     onFinish: nil, from: sender, shown: text)
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
        // Its folder is on its own Mac. Nothing is made here for it.
        if bot.remote != nil { return FileManager.default.homeDirectoryForCurrentUser }
        if let known = workspaceFolders[bot.id] { return known }
        let folder = Self.workspacesDirectory.appendingPathComponent(bot.id.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspaceFolders[bot.id] = folder
        return folder
    }

    /// Bots' own folders, once made. Every tool line and reply in a chat asks for its bot's folder,
    /// and each ask used to go to the disk to make sure it existed.
    @ObservationIgnored private var workspaceFolders: [BotID: URL] = [:]

    static var workspacesDirectory: URL {
        AppHome.directory.appendingPathComponent("workspaces", isDirectory: true)
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
    /// Sets the label beside a bot's name. Kept to a couple of words: it is a tag, and a long one
    /// pushes the name itself out of the sidebar.
    func setRole(_ bot: Bot, _ role: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        let trimmed = String((role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
        bots[index].role = trimmed.isEmpty ? nil : trimmed
        try? store?.save(bots[index].record(sortIndex: index))
    }

    func setOnlyBupsyApps(_ bot: Bot, _ only: Bool) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].onlyBupsyApps = only
        try? store?.save(bots[index].record(sortIndex: index))
    }

    func setSharedWithDevices(_ bot: Bot, _ shared: Bool) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].sharedWithDevices = shared
        try? store?.save(bots[index].record(sortIndex: index))
    }

    func setUseBrowser(_ bot: Bot, _ use: Bool) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index].useBrowser = use
        try? store?.save(bots[index].record(sortIndex: index))
    }

    /// Files the bot changed, from its own recorded tool calls.
    func filesWritten(by bot: Bot) -> [WrittenFile] {
        (try? store?.filesWritten(forBot: bot.id.rawValue)) ?? []
    }

    /// The same, read and parsed off the main thread, for a panel that refreshes while the bot
    /// works. Every tool call's arguments are JSON to decode, and a busy bot's run up to many
    /// megabytes of them: on the main thread that froze the window at each streamed line.
    func filesWrittenInBackground(by bot: Bot) async -> [WrittenFile] {
        guard let store else { return [] }
        let id = bot.id.rawValue
        return await Task.detached(priority: .utility) {
            (try? store.filesWritten(forBot: id)) ?? []
        }.value
    }

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
        // Moves the selection only. The window follows it only while it is showing that bot's
        // chat (RootView.followSelection), so hiding a bot from Team leaves you on Team.
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

    /// When each bot had last been read before it was opened this time — where "New" starts.
    var readBeforeOpening: [BotID: Date?] = [:]

    /// Whether a bot has said something since you last looked at it.
    func isUnread(_ bot: Bot) -> Bool {
        // The conversation you are looking at is never unread. `markRead` fires when the
        // selection changes, so a reply arriving in the thread already on screen left a dot that
        // nothing could clear — the one thing that clears it had already happened.
        guard selectedBotID != bot.id else { return false }
        if let remote = bot.remote { return remote.unread }

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
        // Kept so the thread can draw a "New" line where the unread messages begin. Taken before
        // the update, because by the time the page draws, this bot already counts as read.
        readBeforeOpening[bot.id] = bots[index].lastReadAt
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

    /// Every section, empty ones included, in the order they were made.
    ///
    /// Stored, so a section stays when its last bot leaves and can be made before its first. Kept
    /// in the app's own defaults, a JSON array of names, beside the sidebar's folds
    /// (`SidebarFolds`). A bot's section is still the string on the bot; this list only says
    /// which sections exist. Change it through `addSection`, `renameFolder` and `deleteSection`.
    private(set) var sectionNames: [String] = []

    private static let sectionsKey = "bupsy.sections"

    /// Reads the stored list. With none stored yet (every install before sections were kept),
    /// it is seeded from the bots' own sections, so nothing on screen moves. Any section a bot
    /// is in but the list lacks is added, so the two can never disagree about what exists.
    private func loadSections() {
        let stored = AppHome.defaults.string(forKey: Self.sectionsKey)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        var names = stored ?? []
        for bot in bots {
            if let folder = bot.folder, !folder.isEmpty, !names.contains(folder) {
                names.append(folder)
            }
        }
        sectionNames = names
        if stored != names { saveSections() }
    }

    private func saveSections() {
        guard let data = try? JSONEncoder().encode(sectionNames),
              let json = String(data: data, encoding: .utf8) else { return }
        AppHome.defaults.set(json, forKey: Self.sectionsKey)
    }

    /// Adds a section to the list if it is new. New sections go at the end.
    private func noteSection(_ name: String) {
        guard !name.isEmpty, !sectionNames.contains(name) else { return }
        sectionNames.append(name)
        saveSections()
    }

    /// Makes a section, empty or not. Returns the trimmed name, or nil when it was blank.
    @discardableResult
    func addSection(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        noteSection(trimmed)
        return trimmed
    }

    /// Sections in the order these bots first appear in them, then the sections none of them
    /// is in (empty ones, say), in the order they were made. The order a list showed before
    /// sections were stored is kept; a new section joins at the end.
    func sectionOrder(for members: [Bot]) -> [String] {
        var seen: [String] = []
        for bot in members {
            if let folder = bot.folder, !folder.isEmpty, !seen.contains(folder) {
                seen.append(folder)
            }
        }
        for name in sectionNames where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    /// The sidebar's sections, empty ones included. Pinned and hidden bots do not set the order,
    /// since the sidebar lists them elsewhere.
    var folders: [String] {
        sectionOrder(for: bots.filter { !$0.pinned && !$0.hidden } + linked.remoteBots)
    }

    /// Every section, for pickers and Move to menus: a section holding only pinned or hidden
    /// bots is still one you can move a bot into.
    var allSections: [String] {
        sectionOrder(for: bots)
    }

    /// Whether a section by this name exists, with or without bots.
    func sectionExists(_ name: String) -> Bool {
        sectionNames.contains(name) || bots.contains { $0.folder == name }
    }

    /// Bots with no folder. Shown first, above the named folders, because filing is optional.
    /// This Mac's bots, then other Macs' bots in no section.
    var ungroupedBots: [Bot] {
        bots.filter { ($0.folder ?? "").isEmpty && !$0.pinned && !$0.hidden }
            + linked.remoteBots.filter { ($0.folder ?? "").isEmpty }
    }

    /// Excludes pinned bots, which are already listed at the top. Showing a bot in both places
    /// is the bug that makes a pinned list feel broken rather than useful.
    /// A section's bots: this Mac's, then other Macs' that sit in a section of the same name.
    func bots(in folder: String) -> [Bot] {
        bots.filter { $0.folder == folder && !$0.pinned && !$0.hidden }
            + linked.remoteBots.filter { $0.folder == folder }
    }

    /// A bot by id, from this Mac or another.
    func anyBot(_ id: BotID) -> Bot? {
        bots.first { $0.id == id } ?? linked.remoteBots.first { $0.id == id }
    }

    func setFolder(_ bot: Bot, _ folder: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespaces)
        bots[index].folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let filed = bots[index].folder { noteSection(filed) }
        persistOrder()
    }

    /// Renames a folder everywhere at once, since the folder *is* the string on each bot. A name
    /// another section already has merges the two: the list keeps that one, in its place.
    func renameFolder(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { return }
        for index in bots.indices where bots[index].folder == old {
            bots[index].folder = trimmed
        }
        if sectionNames.contains(trimmed) {
            sectionNames.removeAll { $0 == old }
        } else if let position = sectionNames.firstIndex(of: old) {
            sectionNames[position] = trimmed
        } else {
            sectionNames.append(trimmed)
        }
        saveSections()
        persistOrder()
    }

    /// Empties a folder rather than deleting its bots. Deleting a container should never delete
    /// the things inside it. That is how people lose work they did not mean to. The section
    /// itself stays, empty; `deleteSection` is what removes it.
    func dissolveFolder(_ folder: String) {
        for index in bots.indices where bots[index].folder == folder {
            bots[index].folder = nil
        }
        persistOrder()
    }

    /// Removes a section. Its bots move to Unassigned; no bot, chat or routine is deleted.
    func deleteSection(_ name: String) {
        dissolveFolder(name)
        sectionNames.removeAll { $0 == name }
        saveSections()
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
        var lines = ["\(bot.name), on \(bot.engine.displayName)", ""]

        for entry in thread.entries {
            switch entry.kind {
            case .userMessage(let text): lines.append("You: \(text)")
            case .messageFrom(_, let name, let text): lines.append("\(name): \(text)")
            case .assistantText(let text): lines.append("\(bot.name): \(text)")
            case .tool(let name, let arguments, _, _): lines.append("  [\(name)] \(arguments)")
            case .approval(let approval):
                let decision = switch approval.decided {
                case .allowed: "allowed"
                case .alwaysAllowed: "always allowed"
                case .denied: "denied"
                case .expired: "denied, nobody answered"
                case nil: "waiting"
                }
                lines.append("  [approval: \(approval.summary), \(decision)]")
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
        // Whatever it is doing stops first, and nothing waiting for it starts later: a deleted
        // bot must not keep working in its folder, or be woken by a queued message.
        stop(bot.id)
        queued[bot.id] = nil
        queuedNote[bot.id] = nil
        waitingForBot[bot.id] = nil
        for watch in folderWatches where watch.botID == bot.id.rawValue { deleteFolderWatch(watch) }
        // The database drops its routines and goals with it; these copies go too, and launchd
        // stops waking the app for them.
        routines.removeAll { $0.botID == bot.id.rawValue }
        objectives.removeAll { $0.botID == bot.id.rawValue }
        bots.removeAll { $0.id == bot.id }
        threads[bot.id] = nil
        try? store?.deleteBot(id: bot.id.rawValue)
        // Selection only, as in toggleHidden: deleting from Team must not throw you into another
        // bot's chat. A visible bot is preferred so the sidebar has something to highlight; with
        // none left the selection is nil and the window shows the empty roster.
        if selectedBotID == bot.id {
            selectedBotID = bots.first { !$0.hidden }?.id ?? bots.first?.id
        }
        syncLaunchAgent()
    }
}

/// The approval gate could not be set up, so a run that depends on it is not started.
private struct GateUnavailable: LocalizedError {
    var errorDescription: String? {
        "Bupsy couldn't set up the approval check for this run, so it didn't start. Try again; if it keeps happening, check that your Mac has free disk space."
    }
}
