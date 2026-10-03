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
        // Foreign keys are OFF while migrating, then turned on afterwards.
        //
        // This is GRDB's own recommendation, and it is load-bearing here rather than tidiness. A
        // database that already contains an orphaned row — a conversation pointing at a bot
        // deleted back when the cascade was not enforced — fails the deferred check that runs
        // after a schema change. The whole migration then aborts, `Store` throws, and the app
        // falls back to starter bots: every existing bot silently disappears from the UI while
        // sitting untouched on disk. Measured on a real database, which had exactly one such row.
        //
        // So: migrate without the check, clear the orphans a migration cannot reach, and only
        // then enforce. Enforcement from that point on is what stops new ones appearing.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)

        try Self.migrator.migrate(queue)
        try Self.removeOrphans(in: queue)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        database = queue
    }

    /// Deletes rows whose bot no longer exists.
    ///
    /// Not a migration, because it has to run on every open: a migration records itself as done
    /// and would never run again, and this is cleaning up after a historical bug whose damage can
    /// already be present in any state. Cheap — these are indexed columns and the result is
    /// almost always zero.
    static func removeOrphans(in queue: DatabaseQueue) throws {
        try queue.write { db in
            for table in ["conversations", "runs", "routines", "objectives"] {
                guard try db.tableExists(table) else { continue }
                try db.execute(sql: """
                    DELETE FROM "\(table)"
                    WHERE botID IS NOT NULL
                      AND botID NOT IN (SELECT id FROM bots)
                    """)
            }

            // Events hang off runs, not bots, so the sweep above never reached them. Found on a
            // real database after the first version of this shipped: six events from an early
            // conversation whose run had gone, still sitting in the log. Last, because removing
            // runs above can orphan more of them.
            if try db.tableExists("events") {
                try db.execute(sql: """
                    DELETE FROM events
                    WHERE runID NOT IN (SELECT id FROM runs)
                    """)
            }
        }
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

        // Switching a bot between engines must not lose its history, and must not try to resume
        // a Claude session id inside Codex — the handles are not interchangeable. So a
        // conversation belongs to a (bot, engine) pair rather than a bot.
        migrator.registerMigration("v2-conversations-per-engine") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "engine", .text).notNull().defaults(to: "claude")
            }
            try db.create(
                index: "conversations_bot_engine", on: "conversations",
                columns: ["botID", "engine"])
        }

        // Bots are filed into folders the user names, because a flat list stops being a list and
        // starts being a search problem somewhere around a dozen bots. Nullable: a bot with no
        // folder is the normal case and is shown first, not hidden under "Uncategorised".
        migrator.registerMigration("v3-bot-folders") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "folder", .text)
            }
        }

        // Pinning is per bot rather than a separate list, so a pinned bot cannot end up in the
        // pinned list and nowhere else — the usual way these two get out of step.
        migrator.registerMigration("v4-pinned-bots") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }
        }

        // Hiding and unread, both per bot.
        //
        // `hidden` is separate from deleting: a bot you are done with for now still owns its
        // history, its routines and its conversation id, and "get it out of my sidebar" must not
        // be a destructive act dressed up as tidying.
        //
        // `lastReadAt` is nullable and means "never opened", which is how a brand-new bot reads as
        // unread without anything having to write a row at creation time.
        migrator.registerMigration("v5-hidden-and-unread") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "hidden", .boolean).notNull().defaults(to: false)
                t.add(column: "lastReadAt", .datetime)
            }
        }

        // Who may talk to whom, decided once per ordered pair.
        //
        // One bot messaging another routes around the approval gate: the receiving bot acts on
        // instructions a human never read. So first contact asks, and the answer is remembered
        // per (from, to) — not per bot. "Scout may message Builder" says nothing about whether
        // Builder may message Scout, and treating it as symmetric would grant a direction nobody
        // approved.
        //
        // A refusal is stored too. Re-asking every time something is denied trains people to
        // click through the dialog, which is how a gate stops being one.
        migrator.registerMigration("v6-bot-links") { db in
            try db.create(table: "bot_links") { t in
                t.primaryKey {
                    t.column("fromBotID", .text).references("bots", onDelete: .cascade)
                    t.column("toBotID", .text).references("bots", onDelete: .cascade)
                }
                t.column("allowed", .boolean).notNull()
                t.column("decidedAt", .datetime).notNull()
            }
        }

        // A face someone chose, rather than the one derived from the name.
        //
        // Both nullable, and nil means "derive it as before", so every existing bot keeps exactly
        // the face it already has. The shape is stored by name rather than by position, so adding
        // or reordering shapes later never silently changes a face someone picked.
        migrator.registerMigration("v7-chosen-avatars") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "avatarShape", .text)
                t.add(column: "avatarColour", .integer)
            }
        }

        // What a run would have cost at API rates, as the engine itself reported it.
        //
        // Nullable: Codex reports no figure at all, and a run that failed before its result line
        // has none either. Neither is zero, and showing $0.00 for them would be a false statement.
        migrator.registerMigration("v8-run-cost") { db in
            try db.alter(table: "runs") { t in
                t.add(column: "costUSD", .double)
            }
        }

        // Group threads: several bots in one conversation.
        //
        // The visible thread lives in its own table, because it interleaves bots and so cannot be
        // any one bot's history. Each bot's turn is still an ordinary run — audited, counted in its
        // usage — marked with the group it belongs to, so it does not leak into that bot's
        // one-to-one thread.
        migrator.registerMigration("v9-group-threads") { db in
            try db.create(table: "groups") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                // setNull, never cascade: deleting a bot must not delete the group it led.
                t.column("leadBotID", .text).references("bots", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("lastReadAt", .datetime)
            }
            try db.create(table: "group_members") { t in
                t.primaryKey {
                    t.column("groupID", .text).references("groups", onDelete: .cascade)
                    t.column("botID", .text).references("bots", onDelete: .cascade)
                }
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "group_messages") { t in
                t.primaryKey("id", .text)
                t.column("groupID", .text).notNull().references("groups", onDelete: .cascade)
                // "user", or the bot's id. Not a foreign key: a message must outlive the bot that
                // wrote it, as a transcript does. The name is kept beside it for the same reason.
                t.column("author", .text).notNull()
                t.column("authorName", .text).notNull()
                t.column("text", .text).notNull()
                t.column("at", .datetime).notNull()
                t.column("runID", .text)
            }
            try db.create(index: "group_messages_by_group", on: "group_messages",
                          columns: ["groupID", "at"])
            try db.alter(table: "runs") { t in
                t.add(column: "groupID", .text)
            }
            // A bot's engine session in a group is separate from its session with you alone.
            // Resuming the one-to-one session inside a group would hand the group a conversation
            // it was never part of, and the other way round.
            try db.alter(table: "conversations") { t in
                t.add(column: "groupID", .text)
            }
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

    // MARK: - Bot-to-bot links

    public func botLinks() throws -> [BotLinkRecord] {
        try database.read { db in try BotLinkRecord.fetchAll(db) }
    }

    public func save(_ link: BotLinkRecord) throws {
        // `PersistableRecord`, not `MutablePersistableRecord`: the primary key is the pair of bot
        // ids rather than something the database assigns, so saving never writes back.
        try database.write { db in try link.save(db) }
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

    /// The bot's thread **for this engine**. Switching engines gives a bot a separate thread,
    /// and switching back returns to the one it had.
    /// The bot's session on an engine — its own, or the one it has inside a particular group.
    public func conversation(forBot botID: String, engine: String,
                             group groupID: String? = nil) throws -> ConversationRecord? {
        try database.read { db in
            try ConversationRecord
                .filter(Column("botID") == botID && Column("engine") == engine
                        && Column("groupID") == groupID)
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

    /// Runs with a one-line summary, for a history view.
    ///
    /// The transcript of an unattended run is already on disk; without something that reads it
    /// back, work done overnight is invisible even after it happened — which is most of the
    /// value of having done it.
    public func recentRuns(forBot botID: String, limit: Int = 30) throws -> [RunSummary] {
        try database.read { db in
            let runs = try RunRecord
                .filter(Column("botID") == botID)
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)

            return try runs.map { run in
                let events = try EventRecord
                    .filter(Column("runID") == run.id)
                    .order(Column("seq"))
                    .fetchAll(db)

                let prompt = events.first { $0.type == "userMessage" }
                let reply = events.last { $0.type == "text" }
                let tools = events.filter { $0.type == "toolCall" }.count

                return RunSummary(
                    id: run.id,
                    startedAt: run.startedAt,
                    endedAt: run.endedAt,
                    status: run.status,
                    host: run.host,
                    prompt: prompt.flatMap(Self.text(in:)),
                    reply: reply.flatMap(Self.text(in:)),
                    toolCalls: tools,
                    inputTokens: run.inputTokens,
                    outputTokens: run.outputTokens)
            }
        }
    }

    /// Usage per bot since a moment, for the usage page.
    ///
    /// Summed in SQL rather than by loading every run: a busy roster has thousands of runs and the
    /// page only ever needs one row per bot.
    public func usageByBot(since start: Date = .distantPast) throws -> [BotUsage] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT botID,
                       COUNT(*)            AS runs,
                       SUM(inputTokens)    AS sent,
                       SUM(outputTokens)   AS received,
                       SUM(costUSD)        AS cost,
                       COUNT(costUSD)      AS costed
                FROM runs
                WHERE startedAt >= ?
                GROUP BY botID
                """, arguments: [start])
            .map { row in
                BotUsage(botID: row["botID"], runs: row["runs"],
                         sentTokens: row["sent"] ?? 0, receivedTokens: row["received"] ?? 0,
                         costUSD: (row["costed"] as Int? ?? 0) > 0 ? row["cost"] : nil)
            }
        }
    }

    private static func text(in record: EventRecord) -> String? {
        guard let data = record.payload.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return fields["text"]
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
    /// The most recent `limit` events for a bot, oldest first.
    ///
    /// Newest-first then reversed, not oldest-first then limited. The latter returned the *first*
    /// 500 events a bot ever produced, so once a thread grew past that its recent conversation —
    /// the part anyone opens a thread to see — stopped loading at all.
    public func transcript(forBot botID: String, limit: Int = 500) throws -> [EventRecord] {
        try database.read { db in
            try EventRecord
                .joining(required: EventRecord.belongsTo(RunRecord.self, using: ForeignKey(["runID"]))
                    .filter(Column("botID") == botID)
                    // Its turns in group threads belong to those threads, not this one.
                    .filter(Column("groupID") == nil))
                .order(Column("at").desc, Column("seq").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }
    }

    // MARK: - Groups

    public func groups() throws -> [GroupRecord] {
        try database.read { db in
            try GroupRecord.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ group: GroupRecord) throws {
        try database.write { db in try group.save(db) }
    }

    public func deleteGroup(id: String) throws {
        _ = try database.write { db in try GroupRecord.deleteOne(db, key: id) }
    }

    /// Members in the order they were added, which is the order they are shown.
    public func members(ofGroup groupID: String) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT botID FROM group_members WHERE groupID = ? ORDER BY sortIndex
                """, arguments: [groupID])
        }
    }

    /// Replaces the membership wholesale, in one transaction, so a group is never seen half-edited.
    public func setMembers(ofGroup groupID: String, to botIDs: [String]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM group_members WHERE groupID = ?", arguments: [groupID])
            for (index, botID) in botIDs.enumerated() {
                try db.execute(sql: """
                    INSERT INTO group_members (groupID, botID, sortIndex) VALUES (?, ?, ?)
                    """, arguments: [groupID, botID, index])
            }
        }
    }

    /// The most recent `limit` messages, oldest first — the same newest-then-reverse shape as a
    /// bot's transcript, for the same reason.
    public func messages(inGroup groupID: String, limit: Int = 500) throws -> [GroupMessageRecord] {
        try database.read { db in
            try GroupMessageRecord
                .filter(Column("groupID") == groupID)
                .order(Column("at").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }
    }

    public func append(_ message: GroupMessageRecord) throws {
        try database.write { db in try message.insert(db) }
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

extension Store {
    /// Objectives share the `triggers` table with routines, distinguished by `kind`. They are the
    /// same shape of thing — something a bot does on a schedule — and a separate table would mean
    /// two code paths for one concept.
    public func objectives() throws -> [Objective] {
        try triggers().filter { $0.kind == "objective" }.compactMap(Objective.init(record:))
    }

    public func save(_ objective: Objective) throws {
        try save(objective.record())
    }

    public func deleteObjective(id: String) throws {
        try deleteRoutine(id: id)
    }
}

extension Objective {
    func record() -> TriggerRecord {
        var config: [String: Any] = [
            "goal": goal, "doneWhen": doneWhen, "cron": checkCron,
            "tier": tier.rawValue, "notes": notes,
            "lastCheckedAt": lastCheckedAt?.timeIntervalSince1970 ?? 0,
        ]
        if let lastOutcome, let data = try? JSONEncoder().encode(lastOutcome),
           let encoded = String(data: data, encoding: .utf8) {
            config["lastOutcome"] = encoded
        }
        let json = (try? String(
            data: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            encoding: .utf8)) ?? "{}"
        return TriggerRecord(
            id: id, botID: botID, kind: "objective", config: json, enabled: enabled,
            installedOnMachine: tier == .machine,
            nextFireAt: (try? CronExpression(checkCron))?.nextFire(after: Date()))
    }

    init?(record: TriggerRecord) {
        guard let data = record.config.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = config["goal"] as? String,
              let doneWhen = config["doneWhen"] as? String
        else { return nil }

        let checked = (config["lastCheckedAt"] as? NSNumber)?.doubleValue ?? 0
        let outcome = (config["lastOutcome"] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ObjectiveOutcome.self, from: $0) }

        self.init(
            id: record.id, botID: record.botID, goal: goal, doneWhen: doneWhen,
            checkCron: config["cron"] as? String ?? "0 9-18 * * 1-5",
            enabled: record.enabled,
            tier: Routine.Tier(rawValue: config["tier"] as? String ?? "") ?? .launchAgent,
            notes: config["notes"] as? String ?? "",
            lastCheckedAt: checked > 0 ? Date(timeIntervalSince1970: checked) : nil,
            lastOutcome: outcome)
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
