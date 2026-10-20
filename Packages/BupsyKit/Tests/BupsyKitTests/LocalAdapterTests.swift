import Foundation
import Testing
@testable import BupsyKit

/// Answers a spawn the way a host would, so the "is codex here" check runs without a real CLI.
private struct FakeHost: ExecutionHost {
    var codexInstalled = true
    let id: HostID = .local
    var survivesSleep: Bool { false }

    func spawn(_ invocation: EngineInvocation) async throws -> AsyncThrowingStream<HostOutput, Error> {
        guard codexInstalled else { throw HostError.binaryNotFound(invocation.executable) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout("codex-cli 0.160.0"))
            continuation.yield(.exit(code: 0))
            continuation.finish()
        }
    }

    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, _ data: Data) async throws {}
    func installTrigger(_ trigger: HostTrigger) async throws {}
    func desktopURL() async throws -> URL? { nil }
    func wake() async throws {}
    func sleep() async throws {}
}

/// Shapes of the real replies, trimmed: Ollama's `/api/tags` and LM Studio's `/v1/models`.
private enum Replies {
    static let ollama = #"""
    {"models":[
      {"name":"qwen3:8b","model":"qwen3:8b","modified_at":"2026-09-01T10:00:00Z","size":5225388164,
       "details":{"family":"qwen3","parameter_size":"8.2B","quantization_level":"Q4_K_M"}},
      {"name":"gpt-oss:20b","model":"gpt-oss:20b","size":13780173839},
      {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":274302450}
    ]}
    """#
    static let ollamaEmpty = #"{"models":[]}"#
    static let lmstudio = #"""
    {"object":"list","data":[
      {"id":"qwen/qwen3-8b","object":"model","owned_by":"organization_owner"},
      {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","owned_by":"organization_owner"}
    ]}
    """#
}

/// A fetch that serves the given bodies by port and fails like a closed port for the rest.
private func fetch(ollama: String? = nil, lmstudio: String? = nil) -> LocalDiscovery.Fetch {
    { url in
        let body = url.port == 11434 ? ollama : url.port == 1234 ? lmstudio : nil
        guard let body else { throw URLError(.cannotConnectToHost) }
        return Data(body.utf8)
    }
}

private func adapter(ollama: String? = nil, lmstudio: String? = nil) -> LocalAdapter {
    LocalAdapter(discovery: LocalDiscovery(fetch: fetch(ollama: ollama, lmstudio: lmstudio)))
}

@Suite("Local model: invocation")
struct LocalInvocationTests {
    let local = LocalAdapter()

    @Test("adds --oss, the provider and -m to Codex's own argv")
    func freshRun() {
        let argv = local.invocation(for: RunRequest(prompt: "list the files", model: "ollama:qwen3:8b")).arguments
        #expect(argv == ["exec", "--json", "--oss", "--local-provider", "ollama",
                         "--sandbox", "read-only", "--skip-git-repo-check", "-m", "qwen3:8b", "list the files"])
    }

    /// `codex exec resume` has no --oss or --local-provider, so they must sit on `exec`.
    @Test("every local flag goes before resume, and the model keeps its own colons")
    func resumedRun() throws {
        let request = RunRequest(prompt: "carry on", workingDirectory: URL(fileURLWithPath: "/tmp/work"),
                                 resume: ConversationID("01a0fc87-6711"), model: "lmstudio:qwen/qwen3-8b",
                                 autonomy: .trusted)
        let argv = local.invocation(for: request).arguments
        let resume = try #require(argv.firstIndex(of: "resume"))
        for flag in ["--oss", "--local-provider", "-m", "--sandbox", "-C"] {
            let at = try #require(argv.firstIndex(of: flag), "\(flag) is missing")
            #expect(at < resume, "\(flag) must come before resume")
        }
        #expect(argv[argv.firstIndex(of: "--local-provider")! + 1] == "lmstudio")
        #expect(argv[argv.firstIndex(of: "-m")! + 1] == "qwen/qwen3-8b")
        #expect(Array(argv.suffix(3)) == ["resume", "01a0fc87-6711", "carry on"])
    }

    @Test("Codex's own rules still apply: sandbox per trust, -- before a prompt that looks like a flag")
    func codexRulesCarryOver() {
        let auto = local.invocation(for: RunRequest(prompt: "ship it", model: "ollama:qwen3:8b", autonomy: .auto))
        #expect(auto.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(auto.executable == "codex")
        let dashed = local.invocation(for: RunRequest(prompt: "- be terse", model: "ollama:qwen3:8b")).arguments
        #expect(Array(dashed.suffix(2)) == ["--", "- be terse"])
    }

    /// Without -m, `codex exec --oss` pulls gpt-oss:20b (about 13 GB) on its own.
    @Test("no model, or one that names no provider, never reaches codex", arguments: [nil, "", "qwen3:8b", "llama:3", "ollama:"])
    func refusesWithoutModel(_ model: String?) {
        let invocation = local.invocation(for: RunRequest(prompt: "hi", model: model))
        #expect(invocation.executable != "codex")
        #expect(!invocation.arguments.contains("--oss"))
    }

    @Test("the refusal reads as a failure that says why")
    func refusalIsAFailure() {
        let invocation = LocalAdapter.refusal(LocalModelProblem.noModelChosen.description)
        let line = LocalAdapter.refusalPrefix + LocalModelProblem.noModelChosen.description
        #expect(invocation.arguments.last == LocalModelProblem.noModelChosen.description)
        let events = local.normalise(.stderr(line))
        #expect(events == [.failed(EngineFailure(kind: .launchFailed, message: LocalModelProblem.noModelChosen.description))])
    }

    @Test("Codex's own runtime check surfaces in the chat instead of vanishing")
    func ossSetupFailure() {
        let events = local.normalise(.stderr(
            "Error: OSS setup failed: OSS setup failed: LM Studio is not responding. Install from https://lmstudio.ai/download and run 'lms server start'."))
        #expect(events == [.failed(EngineFailure(kind: .notSignedIn,
            message: "LM Studio is not responding. Install from https://lmstudio.ai/download and run 'lms server start'."))])
    }

    @Test("the stream itself is Codex's")
    func streamIsCodex() {
        #expect(local.normalise(.stdout(#"{"type":"thread.started","thread_id":"t-1"}"#))
            == [.started(conversationID: ConversationID("t-1"))])
        #expect(local.gateMechanism == .sandboxPolicy)
        #expect(local.models.isEmpty)
    }
}

@Suite("Local model: reading what is installed")
struct LocalDiscoveryTests {
    @Test("Ollama's /api/tags gives model names, without embedding models")
    func ollamaNames() {
        #expect(LocalProvider.ollama.modelNames(in: Data(Replies.ollama.utf8)) == ["qwen3:8b", "gpt-oss:20b"])
        #expect(LocalProvider.ollama.modelNames(in: Data(Replies.ollamaEmpty.utf8)) == [])
    }

    @Test("LM Studio's /v1/models gives ids, without embedding models")
    func lmstudioNames() {
        #expect(LocalProvider.lmstudio.modelNames(in: Data(Replies.lmstudio.utf8)) == ["qwen/qwen3-8b"])
    }

    @Test("a reply of the wrong shape is not that provider")
    func wrongShape() {
        #expect(LocalProvider.ollama.modelNames(in: Data(Replies.lmstudio.utf8)) == nil)
        #expect(LocalProvider.lmstudio.modelNames(in: Data("<html>".utf8)) == nil)
    }

    @Test("both running: both listed, Ollama first, each with its provider in the id")
    func bothRunning() async {
        let runtime = await LocalDiscovery(fetch: fetch(ollama: Replies.ollama, lmstudio: Replies.lmstudio)).discover()
        #expect(runtime.running == [.ollama, .lmstudio])
        #expect(runtime.options.map(\.id) == ["ollama:qwen3:8b", "ollama:gpt-oss:20b", "lmstudio:qwen/qwen3-8b"])
        #expect(runtime.options.first?.label == "qwen3:8b")
        #expect(runtime.options.last?.detail == "LM Studio")
    }

    @Test("stored ids split at the first colon only")
    func modelIDs() {
        #expect(LocalModel(id: "ollama:qwen3:8b") == LocalModel(provider: .ollama, name: "qwen3:8b"))
        #expect(LocalModel(id: "lmstudio:qwen/qwen3-8b")?.name == "qwen/qwen3-8b")
        #expect(LocalModel(id: "qwen3:8b") == nil)
        #expect(LocalModel(provider: .ollama, name: "qwen3:8b").id == "ollama:qwen3:8b")
    }

    @Test("only an installed model resolves")
    func resolving() throws {
        let runtime = LocalRuntime(running: [.ollama, .lmstudio], models: [
            LocalModel(provider: .ollama, name: "qwen3:8b"),
            LocalModel(provider: .lmstudio, name: "qwen/qwen3-8b"),
        ])
        try #expect(runtime.resolve("ollama:qwen3:8b").get().id == "ollama:qwen3:8b")
        // A bare name someone typed finds the provider that has it.
        try #expect(runtime.resolve("qwen/qwen3-8b").get().provider == .lmstudio)
        #expect(runtime.resolve(nil) == .failure(.noModelChosen))
        #expect(runtime.resolve("ollama:gpt-oss:20b") == .failure(.notInstalled(name: "gpt-oss:20b", provider: .ollama)))
        #expect(runtime.resolve("llama3") == .failure(.notInstalled(name: "llama3", provider: nil)))
        #expect(LocalRuntime().resolve("ollama:qwen3:8b") == .failure(.noRuntime))
        #expect(LocalRuntime(running: [.lmstudio]).resolve("ollama:qwen3:8b") == .failure(.providerNotRunning(.ollama)))
        #expect(LocalRuntime(running: [.ollama]).resolve("ollama:qwen3:8b") == .failure(.noModels(.ollama)))
    }
}

@Suite("Local model: status and refusing a run")
struct LocalStatusTests {
    @Test("no codex: not installed")
    func noCodex() async {
        let status = await adapter(ollama: Replies.ollama).authStatus(on: FakeHost(codexInstalled: false))
        #expect(status == .notInstalled)
    }

    @Test("neither runtime running: says to start one")
    func nothingRunning() async {
        let status = await adapter().authStatus(on: FakeHost())
        #expect(status == .notReady("Start Ollama or LM Studio"))
        #expect(!status.isUsable)
    }

    @Test("running with no models: says to pull one")
    func noModels() async {
        #expect(await adapter(ollama: Replies.ollamaEmpty).authStatus(on: FakeHost())
            == .notReady("Pull a model first, e.g. ollama pull qwen3:8b"))
        #expect(await adapter(lmstudio: #"{"data":[]}"#).authStatus(on: FakeHost())
            == .notReady("Download a model in LM Studio first, e.g. Qwen3 8B"))
    }

    @Test("a model installed: ready, on this Mac")
    func ready() async {
        let status = await adapter(lmstudio: Replies.lmstudio).authStatus(on: FakeHost())
        #expect(status == .signedIn(method: .onThisMac))
        #expect(status.isUsable)
    }

    @Test("prepare makes a bare name exact")
    func prepareResolves() async throws {
        let prepared = try await adapter(ollama: Replies.ollama).prepare(RunRequest(prompt: "hi", model: "qwen3:8b"))
        #expect(prepared.model == "ollama:qwen3:8b")
    }

    @Test("prepare refuses no model before asking anything")
    func prepareNoModel() async {
        let never = LocalAdapter(discovery: LocalDiscovery(fetch: { _ in
            Issue.record("asked a provider for a run with no model")
            return Data()
        }))
        await #expect(throws: RunRefused(LocalModelProblem.noModelChosen.failure)) {
            try await never.prepare(RunRequest(prompt: "hi", model: nil))
        }
    }

    @Test("prepare refuses a model that isn't installed, so Codex never pulls it")
    func prepareNotInstalled() async {
        await #expect(throws: RunRefused(LocalModelProblem.notInstalled(name: "llama3:70b", provider: .ollama).failure)) {
            try await adapter(ollama: Replies.ollama).prepare(RunRequest(prompt: "hi", model: "ollama:llama3:70b"))
        }
        await #expect(throws: RunRefused(LocalModelProblem.noRuntime.failure)) {
            try await adapter().prepare(RunRequest(prompt: "hi", model: "ollama:qwen3:8b"))
        }
    }

    @Test("Claude and Codex take the request as it is")
    func othersUnchanged() async throws {
        let request = RunRequest(prompt: "hi", model: "gpt-5.6")
        #expect(try await CodexAdapter().prepare(request).model == "gpt-5.6")
        #expect(try await ClaudeAdapter().prepare(request).model == "gpt-5.6")
    }

    @Test("engine facts: Local model runs on codex and has no plan limits")
    func engineFacts() {
        #expect(EngineID.local.displayName == "Local model")
        #expect(EngineID(rawValue: "local") == .local)
        #expect(EngineID.supported.contains(.local))
        #expect(EngineID.local.runsOnCodex && EngineID.codex.runsOnCodex && !EngineID.claude.runsOnCodex)
        #expect(!EngineID.local.hasPlanLimits && EngineID.claude.hasPlanLimits)
    }
}
