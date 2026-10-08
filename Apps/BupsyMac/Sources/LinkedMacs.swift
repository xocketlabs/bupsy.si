import AppKit
import BupsyKit
import Foundation

/// The person's other Macs running Bupsy, and their bots, shown here alongside this Mac's own.
///
/// This Mac pairs with another the way a phone does (that Mac's code, over Tailscale), keeps the
/// key it was given in the Keychain, and from then on asks that Mac for its shared bots every few
/// seconds. Those bots join this Mac's sidebar in the same sections, marked with the other Mac's
/// icon. They are live windows, never copies: their chats are read from their own Mac, and
/// sending, Allow and Deny, answers and Stop all go back to it, where its own gate decides.
@MainActor
@Observable
final class LinkedMacs {
    struct Link: Codable, Identifiable, Equatable, Sendable {
        let id: String
        var name: String
        var address: URL
        /// "laptop" or "desktop".
        var kind: String
    }

    private(set) var links: [Link] = []
    /// Whether each Mac answered the last time it was asked.
    private(set) var online: [String: Bool] = [:]
    /// What went wrong with a Mac that did not answer properly, to show in Settings.
    private(set) var problems: [String: String] = [:]
    /// Every shared bot on every linked Mac, in each Mac's own order.
    private(set) var remoteBots: [Bot] = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var summaries: [String: [RemoteBotSummary]] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let keys = LinkedMacKeys()
    @ObservationIgnored private let file = AppHome.directory.appendingPathComponent("linked-macs.json")

    static let listInterval: Duration = .seconds(3)
    static let chatInterval: Duration = .milliseconds(1500)

    init(model: AppModel) {
        self.model = model
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Link].self, from: data) {
            links = saved
        }
    }

    // MARK: - Ids

    /// A remote bot's id here: its Mac and its id there, so two Macs' bots never collide.
    nonisolated static func localID(mac: String, bot: String) -> BotID { BotID("remote:\(mac):\(bot)") }

    func ref(_ botID: BotID) -> RemoteRef? {
        guard botID.rawValue.hasPrefix("remote:") else { return nil }
        return remoteBots.first { $0.id == botID }?.remote
    }

    func isRemote(_ botID: BotID) -> Bool { botID.rawValue.hasPrefix("remote:") }

    private func client(_ macID: String) -> RemoteClient? {
        guard let link = links.first(where: { $0.id == macID }) else { return nil }
        return RemoteClient(address: link.address, key: keys.get(macID))
    }

    // MARK: - Linking

    /// Pairs with another Mac using the code it shows, and starts showing its bots here.
    func add(address typed: String, code: String) async throws {
        guard let address = RemoteClient.normalisedAddress(typed) else {
            throw RemoteClient.Failure.refused("That doesn't look like an address. Try its Tailscale name.")
        }
        let name = Host.current().localizedName ?? "Mac"
        let key = try await RemoteClient(address: address, key: nil).pair(code: code, name: name)
        let info = try await RemoteClient(address: address, key: key).sessionInfo()
        let id = UUID().uuidString
        try keys.set(key, for: id)
        links.append(Link(id: id, name: info.mac, address: address, kind: info.kind ?? "desktop"))
        save()
        await refresh()
    }

    func remove(_ link: Link) {
        try? keys.remove(link.id)
        links.removeAll { $0.id == link.id }
        summaries[link.id] = nil
        online[link.id] = nil
        problems[link.id] = nil
        save()
        rebuild()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Keeping up

    func start() {
        guard poller == nil else { return }
        #if DEBUG
        // Testing only: link to "<address> <code>" at launch. Debug builds only.
        if let test = ProcessInfo.processInfo.environment["BUPSY_LINK_TEST"]?.split(separator: " "), test.count == 2 {
            Task { try? await add(address: String(test[0]), code: String(test[1])) }
        }
        #endif
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.listInterval)
            }
        }
    }

    /// Asks every linked Mac for its bots, all at once.
    func refresh() async {
        let current = links.map { ($0.id, client($0.id)) }
        await withTaskGroup(of: (String, Result<[RemoteBotSummary], Error>).self) { group in
            for (id, client) in current {
                guard let client else { continue }
                group.addTask { (id, await Result(catching: { try await client.bots() })) }
            }
            for await (id, result) in group {
                switch result {
                case .success(let bots):
                    summaries[id] = bots
                    online[id] = true
                    problems[id] = nil
                case .failure(let error):
                    online[id] = false
                    problems[id] = error.localizedDescription
                }
            }
        }
        rebuild()
    }

    private func rebuild() {
        var bots: [Bot] = []
        for link in links {
            for summary in summaries[link.id] ?? [] {
                bots.append(Bot(remote: summary, on: link, online: online[link.id] ?? false))
            }
        }
        if bots != remoteBots { remoteBots = bots }
        // A remote bot's thread shows it working the way a local one does.
        for bot in bots { model?.thread(for: bot.id).isRunning = bot.remote?.running ?? false }
    }

    /// Keeps a remote bot's chat up to date while it is open. Runs until cancelled, which is when
    /// the page closes.
    func follow(_ botID: BotID) async {
        while !Task.isCancelled {
            await refreshChat(botID)
            try? await Task.sleep(for: Self.chatInterval)
        }
    }

    func refreshChat(_ botID: BotID) async {
        guard let ref = ref(botID), let client = client(ref.macID),
              let entries = try? await client.entries(bot: ref.botID),
              let thread = model?.thread(for: botID) else { return }
        let mirrored = Self.transcript(from: entries)
        // Only when something changed, so an unchanged chat is not redrawn every poll.
        if mirrored.map(\.id) != thread.entries.map(\.id) || Self.lastText(mirrored) != Self.lastText(thread.entries) {
            thread.entries = mirrored
        }
    }

    // MARK: - Acting on another Mac's bot

    func send(_ text: String, to bot: Bot) {
        act(bot) { client, id in try await client.send(text, to: id) }
    }

    func decide(_ approval: PendingApproval, allow: Bool, for bot: Bot) {
        act(bot) { client, id in try await client.decide(approval.id, allow: allow, bot: id) }
    }

    func answer(_ question: BotQuestion, with answer: String, for bot: Bot) {
        act(bot) { client, id in try await client.answer(question.id, with: answer, bot: id) }
    }

    func stop(_ botID: BotID) {
        guard let bot = remoteBots.first(where: { $0.id == botID }) else { return }
        act(bot) { client, id in try await client.stop(bot: id) }
    }

    /// Does it on the bot's own Mac, then refreshes so the result shows at once. A failure is
    /// said in the chat, not swallowed: a message that did not arrive must not look sent.
    private func act(_ bot: Bot, _ work: @escaping @Sendable (RemoteClient, String) async throws -> Void) {
        guard let ref = bot.remote, let client = client(ref.macID) else { return }
        Task {
            do {
                try await work(client, ref.botID)
            } catch {
                model?.thread(for: bot.id).entries.append(TranscriptEntry(kind: .failure(EngineFailure(
                    kind: .unknown, message: "Couldn't reach \(ref.macName): \(error.localizedDescription)"))))
            }
            await refresh()
            await refreshChat(bot.id)
        }
    }

    // MARK: - Mirroring a chat

    static func lastText(_ entries: [TranscriptEntry]) -> String? {
        guard let last = entries.last else { return nil }
        if case .assistantText(let text) = last.kind { return text }
        if case .approval(let approval) = last.kind { return "\(approval.id)\(String(describing: approval.decided))" }
        if case .question(let question) = last.kind { return "\(question.id)\(question.answer ?? "")" }
        return nil
    }

    /// The other Mac's chat, as entries this Mac's chat page draws the same way as its own.
    static func transcript(from entries: [RemoteEntry]) -> [TranscriptEntry] {
        entries.compactMap { entry in
            let id = UUID(uuidString: entry.id) ?? UUID()
            let kind: TranscriptEntry.Kind
            switch entry.kind {
            case "you":
                kind = .userMessage(entry.text ?? "")
            case "bot":
                kind = .assistantText(entry.text ?? "")
            case "from":
                kind = .messageFrom(botID: "", botName: entry.author ?? "A bot", text: entry.text ?? "")
            case "tool":
                guard let tool = entry.tool else { return nil }
                let (name, key) = toolName(tool.verb)
                let arguments = (try? JSONSerialization.data(withJSONObject: [key: tool.target]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                kind = .tool(name: name, arguments: arguments, result: "", failed: tool.failed)
            case "approval":
                guard let approval = entry.approval else { return nil }
                kind = .approval(PendingApproval(
                    id: approval.id, tool: approval.tool, summary: approval.summary, inputJSON: "{}",
                    reason: approval.reason, decided: decision(approval.decided)))
            case "question":
                guard let question = entry.question else { return nil }
                kind = .question(BotQuestion(id: question.id, question: question.question,
                                             options: question.options, answer: question.answer))
            case "failure":
                kind = .failure(EngineFailure(kind: .unknown, message: entry.text ?? ""))
            default:
                guard let text = entry.text else { return nil }
                kind = .note(text)
            }
            return TranscriptEntry(id: id, kind: kind, at: entry.at)
        }
    }

    /// The tool a remote step's verb stands for, and the argument its target fills, so the line
    /// reads the same as it does on its own Mac.
    static func toolName(_ verb: String) -> (String, String) {
        switch verb {
        case "ran": ("Bash", "command")
        case "read": ("Read", "file_path")
        case "edited": ("Edit", "file_path")
        case "looked up": ("WebFetch", "url")
        case "searched": ("Grep", "pattern")
        case "used": ("mcp__remote__tool", "query")
        default: (verb, "command")
        }
    }

    static func decision(_ name: String?) -> PendingApproval.Decision? {
        switch name {
        case "allowed": .allowed
        case "alwaysAllowed": .alwaysAllowed
        case "denied": .denied
        case "expired": .expired
        default: nil
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
