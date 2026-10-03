import Foundation
import Testing
@testable import BupsyKit

/// One bot messaging another is the one path that routes around the approval gate: the receiving
/// bot acts on instructions no human read. These pin the rules that make it safe.
@Suite("Bot-to-bot links")
struct BotLinkTests {

    @Test("first contact needs a person")
    func firstContactAsks() {
        let links = BotLinks()
        #expect(links.needsApproval(from: "scout", to: "builder"))
        #expect(!links.isAllowed(from: "scout", to: "builder"))
    }

    /// The most important case in the file.
    ///
    /// Allowing Scout → Builder must not allow Builder → Scout. In a roster where one bot
    /// orchestrates others, the reverse direction is exactly the one that matters: an
    /// orchestrator instructing a worker must not quietly let the worker instruct it back.
    @Test("a link is one-directional")
    func linksAreDirectional() {
        var links = BotLinks()
        links.decide(from: "scout", to: "builder", allowed: true)

        #expect(links.isAllowed(from: "scout", to: "builder"))
        #expect(!links.isAllowed(from: "builder", to: "scout"))
        #expect(links.needsApproval(from: "builder", to: "scout"))
    }

    /// A refusal is an answer. Re-asking on every attempt is how a gate becomes a thing people
    /// dismiss without reading.
    @Test("a refusal is remembered rather than re-asked")
    func refusalSticks() {
        var links = BotLinks()
        links.decide(from: "scout", to: "builder", allowed: false)

        #expect(!links.isAllowed(from: "scout", to: "builder"))
        #expect(!links.needsApproval(from: "scout", to: "builder"))
    }

    @Test("a decision can be revoked, and then it asks again")
    func revoking() {
        var links = BotLinks()
        links.decide(from: "scout", to: "builder", allowed: true)
        links.forget(from: "scout", to: "builder")

        #expect(links.needsApproval(from: "scout", to: "builder"))
    }

    @Test("deciding again replaces the earlier answer rather than stacking")
    func decidingTwice() {
        var links = BotLinks()
        links.decide(from: "scout", to: "builder", allowed: true)
        links.decide(from: "scout", to: "builder", allowed: false)

        #expect(links.decisions.count == 1)
        #expect(!links.isAllowed(from: "scout", to: "builder"))
    }

    /// Not a permission question. A bot writing into its own thread feeds its own output back as
    /// input, and no human answer makes that safe.
    @Test("a bot cannot message itself")
    func noSelfMessages() {
        #expect(BotLinks.isSelfMessage(from: "scout", to: "scout"))
        #expect(!BotLinks.isSelfMessage(from: "scout", to: "builder"))
    }

    @Test("links survive a round trip through the store")
    func linksPersist() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "scout", name: "Scout", engine: "claude"))
        try store.save(BotRecord(id: "builder", name: "Builder", engine: "claude"))
        try store.save(BotLinkRecord(fromBotID: "scout", toBotID: "builder", allowed: true))

        let loaded = BotLinks(try store.botLinks())
        #expect(loaded.isAllowed(from: "scout", to: "builder"))
        #expect(!loaded.isAllowed(from: "builder", to: "scout"))
    }

    /// Deleting a bot must not leave a permission pointing at nothing, which a later bot could
    /// inherit by reusing an id.
    @Test("deleting a bot takes its links with it")
    func linksCascade() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "scout", name: "Scout", engine: "claude"))
        try store.save(BotRecord(id: "builder", name: "Builder", engine: "claude"))
        try store.save(BotLinkRecord(fromBotID: "scout", toBotID: "builder", allowed: true))

        try store.deleteBot(id: "builder")
        #expect(try store.botLinks().isEmpty)
    }
}
