import BupsyKit
import Foundation

/// Picks up messages bots have asked to send each other.
///
/// `bupsy-mcp` runs inside the engine's sandbox and can only drop a file here; it never delivers
/// anything itself. Delivery is decided on this side, out of the model's reach, which is what
/// makes "first contact asks a person" a rule the bot cannot route around rather than a courtesy
/// it is asked to observe.
///
/// A polled directory rather than a socket or a shared database: it needs no dependencies,
/// survives either side restarting, and works the same on a rented Linux machine as it does here.
/// The same shape as the approval gate's pending/decisions folders, for the same reasons.
/// What a bot asked to change about a bot, by the manage_bot tool.
struct BotChange: Equatable {
    var bot: String
    var job: String?
    var role: String?
    var model: String?
    var engine: String?
    var freshChat = false
    var message: String?

    var isEmpty: Bool { job == nil && role == nil && model == nil && engine == nil && !freshChat && message == nil }
}

@MainActor
final class OutboxWatcher {
    /// Where `bupsy-mcp` drops messages. Passed to it by value in the MCP config.
    static var directory: URL {
        // Beside the database, under the app's own home, rather than a second folder called
        // "bupsy" that nothing else uses.
        AppHome.directory.appendingPathComponent("outbox", isDirectory: true)
    }

    /// What a bot can ask for. Both are requests: bupsy decides, and asks a person where it must.
    enum Request {
        case message(from: String, toName: String, text: String)
        case createBot(from: String, name: String, job: String, role: String?)
        case question(from: String, question: String, options: [String])
        case updateMe(from: String, name: String?, role: String?, job: String?)
        /// File bots into a sidebar section; nil takes them out of any section.
        case moveBots(from: String, bots: [String], section: String?)
        /// Change another bot (or itself): job, role, model, a fresh chat, a message.
        case manageBot(from: String, change: BotChange)
        /// Schedule a message to a bot; replaces its routine of the same name.
        case addRoutine(from: String, bot: String, name: String, message: String, cron: String, whenClosed: Bool)
        case removeRoutine(from: String, bot: String, name: String)
        case stopBot(from: String, bot: String)
        /// A notification for the person, from a bot.
        case notify(from: String, title: String?, text: String)
    }

    /// The roster `list_bots` reads, beside the outbox rather than in it, since the outbox is drained
    /// and emptied every second.
    static var rosterFile: URL {
        directory.deletingLastPathComponent().appendingPathComponent("roster.json")
    }

    private var timer: Timer?
    private let onRequest: (Request) -> Void
    /// The bot a run token belongs to. Who sent a request is taken from this, never from the
    /// file's own "from": every bot shares this folder, and any bot that can write a file could
    /// put another bot's id there and borrow its links and its name.
    private let sender: (String) -> String?

    init(sender: @escaping (String) -> String?, onRequest: @escaping (Request) -> Void) {
        self.sender = sender
        self.onRequest = onRequest
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)

        // One second is well under the time anyone notices, and this reads an almost always empty
        // directory. A file-system event source would be tidier and is worth doing if this ever
        // sits on a network volume, where polling is the wrong shape.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The question as the card can show it. Two to four short answers become buttons; any
    /// other number is folded into the text so nothing the bot offered is lost, and the person
    /// answers in their own words. An empty question stays empty for the caller to explain.
    static func normaliseQuestion(_ question: String?, options raw: Any?) -> (String, [String]) {
        let text = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ((raw as? [Any]) ?? []).compactMap { item -> String? in
            guard let option = item as? String else { return nil }
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if (2...4).contains(options.count) { return (text, options) }
        guard !options.isEmpty, !text.isEmpty else { return (text, []) }
        let listed = options.map { "- \($0)" }.joined(separator: "\n")
        return ("\(text)\n\n\(listed)", [])
    }

    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []

        // Oldest first, so a burst from one bot arrives in the order it was sent.
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            defer { try? FileManager.default.removeItem(at: file) }

            // Deleted rather than retried when unreadable. A file we cannot read will not become
            // readable, and leaving it here would mean parsing it again every second forever.
            // A file without a live run's token was not written by bupsy-mcp for a run we
            // started, so it is dropped unread.
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = payload["token"] as? String, !token.isEmpty,
                  let from = sender(token)
            else { continue }

            func field(_ key: String) -> String? {
                (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            let kind = payload["kind"] as? String
            if kind == "add_routine" {
                guard let bot = field("bot"), let name = field("name"), let message = field("message"),
                      let cron = field("schedule") else { continue }
                onRequest(.addRoutine(from: from, bot: bot, name: name, message: message, cron: cron,
                                      whenClosed: payload["when_closed"] as? Bool ?? false))
            } else if kind == "remove_routine" {
                guard let bot = field("bot"), let name = field("name") else { continue }
                onRequest(.removeRoutine(from: from, bot: bot, name: name))
            } else if kind == "stop_bot" {
                guard let bot = field("bot") else { continue }
                onRequest(.stopBot(from: from, bot: bot))
            } else if kind == "notify" {
                guard let text = field("text") else { continue }
                onRequest(.notify(from: from, title: field("title"), text: text))
            } else if kind == "manage_bot" {
                guard let bot = field("bot") else { continue }
                let change = BotChange(bot: bot, job: field("job"), role: field("role"), model: field("model"),
                                       engine: field("engine"), freshChat: payload["fresh_chat"] as? Bool ?? false, message: field("message"))
                guard !change.isEmpty else { continue }
                onRequest(.manageBot(from: from, change: change))
            } else if payload["kind"] as? String == "move_bots" {
                let names = ((payload["bots"] as? [Any]) ?? []).compactMap { $0 as? String }
                guard !names.isEmpty else { continue }
                onRequest(.moveBots(from: from, bots: names, section: field("section")))
            } else if payload["kind"] as? String == "update_me" {
                onRequest(.updateMe(from: from, name: field("name"), role: field("role"), job: field("job")))
            } else if payload["kind"] as? String == "question" {
                // Never dropped: the bot has stopped to wait for an answer, and a question that
                // vanished here leaves it waiting with nothing on screen. A shape the card cannot
                // show as buttons arrives as a plain question answered in words instead.
                let (question, options) = Self.normaliseQuestion(
                    payload["question"] as? String, options: payload["options"])
                onRequest(.question(from: from, question: question, options: options))
            } else if payload["kind"] as? String == "create_bot" {
                guard let name = payload["name"] as? String, !name.isEmpty,
                      let job = payload["job"] as? String, !job.isEmpty else { continue }
                let role = (payload["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                onRequest(.createBot(from: from, name: name, job: job, role: role))
            } else {
                guard let to = payload["to"] as? String,
                      let text = payload["text"] as? String, !text.isEmpty else { continue }
                onRequest(.message(from: from, toName: to, text: text))
            }
        }
    }
}
