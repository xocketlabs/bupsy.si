import Foundation
import Testing
@testable import BupsyKit

/// Codex exists in the test suite to keep `AgentEvent` honest. If the envelope only ever had to
/// describe Claude it would quietly become Claude-shaped, and the adapter layer would be
/// decoration. Codex's thread/turn/item model shares no structure with Claude's, so these tests
/// are really testing the abstraction.
@Suite("Codex stream normaliser")
struct CodexAdapterTests {
    let adapter = CodexAdapter()

    private func events(fromFixture name: String) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: "ndjson"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { adapter.normalise(.stdout(String($0))) }
    }

    @Test("maps a thread/turn/item session into the same canonical events as Claude")
    func mapsSession() throws {
        let events = try events(fromFixture: "codex-stream")

        #expect(events.first == .started(conversationID: ConversationID("01a0fc87-6711-7501-9d7c-45b0a5cc5307")))
        #expect(events.contains(.text("Three entries: PLAN.md, Packages, docs.")))
        #expect(events.contains(.thinking("The user wants a file listing.")))

        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.count == 1)
        #expect(calls.first?.name == "shell")
        #expect(calls.first?.argumentsJSON == #"{"command":"ls -la"}"#)

        let outcome = events.compactMap { if case .done(let o) = $0 { o } else { nil } }.first
        #expect(outcome?.usage?.inputTokens == 1430)
        #expect(outcome?.usage?.outputTokens == 62)
    }

    /// The resume handle must arrive before any work, so a failed routine is still retryable.
    /// An earlier draft emitted `.done` here, which would have told the UI a run finished
    /// before it started.
    @Test("thread.started yields .started, never .done")
    func threadStartIsNotCompletion() {
        let events = adapter.normalise(
            .stdout(#"{"type":"thread.started","thread_id":"t-1"}"#))
        #expect(events == [.started(conversationID: ConversationID("t-1"))])
        #expect(!events.contains { if case .done = $0 { true } else { false } })
    }

    /// Captured verbatim from a real account in M0. `codex login status` said "Logged in using
    /// ChatGPT" while every model was rejected — so this stream is what "authenticated but
    /// unusable" actually looks like on the wire.
    @Test("unwraps the nested API error from a rejected turn")
    func unwrapsNestedError() throws {
        let events = try events(fromFixture: "codex-no-model-access")
        let failures = events.compactMap { if case .failed(let f) = $0 { f } else { nil } }

        #expect(failures.count >= 1)
        // Codex nests a JSON error document inside a string field; we unwrap one level so the
        // user reads the sentence, not the envelope.
        #expect(failures.contains { $0.message.contains("not supported when using Codex") })
        #expect(failures.allSatisfy { !$0.message.hasPrefix("{") })
        // The thread id still arrived, so the user can retry this thread with another model.
        #expect(events.first == .started(conversationID: ConversationID("01a0fc87-6711-7501-9d7c-45b0a5cc5307")))
    }

    @Test("surfaces unmodelled lines instead of dropping them")
    func neverDropsInput() throws {
        let unknown = try events(fromFixture: "codex-stream")
            .compactMap { if case .unknown(let raw) = $0 { raw } else { nil } }
        #expect(unknown.count == 1)
        #expect(unknown.first?.contains("some_future_event") == true)
    }

    /// Observed in M0: given a prompt argument and an open stdin, Codex prints this and waits
    /// forever. If it ever reaches a user, a host has stopped closing stdin — so it is reported
    /// as a protocol failure rather than ignored as noise.
    @Test("treats the stdin-wait warning as a protocol failure")
    func detectsStdinHang() {
        let events = adapter.normalise(.stderr("Reading additional input from stdin..."))
        let failure = events.compactMap { if case .failed(let f) = $0 { f } else { nil } }.first
        #expect(failure?.kind == .protocolError)
        #expect(failure?.message.contains("close") == true)
    }
}

@Suite("Autonomy maps onto each engine's real enforcement")
struct EnforcementTests {
    /// Codex has no mid-run human gate, so `.ask` cannot mean "wait for me" — it means
    /// "run read-only". The UI must say which, which is what `gateMechanism` is for.
    @Test("the autonomy ladder maps onto Codex sandbox policies")
    func sandboxMapping() {
        #expect(CodexAdapter.sandbox(for: .ask) == "read-only")
        #expect(CodexAdapter.sandbox(for: .allowlist) == "workspace-write")
        #expect(CodexAdapter.sandbox(for: .trusted) == "workspace-write")
        #expect(CodexAdapter.sandbox(for: .auto) == "danger-full-access")
    }

    @Test("only a blocking hook may promise to ask mid-run")
    func onlyHooksCanAsk() {
        #expect(ClaudeAdapter().gateMechanism.canAskMidRun)
        #expect(CodexAdapter().gateMechanism == .sandboxPolicy)
        #expect(!CodexAdapter().gateMechanism.canAskMidRun)
        #expect(!GateMechanism.none.canAskMidRun)
    }

    @Test("full bypass is reachable only at the top of the ladder")
    func bypassOnlyAtAuto() {
        let adapter = CodexAdapter()
        let bypass = "--dangerously-bypass-approvals-and-sandbox"
        for autonomy in [Autonomy.ask, .allowlist, .trusted] {
            let args = adapter.invocation(for: RunRequest(prompt: "x", autonomy: autonomy)).arguments
            #expect(!args.contains(bypass), "\(autonomy) must not bypass the sandbox")
        }
        #expect(adapter.invocation(for: RunRequest(prompt: "x", autonomy: .auto))
            .arguments.contains(bypass))
    }

    @Test("resume targets a thread and keeps the prompt last")
    func resumeShape() {
        let args = CodexAdapter().invocation(for: RunRequest(
            prompt: "carry on", resume: ConversationID("t-9"), model: "gpt-x")).arguments
        #expect(args.contains("resume"))
        #expect(args.contains("t-9"))
        #expect(args.contains("gpt-x"))
        #expect(args.last == "carry on")
    }

    /// "Logged in" and "can actually run" are different questions, and only the second matters.
    @Test("an account without model access is not usable")
    func usability() {
        #expect(AuthStatus.signedIn(method: .subscription).isUsable)
        #expect(!AuthStatus.signedInWithoutModelAccess(detail: "x").isUsable)
        #expect(!AuthStatus.signedOut.isUsable)
        #expect(!AuthStatus.unknown("x").isUsable)
    }
}
