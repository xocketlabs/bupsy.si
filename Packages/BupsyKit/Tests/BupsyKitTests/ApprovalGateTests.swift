import Foundation
import Testing
@testable import BupsyKit

@Suite("Autonomy policy")
struct AutonomyPolicyTests {
    private func asks(_ outcome: AutonomyPolicy.Outcome) -> Bool {
        if case .ask = outcome { return true }
        return false
    }

    @Test("ask gates everything, including reads")
    func askGatesEverything() {
        for tool in ["Read", "Bash", "Write", "mcp__gmail__send"] {
            #expect(asks(AutonomyPolicy.decide(tool: tool, autonomy: .ask)))
        }
    }

    /// Bash is treated as outbound even though most commands are harmless. Its danger is in the
    /// argument, not the name, and a policy reasoning over tool names cannot tell `ls` from
    /// `rm -rf ~`.
    @Test("Bash is never silently safe above the allowlist")
    func bashIsOutbound() {
        #expect(asks(AutonomyPolicy.decide(tool: "Bash", autonomy: .trusted)))
        #expect(asks(AutonomyPolicy.decide(tool: "Bash", autonomy: .allowlist)))
        // Unless the user said so knowingly, which is what an allowlist is.
        #expect(!asks(AutonomyPolicy.decide(
            tool: "Bash", autonomy: .allowlist, allowlist: ["Bash"])))
    }

    @Test("trusted still asks before anything leaves the machine")
    func trustedGatesOutbound() {
        #expect(!asks(AutonomyPolicy.decide(tool: "Read", autonomy: .trusted)))
        #expect(!asks(AutonomyPolicy.decide(tool: "Grep", autonomy: .trusted)))
        #expect(asks(AutonomyPolicy.decide(tool: "WebFetch", autonomy: .trusted)))
        #expect(asks(AutonomyPolicy.decide(tool: "Write", autonomy: .trusted)))
    }

    /// Connector tools reach the user's real Gmail and Slack. They are never implicitly safe.
    @Test("MCP connector tools are gated unless autonomy is auto")
    func mcpToolsAreGated() {
        #expect(asks(AutonomyPolicy.decide(tool: "mcp__gmail__send", autonomy: .trusted)))
        #expect(asks(AutonomyPolicy.decide(tool: "mcp__slack__post", autonomy: .allowlist)))
        #expect(!asks(AutonomyPolicy.decide(tool: "mcp__gmail__send", autonomy: .auto)))
    }

    /// Even auto returns a decision with a named rule, so the audit log records *why* something
    /// ran rather than leaving a hole where the gate would have been.
    @Test("auto allows but still names the rule it allowed under")
    func autoIsStillRecorded() {
        guard case .allow(let rule) = AutonomyPolicy.decide(tool: "Bash", autonomy: .auto) else {
            Issue.record("auto should allow"); return
        }
        #expect(rule == "autonomy: auto")
    }
}

@Suite("Approval gate")
struct ApprovalGateTests {

    @Test("emits the exact JSON Claude Code reads back from a PreToolUse hook")
    func hookResponseShape() throws {
        let allow = ApprovalGate.hookResponse(for: .allow(reason: "you said so"))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(allow.utf8)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(output["hookEventName"] as? String == "PreToolUse")
        #expect(output["permissionDecision"] as? String == "allow")
        #expect(output["permissionDecisionReason"] as? String == "you said so")

        let deny = ApprovalGate.hookResponse(for: .deny(reason: "no"))
        #expect(deny.contains("\"permissionDecision\":\"deny\""))
    }

    @Test("settings install the hook for every tool, at command-line precedence")
    func settingsShape() throws {
        let json = GateInstaller.settingsJSON(scriptPath: "/tmp/gate.sh")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])

        #expect(pre.first?["matcher"] as? String == "*")
        let handlers = try #require(pre.first?["hooks"] as? [[String: Any]])
        #expect(handlers.first?["command"] as? String == "/tmp/gate.sh")
        #expect(handlers.first?["type"] as? String == "command")
    }

    /// The script is the thing that actually runs at 3am, so it gets exercised rather than
    /// inspected. This spawns it exactly as Claude Code would.
    @Test("the hook script relays a decision back to the engine")
    func scriptRelaysDecision() async throws {
        let gate = try ApprovalGate.temporary()
        let settings = try GateInstaller.install(gateDirectory: gate.directory)
        #expect(FileManager.default.fileExists(atPath: settings.path))

        let output = try await runScript(
            gate: gate,
            input: #"{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1"}"#,
            respond: { id in try await gate.decide(id, .allow(reason: "fine")) }
        )

        #expect(output.contains("\"permissionDecision\":\"allow\""))
        #expect(output.contains("fine"))
    }

    /// The safety argument in one test. A `PreToolUse` hook that lets its own timeout lapse
    /// causes the tool call to **proceed** — so the script must answer `deny` first. If this
    /// ever fails, an unattended bot silently gains permission to do anything.
    @Test("fails closed when nobody answers")
    func failsClosed() async throws {
        let gate = try ApprovalGate.temporary()
        _ = try GateInstaller.install(gateDirectory: gate.directory, timeoutSeconds: 2)

        let output = try await runScript(
            gate: gate,
            input: #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#,
            respond: { _ in }   // nobody is watching
        )

        #expect(output.contains("\"permissionDecision\":\"deny\""))
        #expect(output.contains("nobody approved this in time"))
    }

    @Test("parses a request and renders the field that says what will happen")
    func parsesRequest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data(#"{"tool_name":"Bash","tool_input":{"command":"npm test"},"session_id":"s9"}"#.utf8)
            .write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = try #require(ApprovalGate.parse(id: "r1", at: url))
        #expect(request.tool == "Bash")
        #expect(request.sessionID == "s9")
        #expect(request.summary == "npm test")
    }

    @Test("the adapter passes the gate settings to the engine")
    func adapterInstallsGate() {
        let arguments = ClaudeAdapter().invocation(for: RunRequest(
            prompt: "hi", gateSettingsPath: "/tmp/g/settings.json")).arguments
        #expect(arguments.contains("--settings"))
        #expect(arguments.contains("/tmp/g/settings.json"))
        // Widening permissions is not the same as gating them.
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    // MARK: - Helper

    /// Runs `gate.sh` the way the engine would, feeding it hook input on stdin and answering
    /// the request it raises.
    private func runScript(
        gate: ApprovalGate,
        input: String,
        respond: @escaping @Sendable (String) async throws -> Void
    ) async throws -> String {
        let watcher = Task {
            for await request in await gate.requests() {
                try? await respond(request.id)
                break
            }
        }
        defer { watcher.cancel() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [gate.directory.appendingPathComponent("gate.sh").path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        await gate.stop()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@Suite("Model options")
struct ModelOptionTests {
    /// Aliases first; exact versions only in their own section. Aliases track the newest model in
    /// each family, so they stay the obvious choice — a pinned version is something someone picks
    /// on purpose, never what they get by default.
    @Test("Claude offers aliases first, and versions only in their own section")
    func claudeAliasesFirst() {
        let models = ClaudeAdapter().models
        #expect(models.first?.id == nil)
        #expect(models.filter { $0.section == .latest }.map(\.id) == ["opus", "sonnet", "haiku", "fable"])
        let pinned = models.filter { $0.id?.hasPrefix("claude-") == true }
        #expect(!pinned.isEmpty)
        #expect(pinned.allSatisfy { $0.section == .version }, "a pinned version must not look like the default")
        #expect(pinned.contains { $0.id == "claude-opus-5-5" })
        let ids = models.compactMap(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("An unknown model reads as 'update Claude Code', naming the model")
    func unrecognisedModelIsExplained() {
        let raw = #"[claude-code:unrecognized_model] {"model":"claude-opus-5-5","query_source":"sdk"}"#
        let text = ClaudeAdapter.explainUnrecognisedModel(raw)
        #expect(text?.contains("claude-opus-5-5") == true)
        #expect(text?.contains("claude update") == true)
        #expect(ClaudeAdapter.explainUnrecognisedModel("rate limited") == nil)
    }

    /// Not overriding a model the user configured themselves is the right default.
    @Test("every engine offers a default that passes no model flag")
    func defaultPassesNothing() {
        for adapter: any EngineAdapter in [ClaudeAdapter(), CodexAdapter()] {
            #expect(adapter.models.first?.id == nil)
            #expect(adapter.models.first?.label == "Default")
        }
    }

    @Test("a chosen model reaches the command line for both engines")
    func modelReachesInvocation() {
        let claude = ClaudeAdapter().invocation(for: RunRequest(prompt: "x", model: "sonnet"))
        #expect(claude.arguments.contains("--model"))
        #expect(claude.arguments.contains("sonnet"))

        let codex = CodexAdapter().invocation(for: RunRequest(prompt: "x", model: "gpt-5.6"))
        #expect(codex.arguments.contains("-m"))
        #expect(codex.arguments.contains("gpt-5.6"))
    }

    /// No model chosen means no flag at all, rather than an empty one.
    @Test("no model means no flag")
    func noModelNoFlag() {
        let claude = ClaudeAdapter().invocation(for: RunRequest(prompt: "x"))
        #expect(!claude.arguments.contains("--model"))
        let codex = CodexAdapter().invocation(for: RunRequest(prompt: "x"))
        #expect(!codex.arguments.contains("-m"))
    }
}
