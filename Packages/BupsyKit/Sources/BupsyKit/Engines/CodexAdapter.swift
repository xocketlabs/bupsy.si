import Foundation

/// Drives the published `codex` binary in `exec` mode.
///
/// Codex is nothing like Claude Code underneath, which is the point of having an adapter layer at
/// all. Three differences shape this file, each found by running the real binary in M0:
///
/// 1. **Event model.** Claude streams `assistant` / `user` / `result` envelopes. Codex streams a
///    thread-and-turn lifecycle (`thread.started`, `turn.started`, `turn.completed`) with content
///    arriving as typed *items* (`item.completed`). Nothing maps one-to-one.
///
/// 2. **Enforcement.** Claude can pause mid-run and ask a human through a `PreToolUse` hook.
///    `codex exec` cannot: the sandbox policy is fixed before the run and enforced by the OS.
///    Strong, but non-interactive — hence `gateMechanism == .sandboxPolicy`.
///
/// 3. **Stdin must be closed.** Given a prompt argument *and* an open stdin, Codex waits for
///    stdin to close so it can append it as a `<stdin>` block, and hangs forever if it never
///    does. `LocalHost` closes stdin immediately; that is load-bearing, not tidiness, and
///    `LocalHostTests` pins it.
public struct CodexAdapter: EngineAdapter {
    public let id: EngineID = .codex
    public var binaryName: String { overrideBinary ?? "codex" }

    private let overrideBinary: String?

    public init(binary: String? = nil) { self.overrideBinary = binary }

    /// The OS sandbox enforces every level faithfully, so all four are honest here. What it
    /// cannot do is stop to ask, which `gateMechanism` tells the UI.
    public var maximumEnforceableAutonomy: Autonomy { .auto }
    public var gateMechanism: GateMechanism { .sandboxPolicy }

    /// Codex publishes no alias scheme and `--help` lists no models, so these are identifiers
    /// observed in the wild rather than a documented set. **Every one of them was rejected on the
    /// ChatGPT account tested in M0** with "not supported when using Codex with a ChatGPT
    /// account", so the picker must tolerate all of them failing and say why — see
    /// `AuthStatus.signedInWithoutModelAccess`.
    public var models: [ModelOption] {
        [
            ModelOption(id: nil, label: "Default", detail: "Whatever your CLI is set to"),
            ModelOption(id: "gpt-5.6-codex", label: "GPT-5.6 Codex", detail: "Tuned for code", section: .version),
            ModelOption(id: "gpt-5.6", label: "GPT-5.6", detail: "General purpose", section: .version),
            ModelOption(id: "gpt-5-codex", label: "GPT-5 Codex", detail: "Previous generation", section: .version),
        ]
    }

    public func loginCommand() -> LoginCommand {
        LoginCommand(
            command: "codex login --device-auth",
            hint: "Complete the code in your browser. bupsy never sees the token — "
                + "it stays in ~/.codex, owned by you and the CLI."
        )
    }

    public func authStatus(on host: any ExecutionHost) async -> AuthStatus {
        // `codex login status` is necessary but NOT sufficient. It reported "Logged in using
        // ChatGPT" on an account where every model returned HTTP 400. So: check the cheap status
        // first, then confirm a turn can actually start.
        guard case .signedIn = await statusCommandVerdict(on: host) else {
            return await statusCommandVerdict(on: host)
        }
        return await probeModelAccess(on: host)
    }

    private func statusCommandVerdict(on host: any ExecutionHost) async -> AuthStatus {
        let probe = EngineInvocation(executable: binaryName, arguments: ["login", "status"])
        var output = ""
        do {
            for try await chunk in try await host.spawn(probe) {
                switch chunk {
                case .stdout(let line), .stderr(let line): output += line + "\n"
                case .exit(let code):
                    let lowered = output.lowercased()
                    if code == 0, lowered.contains("logged in") {
                        return .signedIn(method: lowered.contains("api key") ? .apiKey : .subscription)
                    }
                    return .signedOut
                }
            }
            return .unknown("status probe ended without an exit status")
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Starts a minimal turn to see whether the account may actually run a model. Read-only
    /// sandbox, so it cannot touch anything even if the model misbehaves.
    private func probeModelAccess(on host: any ExecutionHost) async -> AuthStatus {
        let probe = EngineInvocation(
            executable: binaryName,
            arguments: ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "ok"]
        )
        do {
            for try await chunk in try await host.spawn(probe) {
                guard case .stdout(let line) = chunk, let json = JSONLine(line) else { continue }
                switch json.string("type") {
                case "turn.completed":
                    return .signedIn(method: .subscription)
                case "error", "turn.failed":
                    let detail = Self.failureMessage(json) ?? "model request rejected"
                    if detail.lowercased().contains("not supported") {
                        return .signedInWithoutModelAccess(detail: detail)
                    }
                    return .unknown(detail)
                default:
                    continue
                }
            }
            return .signedIn(method: .subscription)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    public func invocation(for request: RunRequest) -> EngineInvocation {
        var arguments = ["exec", "--json"]

        if let resume = request.resume {
            // `exec resume <thread_id>` continues a thread; the prompt follows.
            arguments += ["resume", resume.rawValue]
        }

        let sandbox = Self.sandbox(for: request.autonomy)
        arguments += ["--sandbox", sandbox]

        if sandbox == "read-only" {
            // Codex refuses to start outside a git repository unless this is passed, which would
            // otherwise make every bot pointed at an ordinary folder fail before it began.
            // Confirmed against the real binary.
            //
            // Passed only for read-only runs. Codex wants a repo so its edits stay recoverable,
            // and that concern is real the moment writes are possible — so a write-capable run
            // keeps the check and the refusal is surfaced to the user as a decision, rather than
            // overridden quietly on their behalf. Previously this was passed unconditionally,
            // which silently removed the one safety net standing between a write-capable bot and
            // an unrecoverable folder.
            arguments.append("--skip-git-repo-check")
        }

        if request.autonomy == .auto {
            // Only at the top of the ladder, and only because the user typed a confirmation.
            arguments.append("--dangerously-bypass-approvals-and-sandbox")
        }
        if let model = request.model {
            arguments += ["-m", model]
        }
        if let cwd = request.workingDirectory {
            arguments += ["-C", cwd.path]
        }
        arguments.append(request.prompt)

        // MCP servers are registered out of band with `codex mcp`, not per invocation, so
        // request.mcpConfigPaths is deliberately not forwarded here. The connector layer
        // installs them once per host instead.
        return EngineInvocation(
            executable: binaryName,
            arguments: arguments,
            workingDirectory: request.workingDirectory
        )
    }

    /// Maps our ladder onto the only enforcement Codex offers. Note `.ask` becomes "read-only"
    /// rather than "pause and ask" — the honest translation, and why `gateMechanism` exists.
    static func sandbox(for autonomy: Autonomy) -> String {
        switch autonomy {
        case .ask: "read-only"
        case .allowlist, .trusted: "workspace-write"
        case .auto: "danger-full-access"
        }
    }

    public func normalise(_ output: HostOutput) -> [AgentEvent] {
        switch output {
        case .stderr(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // "Reading additional input from stdin..." is NOT a problem and must not be reported
            // as one.
            //
            // M0 recorded it as the signal that a host had left stdin open and the run was about
            // to hang. Checked again against the real binary: codex prints it on every single
            // run, including with stdin on /dev/null, where it reads EOF and continues normally.
            // `codex exec --help` confirms the design — stdin is an additional input channel,
            // appended as a <stdin> block when piped.
            //
            // So the line cannot distinguish a hang from a healthy run, and treating it as a
            // protocol error failed every codex run before it produced a single event. A hang is
            // only detectable by a timeout, which belongs to the host, not here.

            // This one genuinely stops the run, and dropping it left the user with no events and
            // no reason — the worst way for anything to fail.
            if trimmed.contains("Not inside a trusted directory") {
                return [.failed(EngineFailure(
                    kind: .untrustedDirectory,
                    message: "codex will not run in this folder because it is not a git "
                        + "repository. Point the bot at a repository, or set it to read-only."
                ))]
            }
            return []

        case .exit:
            // A rejected turn already produced a `.failed` from the stream; do not double up.
            return []

        case .stdout(let line):
            guard let json = JSONLine(line) else { return [] }
            return Self.events(from: json)
        }
    }

    // MARK: - Stream mapping

    static func events(from json: JSONLine) -> [AgentEvent] {
        switch json.string("type") {
        case "thread.started":
            // The resume handle, emitted before any work — so a run stays resumable even if the
            // turn then fails. Deliberately NOT `.done`: that would tell the UI a run finished
            // before it began.
            guard let thread = json.string("thread_id") else { return [.unknown(raw: json.raw)] }
            return [.started(conversationID: ConversationID(thread))]

        case "turn.started":
            return []

        case "turn.completed":
            let usage = json.dictionary("usage").map { u in
                Usage(
                    inputTokens: (u["input_tokens"] as? NSNumber)?.intValue,
                    outputTokens: (u["output_tokens"] as? NSNumber)?.intValue
                )
            }
            return [.done(Outcome(summary: nil, conversationID: nil, usage: usage))]

        case "turn.failed":
            return [.failed(EngineFailure(
                kind: .unknown,
                message: failureMessage(json) ?? "turn failed"
            ))]

        case "error":
            return [.failed(EngineFailure(
                kind: .unknown,
                message: failureMessage(json) ?? "error"
            ))]

        case "item.completed", "item.started", "item.updated":
            guard let item = json.dictionary("item") else { return [.unknown(raw: json.raw)] }
            return events(fromItem: item, raw: json.raw)

        default:
            return [.unknown(raw: json.raw)]
        }
    }

    /// Item types beyond `error` are inferred and not yet observed against a working account.
    /// Anything unrecognised becomes `.unknown` rather than being dropped, so the first real
    /// successful run will show us exactly what is missing. See docs/01-spikes.md.
    static func events(fromItem item: [String: Any], raw: String) -> [AgentEvent] {
        switch item["type"] as? String {
        case "error":
            return [.failed(EngineFailure(
                kind: .unknown,
                message: item["message"] as? String ?? "error item"
            ))]

        case "agent_message", "assistant_message":
            guard let text = (item["text"] ?? item["message"]) as? String, !text.isEmpty
            else { return [.unknown(raw: raw)] }
            return [.text(text)]

        case "reasoning":
            guard let text = (item["text"] ?? item["summary"]) as? String, !text.isEmpty
            else { return [] }
            return [.thinking(text)]

        case "command_execution":
            return [.toolCall(ToolCall(
                id: item["id"] as? String ?? UUID().uuidString,
                name: "shell",
                argumentsJSON: JSONLine.encode(["command": item["command"] as? String ?? ""])
            ))]

        case "file_change", "patch_apply":
            return [.toolCall(ToolCall(
                id: item["id"] as? String ?? UUID().uuidString,
                name: "edit",
                argumentsJSON: JSONLine.encode(item["changes"] ?? item)
            ))]

        default:
            return [.unknown(raw: raw)]
        }
    }

    /// Codex nests a JSON API error inside a string field, so unwrap one level when possible.
    static func failureMessage(_ json: JSONLine) -> String? {
        let raw = json.string("message") ?? (json.dictionary("error")?["message"] as? String)
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = nested["error"] as? [String: Any],
              let message = inner["message"] as? String
        else { return raw }
        return message
    }
}
