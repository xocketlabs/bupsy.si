import Foundation
import Testing
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
