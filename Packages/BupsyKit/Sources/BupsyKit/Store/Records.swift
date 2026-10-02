import Foundation
import GRDB

/// A machine in the user's pool.
///
/// A user may own zero machines, which is the common case — see PLAN.md §3. Machines are rented
/// with the user's own boat key; nothing here is ours.
public struct MachineRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
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

public struct BotRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
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

    public init(id: String = UUID().uuidString, name: String, engine: String,
                model: String? = nil, machineID: String? = nil, autonomy: String = "ask",
                personaPrompt: String? = nil, workdir: String? = nil, avatarHue: Double = 0.5,
                createdAt: Date = Date(), sortIndex: Int = 0) {
        self.id = id; self.name = name; self.engine = engine; self.model = model
        self.machineID = machineID; self.autonomy = autonomy; self.personaPrompt = personaPrompt
        self.workdir = workdir; self.avatarHue = avatarHue; self.createdAt = createdAt
        self.sortIndex = sortIndex
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

    public init(id: String = UUID().uuidString, botID: String,
                providerConversationID: String? = nil, title: String? = nil,
                lastEventAt: Date = Date()) {
        self.id = id; self.botID = botID
        self.providerConversationID = providerConversationID
        self.title = title; self.lastEventAt = lastEventAt
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

    public init(id: String = UUID().uuidString, botID: String, conversationID: String,
                triggerID: String? = nil, host: String, status: String = "running",
                startedAt: Date = Date(), endedAt: Date? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.id = id; self.botID = botID; self.conversationID = conversationID
        self.triggerID = triggerID; self.host = host; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
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
