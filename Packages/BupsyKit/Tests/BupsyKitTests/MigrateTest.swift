import Foundation
import GRDB
import Testing
@testable import BupsyKit

/// Opening a database that already has orphaned rows in it.
///
/// Found on a real database, not imagined: one `conversations` row pointed at a bot deleted back
/// when the cascade was not being enforced. On the next launch the deferred foreign-key check that
/// follows a schema change failed, the whole migration aborted, `Store` threw, and the app fell
/// back to starter bots — so every bot the person had vanished from the UI while sitting intact on
/// disk. Silent, total, and recoverable only by someone reading SQLite by hand.
@Suite("Opening a damaged database")
struct DamagedDatabaseTests {

    /// Builds a store, then breaks it the way the historical bug did: a child row whose bot is
    /// gone, with the foreign key not enforced at the time of deletion.
    private func makeDamagedDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")

        let store = try Store(url: url)
        try store.save(BotRecord(id: "ghost", name: "Ghost", engine: "claude"))
        try store.save(ConversationRecord(botID: "ghost", engine: "claude"))
        try store.save(BotRecord(id: "keeper", name: "Keeper", engine: "claude"))

        // Delete the bot with the constraint switched off, which is exactly the state a database
        // written by an older build can be in.
        try store.database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM bots WHERE id = 'ghost'")
        }
        return url
    }

    @Test("a database with an orphaned row still opens, and keeps its bots")
    func opensDespiteOrphans() throws {
        let url = try makeDamagedDatabase()

        // The assertion that matters: this used to throw, and everything downstream of it treated
        // the throw as "no data", which is the opposite of what was true.
        let reopened = try Store(url: url)
        let bots = try reopened.bots()

        #expect(bots.count == 1)
        #expect(bots.first?.name == "Keeper")
    }

    @Test("the orphan is cleared rather than left to break the next migration")
    func orphansAreRemoved() throws {
        let url = try makeDamagedDatabase()
        let reopened = try Store(url: url)

        let orphans = try reopened.database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM conversations
                WHERE botID NOT IN (SELECT id FROM bots)
                """) ?? 0
        }
        #expect(orphans == 0)
    }

    /// Cleaning up historical damage must not mean tolerating new damage. Once the database is
    /// open, the constraint is enforced again.
    @Test("foreign keys are enforced once the database is open")
    func foreignKeysEndUpOn() throws {
        let url = try makeDamagedDatabase()
        let reopened = try Store(url: url)

        let enabled = try reopened.database.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)

        // And proves it: a conversation for a bot that does not exist is refused outright.
        #expect(throws: (any Error).self) {
            try reopened.save(ConversationRecord(botID: "nobody", engine: "claude"))
        }
    }

    /// Events belong to runs rather than bots, so a sweep keyed on `botID` missed them. Found on
    /// a real database: six events whose run was gone survived the first version of this fix.
    @Test("events whose run is gone are cleared too")
    func orphanedEventsAreRemoved() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = try Store(url: url)
        try store.save(BotRecord(id: "b", name: "B", engine: "claude"))
        let conversation = ConversationRecord(botID: "b", engine: "claude")
        try store.save(conversation)
        let run = RunRecord(botID: "b", conversationID: conversation.id, host: "local")
        try store.save(run)
        try store.append([EventRecord(runID: run.id, seq: 0, type: "text", payload: "{}")])

        try store.database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM runs")
        }

        let reopened = try Store(url: url)
        let orphans = try reopened.database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM events WHERE runID NOT IN (SELECT id FROM runs)
                """) ?? 0
        }
        #expect(orphans == 0)
    }
}
