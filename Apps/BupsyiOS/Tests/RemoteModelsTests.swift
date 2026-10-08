import Foundation
import Testing
@testable import Bupsy

/// The JSON here is what `RemoteAccess` on the Mac sends, field for field. If the Mac's shapes
/// change, these are the tests that should go red.
@Suite("Remote API: decoding")
struct RemoteModelsTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try RemoteClient.decoder().decode(type, from: Data(json.utf8))
    }

    private let bot = """
        {"id":"b1","name":"Lead","role":"Planner","section":null,"colour":"#e075c8","mood":"waitingForYou",
         "running":false,"needsYou":true,"unread":true,"preview":"Can I push?"}
        """

    @Test("a bot list decodes, with its waiting count")
    func botList() throws {
        let list = try decode(BotList.self, #"{"bots":[\#(bot)],"waiting":1}"#)
        #expect(list.waiting == 1)
        let first = try #require(list.bots.first)
        #expect(first.name == "Lead")
        #expect(first.role == "Planner")
        #expect(first.section == nil)
        #expect(first.mood == .waitingForYou)
        #expect(first.needsYou && first.unread && !first.running)
        #expect(first.preview == "Can I push?")
    }

    @Test("an unknown mood reads as idle, and one unreadable bot doesn't sink the list")
    func forgivingBots() throws {
        let newer = bot.replacingOccurrences(of: "waitingForYou", with: "dreaming")
        let list = try decode(BotList.self, #"{"bots":[\#(newer),{"id":7}],"waiting":0}"#)
        #expect(list.bots.count == 1)
        #expect(list.bots.first?.mood == .idle)
    }

    @Test("the session names the Mac")
    func session() throws {
        #expect(try decode(MacInfo.self, #"{"mac":"Vansh's MacBook Pro"}"#).mac == "Vansh's MacBook Pro")
    }

    @Test("every kind of entry decodes")
    func everyKind() throws {
        let json = """
            {"bot":\(bot),"entries":[
              {"id":"1","kind":"you","at":"2026-10-08T09:00:00Z","text":"Ship it"},
              {"id":"2","kind":"bot","at":"2026-10-08T09:00:05Z","text":"**On it.**"},
              {"id":"3","kind":"from","at":"2026-10-08T09:00:06Z","author":"Scout","text":"Found 3 bugs"},
              {"id":"4","kind":"tool","at":"2026-10-08T09:00:07Z","tool":{"verb":"ran","target":"npm test","failed":true}},
              {"id":"5","kind":"approval","at":"2026-10-08T09:00:08Z","approval":{"id":"a1","tool":"Bash",
                "summary":"git push","reason":"To publish the fix","decided":null}},
              {"id":"6","kind":"approval","at":"2026-10-08T09:00:09Z","approval":{"id":"a0","tool":"Bash",
                "summary":"ls","reason":"","decided":"alwaysAllowed"}},
              {"id":"7","kind":"question","at":"2026-10-08T09:00:10Z","question":{"id":"q1",
                "question":"Which branch?","options":["main","dev"],"answer":null}},
              {"id":"8","kind":"note","at":"2026-10-08T09:00:11Z","text":"Messaged Scout"},
              {"id":"9","kind":"failure","at":"2026-10-08T09:00:12Z","text":"The engine stopped"},
              {"id":"10","kind":"hologram","at":"2026-10-08T09:00:13Z","text":"From the future"}
            ]}
            """
        let thread = try decode(BotThread.self, json)
        let kinds = thread.entries.map(\.kind)
        #expect(kinds.count == 10)
        #expect(kinds[0] == .you("Ship it"))
        #expect(kinds[1] == .bot("**On it.**"))
        #expect(kinds[2] == .from(author: "Scout", text: "Found 3 bugs"))
        #expect(kinds[3] == .tool(ToolStep(verb: "ran", target: "npm test", failed: true)))
        guard case .approval(let open) = kinds[4], case .approval(let decided) = kinds[5] else {
            Issue.record("approvals didn't decode as approvals")
            return
        }
        #expect(open.id == "a1" && open.summary == "git push" && open.reason == "To publish the fix")
        #expect(open.decided == nil)
        #expect(decided.decided == .alwaysAllowed)
        guard case .question(let question) = kinds[6] else {
            Issue.record("the question didn't decode as one")
            return
        }
        #expect(question.question == "Which branch?" && question.options == ["main", "dev"] && question.answer == nil)
        #expect(kinds[7] == .note("Messaged Scout"))
        #expect(kinds[8] == .failure("The engine stopped"))
        #expect(kinds[9] == .other("From the future"))
        #expect(thread.entries[0].at == Date(timeIntervalSince1970: 1_791_450_000))
    }

    @Test("an entry that can't be read is dropped, and the rest still show")
    func forgivingEntries() throws {
        let json = """
            {"bot":\(bot),"entries":[
              {"id":"1","kind":"you","at":"not a date","text":"lost"},
              {"id":"2","kind":"tool","at":"2026-10-08T09:00:07Z"},
              {"id":"3","kind":"bot","at":"2026-10-08T09:00:05Z","text":"kept"}
            ]}
            """
        #expect(try decode(BotThread.self, json).entries.map(\.id) == ["3"])
    }

    @Test("approvals say what the bot wants in plain words")
    func approvalWords() {
        func action(_ tool: String) -> String {
            Approval(id: "", tool: tool, summary: "", reason: "", decided: nil).action
        }
        #expect(action("Bash") == "run a command")
        #expect(action("Edit") == "edit a file")
        #expect(action("WebFetch") == "open a web page")
        #expect(action("mcp__github__create_issue") == "use create issue")
        #expect(action("Frobnicate") == "use Frobnicate")
    }

    @Test("a notification says what the bot is waiting for")
    func notificationText() throws {
        let approval = Entry(id: "1", at: .now, kind: .approval(
            Approval(id: "a", tool: "Bash", summary: "npm publish\n--tag next", reason: "", decided: nil)))
        let answered = Entry(id: "2", at: .now, kind: .approval(
            Approval(id: "b", tool: "Bash", summary: "ls", reason: "", decided: .allowed)))
        #expect(NeedsYouAlerts.describe([approval, answered]) == "Wants to run a command: npm publish")
        #expect(NeedsYouAlerts.describe([answered]) == "Waiting on you")
    }

    @Test("sections keep the Mac's order, with unsectioned bots first")
    func sections() throws {
        let mac = PairedMac(id: "m", name: "Studio", address: URL(string: "https://studio.ts.net:8443")!)
        func bot(_ id: String, _ section: String?) -> Bot {
            Bot(ref: BotRef(macID: "m", botID: id), name: id, section: section, colour: "#000000")
        }
        func groups(_ bots: [Bot]) -> [BotSection] {
            BotDirectory.sections(macs: [mac], states: ["m": MacState(reached: true, bots: bots)])
        }
        let grouped = groups([bot("a", "Work"), bot("b", nil), bot("c", "Home"), bot("d", "Work")])
        #expect(grouped.map(\.title) == [nil, "Work", "Home"])
        #expect(grouped.map { $0.bots.map(\.id.botID) } == [["b"], ["a", "d"], ["c"]])
        #expect(groups([bot("a", "Work")]).map(\.title) == ["Work"])
    }

    @Test("a bot's face and a Mac's kind decode, and an older Mac without them still works")
    func faceAndKind() throws {
        let withFace = bot.replacingOccurrences(of: #""preview":"Can I push?"}"#,
            with: #""preview":"Can I push?","face":{"shape":"blob","colour":14710216,"hue":0.86}}"#)
        let face = try #require(try decode(BotList.self, #"{"bots":[\#(withFace)],"waiting":1}"#).bots.first?.face)
        #expect(face == Bot.Face(shape: "blob", colour: 14_710_216, hue: 0.86))
        #expect(try decode(BotList.self, #"{"bots":[\#(bot)],"waiting":1}"#).bots.first?.face == nil)
        // A face from a newer Mac in a shape this app can't read loses the face, not the bot.
        let oddFace = bot.replacingOccurrences(of: #""preview":"Can I push?"}"#, with: #""preview":"Can I push?","face":"🙂"}"#)
        #expect(try decode(BotList.self, #"{"bots":[\#(oddFace)],"waiting":1}"#).bots.first?.name == "Lead")

        #expect(try decode(MacInfo.self, #"{"mac":"MacBook Air","kind":"laptop"}"#).kind == "laptop")
        #expect(try decode(MacInfo.self, #"{"mac":"Mac mini"}"#).kind == nil)
    }

    @Test("bubbles from one speaker run together; anything between them starts a new run")
    func runs() {
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let entries: [Entry] = [
            Entry(id: "1", at: start, kind: .bot("a")),
            Entry(id: "2", at: start, kind: .bot("b")),
            Entry(id: "3", at: start, kind: .tool(ToolStep(verb: "ran", target: "ls", failed: false))),
            Entry(id: "4", at: start, kind: .bot("c")),
            Entry(id: "5", at: start, kind: .you("d")),
            Entry(id: "6", at: start.addingTimeInterval(86_400), kind: .you("e")),
        ]
        let rows = ThreadRow.rows(entries)
        #expect(rows.map(\.startsRun) == [true, false, true, true, true, true])
        #expect(rows.map(\.startsDay) == [true, false, false, false, false, true])
    }
}
