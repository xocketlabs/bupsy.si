import Foundation
import GRDB

/// A machine in the user's pool.
///
/// A user may own zero machines, which is the common case — see PLAN.md §3. Machines are rented
/// with the user's own boat key; nothing here is ours.
public struct MachineRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "machines"

    public var id: String
    public var name: String
    public var provider: String
    public var providerID: String?
    public var snapshotID: String?
    public var state: String
    public var size: String
    /// nil means auto-stop is disabled — the machine is meant to stay up for scheduled work.
    /// See `CreateOptions.alwaysOn`, and the bug it exists to prevent.
    public var ttlSeconds: Int?
    public var lastActiveAt: Date?
    public var vmSecondsMonthToDate: Double

    public init(id: String = UUID().uuidString, name: String, provider: String = "boat",
                providerID: String? = nil, snapshotID: String? = nil, state: String = "unknown",
                size: String = "small", ttlSeconds: Int? = nil, lastActiveAt: Date? = nil,
                vmSecondsMonthToDate: Double = 0) {
        self.id = id; self.name = name; self.provider = provider
        self.providerID = providerID; self.snapshotID = snapshotID; self.state = state
        self.size = size; self.ttlSeconds = ttlSeconds; self.lastActiveAt = lastActiveAt
        self.vmSecondsMonthToDate = vmSecondsMonthToDate
    }
}

public struct BotRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "bots"

    public var id: String
    public var name: String
    public var engine: String
    public var model: String?
    /// **Nullable on purpose.** A bot with no machine runs on the Mac and cannot run routines
    /// while it sleeps. That is the default, not a broken row, and every host-resolution path
    /// must handle it. PLAN.md §3.
    public var machineID: String?
    public var autonomy: String
    public var personaPrompt: String?
    public var workdir: String?
    public var avatarHue: Double
    public var createdAt: Date
    public var sortIndex: Int
    /// The folder the user filed this bot under, or nil for the ungrouped bots shown first.
    public var folder: String?
    /// Kept at the top of the sidebar, above the folders.
    public var pinned: Bool
    /// Out of the sidebar, but not deleted — it keeps its history, routines and conversation.
    public var hidden: Bool
    /// nil means never opened, which is what makes a new bot read as unread with no row written.
    public var lastReadAt: Date?
    /// A shape chosen by name, or nil to derive one from the hue.
    public var avatarShape: String?
    /// A palette position chosen by hand, or nil to derive one from the hue.
    public var avatarColour: Int?

    public init(id: String = UUID().uuidString, name: String, engine: String,
                model: String? = nil, machineID: String? = nil, autonomy: String = "ask",
                personaPrompt: String? = nil, workdir: String? = nil, avatarHue: Double = 0.5,
                createdAt: Date = Date(), sortIndex: Int = 0, folder: String? = nil,
                pinned: Bool = false, hidden: Bool = false, lastReadAt: Date? = nil,
                avatarShape: String? = nil, avatarColour: Int? = nil) {
        self.id = id; self.name = name; self.engine = engine; self.model = model
        self.machineID = machineID; self.autonomy = autonomy; self.personaPrompt = personaPrompt
        self.workdir = workdir; self.avatarHue = avatarHue; self.createdAt = createdAt
        self.sortIndex = sortIndex; self.folder = folder; self.pinned = pinned
        self.hidden = hidden; self.lastReadAt = lastReadAt
        self.avatarShape = avatarShape; self.avatarColour = avatarColour
    }
}

public struct ConversationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "conversations"

    public var id: String
    public var botID: String
    /// The engine's own resume handle, captured from `.started`. Kept even when a run fails,
    /// because a failed overnight routine is exactly what someone wants to retry.
    public var providerConversationID: String?
    public var title: String?
    public var lastEventAt: Date
    /// Resume handles are engine-specific, so a conversation belongs to a (bot, engine) pair.
    public var engine: String
    /// Set for the bot's session inside a group; nil for its session with you alone.
    public var groupID: String?

    public init(id: String = UUID().uuidString, botID: String, engine: String,
                providerConversationID: String? = nil, title: String? = nil,
                lastEventAt: Date = Date(), groupID: String? = nil) {
        self.id = id; self.botID = botID; self.engine = engine
        self.providerConversationID = providerConversationID
        self.title = title; self.lastEventAt = lastEventAt; self.groupID = groupID
    }
}

public struct RunRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "runs"

    public var id: String
    public var botID: String
    public var conversationID: String
    public var triggerID: String?
    /// "local" or "cloud:<machineID>" — which host actually ran it, for the audit trail.
    public var host: String
    public var status: String
    public var startedAt: Date
    public var endedAt: Date?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// API-equivalent cost as the engine reported it. Not what a subscriber paid.
    public var costUSD: Double?
    /// The group thread this run was a turn in, or nil for a bot's own thread.
    public var groupID: String?

    public init(id: String = UUID().uuidString, botID: String, conversationID: String,
                triggerID: String? = nil, host: String, status: String = "running",
                startedAt: Date = Date(), endedAt: Date? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
                groupID: String? = nil) {
        self.id = id; self.botID = botID; self.conversationID = conversationID
        self.triggerID = triggerID; self.host = host; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD
        self.groupID = groupID
    }
}

/// One canonical event. **Append-only** — see the trigger installed in `Schema`.
public struct EventRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "events"

    public var id: String
    public var runID: String
    public var seq: Int
    public var type: String
    public var payload: String
    public var at: Date

    public init(id: String = UUID().uuidString, runID: String, seq: Int,
                type: String, payload: String, at: Date = Date()) {
        self.id = id; self.runID = runID; self.seq = seq
        self.type = type; self.payload = payload; self.at = at
    }
}

public struct TriggerRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "triggers"

    public var id: String
    public var botID: String
    public var kind: String
    public var config: String
    public var enabled: Bool
    /// False means the schedule lives on the Mac and will not fire while it sleeps. The UI has
    /// to say so rather than imply a guarantee it cannot keep. PLAN.md §4.
    public var installedOnMachine: Bool
    public var nextFireAt: Date?

    public init(id: String = UUID().uuidString, botID: String, kind: String, config: String,
                enabled: Bool = true, installedOnMachine: Bool = false, nextFireAt: Date? = nil) {
        self.id = id; self.botID = botID; self.kind = kind; self.config = config
        self.enabled = enabled; self.installedOnMachine = installedOnMachine
        self.nextFireAt = nextFireAt
    }
}

/// Whether an engine is signed in **where**, and nothing more.
///
/// There is deliberately no token column here, and there never will be. Sign-in happens in a
/// terminal we render but do not read, and the credential lives in files owned by the user and
/// the CLI. `SchemaTests.noColumnCanHoldACredential` enforces this rather than trusting review.
public struct EngineLinkRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "engineLinks"

    public var id: String
    /// nil means this Mac's own sign-in rather than a machine's.
    public var machineID: String?
    public var engine: String
    public var status: String
    public var method: String?
    public var lastCheckedAt: Date

    public init(id: String = UUID().uuidString, machineID: String? = nil, engine: String,
                status: String, method: String? = nil, lastCheckedAt: Date = Date()) {
        self.id = id; self.machineID = machineID; self.engine = engine
        self.status = status; self.method = method; self.lastCheckedAt = lastCheckedAt
    }
}

/// One past run, condensed enough to list.
public struct RunSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let status: String
    /// "local", or "cloud:<machineID>" — which host actually did the work.
    public let host: String
    public let prompt: String?
    public let reply: String?
    public let toolCalls: Int
    /// As the engine reported them. nil when a run failed before it said anything, which is a
    /// different fact from zero and is shown differently.
    public let inputTokens: Int?
    public let outputTokens: Int?

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var succeeded: Bool { status == "finished" }

    public init(id: String, startedAt: Date, endedAt: Date?, status: String, host: String,
                prompt: String?, reply: String?, toolCalls: Int,
                inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.status = status; self.host = host
        self.prompt = prompt; self.reply = reply; self.toolCalls = toolCalls
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}


/// One bot's standing permission to message another, in one direction.
///
/// Deliberately not symmetric. "Scout may message Builder" says nothing about whether Builder may
/// message Scout, and collapsing the two would grant a direction nobody was asked about.
public struct BotLinkRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "bot_links"

    public var fromBotID: String
    public var toBotID: String
    /// false is a real answer, kept so a refusal is not re-asked on every attempt. A dialog that
    /// keeps coming back is a dialog people learn to dismiss without reading.
    public var allowed: Bool
    public var decidedAt: Date

    public init(fromBotID: String, toBotID: String, allowed: Bool, decidedAt: Date = Date()) {
        self.fromBotID = fromBotID; self.toBotID = toBotID
        self.allowed = allowed; self.decidedAt = decidedAt
    }
}


/// One bot's usage over a period, summed.
public struct BotUsage: Sendable, Equatable {
    public let botID: String
    public let runs: Int
    public let sentTokens: Int
    public let receivedTokens: Int
    /// nil when no run in the period reported a cost — Codex never does. Distinct from zero.
    public let costUSD: Double?

    public init(botID: String, runs: Int, sentTokens: Int, receivedTokens: Int, costUSD: Double?) {
        self.botID = botID; self.runs = runs; self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens; self.costUSD = costUSD
    }
}


/// A conversation with several bots in it.
public struct GroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "groups"

    public var id: String
    public var name: String
    /// Who answers a message that mentions nobody. nil if that bot was deleted.
    public var leadBotID: String?
    public var createdAt: Date
    public var sortIndex: Int
    public var pinned: Bool
    public var lastReadAt: Date?

    public init(id: String = UUID().uuidString, name: String, leadBotID: String?,
                createdAt: Date = Date(), sortIndex: Int = 0, pinned: Bool = false,
                lastReadAt: Date? = nil) {
        self.id = id; self.name = name; self.leadBotID = leadBotID; self.createdAt = createdAt
        self.sortIndex = sortIndex; self.pinned = pinned; self.lastReadAt = lastReadAt
    }
}

/// One message in a group thread, from the person or from a bot.
public struct GroupMessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "group_messages"
    public static let userAuthor = "user"

    public var id: String
    public var groupID: String
    public var author: String
    public var authorName: String
    public var text: String
    public var at: Date
    /// The run that produced it, for a bot's message — the link back to the audited events.
    public var runID: String?

    public var isFromUser: Bool { author == Self.userAuthor }

    public init(id: String = UUID().uuidString, groupID: String, author: String,
                authorName: String, text: String, at: Date = Date(), runID: String? = nil) {
        self.id = id; self.groupID = groupID; self.author = author; self.authorName = authorName
        self.text = text; self.at = at; self.runID = runID
    }
}
