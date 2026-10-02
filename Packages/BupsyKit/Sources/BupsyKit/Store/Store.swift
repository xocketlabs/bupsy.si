import Foundation
import GRDB

/// Local persistence. SQLite on disk, explicit migrations, no network.
///
/// Everything a user has is here or in files on their own machines. There is no server copy, and
/// deliberately no column anywhere that could hold a model or connector credential.
public struct Store: Sendable {
    let database: DatabaseQueue

    /// `~/Library/Application Support/si.bupsy/bupsy.sqlite`
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("si.bupsy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("bupsy.sqlite")
    }

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(database)
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> Store {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return Store(database: queue)
    }

    private init(database: DatabaseQueue) { self.database = database }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "machines") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("providerID", .text)
                t.column("snapshotID", .text)
                t.column("state", .text).notNull()
                t.column("size", .text).notNull()
                t.column("ttlSeconds", .integer)
                t.column("lastActiveAt", .datetime)
                t.column("vmSecondsMonthToDate", .double).notNull().defaults(to: 0)
            }

            try db.create(table: "bots") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("engine", .text).notNull()
                t.column("model", .text)
                // A bot losing its machine must not delete the bot. setNull, never cascade.
                t.column("machineID", .text).references("machines", onDelete: .setNull)
                t.column("autonomy", .text).notNull().defaults(to: "ask")
                t.column("personaPrompt", .text)
                t.column("workdir", .text)
                t.column("avatarHue", .double).notNull().defaults(to: 0.5)
                t.column("createdAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "conversations") { t in
                t.primaryKey("id", .text)
                t.column("botID", .text).notNull().references("bots", onDelete: .cascade)
                t.column("providerConversationID", .text)
                t.column("title", .text)
                t.column("lastEventAt", .datetime).notNull()
            }

            try db.create(table: "runs") { t in
                t.primaryKey("id", .text)
                t.column("botID", .text).notNull().references("bots", onDelete: .cascade)
                t.column("conversationID", .text).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("triggerID", .text)
                t.column("host", .text).notNull()
                t.column("status", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
            }

            try db.create(table: "events") { t in
                t.primaryKey("id", .text)
                t.column("runID", .text).notNull().references("runs", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("at", .datetime).notNull()
            }
            try db.create(index: "events_run_seq", on: "events", columns: ["runID", "seq"],
                          unique: true)

            // The audit trail only means something if it cannot be rewritten. SQLite will not
            // enforce append-only by itself, so say it in the schema: a transcript that can be
            // quietly edited is not evidence of what an agent did.
            try db.execute(sql: """
                CREATE TRIGGER events_are_append_only
                BEFORE UPDATE ON events
                BEGIN
                    SELECT RAISE(ABORT, 'events are append-only');
                END;
                """)

            try db.create(table: "triggers") { t in
                t.primaryKey("id", .text)
                t.column("botID", .text).notNull().references("bots", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("config", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("installedOnMachine", .boolean).notNull().defaults(to: false)
                t.column("nextFireAt", .datetime)
            }

            // Status only. If a token ever appears in this table, the product has broken the one
            // promise it cannot break. SchemaTests enforces it.
            try db.create(table: "engineLinks") { t in
                t.primaryKey("id", .text)
                t.column("machineID", .text).references("machines", onDelete: .cascade)
                t.column("engine", .text).notNull()
                t.column("status", .text).notNull()
                t.column("method", .text)
                t.column("lastCheckedAt", .datetime).notNull()
            }
            try db.create(index: "engineLinks_scope", on: "engineLinks",
                          columns: ["machineID", "engine"], unique: true)
        }

        return migrator
    }

    // MARK: - Bots and machines

    public func bots() throws -> [BotRecord] {
        try database.read { db in
            try BotRecord.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ bot: BotRecord) throws {
        var bot = bot
        try database.write { db in try bot.save(db) }
    }

    public func deleteBot(id: String) throws {
        _ = try database.write { db in try BotRecord.deleteOne(db, key: id) }
    }

    public func machines() throws -> [MachineRecord] {
        try database.read { db in try MachineRecord.order(Column("name")).fetchAll(db) }
    }

    public func save(_ machine: MachineRecord) throws {
        var machine = machine
        try database.write { db in try machine.save(db) }
    }

    /// Removing a machine leaves its bots alive and machine-less rather than deleting them.
    /// Losing a rented machine should never lose a bot's identity or its transcripts.
    public func deleteMachine(id: String) throws {
        _ = try database.write { db in try MachineRecord.deleteOne(db, key: id) }
    }

    // MARK: - Conversations, runs, events

    public func conversation(forBot botID: String) throws -> ConversationRecord? {
        try database.read { db in
            try ConversationRecord
                .filter(Column("botID") == botID)
                .order(Column("lastEventAt").desc)
                .fetchOne(db)
        }
    }

    public func save(_ conversation: ConversationRecord) throws {
        var conversation = conversation
        try database.write { db in try conversation.save(db) }
    }

    public func save(_ run: RunRecord) throws {
        var run = run
        try database.write { db in try run.save(db) }
    }

    public func runs(forBot botID: String, limit: Int = 50) throws -> [RunRecord] {
        try database.read { db in
            try RunRecord
                .filter(Column("botID") == botID)
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Appends events. Idempotent on `(runID, seq)` so reconciling the same machine twice —
    /// which happens whenever a Mac wakes and re-reads a routine's log — cannot duplicate them.
    public func append(_ events: [EventRecord]) throws {
        try database.write { db in
            for var event in events {
                try event.insert(db, onConflict: .ignore)
            }
        }
    }

    public func events(forRun runID: String) throws -> [EventRecord] {
        try database.read { db in
            try EventRecord
                .filter(Column("runID") == runID)
                .order(Column("seq"))
                .fetchAll(db)
        }
    }

    /// The whole transcript for a bot, oldest first, across every run.
    public func transcript(forBot botID: String, limit: Int = 500) throws -> [EventRecord] {
        try database.read { db in
            try EventRecord
                .joining(required: EventRecord.belongsTo(RunRecord.self, using: ForeignKey(["runID"]))
                    .filter(Column("botID") == botID))
                .order(Column("at"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Engine links

    public func engineLinks() throws -> [EngineLinkRecord] {
        try database.read { db in try EngineLinkRecord.fetchAll(db) }
    }

    public func save(_ link: EngineLinkRecord) throws {
        var link = link
        try database.write { db in try link.save(db) }
    }

    // MARK: - Triggers

    public func triggers(enabledOnly: Bool = false) throws -> [TriggerRecord] {
        try database.read { db in
            let request = enabledOnly
                ? TriggerRecord.filter(Column("enabled") == true)
                : TriggerRecord.all()
            return try request.order(Column("nextFireAt")).fetchAll(db)
        }
    }

    public func save(_ trigger: TriggerRecord) throws {
        var trigger = trigger
        try database.write { db in try trigger.save(db) }
    }

    // MARK: - Routines
    //
    // Stored in `triggers`, since a routine is the cron kind of trigger. Email and webhook
    // triggers will share the table rather than needing one of their own.

    public func routines() throws -> [Routine] {
        try triggers().filter { $0.kind == "cron" }.compactMap(Routine.init(record:))
    }

    public func save(_ routine: Routine) throws {
        try save(routine.record())
    }

    public func deleteRoutine(id: String) throws {
        _ = try database.write { db in try TriggerRecord.deleteOne(db, key: id) }
    }
}

extension Routine {
    /// Packs the routine-specific fields into the trigger's `config` blob, so adding a field
    /// later needs no migration.
    func record() -> TriggerRecord {
        let config: [String: Any] = [
            "name": name, "prompt": prompt, "cron": cron, "tier": tier.rawValue,
            "lastFiredAt": lastFiredAt?.timeIntervalSince1970 ?? 0,
        ]
        let encoded = (try? String(
            data: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            encoding: .utf8)) ?? "{}"
        return TriggerRecord(
            id: id, botID: botID, kind: "cron", config: encoded, enabled: enabled,
            installedOnMachine: tier == .machine,
            nextFireAt: (try? CronExpression(cron))?.nextFire(after: Date()))
    }

    init?(record: TriggerRecord) {
        guard let data = record.config.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = config["name"] as? String,
              let prompt = config["prompt"] as? String,
              let cron = config["cron"] as? String
        else { return nil }

        let fired = (config["lastFiredAt"] as? NSNumber)?.doubleValue ?? 0
        self.init(
            id: record.id, botID: record.botID, name: name, prompt: prompt, cron: cron,
            enabled: record.enabled,
            tier: Tier(rawValue: config["tier"] as? String ?? "") ?? .appOpen,
            lastFiredAt: fired > 0 ? Date(timeIntervalSince1970: fired) : nil)
    }
}
