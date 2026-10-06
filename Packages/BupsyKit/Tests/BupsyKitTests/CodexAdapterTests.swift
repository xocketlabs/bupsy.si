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

    /// M0 read this line as the signal that Codex was about to hang on an open stdin, and this
    /// test used to assert it became a protocol failure. Rechecked against the real binary, that
    /// was wrong: Codex prints it on *every* run, including with stdin on `/dev/null`, where it
    /// reads EOF and carries on normally. `codex exec --help` confirms the design — stdin is
    /// simply an additional input channel.
    ///
    /// So the old behaviour failed every Codex run before it produced a single event. The test
    /// passed throughout, because it asserted the mapping rather than the premise behind it. Kept
    /// as a regression guard with its meaning inverted: a hang is only detectable by a timeout,
    /// which belongs to the host.
    @Test("the stdin notice is routine and produces nothing")
    func stdinNoticeIsNotAFailure() {
        #expect(adapter.normalise(.stderr("Reading additional input from stdin...")).isEmpty)
    }

    /// The line that *does* stop a run. It was being dropped, which left the user with no events
    /// and no reason — the worst way for anything to fail.
    @Test("reports a refusal to run outside a git repository")
    func reportsUntrustedDirectory() {
        let events = adapter.normalise(.stderr(
            "Not inside a trusted directory and --skip-git-repo-check was not specified."))
        let failure = events.compactMap { if case .failed(let f) = $0 { f } else { nil } }.first
        #expect(failure?.kind == .untrustedDirectory)
        #expect(failure?.message.contains("git repository") == true)
    }

    /// The override is passed for read-only runs, where Codex's recoverability concern cannot
    /// apply, and withheld once writes are possible — where it can.
    @Test("the git-repo override follows the sandbox, not convenience")
    func gitRepoOverrideIsConditional() {
        let readOnly = adapter.invocation(for: RunRequest(prompt: "hi", autonomy: .ask)).arguments
        #expect(readOnly.contains("--skip-git-repo-check"))

        let writable = adapter
            .invocation(for: RunRequest(prompt: "hi", autonomy: .trusted)).arguments
        #expect(!writable.contains("--skip-git-repo-check"))
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

    /// `codex exec resume` rejects `--sandbox` and `-C` ("unexpected argument"), so they must sit
    /// on `exec`, ahead of the subcommand. The old order failed every resumed run before it began.
    @Test("a resumed run puts every option before the resume subcommand")
    func resumeOptionsPrecedeSubcommand() throws {
        let args = CodexAdapter().invocation(for: RunRequest(
            prompt: "carry on", workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            resume: ConversationID("t-9"), model: "gpt-x", autonomy: .auto)).arguments
        #expect(args == [
            "exec", "--json", "--sandbox", "danger-full-access",
            "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-x", "-C", "/tmp/work",
            "resume", "t-9", "carry on",
        ])
        let resume = try #require(args.firstIndex(of: "resume"))
        for flag in ["--sandbox", "-C", "-m", "--json"] {
            let at = try #require(args.firstIndex(of: flag))
            #expect(at < resume, "\(flag) must precede `resume`")
        }
    }

    /// A persona or prompt that opens with "-" must not be parsed as a flag.
    @Test("a prompt starting with a dash is passed after --")
    func dashPromptIsPositional() {
        let codex = CodexAdapter().invocation(for: RunRequest(
            prompt: "-rf everything", resume: ConversationID("t-9"))).arguments
        #expect(Array(codex.suffix(4)) == ["resume", "t-9", "--", "-rf everything"])
        let claude = ClaudeAdapter().invocation(for: RunRequest(
            prompt: "--help me", mcpConfigPaths: ["/x.json"])).arguments
        #expect(Array(claude.suffix(2)) == ["--", "--help me"])
        #expect(claude.filter { $0 == "--help me" }.count == 1)
        // An ordinary prompt keeps the argv every core agrees on.
        #expect(!CodexAdapter().invocation(for: RunRequest(prompt: "hi")).arguments.contains("--"))
        #expect(!ClaudeAdapter().invocation(for: RunRequest(prompt: "hi")).arguments.contains("--"))
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
