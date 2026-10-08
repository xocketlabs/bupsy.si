import Foundation

// What the Mac's remote API sends, decoded once at the edge so views only ever see typed values.
// The shapes are defined by `RemoteAccess` in the Mac app; this file is the phone's half of that
// contract.
//
// Decoding is forgiving wherever the Mac might grow. An unknown mood reads as idle, an unknown
// kind of entry still shows its text, and one entry this app can't read is dropped rather than
// blanking the whole chat. A newer Mac should never leave an older phone with an empty screen.

/// One bot, as the list and a chat's header show it.
struct Bot: Identifiable, Hashable, Sendable {
    /// Which Mac it lives on, and its id there. The JSON carries only the bot's own id; the client
    /// that fetched it fills in its Mac (see `RemoteClient`), so no bot leaves the edge without one.
    private(set) var ref: BotRef
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
    /// The face the Mac draws it with. Nil from a Mac on an older Bupsy. The phone keeps to the
    /// colour and initial for now; this is decoded so drawing faces later needs no server change.
    let face: Face?

    var id: BotRef { ref }

    init(ref: BotRef, name: String, role: String? = nil, section: String? = nil, colour: String = "",
         mood: Mood = .idle, running: Bool = false, needsYou: Bool = false, unread: Bool = false,
         preview: String? = nil, face: Face? = nil) {
        self.ref = ref
        self.name = name
        self.role = role
        self.section = section
        self.colour = colour
        self.mood = mood
        self.running = running
        self.needsYou = needsYou
        self.unread = unread
        self.preview = preview
        self.face = face
    }

    /// The same bot, marked as living on the Mac with this id.
    func on(_ macID: String) -> Bot {
        var bot = self
        bot.ref = BotRef(macID: macID, botID: ref.botID)
        return bot
    }

    enum Mood: String, Decodable, Sendable {
        case idle, working, waitingForYou, done, sleeping, failed

        init(from decoder: Decoder) throws {
            self = Mood(rawValue: try String(from: decoder)) ?? .idle
        }
    }

    /// `shape` is a name the Mac knows, `colour` a packed RGB integer, `hue` from 0 to 1.
    struct Face: Decodable, Hashable, Sendable {
        let shape: String
        let colour: Int
        let hue: Double
    }

    /// A stand-in until the Mac answers, so a chat opened from a notification has a header at once.
    static func placeholder(_ ref: BotRef) -> Bot {
        Bot(ref: ref, name: "")
    }
}

extension Bot: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, role, section, colour, mood, running, needsYou, unread, preview, face
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        ref = BotRef(macID: "", botID: try container.decode(String.self, forKey: .id))
        name = try container.decode(String.self, forKey: .name)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        section = try container.decodeIfPresent(String.self, forKey: .section)
        colour = try container.decode(String.self, forKey: .colour)
        mood = try container.decode(Mood.self, forKey: .mood)
        running = try container.decode(Bool.self, forKey: .running)
        needsYou = try container.decode(Bool.self, forKey: .needsYou)
        unread = try container.decode(Bool.self, forKey: .unread)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        // A face this app can't read is no reason to lose the bot.
        face = (try? container.decodeIfPresent(Face.self, forKey: .face)) ?? nil
    }
}

struct BotList: Decodable, Sendable {
    var bots: [Bot]
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
    /// "laptop" or "desktop". Nil from a Mac on an older Bupsy.
    let kind: String?
}

/// A bot and the latest of its conversation, oldest first.
struct BotThread: Decodable, Sendable {
    var bot: Bot
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
