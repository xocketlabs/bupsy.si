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

@Suite("Tool names, as a person reads them")
struct ToolNameTests {
    @Test("engine tool names become plain actions")
    func plainActions() {
        #expect(ToolNames.action("Bash") == "run a command")
        #expect(ToolNames.action("Edit") == "edit a file")
        #expect(ToolNames.action("WebFetch") == "fetch a web page")
    }

    /// The server is what the person installed and recognises; the function name is detail.
    @Test("an MCP tool is named for its server")
    func mcpTools() {
        #expect(ToolNames.action("mcp__linear__create_issue") == "use Linear")
        #expect(ToolNames.action("mcp__bupsy__message_bot") == "use Bupsy")
    }

    @Test("an unknown tool still reads as a sentence")
    func unknownTools() {
        #expect(ToolNames.action("Frobnicate") == "use Frobnicate")
        // Malformed MCP names fall through rather than producing "use ".
        #expect(ToolNames.action("mcp____x") == "use mcp____x")
    }

    /// In a proportional font `ls` reads as "Is".
    @Test("shell commands are flagged for a fixed-width font")
    func commandsAreMonospaced() {
        #expect(ToolNames.isCommand("Bash"))
        #expect(!ToolNames.isCommand("Edit"))
    }

    @Test("approval reasons are sentences")
    func reasonsAreSentences() {
        guard case .ask(let reason) = AutonomyPolicy.decide(
            tool: "Bash", autonomy: .ask, allowlist: []) else {
            Issue.record("Bash at .ask must ask"); return
        }
        #expect(reason.first?.isUppercase == true)
        #expect(reason.hasSuffix("."))
    }
}

@Suite("bupsy's own tools")
struct BupsyOwnToolsPolicyTests {
    @Test("are not gated twice — bupsy asks about their effects itself")
    func bupsyToolsSkipTheGate() {
        for tool in ["mcp__bupsy__create_bot", "mcp__bupsy__message_bot", "mcp__bupsy__list_bots"] {
            for autonomy in [Autonomy.ask, .allowlist, .trusted] {
                if case .ask = AutonomyPolicy.decide(tool: tool, autonomy: autonomy) {
                    Issue.record("\(tool) asked under \(autonomy)")
                }
            }
        }
        // Another server's tools still ask.
        if case .allow = AutonomyPolicy.decide(tool: "mcp__bupsyx__send", autonomy: .trusted) {
            Issue.record("a lookalike server was let through")
        }
    }
}

@Suite("Engine plumbing")
struct EnginePlumbingPolicyTests {
    @Test("ToolSearch never asks, even on a bot that asks before everything")
    func toolSearchIsNotAnAction() {
        if case .ask = AutonomyPolicy.decide(tool: "ToolSearch", autonomy: .ask) {
            Issue.record("ToolSearch asked")
        }
        // A real action on the same bot still asks.
        if case .allow = AutonomyPolicy.decide(tool: "Bash", autonomy: .ask) {
            Issue.record("Bash was let through")
        }
    }
}

@Suite("Always allow")
struct AlwaysAllowTests {
    @Test("an always-allowed tool runs without asking, even on a bot that asks about everything")
    func askModeHonoursAllowlist() {
        if case .ask = AutonomyPolicy.decide(tool: "Write", autonomy: .ask, allowlist: ["Write"]) {
            Issue.record("Write still asked")
        }
        if case .allow = AutonomyPolicy.decide(tool: "Edit", autonomy: .ask, allowlist: ["Write"]) {
            Issue.record("Edit was let through")
        }
    }

    @Test("shell commands are never offered for always-allow")
    func noAlwaysForShell() {
        #expect(!ToolNames.canAlwaysAllow("Bash"))
        #expect(ToolNames.canAlwaysAllow("Write"))
    }

    @Test("an allowlist survives a save and reload, and a link can be forgotten")
    func persists() throws {
        let store = try Store.inMemory()
        let a = BotRecord(name: "A", engine: "claude", toolAllowlist: #"["Write"]"#)
        let b = BotRecord(name: "B", engine: "claude")
        try store.save(a); try store.save(b)
        #expect(try store.bots().first { $0.name == "A" }?.toolAllowlist == #"["Write"]"#)
        try store.save(BotLinkRecord(fromBotID: a.id, toBotID: b.id, allowed: true))
        try store.deleteLink(from: a.id, to: b.id)
        #expect(try store.botLinks().isEmpty)
    }
}
