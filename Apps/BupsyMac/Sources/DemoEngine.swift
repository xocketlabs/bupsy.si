#if DEBUG
import BupsyKit
import Foundation

/// Debug-only: answers runs with a script instead of launching `claude`.
///
/// It stands where the real host does and writes what Claude Code writes: stream-json lines on
/// stdout, which the real `ClaudeAdapter` parses and the real thread applies. Tool calls to
/// bupsy's own tools are carried out the way `bupsy-mcp` does, by dropping a file signed with the
/// run's token into the outbox, so renaming, hand-offs and their consequences are the real ones.
/// Which script plays is chosen from the prompt (`DemoScript.scene(for:)`).
struct DemoHost: ExecutionHost {
    let id: HostID = .local
    var survivesSleep: Bool { false }

    func spawn(_ invocation: EngineInvocation) async throws -> AsyncThrowingStream<HostOutput, Error> {
        let prompt = Self.prompt(in: invocation.arguments)
        let token = invocation.environment["BUPSY_RUN_TOKEN"] ?? ""
        let folder = invocation.workingDirectory
        let steps = DemoScript.scene(for: prompt, folder: folder)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .line(let line): continuation.yield(.stdout(line))
                    case .wait(let seconds): try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                    case .drop(let fields): Self.drop(fields, token: token)
                    case .file(let path, let contents):
                        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
                continuation.yield(.exit(code: Task.isCancelled ? 143 : 0))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func read(_ path: String) async throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    func write(_ path: String, _ data: Data) async throws { try data.write(to: URL(fileURLWithPath: path)) }
    func installTrigger(_ trigger: HostTrigger) async throws { throw HostError.unsupported("demo") }
    func desktopURL() async throws -> URL? { nil }
    func wake() async throws {}
    func sleep() async throws {}

    /// The prompt Claude Code would have been given: the argument after `-p`, or after `--`.
    static func prompt(in arguments: [String]) -> String {
        if let dash = arguments.firstIndex(of: "--"), dash + 1 < arguments.count { return arguments[dash + 1] }
        if let print = arguments.firstIndex(of: "-p"), print + 1 < arguments.count,
           !arguments[print + 1].hasPrefix("--") { return arguments[print + 1] }
        return ""
    }

    /// As `bupsy-mcp` writes it: a temporary name renamed into place, with the run's token.
    private static func drop(_ fields: [String: String], token: String) {
        let outbox = AppHome.directory.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var payload: [String: Any] = fields
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        payload["token"] = token
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let name = "\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))-\(getpid()).json"
        let final = outbox.appendingPathComponent(name)
        let partial = outbox.appendingPathComponent(name + ".part")
        do {
            try data.write(to: partial)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
        }
    }
}

enum DemoStep: Sendable {
    /// One line of Claude Code's stream-json output.
    case line(String)
    case wait(Double)
    /// A request to bupsy, as bupsy-mcp would leave it in the outbox.
    case drop([String: String])
    /// A file the bot writes, so a tool row's file really is there to open.
    case file(path: String, contents: String)
}

/// The stories a demo can tell, picked by what the run was asked.
///
/// Paced for video: a whole beat is a few seconds, text arrives a few words at a time, tool steps
/// take long enough to read their row. Anything unrecognised gets a short, plausible reply.
enum DemoScript {
    static let job = "Find this week's top 3 AI launches and get Writer to draft a post"
    /// The job Scout proposes for itself, which waits for the person's yes.
    static let scoutJob = "Watch for the week's biggest AI launches and hand the best ones to Writer for a post."

    static func scene(for prompt: String, folder: URL?) -> [DemoStep] {
        let lowered = prompt.lowercased()
        if prompt.contains("You have just been created in Bupsy") { return greeting() }
        if lowered.contains("message from scout") { return writerDraft(folder: folder) }
        if lowered.contains("ai launches") { return scoutResearch() }
        if lowered.contains("morning brief") { return leadBrief() }
        return fallback()
    }

    // MARK: - Scenes

    private static func greeting() -> [DemoStep] {
        var scene = Scene()
        scene.wait(0.5)
        scene.say("Hi! What should I work on? Lead, Researcher and Writer are already on the launch, "
                  + "so I'm free for anything new.")
        scene.finish(cached: 9_800, new: 1_900, reply: 60)
        return scene.steps
    }

    private static func scoutResearch() -> [DemoStep] {
        var scene = Scene()
        scene.wait(0.35)
        scene.tool("mcp__bupsy__update_me", ["name": "Scout", "role": "News", "job": scoutJob],
                   drop: ["kind": "update_me", "from": "", "name": "Scout", "role": "News", "job": scoutJob],
                   result: "Done.", after: 0.45)
        scene.tool("WebSearch", ["query": "AI product launches this week"], result: "10 results", after: 1.1)
        scene.tools([("WebFetch", ["url": "https://news.ycombinator.com/show"]),
                     ("WebFetch", ["url": "https://www.producthunt.com/topics/artificial-intelligence"])],
                    result: "Fetched", after: 1.0)
        scene.say("""
            This week's top 3 AI launches:

            1. **Lumen Notes 2**: records meetings offline and writes the action items for you.
            2. **Pathway Agents**: open-source workflow agents, with a visual debugger.
            3. **Quill Voice**: live translation in 40 languages, right on a laptop.
            """)
        scene.wait(0.3)
        let brief = "This week's top 3 AI launches: Lumen Notes 2 (offline meeting notes with action items), "
            + "Pathway Agents (open-source workflow agents, visual debugger), Quill Voice (live translation "
            + "in 40 languages, on-device). Can you draft a short roundup post?"
        scene.tool("mcp__bupsy__message_bot", ["to": "Writer", "text": brief],
                   drop: ["from": "", "to": "Writer", "text": brief],
                   result: "Queued for Writer.", after: 0.5)
        scene.say("Sent to Writer for a draft.")
        scene.finish(cached: 18_400, new: 6_200, reply: 540)
        return scene.steps
    }

    private static func writerDraft(folder: URL?) -> [DemoStep] {
        var scene = Scene()
        let base = folder ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let guide = base.appendingPathComponent("style-guide.md").path
        let post = base.appendingPathComponent("launch-post.md").path
        let draft = """
            **Three AI launches worth your week**

            Lumen Notes 2 records your meetings offline and hands you the action items before \
            you've left the room. Pathway Agents open-sources workflow agents, with a debugger you \
            can actually watch. And Quill Voice translates live in 40 languages, right on your laptop.
            """
        scene.wait(0.4)
        scene.tool("Read", ["file_path": guide], result: "Warm, plain, short sentences.", after: 0.7)
        scene.file(path: post, contents: draft + "\n")
        scene.tool("Write", ["file_path": post, "content": draft], result: "File created successfully", after: 1.1)
        scene.say("Here's the draft, saved as launch-post.md:\n\n" + draft + "\n\nWant a shorter cut for social?")
        scene.finish(cached: 21_000, new: 3_400, reply: 410)
        return scene.steps
    }

    private static func leadBrief() -> [DemoStep] {
        var scene = Scene()
        scene.wait(0.4)
        scene.tool("mcp__bupsy__read_chat", ["bot": "Scout"], result: "Top 3 AI launches, sent to Writer.", after: 0.55)
        scene.tool("mcp__bupsy__read_chat", ["bot": "Writer"], result: "Roundup post drafted.", after: 0.55)
        scene.tool("mcp__bupsy__read_chat", ["bot": "Researcher"], result: "Pricing table done.", after: 0.55)
        scene.say("""
            Morning! Here's where the launch is.

            **Moving**
            - Scout found this week's top 3 AI launches.
            - Writer drafted the roundup post in launch-post.md.
            - Researcher's pricing table is done.

            **Blocked**
            - Nothing.

            **Needs you**
            - A quick yes on the roundup post, so it goes out Thursday.
            """)
        scene.finish(cached: 44_900, new: 3_100, reply: 880)
        return scene.steps
    }

    private static func fallback() -> [DemoStep] {
        var scene = Scene()
        scene.wait(0.5)
        scene.say("On it. I'll fold that into what I'm doing and tell you when it's done.")
        scene.finish(cached: 12_000, new: 800, reply: 90)
        return scene.steps
    }

    // MARK: - Building a scene

    /// Steps, written as Claude Code would stream them.
    private struct Scene {
        var steps: [DemoStep] = []
        let session = UUID().uuidString.lowercased()
        private var count = 0
        private var said = ""

        init() {
            steps.append(.line(Self.json([
                "type": "system", "subtype": "init", "session_id": session,
                "mcp_servers": [["name": "bupsy", "status": "connected"]],
            ])))
            let hour = Date().addingTimeInterval(3 * 3_600).timeIntervalSince1970.rounded()
            let week = Date().addingTimeInterval(4 * 86_400).timeIntervalSince1970.rounded()
            steps.append(.line(Self.json([
                "type": "rate_limit_event",
                "rate_limit_info": [
                    "status": "allowed", "isUsingOverage": false,
                    "unifiedWindows": [
                        "five_hour": ["utilization": 0.18, "resetsAt": hour],
                        "seven_day": ["utilization": 0.31, "resetsAt": week],
                    ],
                ],
            ])))
        }

        mutating func wait(_ seconds: Double) { steps.append(.wait(seconds)) }

        mutating func file(path: String, contents: String) { steps.append(.file(path: path, contents: contents)) }

        /// Text a few words at a time, fast but readable.
        mutating func say(_ text: String) {
            said = text
            var chunk = ""
            var words = 0
            for piece in Self.pieces(of: text) {
                chunk += piece
                words += 1
                if words == 3 || piece.contains("\n") {
                    emitText(chunk)
                    chunk = ""
                    words = 0
                }
            }
            if !chunk.isEmpty { emitText(chunk) }
        }

        private mutating func emitText(_ chunk: String) {
            steps.append(.line(Self.json([
                "type": "assistant",
                "message": ["role": "assistant", "content": [["type": "text", "text": chunk]]],
            ])))
            steps.append(.wait(0.06))
        }

        /// One tool call, its result `after` seconds later.
        mutating func tool(_ name: String, _ input: [String: String], drop: [String: String]? = nil,
                           result: String, after: Double) {
            let id = nextID()
            steps.append(.line(Self.call(id: id, name: name, input: input)))
            if let drop { steps.append(.drop(drop)) }
            steps.append(.wait(after))
            steps.append(.line(Self.result(id: id, content: result)))
            steps.append(.wait(0.15))
        }

        /// Calls made together, answered together.
        mutating func tools(_ calls: [(String, [String: String])], result: String, after: Double) {
            let ids = calls.map { _ in nextID() }
            for (id, call) in zip(ids, calls) { steps.append(.line(Self.call(id: id, name: call.0, input: call.1))) }
            steps.append(.wait(after))
            for id in ids { steps.append(.line(Self.result(id: id, content: result))) }
            steps.append(.wait(0.15))
        }

        /// The closing `result` line, with usage figures for the context meter.
        mutating func finish(cached: Int, new: Int, reply: Int) {
            steps.append(.wait(0.2))
            let turn: [String: Any] = [
                "input_tokens": 6, "cache_creation_input_tokens": new - 6,
                "cache_read_input_tokens": cached, "output_tokens": reply,
            ]
            steps.append(.line(Self.json([
                "type": "result", "subtype": "success", "is_error": false,
                "session_id": session, "result": said, "duration_ms": 6_400, "num_turns": 3,
                "usage": turn.merging(["iterations": [turn]]) { $1 },
                "modelUsage": ["claude-sonnet-5-5": ["contextWindow": 200_000]],
            ])))
        }

        private mutating func nextID() -> String {
            count += 1
            return "toolu_demo_\(session.prefix(8))_\(count)"
        }

        private static func call(id: String, name: String, input: [String: String]) -> String {
            json(["type": "assistant",
                  "message": ["role": "assistant",
                              "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
        }

        private static func result(id: String, content: String) -> String {
            json(["type": "user",
                  "message": ["role": "user",
                              "content": [["type": "tool_result", "tool_use_id": id, "content": content]]]])
        }

        /// Words with the space or line break after each one, so chunks rejoin exactly.
        private static func pieces(of text: String) -> [String] {
            var pieces: [String] = []
            var current = ""
            var inSpace = false
            for character in text {
                if character.isWhitespace {
                    inSpace = true
                    current.append(character)
                } else {
                    if inSpace { pieces.append(current); current = ""; inSpace = false }
                    current.append(character)
                }
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces
        }

        private static func json(_ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
#endif
