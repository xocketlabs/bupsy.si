import Foundation
import Testing
import GRDB
@testable import BupsyKit

@Suite("Group threads")
struct GroupTests {
    let scout = GroupRouting.Member(id: "s", name: "Scout")
    let builder = GroupRouting.Member(id: "b", name: "Builder")
    let email = GroupRouting.Member(id: "e", name: "Email")
    let agent3 = GroupRouting.Member(id: "a3", name: "Email Agent 3")
    var all: [GroupRouting.Member] { [scout, builder, email, agent3] }

    @Test("mentions are found in the order they appear, once each")
    func orderOfMentions() {
        let found = GroupRouting.mentions(in: "@builder can you and @Scout check, then @Builder ship",
                                          members: all)
        #expect(found == [builder, scout])
    }

    /// Longest name first, or "@Email Agent 3" would summon "Email".
    @Test("a longer name wins over a shorter one it starts with")
    func longestNameWins() {
        #expect(GroupRouting.mentions(in: "ask @Email Agent 3 please", members: all) == [agent3])
        #expect(GroupRouting.mentions(in: "ask @email please", members: all) == [email])
    }

    @Test("a name inside a longer word is not a mention")
    func wordBoundary() {
        #expect(GroupRouting.mentions(in: "@Scouting around", members: all).isEmpty)
        #expect(GroupRouting.mentions(in: "@Scout, look", members: all) == [scout])
    }

    /// The quota rule: nobody mentioned means the lead answers, not everyone.
    @Test("an unaddressed message goes to the lead, never to everyone")
    func leadAnswers() {
        #expect(GroupRouting.addressees(of: "what's next?", members: all, lead: "b") == [builder])
        #expect(GroupRouting.addressees(of: "what's next?", members: all, lead: nil) == [scout])
        #expect(GroupRouting.addressees(of: "@Scout what's next?", members: all, lead: "b") == [scout])
    }

    /// A lead that was deleted falls back to the first member rather than to nobody.
    @Test("a missing lead falls back to the first member")
    func missingLead() {
        #expect(GroupRouting.addressees(of: "hi", members: all, lead: "gone") == [scout])
    }

    @Test("a bot cannot hand off to itself")
    func noSelfHandOff() {
        let next = GroupRouting.handOffs(from: scout, reply: "@Scout and @Builder", members: all)
        #expect(next == [builder])
    }

    @Test("the turn ceiling exists and is small")
    func turnCeiling() {
        #expect(GroupRouting.maxBotTurnsPerMessage > 0)
        #expect(GroupRouting.maxBotTurnsPerMessage <= 10)
    }

    @Test("every turn-limit choice is within the hard ceiling, and the default is one of them")
    func turnLimitChoices() {
        #expect(GroupRouting.turnLimitChoices.contains(GroupRouting.defaultTurnLimit))
        for choice in GroupRouting.turnLimitChoices {
            #expect(choice > 0)
            #expect(choice <= GroupRouting.maxBotTurnsPerMessage)
            #expect(GroupRouting.effectiveTurnLimit(choice) == choice)
        }
    }

    /// A damaged or hand-edited row must never mean "never check with me", or "never answer".
    @Test("a stored turn limit is kept between one turn and the ceiling")
    func turnLimitIsClamped() {
        #expect(GroupRouting.effectiveTurnLimit(0) == 1)
        #expect(GroupRouting.effectiveTurnLimit(-4) == 1)
        #expect(GroupRouting.effectiveTurnLimit(500) == GroupRouting.maxBotTurnsPerMessage)
    }

    @Test("the group pauses once it has taken its limit, not before")
    func pausesAtLimit() {
        #expect(!GroupRouting.shouldPause(afterTaking: 0, limit: 3))
        #expect(!GroupRouting.shouldPause(afterTaking: 2, limit: 3))
        #expect(GroupRouting.shouldPause(afterTaking: 3, limit: 3))
        #expect(GroupRouting.shouldPause(afterTaking: 10, limit: 99))
    }

    @Test("a bot is told the group, the others, and what it missed")
    func promptCarriesContext() {
        let prompt = GroupRouting.prompt(group: "Launch", members: [scout, builder], me: builder,
                                         recent: [("You", "ship it"), ("Scout", "tests are green")])
        #expect(prompt.contains("You are Builder"))
        #expect(prompt.contains("@Scout"))
        #expect(!prompt.contains("@Builder"))
        #expect(prompt.contains("Scout: tests are green"))
    }

    // MARK: - Storage

    @Test("a group, its members and its messages round-trip; a bot's own thread excludes them")
    func storage() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "s", name: "Scout", engine: "claude"))
        try store.save(BotRecord(id: "b", name: "Builder", engine: "claude"))
        let group = GroupRecord(name: "Launch", leadBotID: "s")
        try store.save(group)
        try store.setMembers(ofGroup: group.id, to: ["s", "b"])
        try store.append(GroupMessageRecord(groupID: group.id, author: "user",
                                            authorName: "You", text: "go"))

        #expect(try store.members(ofGroup: group.id) == ["s", "b"])
        #expect(try store.messages(inGroup: group.id).map(\.text) == ["go"])

        // A run taken as a group turn must not appear in Scout's own thread.
        let conversation = ConversationRecord(botID: "s", engine: "claude")
        try store.save(conversation)
        let run = RunRecord(botID: "s", conversationID: conversation.id, host: "local",
                            groupID: group.id)
        try store.save(run)
        try store.append([EventRecord(runID: run.id, seq: 0, type: "text", payload: "{}")])
        #expect(try store.transcript(forBot: "s").isEmpty)
    }

    @Test("a group's turn limit defaults to five and round-trips")
    func turnLimitStorage() throws {
        let store = try Store.inMemory()
        try store.save(GroupRecord(id: "default", name: "Launch", leadBotID: nil))
        try store.save(GroupRecord(id: "short", name: "Review", leadBotID: nil, turnLimit: 3))

        let groups = try store.groups()
        #expect(groups.first(where: { $0.id == "default" })?.turnLimit == GroupRouting.defaultTurnLimit)
        #expect(groups.first(where: { $0.id == "short" })?.turnLimit == 3)

        var edited = try #require(groups.first(where: { $0.id == "short" }))
        edited.turnLimit = 10
        try store.save(edited)
        #expect(try store.groups().first(where: { $0.id == "short" })?.turnLimit == 10)
    }

    /// A group made before the setting existed has no value of its own; the migration's column
    /// default is what it gets.
    @Test("a group row written without a turn limit gets the default")
    func turnLimitColumnDefault() throws {
        let store = try Store.inMemory()
        try store.database.write { db in
            try db.execute(sql: """
                INSERT INTO groups (id, name, createdAt, sortIndex, pinned)
                VALUES ('old', 'Old group', ?, 0, 0)
                """, arguments: [Date()])
        }
        #expect(try store.groups().first?.turnLimit == GroupRouting.defaultTurnLimit)
    }

    /// Deleting a bot must not delete the group it led — only its membership.
    @Test("deleting the lead keeps the group and clears the lead")
    func deletingLead() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "s", name: "Scout", engine: "claude"))
        try store.save(BotRecord(id: "b", name: "Builder", engine: "claude"))
        let group = GroupRecord(name: "Launch", leadBotID: "s")
        try store.save(group)
        try store.setMembers(ofGroup: group.id, to: ["s", "b"])

        try store.deleteBot(id: "s")
        let groups = try store.groups()
        #expect(groups.count == 1)
        #expect(groups.first?.leadBotID == nil)
        #expect(try store.members(ofGroup: group.id) == ["b"])
    }
}

@Suite("Group sessions")
struct GroupSessionTests {
    /// A bot's session in a group must never be resumed as its session with you, or the other way
    /// round — each would hand the bot a conversation it was not part of.
    @Test("a bot's group session and its own session are looked up separately")
    func sessionsAreSeparate() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "s", name: "Scout", engine: "claude"))
        try store.save(GroupRecord(id: "g", name: "Launch", leadBotID: "s"))
        try store.save(ConversationRecord(id: "own", botID: "s", engine: "claude",
                                          providerConversationID: "sess-own"))
        try store.save(ConversationRecord(id: "grp", botID: "s", engine: "claude",
                                          providerConversationID: "sess-group", groupID: "g"))

        #expect(try store.conversation(forBot: "s", engine: "claude")?.id == "own")
        #expect(try store.conversation(forBot: "s", engine: "claude", group: "g")?.id == "grp")
    }
}
