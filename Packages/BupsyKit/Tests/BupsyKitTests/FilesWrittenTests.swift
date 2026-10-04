import Foundation
import Testing
@testable import BupsyKit

@Suite("Files a bot changed")
struct FilesWrittenTests {
    @Test("reads paths from Claude's and Codex's file tools, and nothing else")
    func parsesPaths() {
        #expect(FilesWritten.paths(tool: "Write", argumentsJSON: #"{"file_path":"/a/b.md","content":"x"}"#) == ["/a/b.md"])
        #expect(FilesWritten.paths(tool: "NotebookEdit", argumentsJSON: #"{"notebook_path":"/n.ipynb"}"#) == ["/n.ipynb"])
        #expect(FilesWritten.paths(tool: "edit", argumentsJSON: #"[{"path":"/x.swift","kind":"update"}]"#) == ["/x.swift"])
        #expect(FilesWritten.paths(tool: "Read", argumentsJSON: #"{"file_path":"/a/b.md"}"#).isEmpty)
        #expect(FilesWritten.paths(tool: "Bash", argumentsJSON: #"{"command":"ls"}"#).isEmpty)
    }

    @Test("lists each file once, newest first, leaving out writes that failed")
    func storeQuery() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Builder", engine: "claude")
        try store.save(bot)
        let conversation = ConversationRecord(botID: bot.id, engine: "claude")
        try store.save(conversation)
        let run = RunRecord(botID: bot.id, conversationID: conversation.id, host: "local", status: "finished")
        try store.save(run)
        func call(_ id: String, _ path: String, _ seq: Int) throws {
            try store.append([EventRecord(runID: run.id, seq: seq, type: "toolCall",
                payload: #"{"id":"\#(id)","name":"Write","arguments":"{\"file_path\":\"\#(path)\"}"}"#,
                at: Date(timeIntervalSince1970: Double(1000 + seq)))])
        }
        try call("c1", "/old.md", 1)
        try call("c2", "/new.md", 2)
        try call("c3", "/old.md", 3)
        try call("c4", "/denied.md", 4)
        try store.append([EventRecord(runID: run.id, seq: 5, type: "toolResult",
            payload: #"{"callID":"c4","content":"denied","isError":"true"}"#, at: Date(timeIntervalSince1970: 1005))])

        #expect(try store.filesWritten(forBot: bot.id).map(\.path) == ["/old.md", "/new.md"])
    }
}
