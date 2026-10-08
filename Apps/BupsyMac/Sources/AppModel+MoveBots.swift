import BupsyKit
import Foundation

/// Moving a bot, or a whole section of them, to another of the person's Macs, where it runs from
/// then on.
///
/// A bot's engine session cannot go with it: Claude Code and Codex keep it under the folder the
/// bot works in, on this Mac, and a copied session would point at paths the other Mac does not
/// have. So the bot carries on the way a fresh chat does: it first writes itself hand-off notes,
/// and its first turn on the other Mac starts from them. Its recent messages go too, so the person
/// still sees what was said, and so do its routines, goals, folder watches and the files in its
/// own folder.
///
/// Nothing is removed here until the other Mac says the bot is set up there. A move that fails at
/// any step leaves the bot on this Mac as it was, and says why.
extension AppModel {
    struct MoveRequest: Identifiable {
        let id = UUID()
        let botIDs: [BotID]
        let mac: LinkedMacs.Link
        /// Set when a whole section is moving.
        let section: String?
    }

    struct MoveOutcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// The Settings pane that fixes it, offered as a button beside OK.
        var settingsPane: SettingsPane?
    }

    struct MoveFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The person's linked Macs that answered the last time they were asked. A Mac that is
    /// asleep or off is left out rather than offered and then failed.
    var moveTargets: [LinkedMacs.Link] {
        linked.links.filter { linked.online[$0.id] == true }
    }

    func askToMove(_ bot: Bot, to mac: LinkedMacs.Link) {
        guard bot.remote == nil, moving.isEmpty else { return }
        moveRequest = MoveRequest(botIDs: [bot.id], mac: mac, section: nil)
    }

    /// Every bot of this Mac's filed in the section, pinned and hidden ones too: they are filed
    /// there just the same. Bots shown from other Macs stay where they are.
    func askToMove(section: String, to mac: LinkedMacs.Link) {
        let members = bots.filter { $0.folder == section }
        guard !members.isEmpty, moving.isEmpty else { return }
        moveRequest = MoveRequest(botIDs: members.map(\.id), mac: mac, section: section)
    }

    func moveTitle(_ request: MoveRequest) -> String {
        if let section = request.section { return "Move the \(section) section to \(request.mac.name)?" }
        let name = bots.first { $0.id == request.botIDs.first }?.name ?? "this bot"
        return "Move \(name) to \(request.mac.name)?"
    }

    /// What will happen, in the words the confirmation shows.
    func moveMessage(_ request: MoveRequest) -> String {
        let mac = request.mac.name
        let movers = request.botIDs.compactMap { id in bots.first { $0.id == id } }
        let subject = request.section != nil
            ? (movers.count == 1 ? "Its bot" : "Its \(movers.count) bots")
            : "It"
        var lines = [
            "\(subject) will run on \(mac) from now on, and leave this Mac.",
            "Each first writes itself notes on where it is up to, then carries on from them in a fresh chat there. Recent messages, routines, goals and folder watches go too.",
        ]
        let own = movers.filter { $0.workdir == nil }
        let chosen = movers.filter { $0.workdir != nil }
        if !own.isEmpty {
            lines.append("Files in \(own.count == movers.count ? "its own folder" : "the bots' own folders") are copied over (up to \(BotMove.formatted(BotMove.maxFolderBytes)) each).")
        }
        if let first = chosen.first, let path = first.workdir {
            lines.append(chosen.count == 1
                ? "\(first.name) keeps working in \((path as NSString).abbreviatingWithTildeInPath) if \(mac) has that folder; its files aren't copied."
                : "Bots working in a folder you chose keep it if \(mac) has the same folder; those files aren't copied.")
        }
        return lines.joined(separator: "\n\n")
    }

    func confirmMove(_ request: MoveRequest) {
        Task { await move(request) }
    }

    // MARK: - Leaving this Mac

    func move(_ request: MoveRequest) async {
        guard moving.isEmpty else {
            moveOutcome = MoveOutcome(title: "Another move is under way",
                                      message: "Try again when it has finished.")
            return
        }
        let mac = request.mac
        let movers = request.botIDs.compactMap { id in bots.first { $0.id == id && $0.remote == nil } }
        guard !movers.isEmpty else { return }
        let what = request.section.map { "The \($0) section" } ?? movers[0].name

        // Whatever would stop any of them is found before the first one goes, so a section never
        // half-moves for a reason that was known at the start.
        for bot in movers { moving[bot.id] = mac.name }
        var problems: [String] = []
        for bot in movers {
            if let problem = await moveProblem(bot) { problems.append(problem) }
        }
        guard problems.isEmpty, let client = linked.client(mac.id) else {
            moving = [:]
            moveOutcome = MoveOutcome(
                title: "\(what) can't move yet",
                message: problems.isEmpty
                    ? "\(mac.name) isn't linked any more. Link it again in Settings › Other Macs."
                    : problems.joined(separator: "\n\n") + (movers.count > 1 ? "\n\nNothing was moved." : ""),
                settingsPane: problems.isEmpty ? .otherMacs : nil)
            return
        }

        var arrived: [String] = []
        for (index, bot) in movers.enumerated() {
            do {
                let receipt = try await moveOne(bot, to: mac, client: client)
                arrived.append(receipt.name)
                moving[bot.id] = nil
            } catch {
                moving = [:]
                let reason = error.localizedDescription
                if bots.contains(where: { $0.id == bot.id }) {
                    thread(for: bot.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                        kind: .unknown, message: "Couldn't move to \(mac.name): \(reason) \(bot.name) stays on this Mac."))))
                }
                let stayed = movers[index...].map(\.name)
                var message = "\(reason)\n\n\(Self.listed(stayed)) \(stayed.count == 1 ? "stays" : "stay") on this Mac, as before."
                if !arrived.isEmpty {
                    message += " \(Self.listed(arrived)) moved to \(mac.name) already."
                }
                moveOutcome = MoveOutcome(title: "\(bot.name) couldn't move to \(mac.name)", message: message)
                return
            }
        }
        moving = [:]
        // The section went with its bots: an empty heading left behind here would read as if
        // something were missing. It comes back here with the other Mac's bots in it while they
        // are shared, since that Mac files them under the same name.
        if let section = request.section, !bots.contains(where: { $0.folder == section }) {
            deleteSection(section)
        }
        let renamed = zip(movers, arrived).filter { $0.0.name != $0.1 }
            .map { "\($0.0.name) is called \($0.1) there, since a bot there already had that name." }
        let shared = movers.filter(\.sharedWithDevices).count
        var message = "\(movers.count == 1 ? "It runs" : "They run") on \(mac.name) now."
        if shared > 0 {
            message += " \(shared == movers.count ? (movers.count == 1 ? "It still shows" : "They still show") : "The ones shared with your devices still show") here with \(mac.name)'s icon."
        }
        if !renamed.isEmpty { message += "\n\n" + renamed.joined(separator: "\n") }
        moveOutcome = MoveOutcome(title: "\(what) moved to \(mac.name)", message: message)
    }

    /// Why a bot cannot move right now, or nil.
    private func moveProblem(_ bot: Bot) async -> String? {
        if bot.machineID != nil {
            return "\(bot.name) runs on a cloud machine. Set it to run on This Mac first."
        }
        if isRunning(bot.id) || writingHandoff.contains(bot.id) {
            return "\(bot.name) is working. Try again when it finishes."
        }
        guard bot.workdir == nil else { return nil }
        let folder = Self.workspacesDirectory.appendingPathComponent(bot.id.rawValue, isDirectory: true)
        let bytes = await Task.detached { BotMove.folderSize(folder) }.value
        return BotMove.sizeRefusal(botName: bot.name, bytes: bytes)
    }

    private func moveOne(_ bot: Bot, to mac: LinkedMacs.Link, client: RemoteClient) async throws -> BotMoveReceipt {
        let thread = thread(for: bot.id)
        var notes: String?
        if thread.conversationID != nil {
            thread.entries.append(TranscriptEntry(kind: .note("Writing notes before moving to \(mac.name)…")))
            notes = try await writeMoveNotes(bot, to: mac.name)
        }
        // As it is now: its notes run may have been followed by something it was asked meanwhile.
        guard let current = bots.first(where: { $0.id == bot.id }) else {
            throw MoveFailure("\(bot.name) was deleted.")
        }
        guard !isRunning(current.id) else {
            throw MoveFailure("\(bot.name) started working again before it could go.")
        }
        sealedForMove.insert(current.id)
        defer { sealedForMove.remove(current.id) }
        thread.entries.append(TranscriptEntry(kind: .note("Moving to \(mac.name)…")))

        let moveID = UUID().uuidString
        var files: BotMoveFiles?
        var archive: URL?
        defer { if let archive { try? FileManager.default.removeItem(at: archive) } }
        let ownFolder = current.workdir == nil ? workingDirectory(for: current) : nil
        if let ownFolder, BotMove.hasFiles(ownFolder) {
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("bupsy-move-\(moveID).zip")
            archive = zip
            try await BotMove.zip(ownFolder, to: zip)
            let bytes = Int64((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard bytes <= BotMove.maxArchiveBytes else {
                throw MoveFailure(BotMove.sizeRefusal(botName: current.name, bytes: bytes) ?? "Its folder is too big to move.")
            }
            let hash = try await Task.detached { try BotMove.sha256(of: zip) }.value
            files = BotMoveFiles(bytes: bytes, sha256: hash)
        }

        try await client.beginMove(moveID, bytes: files?.bytes ?? 0)
        if let archive, let files {
            thread.entries.append(TranscriptEntry(kind: .note("Copying \(BotMove.formatted(files.bytes)) of files to \(mac.name)…")))
            try await client.sendMoveFiles(moveID, archive: archive)
        }
        let manifest = moveManifest(current, notes: notes, files: files, oldFolder: ownFolder?.path)
        let receipt = try await client.finishMove(moveID, manifest: manifest)

        // There now, so gone from here. Deleting stops anything it was doing (nothing: it was
        // sealed), and takes its routines, goals and watches with it, so nothing fires twice.
        // Its own folder stays on disk, as it does for any deleted bot.
        deleteBot(current)
        return receipt
    }

    static func movePrompt(to mac: String) -> String {
        """
        You are about to move to another of the person's Macs, \(mac), and carry on there in a \
        fresh chat that starts with no memory of this one. Write yourself hand-off notes: what \
        you are working on, what is done, decisions made and why, the files and commands that \
        matter, anything the person asked you to remember, and the next steps. Name files \
        relative to your folder, since full paths may differ there. Be specific and brief, under \
        300 words. Reply with only the notes, and don't use any tools.
        """
    }

    /// Asks the bot for its notes and waits for them. Throws when it was stopped, or wrote
    /// nothing: moving without them would leave it knowing nothing of its work.
    private func writeMoveNotes(_ bot: Bot, to mac: String) async throws -> String {
        let box = MoveNotes()
        // Counted as a hand-off, so a long chat does not also ask for a fresh chat as it ends.
        writingHandoff.insert(bot.id)
        defer { writingHandoff.remove(bot.id) }
        let started = startRun(Self.movePrompt(to: mac), bot: bot, thread: thread(for: bot.id), groupID: nil,
                               onFinish: { reply in box.reply = reply }, hidesPrompt: true)
        guard started else { throw MoveFailure("\(bot.name) couldn't start writing its notes.") }
        // `onFinish` runs as the run ends, before the bot counts as free, so once it is free the
        // notes are in — or the run was stopped, which never calls it.
        while isRunning(bot.id) { try? await Task.sleep(for: .milliseconds(300)) }
        guard let reply = box.reply else {
            throw MoveFailure("It was stopped before it finished its notes.")
        }
        let notes = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            throw MoveFailure("\(bot.name) couldn't write its hand-off notes. Try again, or give it a fresh chat first.")
        }
        return notes
    }

    func moveManifest(_ bot: Bot, notes: String?, files: BotMoveFiles?, oldFolder: String?) -> BotMoveManifest {
        let profile = BotMoveProfile(
            name: bot.name, engine: bot.engine.rawValue, model: bot.model, autonomy: bot.autonomy.rawValue,
            job: bot.personaPrompt, workdir: bot.workdir, avatarHue: bot.avatarHue,
            avatarShape: bot.avatarShape?.rawValue, avatarColour: bot.avatarColour, role: bot.role,
            section: bot.folder, pinned: bot.pinned, hidden: bot.hidden, onlyBupsyApps: bot.onlyBupsyApps,
            useBrowser: bot.useBrowser, sharedWithDevices: bot.sharedWithDevices,
            toolAllowlist: bot.toolAllowlist.sorted())
        let id = bot.id.rawValue
        return BotMoveManifest(
            fromMac: Host.current().localizedName ?? "your other Mac", profile: profile,
            routines: routines.filter { $0.botID == id },
            objectives: objectives.filter { $0.botID == id },
            folderWatches: folderWatches.filter { $0.botID == id },
            history: Self.movedHistory(thread(for: bot.id).entries),
            notes: notes, files: files, oldFolder: oldFolder)
    }

    /// The chat as it travels: what was said and done, newest `historyLimit` lines. Approvals,
    /// questions and Bupsy's own notes are about runs here and stay behind.
    static func movedHistory(_ entries: [TranscriptEntry]) -> [MovedEntry] {
        let moved: [MovedEntry] = entries.compactMap { entry in
            switch entry.kind {
            case .userMessage(let text):
                MovedEntry(kind: .you, text: BotMove.capped(text), at: entry.at)
            case .assistantText(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                MovedEntry(kind: .bot, text: BotMove.capped(text), at: entry.at)
            case .messageFrom(let id, let name, let text):
                MovedEntry(kind: .from, text: BotMove.capped(text), author: name, authorID: id, at: entry.at)
            case .tool(let name, let arguments, _, _):
                MovedEntry(kind: .tool, text: BotMove.cappedArguments(arguments), tool: name, at: entry.at)
            default:
                nil
            }
        }
        return Array(moved.suffix(BotMove.historyLimit))
    }

    static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    // MARK: - Arriving here

    /// Sets up a bot another of the person's Macs is moving here, and returns its id and name
    /// here. Throws, leaving nothing behind, when it cannot be set up; the other Mac then keeps it.
    func receiveMovedBot(_ manifest: BotMoveManifest, archive: URL?) async throws -> BotMoveReceipt {
        guard manifest.version <= BotMoveManifest.currentVersion else {
            throw MoveFailure("This Mac's Bupsy is older than the one sending the bot. Update Bupsy here, then try again.")
        }
        let profile = manifest.profile
        var bot = Bot(name: profile.name, engine: EngineID(rawValue: profile.engine) ?? .claude,
                      model: profile.model, personaPrompt: profile.job)
        bot.autonomy = Autonomy(rawValue: profile.autonomy) ?? .ask
        bot.avatarHue = profile.avatarHue
        bot.avatarShape = profile.avatarShape.flatMap(BotShape.init(rawValue:))
        bot.avatarColour = profile.avatarColour
        bot.role = profile.role
        bot.pinned = profile.pinned
        bot.hidden = profile.hidden
        bot.onlyBupsyApps = profile.onlyBupsyApps
        bot.useBrowser = profile.useBrowser
        bot.sharedWithDevices = profile.sharedWithDevices
        bot.toolAllowlist = Set(profile.toolAllowlist)

        // Its files first, into a folder of its own that only becomes its folder once whole.
        let ownFolder = Self.workspacesDirectory.appendingPathComponent(bot.id.rawValue, isDirectory: true)
        if let archive {
            let landing = Self.workspacesDirectory.appendingPathComponent(".moving-\(bot.id.rawValue)", isDirectory: true)
            do {
                try await BotMove.unzip(archive, into: landing)
                try FileManager.default.moveItem(at: landing, to: ownFolder)
            } catch {
                try? FileManager.default.removeItem(at: landing)
                throw error
            }
        }
        var said = ["Moved here from \(manifest.fromMac)."]
        if let chosen = profile.workdir {
            if FileManager.default.fileExists(atPath: chosen) {
                bot.workdir = chosen
            } else {
                said.append("\((chosen as NSString).abbreviatingWithTildeInPath) isn't on this Mac, so it works in a folder of its own here instead. Choose another in its details if it should work somewhere else.")
            }
        }
        // Named after unpacking, which awaited: a bot made here meanwhile counts too.
        bot.name = BotMove.freeName(profile.name) { isNameTaken($0) }
        if bot.name != profile.name {
            said.append("A bot here was already called \(profile.name), so this one is \(bot.name).")
        }

        bots.append(bot)
        do {
            try store?.save(bot.record(sortIndex: bots.count - 1))
        } catch {
            bots.removeAll { $0.id == bot.id }
            try? FileManager.default.removeItem(at: ownFolder)
            throw error
        }
        if let section = profile.section { setFolder(bot, section) }

        // Its recent chat, as its own, in a conversation with no engine session: the next turn
        // starts a fresh one, carrying the notes.
        let conversation = ConversationRecord(botID: bot.id.rawValue, engine: bot.engine.rawValue,
                                              lastEventAt: manifest.history.last?.at ?? Date())
        try? store?.save(conversation)
        importMovedHistory(manifest.history, bot: bot, conversation: conversation.id)
        let folder = workingDirectory(for: bot).path
        if let notes = manifest.notes {
            let here = Host.current().localizedName ?? "this Mac"
            AppHome.defaults.set("You now run on \(here), moved here from \(manifest.fromMac). "
                + "Your folder here is \(folder).\n\n\(notes)", forKey: Self.handoffKey(bot.id))
        }

        let id = bot.id.rawValue
        for var routine in manifest.routines {
            routine.id = UUID().uuidString
            routine.botID = id
            // A cloud machine is this Mac's no more than the bot's: it runs here now.
            if routine.tier == .machine { routine.tier = .appOpen }
            routines.append(routine)
            try? store?.save(routine)
        }
        for var objective in manifest.objectives {
            objective.id = UUID().uuidString
            objective.botID = id
            if objective.tier == .machine { objective.tier = .appOpen }
            objectives.append(objective)
            try? store?.save(objective)
        }
        for var watch in manifest.folderWatches {
            watch.id = UUID().uuidString
            watch.botID = id
            watch.path = BotMove.followFolder(watch.path, from: manifest.oldFolder, to: ownFolder.path)
            folderWatches.append(watch)
            try? store?.save(watch)
            syncWatcher(watch)
            if !FileManager.default.fileExists(atPath: watch.path) {
                said.append("Its folder watch \"\(watch.name)\" looks at \((watch.path as NSString).abbreviatingWithTildeInPath), which isn't on this Mac. Point it at another folder in its details.")
            }
        }
        syncLaunchAgent()

        // Read back from the store, as a relaunch would show it, with the arrival said under it.
        thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(said.joined(separator: " "))))
        return BotMoveReceipt(id: id, name: bot.name)
    }

    /// The moved chat, kept as the bot's own with the times it was said, the way a continued
    /// Claude Code chat's history is (`AppModel+ClaudeChats`).
    private func importMovedHistory(_ history: [MovedEntry], bot: Bot, conversation: String) {
        guard let first = history.first else { return }
        let run = RunRecord(botID: bot.id.rawValue, conversationID: conversation, host: "local",
                            status: "imported", startedAt: first.at, endedAt: history.last?.at)
        try? store?.save(run)
        var records: [EventRecord] = []
        func record(_ event: AgentEvent, as type: String? = nil, at: Date) {
            let (kind, payload) = EventCodec.encode(event)
            records.append(EventRecord(runID: run.id, seq: records.count, type: type ?? kind, payload: payload, at: at))
        }
        for entry in history {
            switch entry.kind {
            case .you:
                record(.text(entry.text), as: "userMessage", at: entry.at)
            case .bot:
                record(.text(entry.text), at: entry.at)
            case .from:
                // The same shape `startRun` stores a message from another bot in.
                let joined = [entry.authorID ?? "", entry.author ?? "A bot", entry.text].joined(separator: "\u{1}")
                record(.text(joined), as: "messageFrom", at: entry.at)
            case .tool:
                // Settled: these ran on the other Mac, before it moved.
                let call = UUID().uuidString
                record(.toolCall(ToolCall(id: call, name: entry.tool ?? "tool", argumentsJSON: entry.text)), at: entry.at)
                record(.toolResult(ToolResult(callID: call, content: "", isError: false)), at: entry.at)
            }
        }
        try? store?.append(records)
    }
}

/// Where a bot's move notes land when its run ends. A class, so the run's finish handler can
/// fill it in for the move that is waiting on it.
@MainActor
private final class MoveNotes {
    var reply: String?
}

#if DEBUG
extension AppModel {
    /// Testing only: moves a bot by name, or a section as "section:<name>", to the first linked
    /// Mac, and prints how it went. Set with BUPSY_MOVE_TEST beside BUPSY_LINK_TEST, against two
    /// throwaway homes on loopback. Debug builds only.
    func runMoveTest(_ what: String) async {
        for _ in 0..<40 where moveTargets.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        guard let mac = moveTargets.first else {
            FileHandle.standardError.write(Data("MOVE_TEST_OUTCOME no linked Mac online\n".utf8))
            return
        }
        if what.hasPrefix("section:") {
            askToMove(section: String(what.dropFirst("section:".count)), to: mac)
        } else if let bot = bots.first(where: { $0.name == what }) {
            askToMove(bot, to: mac)
        }
        guard let request = moveRequest else {
            FileHandle.standardError.write(Data("MOVE_TEST_OUTCOME nothing to move called \(what)\n".utf8))
            return
        }
        moveRequest = nil
        await move(request)
        let outcome = moveOutcome.map { "\($0.title) | \($0.message)" } ?? "no outcome"
        FileHandle.standardError.write(Data("MOVE_TEST_OUTCOME \(outcome.replacingOccurrences(of: "\n", with: " / "))\n".utf8))
    }
}
#endif
