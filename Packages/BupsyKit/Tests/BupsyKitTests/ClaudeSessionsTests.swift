import Foundation
import Testing
@testable import BupsyKit

@Suite("Continuing a Claude Code conversation")
struct ClaudeSessionsTests {
    /// A projects folder with conversations shaped like Claude Code's own files.
    private func projects(_ files: [String: [[String: Any]]], padding: [String: Int] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        for (name, records) in files {
            let folder = root.appendingPathComponent("-Users-me-app")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var lines = records.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            if let pad = padding[name] {
                let filler = String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "file-history-snapshot", "x": String(repeating: "z", count: 1000)]), as: UTF8.self)
                lines.insert(contentsOf: Array(repeating: filler, count: pad), at: 1)
            }
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func user(_ text: Any, entry: String = "claude-vscode") -> [String: Any] {
        ["type": "user", "sessionId": "s1", "cwd": "/Users/me/app", "entrypoint": entry,
         "timestamp": "2026-10-08T10:00:00.000Z", "message": ["role": "user", "content": text]]
    }

    private func assistant(_ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "sessionId": "s1", "cwd": "/Users/me/app", "entrypoint": "claude-vscode",
         "timestamp": "2026-10-08T10:00:05.000Z", "message": ["role": "assistant", "content": blocks]]
    }

    @Test("a VS Code conversation is listed by its title, and headless runs are not")
    func lists() throws {
        let root = try projects([
            "s1": [user("Fix the login bug"), ["type": "ai-title", "aiTitle": "Fix login bug", "sessionId": "s1"]],
            "s2": [user("Run the report", entry: "sdk-cli")],
            "s3": [user("Add dark mode", entry: "cli")],
            // A helper agent's conversation: all side-thread.
            "s4": [{ var record = user("You are a subagent"); record["isSidechain"] = true; return record }()],
        ])
        let sessions = ClaudeSessions.recent(in: root)
        #expect(Set(sessions.map(\.title)) == ["Fix login bug", "Add dark mode"])
        let vscode = try #require(sessions.first { $0.title == "Fix login bug" })
        #expect(vscode.source == .vscode)
        #expect(vscode.folder == "/Users/me/app")
        #expect(vscode.id == "s1")
        #expect(sessions.first { $0.title == "Add dark mode" }?.source == .terminal)
    }

    @Test("the transcript keeps what was said and done, and drops the rest")
    func transcript() throws {
        let root = try projects(["s1": [
            user("Fix the login bug"),
            user("<command-name>/clear</command-name>"),
            ["type": "user", "isMeta": true, "sessionId": "s1", "cwd": "/Users/me/app", "entrypoint": "claude-vscode",
             "message": ["role": "user", "content": "Caveat: internal"]],
            assistant([["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "Looking at it."]]),
            assistant([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "npm test"]]]),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]),
            ["type": "assistant", "isSidechain": true, "sessionId": "s1", "message": ["content": [["type": "text", "text": "side"]]]],
            assistant([["type": "text", "text": "Fixed."]]),
        ]])
        let session = try #require(ClaudeSessions.recent(in: root).first)
        let messages = ClaudeSessions.transcript(of: session)
        #expect(messages.count == 4)
        guard case .you("Fix the login bug", _) = messages[0] else { Issue.record("first should be the prompt"); return }
        guard case .bot("Looking at it.", _) = messages[1] else { Issue.record("then the reply"); return }
        guard case .tool(name: "Bash", let arguments, _) = messages[2] else { Issue.record("then the tool"); return }
        #expect(arguments.contains("npm test"))
        guard case .bot("Fixed.", _) = messages[3] else { Issue.record("then the last reply"); return }
    }

    @Test("a long conversation is described from its end without reading it all")
    func longFile() throws {
        // About 2 MB of filler between the start and the title at the end.
        let root = try projects(["s1": [user("Start"), ["type": "ai-title", "aiTitle": "Long one", "sessionId": "s1"],
                                        user("Latest question")]], padding: ["s1": 2000])
        let session = try #require(ClaudeSessions.recent(in: root).first)
        #expect(session.title == "Long one")
        guard case .you("Latest question", _) = ClaudeSessions.transcript(of: session).last else {
            Issue.record("the latest message should come through"); return
        }
    }

    @Test("a copy forks the conversation; a move resumes it as it is")
    func forks() {
        let id = ConversationID("s1")
        let copy = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", resume: id, forkSession: true)).arguments
        #expect(copy.contains("--fork-session"))
        #expect(copy.firstIndex(of: "--resume").map { copy[$0 + 1] } == "s1")
        let move = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", resume: id)).arguments
        #expect(!move.contains("--fork-session"))
        // Nothing to fork without a conversation to resume.
        #expect(!ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", forkSession: true)).arguments.contains("--fork-session"))
    }
}
