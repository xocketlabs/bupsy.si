import Foundation
import Testing
@testable import BupsyKit

/// Fixture-driven, because the stream schema is observed rather than documented. When spike 3
/// captures a real stream, replace the fixture and these tests tell you what changed.
@Suite("Claude stream normaliser")
struct ClaudeNormaliserTests {
    let adapter = ClaudeAdapter()

    private func events(fromFixture name: String) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: "ndjson"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { adapter.normalise(.stdout(String($0))) }
    }

    @Test("maps a whole session into canonical events")
    func mapsFullSession() throws {
        let events = try events(fromFixture: "claude-stream")

        #expect(events.contains(.text("Let me look at the files.")))
        #expect(events.contains(.text("Two entries: PLAN.md and docs.")))

        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.count == 1)
        #expect(calls.first?.name == "Bash")
        // Arguments are re-encoded with sorted keys so transcripts diff cleanly.
        #expect(calls.first?.argumentsJSON == #"{"command":"ls -la"}"#)

        let results = events.compactMap { if case .toolResult(let r) = $0 { r } else { nil } }
        #expect(results.first?.callID == "call_1")
        #expect(results.first?.isError == false)
    }

    /// Both engines must report the resume handle early, from different places: Codex has
    /// `thread.started`, Claude has `session_id` on its init banner. Same canonical event.
    @Test("emits .started from the init banner, before any work")
    func emitsStartedEarly() throws {
        let events = try events(fromFixture: "claude-stream")
        let started = events.firstIndex { if case .started = $0 { true } else { false } }
        let firstText = events.firstIndex { if case .text = $0 { true } else { false } }
        #expect(started != nil)
        #expect(events[started!] == .started(conversationID: ConversationID("sess-abc123")))
        if let started, let firstText { #expect(started < firstText) }
    }

    /// Observed in M0: the init line reports a live status per connector. Worth more than
    /// inferring readiness from configuration, because a server can be configured perfectly and
    /// still fail to start — and a tick next to something about to break a run is worse than
    /// no tick at all.
    @Test("reads real connector status from the init line")
    func readsConnectorStatus() {
        let events = adapter.normalise(.stdout(#"""
            {"type":"system","subtype":"init","session_id":"s1","mcp_servers":[\
            {"name":"files","status":"connected"},{"name":"fcpxml","status":"failed"},\
            {"name":"cloudflare","status":"needs-auth"}]}
            """#.replacingOccurrences(of: "\\\n", with: "")))

        let states = events.compactMap { if case .connectors(let s) = $0 { s } else { nil } }.first
        #expect(states?.count == 3)
        #expect(states?.first { $0.name == "files" }?.isUsable == true)
        #expect(states?.first { $0.name == "fcpxml" }?.status == .failed)
        #expect(states?.first { $0.name == "cloudflare" }?.status == .needsAuth)
    }

    @Test("carries usage and the resumable conversation id out of the result line")
    func extractsOutcome() throws {
        let events = try events(fromFixture: "claude-stream")
        let outcome = try #require(events.compactMap {
            if case .done(let o) = $0 { o } else { nil }
        }.first)

        #expect(outcome.conversationID == ConversationID("sess-abc123"))
        #expect(outcome.usage?.inputTokens == 1200)
        #expect(outcome.usage?.outputTokens == 48)
        #expect(outcome.usage?.durationMS == 4210)
    }

    /// Spike 3 found `claude` volunteering the user's own subscription utilisation. It drives
    /// the limit-burn gauge, so it must survive refactors — and degrade, not crash, if the
    /// undocumented shape changes.
    @Test("reads subscription headroom out of rate_limit_event")
    func mapsRateLimits() throws {
        let events = try events(fromFixture: "claude-stream")
        let limit = try #require(events.compactMap {
            if case .rateLimit(let l) = $0 { l } else { nil }
        }.first)

        #expect(limit.status == "allowed")
        #expect(limit.isUsingOverage == false)
        #expect(limit.windows["five_hour"]?.utilization == 0.03)
        #expect(limit.windows["seven_day"]?.utilization == 0.01)
        #expect(limit.windows["five_hour"]?.resetsAt != nil)
        // Warnings are driven from whichever window is closest to exhaustion.
        #expect(limit.tightest?.name == "five_hour")
    }

    @Test("a malformed rate_limit_event degrades instead of crashing")
    func toleratesMalformedRateLimit() {
        let events = adapter.normalise(.stdout(#"{"type":"rate_limit_event"}"#))
        #expect(events.count == 1)
        if case .unknown = events[0] {} else {
            Issue.record("expected an unmodelled line, got \(events[0])")
        }

        let partial = adapter.normalise(
            .stdout(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#))
        let limit = partial.compactMap { if case .rateLimit(let l) = $0 { l } else { nil } }.first
        #expect(limit?.windows.isEmpty == true)
        #expect(limit?.status == "allowed")
    }

    /// The property that matters most: a schema change must surface, not vanish.
    @Test("surfaces unmodelled lines instead of dropping them")
    func neverDropsInput() throws {
        let events = try events(fromFixture: "claude-stream")
        let unknown = events.compactMap { if case .unknown(let raw) = $0 { raw } else { nil } }
        #expect(unknown.count == 1)
        #expect(unknown.first?.contains("some_future_event") == true)
    }

    @Test("ignores non-JSON noise on stdout")
    func ignoresNoise() {
        #expect(adapter.normalise(.stdout("")).isEmpty)
        #expect(adapter.normalise(.stdout("Loading…")).isEmpty)
    }

    @Test("reports a signed-out engine as a typed failure")
    func detectsSignedOut() {
        let events = adapter.normalise(.stderr("Error: not logged in. Please run /login"))
        let failure = events.compactMap { if case .failed(let f) = $0 { f } else { nil } }.first
        #expect(failure?.kind == .notSignedIn)
    }

    @Test("a non-zero exit is a failure, a clean exit is silence")
    func mapsExitCodes() {
        #expect(adapter.normalise(.exit(code: 0)).isEmpty)
        let events = adapter.normalise(.exit(code: 1))
        #expect(events.count == 1)
    }
}

@Suite("Host and engine contracts")
struct ContractTests {
    /// The promise the product makes about lid-closed autonomy is encoded in the type system.
    @Test("only cloud hosts survive sleep")
    func sleepSemantics() {
        #expect(LocalHost().survivesSleep == false)
        #expect(HostID.cloud(provider: .boat).survivesSleep == true)
        #expect(HostID.local.survivesSleep == false)
    }

    @Test("a local host refuses to hold a schedule rather than silently missing it")
    func localRefusesTriggers() async {
        await #expect(throws: HostError.self) {
            try await LocalHost().installTrigger(
                HostTrigger(id: "t1", cron: "0 7 * * 1-5", command: "bupsy-run inbox t1"))
        }
    }

    @Test("autonomy is ordered so policy can be compared")
    func autonomyOrdering() {
        #expect(Autonomy.ask < .allowlist)
        #expect(Autonomy.allowlist < .trusted)
        #expect(Autonomy.trusted < .auto)
    }

    @Test("resume and model flags reach the invocation")
    func buildsInvocation() {
        let invocation = ClaudeAdapter().invocation(for: RunRequest(
            prompt: "hi", resume: ConversationID("sess-1"), model: "claude-opus-5",
            mcpConfigPaths: ["/tmp/mcp.json"]))

        #expect(invocation.arguments.contains("--output-format"))
        #expect(invocation.arguments.contains("stream-json"))
        #expect(invocation.arguments.contains("sess-1"))
        #expect(invocation.arguments.contains("claude-opus-5"))
        #expect(invocation.arguments.contains("/tmp/mcp.json"))
    }

    /// Settings → Engines must keep working: the terms forbid restricting an engine's own
    /// authentication paths, and a user pinning a specific build is a legitimate need.
    @Test("a user-chosen binary path overrides the default")
    func honoursBinaryOverride() {
        #expect(ClaudeAdapter(binary: "/opt/custom/claude").binaryName == "/opt/custom/claude")
        #expect(ClaudeAdapter().binaryName == "claude")
    }
}
