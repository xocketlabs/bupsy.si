import Testing
@testable import BupsyKit

@Suite("Mention chips")
struct MentionSplitterTests {
    @Test("splits a known bot's @mention out of the sentence")
    func splitsMention() {
        #expect(MentionSplitter.split("done @scout — over to you", names: ["Scout"])
                == [.text("done "), .mention("Scout"), .text(" — over to you")])
    }

    @Test("prefers the longest name, and needs a word boundary")
    func longestNameAndBoundary() {
        #expect(MentionSplitter.split("@Email Agent 3 go", names: ["Email", "Email Agent 3"])
                == [.mention("Email Agent 3"), .text(" go")])
        #expect(MentionSplitter.split("@Scouting is not a bot", names: ["Scout"])
                == [.text("@Scouting is not a bot")])
    }

    @Test("leaves text without mentions, and unknown names, alone")
    func leavesOtherTextAlone() {
        #expect(MentionSplitter.split("no mentions", names: ["Scout"]) == [.text("no mentions")])
        #expect(MentionSplitter.split("mail me@example.com", names: ["Scout"]) == [.text("mail me@example.com")])
    }
}

@Suite("Bot roles")
struct BotRoleStoreTests {
    @Test("a bot's role tag round-trips through the store")
    func roleRoundTrips() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(name: "zarya", engine: "claude", role: "PA"))
        #expect(try store.bots().first?.role == "PA")
    }
}

@Suite("Mention chips in code")
struct MentionInCodeTests {
    @Test("a mention inside `code` stays plain code")
    func codeIsLeftAlone() {
        #expect(MentionSplitter.split("default to `@Builder for code` and @Scout", names: ["Builder", "Scout"])
                == [.text("default to `@Builder for code` and "), .mention("Scout")])
    }
}
