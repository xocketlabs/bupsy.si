import Foundation

// What the Mac's remote API sends, decoded once at the edge so views only ever see typed values.
// The shapes are defined by `RemoteAccess` in the Mac app; this file is the phone's half of that
// contract.
//
// Decoding is forgiving wherever the Mac might grow. An unknown mood reads as idle, an unknown
// kind of entry still shows its text, and one entry this app can't read is dropped rather than
// blanking the whole chat. A newer Mac should never leave an older phone with an empty screen.

/// One bot, as the list and a chat's header show it.
struct Bot: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String?
    /// The sidebar section it sits in on the Mac. Nil for pinned bots and bots in no section.
    let section: String?
    /// `#rrggbb`, the bot's own colour from its face on the Mac.
    let colour: String
    let mood: Mood
    let running: Bool
    let needsYou: Bool
    let unread: Bool
    let preview: String?

    enum Mood: String, Decodable, Sendable {
        case idle, working, waitingForYou, done, sleeping, failed

        init(from decoder: Decoder) throws {
            self = Mood(rawValue: try String(from: decoder)) ?? .idle
        }
    }

    /// A stand-in until the Mac answers, so a chat opened from a notification has a header at once.
    static func placeholder(_ id: String) -> Bot {
        Bot(id: id, name: "", role: nil, section: nil, colour: "", mood: .idle,
            running: false, needsYou: false, unread: false, preview: nil)
    }
}

/// The bots under one section heading, in the Mac's sidebar order.
struct BotSection: Identifiable, Equatable {
    /// Nil for the bots above every section: pinned ones and those in no section.
    let title: String?
    let bots: [Bot]

    var id: String { title ?? "" }

    /// Keeps the server's order. Bots in no section come first; sections follow in the order
    /// they first appear, which is the order the Mac's sidebar shows them.
    static func group(_ bots: [Bot]) -> [BotSection] {
        var titles: [String?] = [nil]
        var members: [String?: [Bot]] = [:]
        for bot in bots {
            let title = bot.section.flatMap { $0.isEmpty ? nil : $0 }
            if !titles.contains(title) { titles.append(title) }
            members[title, default: []].append(bot)
        }
        return titles.compactMap { title in
            members[title].map { BotSection(title: title, bots: $0) }
        }
    }
}

struct BotList: Decodable, Sendable {
    let bots: [Bot]
    /// How many bots need the person right now.
    let waiting: Int

    private enum Keys: String, CodingKey { case bots, waiting }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        bots = try container.decode([Lossy<Bot>].self, forKey: .bots).compactMap(\.value)
        waiting = try container.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
    }
}

struct MacInfo: Decodable, Sendable {
    /// The Mac's own name, as the person set it in System Settings.
    let mac: String
}

/// A bot and the latest of its conversation, oldest first.
struct BotThread: Decodable, Sendable {
    let bot: Bot
    let entries: [Entry]

    private enum Keys: String, CodingKey { case bot, entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        bot = try container.decode(Bot.self, forKey: .bot)
        entries = try container.decode([Lossy<Entry>].self, forKey: .entries).compactMap(\.value)
    }
}

/// One line of a conversation.
struct Entry: Identifiable, Equatable, Sendable {
    let id: String
    let at: Date
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case you(String)
        case bot(String)
        /// Another bot speaking into this one's chat.
        case from(author: String, text: String)
        case tool(ToolStep)
        case approval(Approval)
        case question(Question)
        case note(String)
        case failure(String)
        /// A kind a newer Mac sends that this app doesn't know yet. Its text, if any, shows as a note.
        case other(String?)
    }

    /// Who is speaking, for grouping bubbles into runs. Nil for everything that isn't a bubble.
    var speaker: String? {
        switch kind {
        case .you: "you"
        case .bot: "bot"
        case .from(let author, _): "from:\(author)"
        default: nil
        }
    }
}

extension Entry: Decodable {
    private enum Keys: String, CodingKey { case id, kind, at, text, author, tool, approval, question }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Date.self, forKey: .at)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        switch try container.decode(String.self, forKey: .kind) {
        case "you":
            kind = .you(text ?? "")
        case "bot":
            kind = .bot(text ?? "")
        case "from":
            kind = .from(author: try container.decodeIfPresent(String.self, forKey: .author) ?? "Another bot",
                         text: text ?? "")
        case "tool":
            kind = .tool(try container.decode(ToolStep.self, forKey: .tool))
        case "approval":
            kind = .approval(try container.decode(Approval.self, forKey: .approval))
        case "question":
            kind = .question(try container.decode(Question.self, forKey: .question))
        case "note":
            kind = .note(text ?? "")
        case "failure":
            kind = .failure(text ?? "Something went wrong.")
        default:
            kind = .other(text)
        }
    }
}

/// A tool the bot used, shown as a quiet one-line row: "ran `npm test`".
struct ToolStep: Decodable, Equatable, Sendable {
    let verb: String
    let target: String
    let failed: Bool
}

/// A bot asking to do something that needs the person's say-so.
struct Approval: Decodable, Equatable, Sendable {
    let id: String
    let tool: String
    /// What exactly will run or change: a command, a path. Shown in mono.
    let summary: String
    let reason: String
    /// Nil while it is still waiting for an answer.
    let decided: Decision?

    enum Decision: String, Decodable, Sendable {
        case allowed, alwaysAllowed, denied, expired
        /// A decision a newer Mac knows and this app doesn't. Still decided: no buttons.
        case other

        init(from decoder: Decoder) throws {
            self = Decision(rawValue: try String(from: decoder)) ?? .other
        }
    }

    /// What the bot wants, as the end of "Lead wants to …". The same words the web app uses.
    var action: String {
        switch tool {
        case "Bash", "shell": return "run a command"
        case "Edit", "MultiEdit": return "edit a file"
        case "Write": return "write a file"
        case "NotebookEdit": return "edit a notebook"
        case "Read": return "read a file"
        case "Glob": return "look through files"
        case "Grep": return "search files"
        case "WebFetch": return "open a web page"
        case "WebSearch": return "search the web"
        case "": return "do something"
        default:
            // "mcp__github__create_issue" reads as "use create issue".
            let parts = tool.components(separatedBy: "__")
            if tool.hasPrefix("mcp__"), parts.count >= 3 {
                return "use " + parts.dropFirst(2).joined(separator: "__").replacingOccurrences(of: "_", with: " ")
            }
            return "use \(tool)"
        }
    }
}

/// A question the bot asked, with the answers it offered.
struct Question: Decodable, Equatable, Sendable {
    let id: String
    let question: String
    let options: [String]
    /// Nil until someone answers, here or on the Mac.
    let answer: String?

    private enum Keys: String, CodingKey { case id, question, options, answer }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
    }
}

/// Decodes what it can and keeps nil for the rest, so one bad element never fails a whole list.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
