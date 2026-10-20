import Foundation

/// Runs a bot on a model in the person's own Ollama or LM Studio, through Codex CLI's local mode:
/// `codex exec --oss --local-provider <ollama|lmstudio> -m <model>`.
///
/// Everything else is Codex's, so it is `CodexAdapter`'s: the argv rules (every option on `exec`,
/// before `resume`), the sandbox that enforces trust, the JSON event stream, and the session files
/// the context meter reads. This adapter adds the two local flags and one rule that matters more
/// than the rest:
///
/// **Never start without `-m` naming a model that is installed.** Given `--oss` and no model,
/// Codex pulls `gpt-oss:20b` (about 13 GB) on its own, and given a model Ollama does not have, it
/// pulls that one. A bot must never start a download nobody asked for, so `prepare` checks the
/// model against what the provider lists right now, and `invocation` refuses outright when the
/// request names no provider and model.
public struct LocalAdapter: EngineAdapter {
    public let id: EngineID = .local
    public var binaryName: String { codex.binaryName }

    private let codex: CodexAdapter
    private let discovery: LocalDiscovery

    public init(binary: String? = nil, discovery: LocalDiscovery = LocalDiscovery()) {
        self.codex = CodexAdapter(binary: binary)
        self.discovery = discovery
    }

    public var maximumEnforceableAutonomy: Autonomy { codex.maximumEnforceableAutonomy }
    public var gateMechanism: GateMechanism { codex.gateMechanism }

    /// Empty here: the models are whatever the person has installed, read live with
    /// `discover()` and offered from there. A fixed list would name models they do not have,
    /// and picking one would start a download.
    public var models: [ModelOption] { [] }

    /// What is running on this Mac now, and its models.
    public func discover() async -> LocalRuntime { await discovery.discover() }

    /// There is nothing to sign in to. The "command" is the first step of getting a model, shown
    /// as a suggestion; Bupsy itself never runs it, since it would download several gigabytes.
    public func loginCommand() -> LoginCommand {
        LoginCommand(
            command: "ollama pull qwen3:8b",
            hint: "Install Ollama (ollama.com) or LM Studio (lmstudio.ai), then get a model. "
                + "Nothing to sign in to: the model runs on this Mac."
        )
    }

    /// Codex installed, then the runtime. No model is started: a probe turn would load one into
    /// memory, and with the wrong id would start a download.
    public func authStatus(on host: any ExecutionHost) async -> AuthStatus {
        if let missing = await codexMissing(on: host) { return missing }
        return await discovery.discover().status
    }

    /// `.notInstalled` when there is no `codex`, an `.unknown` when it could not be asked, or nil
    /// when it is there.
    private func codexMissing(on host: any ExecutionHost) async -> AuthStatus? {
        let probe = EngineInvocation(executable: binaryName, arguments: ["--version"])
        do {
            for try await chunk in try await host.spawn(probe) {
                guard case .exit(let code) = chunk else { continue }
                // 127 is the shell's "command not found", from a host that runs through one.
                return code == 127 ? .notInstalled : nil
            }
            return nil
        } catch HostError.binaryNotFound(_) {
            return .notInstalled
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Makes the model exact, or refuses the run. A bare name someone typed is matched to the
    /// provider that has it; a model that is not installed is refused, never left for Codex to
    /// download.
    public func prepare(_ request: RunRequest) async throws -> RunRequest {
        // Checked before asking anything, so a bot with no model fails at once.
        if (request.model?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty {
            throw RunRefused(LocalModelProblem.noModelChosen.failure)
        }
        switch await discovery.discover().resolve(request.model) {
        case .success(let model):
            var prepared = request
            prepared.model = model.id
            return prepared
        case .failure(let problem):
            throw RunRefused(problem.failure)
        }
    }

    public func invocation(for request: RunRequest) -> EngineInvocation {
        guard let model = request.model.flatMap(LocalModel.init(id:)) else {
            // A caller that skipped `prepare`. Running codex here would mean `--oss` without a
            // model, which downloads one, so this runs nothing and says why instead.
            return Self.refusal(LocalModelProblem.noModelChosen.description)
        }
        var forCodex = request
        forCodex.model = model.name
        var invocation = codex.invocation(for: forCodex)
        // On `exec`, before everything else and so before any `resume`: `codex exec resume`
        // has no `--oss` or `--local-provider` of its own, and takes them from `exec`. Checked
        // against `codex exec --help` and `codex exec resume --help` (codex-cli 0.160).
        let local = ["--oss", "--local-provider", model.provider.rawValue]
        let at = invocation.arguments.firstIndex(of: "--json").map { $0 + 1 } ?? 1
        invocation.arguments.insert(contentsOf: local, at: at)
        return invocation
    }

    /// Prefixes the line a refusal prints, so `normalise` can tell it from Codex's own output.
    static let refusalPrefix = "bupsy-local-refused: "

    /// A process that prints the reason and exits, in place of a run that must not start.
    static func refusal(_ message: String) -> EngineInvocation {
        EngineInvocation(
            executable: "/bin/sh",
            // The message is an argument, never part of the script, so nothing in it is run.
            arguments: ["-c", "printf '%s%s\\n' \"$1\" \"$2\" >&2; exit 64", "sh", refusalPrefix, message]
        )
    }

    public func normalise(_ output: HostOutput) -> [AgentEvent] {
        if case .stderr(let line) = output {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(Self.refusalPrefix) {
                return [.failed(EngineFailure(kind: .launchFailed,
                                              message: String(trimmed.dropFirst(Self.refusalPrefix.count))))]
            }
            // Codex's own check that the runtime is up, e.g. "Error: OSS setup failed: No running
            // Ollama server detected. Start it with: `ollama serve`". It stops the run before any
            // event, so dropping it would leave the chat with no reason at all.
            if let range = trimmed.range(of: "OSS setup failed: ") {
                var reason = String(trimmed[range.upperBound...])
                while let again = reason.range(of: "OSS setup failed: ") { reason = String(reason[again.upperBound...]) }
                return [.failed(EngineFailure(kind: .notSignedIn, message: reason))]
            }
        }
        return codex.normalise(output)
    }
}
