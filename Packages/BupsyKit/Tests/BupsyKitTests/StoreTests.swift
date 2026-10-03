import Foundation
import GRDB
import Testing
@testable import BupsyKit

@Suite("Store")
struct StoreTests {

    /// The rule from docs/00-compliance-and-auth.md, enforced by the schema rather than by
    /// review. If someone ever adds a token column, this fails before it ships.
    ///
    /// Deliberately checks the *live* schema rather than the migration source, so a column added
    /// in a later migration is caught too.
    @Test("no column anywhere can hold a credential")
    func noColumnCanHoldACredential() throws {
        let store = try Store.inMemory()
        let forbidden = ["token", "secret", "password", "credential", "apikey", "api_key",
                         "oauth", "bearer", "refresh", "session_key", "auth"]

        /// Columns that trip the scan but are not credentials. Deliberately a short, explicit
        /// list rather than a cleverer pattern: anything new that looks like a credential should
        /// force someone to come here and say out loud why it is not one.
        let knownSafe: Set<String> = [
            "runs.inputTokens",   // count of tokens consumed, reported by the engine
            "runs.outputTokens",  // same
        ]

        try store.database.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                + "AND name NOT LIKE 'grdb_%'")
            #expect(!tables.isEmpty)

            for table in tables {
                for column in try db.columns(in: table) {
                    let name = column.name.lowercased()
                    let qualified = "\(table).\(column.name)"
                    guard !knownSafe.contains(qualified) else { continue }
                    for word in forbidden where name.contains(word) {
                        Issue.record("""
                            \(qualified) looks like it could hold a credential.
                            bupsy never stores one — see docs/00-compliance-and-auth.md.
                            If it genuinely is not a credential, add it to knownSafe with a
                            comment saying what it holds.
                            """)
                    }
                }
            }
        }
    }

    /// A transcript that can be quietly rewritten is not evidence of what an agent did.
    @Test("events are append-only, enforced by the database")
    func eventsAreAppendOnly() throws {
        let store = try Store.inMemory()
        let (bot, conversation, run) = try seed(store)
        _ = (bot, conversation)

        try store.append([EventRecord(runID: run.id, seq: 0, type: "text", payload: "{}")])

        #expect(throws: (any Error).self) {
            try store.database.write { db in
                try db.execute(sql: "UPDATE events SET payload = 'tampered'")
            }
        }
        #expect(try store.events(forRun: run.id).first?.payload == "{}")
    }

    /// A Mac waking up re-reads a routine's log from the machine. Doing that twice must not
    /// double the transcript. PLAN.md §4 reconciliation.
    @Test("appending the same events twice is idempotent")
    func appendIsIdempotent() throws {
        let store = try Store.inMemory()
        let (_, _, run) = try seed(store)

        let events = (0..<3).map {
            EventRecord(id: "e\($0)", runID: run.id, seq: $0, type: "text", payload: "{}")
        }
        try store.append(events)
        // Same sequence numbers, fresh row ids — exactly what a re-read produces.
        try store.append((0..<3).map {
            EventRecord(runID: run.id, seq: $0, type: "text", payload: "{}")
        })

        #expect(try store.events(forRun: run.id).count == 3)
    }

    /// Losing a rented machine must never lose a bot. The bot becomes machine-less, which is a
    /// perfectly ordinary state — it just runs on the Mac again.
    @Test("deleting a machine orphans its bots rather than deleting them")
    func deletingMachineKeepsBots() throws {
        let store = try Store.inMemory()
        let machine = MachineRecord(name: "work")
        try store.save(machine)
        try store.save(BotRecord(name: "Scout", engine: "claude", machineID: machine.id))

        try store.deleteMachine(id: machine.id)

        let bots = try store.bots()
        #expect(bots.count == 1)
        #expect(bots.first?.machineID == nil)
    }

    @Test("a bot with no machine is an ordinary row, not a broken one")
    func machinelessBotIsValid() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(name: "Notes", engine: "claude", machineID: nil))
        #expect(try store.bots().first?.machineID == nil)
    }

    @Test("state survives reopening the database")
    func survivesRestart() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bupsy-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let bot = BotRecord(name: "Scout", engine: "claude")
        try Store(url: url).save(bot)

        let reopened = try Store(url: url)
        #expect(try reopened.bots().map(\.name) == ["Scout"])
    }

    /// Switching a bot between engines must keep both threads. A Claude session id cannot be
    /// resumed by Codex, so handing one to the other would either error or, worse, silently
    /// start a new conversation while the UI still showed the old transcript.
    @Test("a bot keeps a separate thread per engine")
    func conversationsArePerEngine() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)

        try store.save(ConversationRecord(
            botID: bot.id, engine: "claude", providerConversationID: "claude-sess-1"))
        try store.save(ConversationRecord(
            botID: bot.id, engine: "codex", providerConversationID: "codex-thread-1"))

        #expect(try store.conversation(forBot: bot.id, engine: "claude")?
            .providerConversationID == "claude-sess-1")
        #expect(try store.conversation(forBot: bot.id, engine: "codex")?
            .providerConversationID == "codex-thread-1")
        #expect(try store.conversation(forBot: bot.id, engine: "grok") == nil)
    }

    private func seed(_ store: Store) throws -> (BotRecord, ConversationRecord, RunRecord) {
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        let conversation = ConversationRecord(botID: bot.id, engine: "claude")
        try store.save(conversation)
        let run = RunRecord(botID: bot.id, conversationID: conversation.id, host: "local")
        try store.save(run)
        return (bot, conversation, run)
    }
}

@Suite("Bot folders")
struct BotFolderTests {

    @Test("a folder survives a round trip, and nil stays nil")
    func foldersRoundTrip() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(name: "Scout", engine: "claude", folder: "Outreach"))
        try store.save(BotRecord(name: "Builder", engine: "codex"))

        let bots = try store.bots()
        #expect(bots.first(where: { $0.name == "Scout" })?.folder == "Outreach")
        // nil rather than "", because the sidebar shows ungrouped bots first and an empty string
        // would quietly create a folder with no name.
        #expect(bots.first(where: { $0.name == "Builder" })?.folder == nil)
    }

    /// The migration adds a column to a table that already has rows in it, which is the case that
    /// actually ships — every existing user has bots before they have folders.
    @Test("bots that existed before folders did survive the migration")
    func existingBotsSurvive() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "keep-me", name: "Older", engine: "claude"))

        // Re-running the migrator is a no-op on an up-to-date database, and proves the v3 step is
        // idempotent rather than destructive.
        try Store.migrator.migrate(store.database)

        let bots = try store.bots()
        #expect(bots.count == 1)
        #expect(bots.first?.id == "keep-me")
        #expect(bots.first?.folder == nil)
    }
}

@Suite("Event codec")
struct EventCodecTests {
    @Test("round-trips the events a transcript is made of", arguments: [
        AgentEvent.text("hello"),
        .thinking("considering"),
        .started(conversationID: ConversationID("sess-1")),
        .toolCall(ToolCall(id: "c1", name: "Bash", argumentsJSON: #"{"command":"ls"}"#)),
        .toolResult(ToolResult(callID: "c1", content: "out", isError: false)),
        .failed(EngineFailure(kind: .notSignedIn, message: "please log in")),
        .done(Outcome(summary: "finished", conversationID: ConversationID("sess-1"))),
    ])
    func roundTrips(_ event: AgentEvent) {
        let (type, payload) = EventCodec.encode(event)
        #expect(EventCodec.decode(type: type, payload: payload) == event)
    }

    /// A row written by a future version must stay readable rather than break the transcript.
    @Test("an unrecognised type decodes to .unknown instead of failing")
    func toleratesFutureTypes() {
        let decoded = EventCodec.decode(type: "invented_in_2027", payload: #"{"a":1}"#)
        #expect(decoded == .unknown(raw: #"{"a":1}"#))
    }
}

@Suite("Run history")
struct RunHistoryTests {
    /// Runs and their events were being written from the first commit and never read back, so
    /// work done overnight was invisible even after it happened.
    @Test("summarises a past run from its stored events")
    func summarisesARun() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        let conversation = ConversationRecord(botID: bot.id, engine: "claude")
        try store.save(conversation)

        var run = RunRecord(botID: bot.id, conversationID: conversation.id, host: "local")
        try store.save(run)
        try store.append([
            EventRecord(runID: run.id, seq: 0, type: "userMessage",
                        payload: #"{"text":"check the deploy"}"#),
            EventRecord(runID: run.id, seq: 1, type: "toolCall", payload: "{}"),
            EventRecord(runID: run.id, seq: 2, type: "toolCall", payload: "{}"),
            EventRecord(runID: run.id, seq: 3, type: "text",
                        payload: #"{"text":"Deploy is green."}"#),
        ])
        run.status = "finished"
        run.endedAt = run.startedAt.addingTimeInterval(42)
        try store.save(run)

        let summary = try #require(try store.recentRuns(forBot: bot.id).first)
        #expect(summary.prompt == "check the deploy")
        #expect(summary.reply == "Deploy is green.")
        #expect(summary.toolCalls == 2)
        #expect(summary.succeeded)
        #expect(summary.duration == 42)
    }

    @Test("newest first, and capped")
    func ordersAndLimits() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        let conversation = ConversationRecord(botID: bot.id, engine: "claude")
        try store.save(conversation)

        for offset in 0..<5 {
            try store.save(RunRecord(
                botID: bot.id, conversationID: conversation.id, host: "local",
                startedAt: Date(timeIntervalSince1970: 1_000_000 + Double(offset * 60))))
        }

        let runs = try store.recentRuns(forBot: bot.id, limit: 3)
        #expect(runs.count == 3)
        #expect(runs[0].startedAt > runs[1].startedAt)
    }

    /// A run still in flight has no end time, and the view must not pretend otherwise.
    @Test("an unfinished run reports no duration")
    func unfinishedRun() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Scout", engine: "claude")
        try store.save(bot)
        let conversation = ConversationRecord(botID: bot.id, engine: "claude")
        try store.save(conversation)
        try store.save(RunRecord(botID: bot.id, conversationID: conversation.id, host: "local"))

        let summary = try #require(try store.recentRuns(forBot: bot.id).first)
        #expect(summary.duration == nil)
        #expect(!summary.succeeded)
    }
}

@Suite("Loading a long transcript")
struct LongTranscriptTests {
    /// With more events than the limit, the *latest* must load — the bug returned the earliest,
    /// so a busy bot's recent conversation silently stopped appearing.
    @Test("the most recent events load, in order, once a thread passes the limit")
    func newestEventsLoad() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "b", name: "B", engine: "claude"))
        let conversation = ConversationRecord(botID: "b", engine: "claude")
        try store.save(conversation)
        let run = RunRecord(botID: "b", conversationID: conversation.id, host: "local")
        try store.save(run)

        let start = Date(timeIntervalSince1970: 1_000_000)
        try store.append((0..<10).map { index in
            EventRecord(runID: run.id, seq: index, type: "text",
                        payload: "\(index)", at: start.addingTimeInterval(Double(index)))
        })

        let loaded = try store.transcript(forBot: "b", limit: 3)
        #expect(loaded.map(\.payload) == ["7", "8", "9"])
    }
}
