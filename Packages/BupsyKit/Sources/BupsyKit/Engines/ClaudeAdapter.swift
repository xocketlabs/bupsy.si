import Foundation

/// Drives the published `claude` binary in print mode.
///
/// We shell out rather than embedding the Agent SDK: Anthropic does not permit third-party
/// products to use claude.ai login or subscription rate limits through the SDK, while an end
/// user signing into the unmodified binary on a host we provide is expressly allowed.
/// See docs/00-compliance-and-auth.md §4.
///
/// Flag set and stream schema are confirmed by M0 spike 3 — see docs/01-spikes.md. Treat the
/// mappings below as fixture-driven, not as documented API.
public struct ClaudeAdapter: EngineAdapter {
    public let id: EngineID = .claude
    public var binaryName: String { overrideBinary ?? "claude" }

    /// Settings → Engines lets the user point at a specific build or wrapper. Never hide this.
    private let overrideBinary: String?

    public init(binary: String? = nil) { self.overrideBinary = binary }

    /// Claude Code exposes `PreToolUse` hooks that can block and return a decision, which is
    /// what lets us honestly offer autonomy above `.ask`. Confirmed by spike 4.
    public var maximumEnforceableAutonomy: Autonomy { .auto }

    /// A hook can hold the run open while a human decides, so `.ask` genuinely means "ask me".
    public var gateMechanism: GateMechanism { .blockingHook }

    /// Aliases first, then exact versions.
    ///
    /// `claude --help` documents aliases that track the latest model in each family, so they keep
    /// working when new versions ship and stay the default choice. Exact versions are listed too,
    /// for when a bot must not change underneath someone — and anything newer than this list can
    /// still be typed in as a custom model, so a release never waits on an update to bupsy.
    ///
    /// Which versions a CLI accepts depends on its own version: an older Claude Code rejects a
    /// newer model with `unrecognized_model`, which `events(from:)` turns into "update Claude Code".
    public var models: [ModelOption] {
        [
            ModelOption(id: nil, label: "Default", detail: "Whatever your CLI is set to"),
            ModelOption(id: "opus", label: "Opus", detail: "Newest Opus, most capable", section: .latest),
            ModelOption(id: "sonnet", label: "Sonnet", detail: "Newest Sonnet, balanced", section: .latest),
            ModelOption(id: "haiku", label: "Haiku", detail: "Newest Haiku, fastest", section: .latest),
            ModelOption(id: "fable", label: "Fable", detail: "Newest Fable", section: .latest),
            ModelOption(id: "claude-opus-5-5", label: "Opus 5.5", section: .version),
            ModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5", section: .version),
            ModelOption(id: "claude-fable-5-1", label: "Fable 5.1", section: .version),
            ModelOption(id: "claude-opus-5", label: "Opus 5", section: .version),
            ModelOption(id: "claude-sonnet-5", label: "Sonnet 5", section: .version),
            ModelOption(id: "claude-opus-4-5", label: "Opus 4.5", section: .version),
            ModelOption(id: "claude-sonnet-4-5", label: "Sonnet 4.5", section: .version),
            ModelOption(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5", section: .version),
        ]
    }

    /// What to say when a run fails because the CLI does not know the model.
    ///
    /// The raw text is `[claude-code:unrecognized_model] {"model":…}`, which reads like a crash.
    /// It almost always means the CLI is older than the model, and the fix is one command.
    static func explainUnrecognisedModel(_ message: String) -> String? {
        guard message.contains("unrecognized_model") else { return nil }
        let name = message.range(of: #""model":"([^"]+)""#, options: .regularExpression)
            .map { String(message[$0]).replacingOccurrences(of: "\"model\":", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        return "Your Claude Code doesn't know \(name ?? "this model") yet. It's probably older "
            + "than the model. Update it with `claude update`, or pick another model."
    }

    public func loginCommand() -> LoginCommand {
        LoginCommand(
            command: "claude",
            hint: "Type /login and complete sign-in in your browser. "
                + "Bupsy never sees the result, only that it worked."
        )
    }

    public func authStatus(on host: any ExecutionHost) async -> AuthStatus {
        // A trivial prompt is the cheapest honest probe. We deliberately do not read
        // ~/.claude to inspect expiry: reading a credential file is the line we do not cross.
        let probe = EngineInvocation(
            executable: binaryName,
            arguments: ["-p", "ok", "--output-format", "json"]
        )
        do {
            var sawOutput = false
            var stderr = ""
            for try await output in try await host.spawn(probe) {
                switch output {
                case .stdout(let line) where !line.isEmpty: sawOutput = true
                case .stderr(let line): stderr += line + "\n"
                case .exit(let code):
                    if code == 0 && sawOutput { return .signedIn(method: .subscription) }
                    if Self.looksLikeSignedOut(stderr) { return .signedOut }
                    // 127 is the shell's "command not found", from a host that runs through one.
                    if code == 127 { return .notInstalled }
                    return .unknown(stderr.isEmpty ? "exit \(code)" : stderr)
                default: break
                }
            }
            return .unknown("probe ended without an exit status")
        } catch HostError.binaryNotFound(_) {
            return .notInstalled
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    public func invocation(for request: RunRequest) -> EngineInvocation {
        // `-p` is a boolean (`--print`); the prompt is the positional argument
        // (`claude [options] [command] [prompt]`). So a prompt or persona starting with "-" was
        // read as an option — and "--dangerously-skip-permissions" is one. Such a prompt goes
        // last instead, behind "--", which the CLI's parser treats as the end of options.
        //
        // Only such prompts, matching bupsy-run: every other prompt keeps the argv the
        // conformance cases pin, so moving all of them is a change both cores make together.
        let dashed = Self.startsLikeOption(request.prompt)
        var arguments = ["-p"]
        if !dashed { arguments.append(request.prompt) }
        arguments += [
            "--output-format", "stream-json",
            "--verbose",
        ]
        if let resume = request.resume {
            arguments += ["--resume", resume.rawValue]
        }
        if let model = request.model {
            arguments += ["--model", model]
        }
        for path in request.mcpConfigPaths {
            arguments += ["--mcp-config", path]
        }
        // Without this a bot also gets every app connected to the person's Claude account —
        // their mail, their Slack — whether or not they meant this bot to have them.
        if request.onlyGivenApps {
            arguments.append("--strict-mcp-config")
        }
        if let settings = request.gateSettingsPath {
            // Command-line settings sit above project and user settings in precedence, and —
            // unlike project `.claude/settings.json` hooks, which do not run in `-p` sessions —
            // these take effect in print mode, which is the only mode we ever use.
            arguments += ["--settings", settings]
        }
        // No `--permission-mode` here on purpose: widening permissions is not the same as
        // gating them, and the gate is the hook.
        if dashed { arguments += ["--", request.prompt] }
        return EngineInvocation(
            executable: binaryName,
            arguments: arguments,
            workingDirectory: request.workingDirectory
        )
    }

    /// Whether an argument would be parsed as a flag if passed bare.
    static func startsLikeOption(_ argument: String) -> Bool { argument.hasPrefix("-") }

    public func normalise(_ output: HostOutput) -> [AgentEvent] {
        switch output {
        case .stderr(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if Self.looksLikeSignedOut(trimmed) {
                return [.failed(EngineFailure(kind: .notSignedIn, message: trimmed))]
            }
            return []

        case .exit(let code):
            guard code != 0 else { return [] }
            return [.failed(EngineFailure(kind: .nonZeroExit, message: "claude exited \(code)"))]

        case .stdout(let line):
            guard let json = JSONLine(line) else { return [] }
            return Self.events(from: json)
        }
    }

    // MARK: - Stream mapping

    static func events(from json: JSONLine) -> [AgentEvent] {
        switch json.string("type") {
        case "system":
            // The init banner carries session id, cwd and the tool list. Only the session id
            // matters to us, and it makes the thread resumable from the very first line.
            guard json.string("subtype") == "init" else { return [] }

            var events: [AgentEvent] = []
            if let session = json.string("session_id") {
                events.append(.started(conversationID: ConversationID(session)))
            }
            if let servers = json.array("mcp_servers") {
                events.append(.connectors(servers.compactMap { entry in
                    guard let name = entry["name"] as? String else { return nil }
                    return ConnectorState(
                        name: name,
                        status: ConnectorState.Status(
                            rawValue: entry["status"] as? String ?? "") ?? .unknown)
                }))
            }
            return events

        case "rate_limit_event":
            // Undocumented, and valuable: the engine volunteers how much of the user's own
            // subscription window they have burned. Observed in M0 spike 3. Every field is
            // treated as optional because an undocumented shape can change without notice.
            guard let info = json.dictionary("rate_limit_info") else {
                return [.unknown(raw: json.raw)]
            }
            var windows: [String: RateLimit.Window] = [:]
            for (name, value) in (info["unifiedWindows"] as? [String: [String: Any]] ?? [:]) {
                guard let utilization = (value["utilization"] as? NSNumber)?.doubleValue
                else { continue }
                let resetsAt = (value["resetsAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows[name] = RateLimit.Window(utilization: utilization, resetsAt: resetsAt)
            }
            return [.rateLimit(RateLimit(
                status: info["status"] as? String,
                windows: windows,
                isUsingOverage: info["isUsingOverage"] as? Bool ?? false
            ))]

        case "assistant":
            guard let message = json.dictionary("message") else { return [.unknown(raw: json.raw)] }
            var events: [AgentEvent] = []
            for block in (message["content"] as? [[String: Any]] ?? []) {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.text(text))
                    }
                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        events.append(.thinking(thinking))
                    }
                case "tool_use":
                    events.append(.toolCall(ToolCall(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: block["name"] as? String ?? "unknown",
                        argumentsJSON: JSONLine.encode(block["input"])
                    )))
                default:
                    events.append(.unknown(raw: json.raw))
                }
            }
            return events

        case "user":
            guard let message = json.dictionary("message") else { return [.unknown(raw: json.raw)] }
            return (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                guard block["type"] as? String == "tool_result" else { return nil }
                return .toolResult(ToolResult(
                    callID: block["tool_use_id"] as? String ?? "",
                    content: Self.flatten(block["content"]),
                    isError: block["is_error"] as? Bool ?? false
                ))
            }

        case "result":
            let usage = Self.usage(from: json)
            let conversation = json.string("session_id").map { ConversationID($0) }
            if json.string("subtype") != "success" || json.bool("is_error") == true {
                return [
                    .usage(usage),
                    .failed(EngineFailure(
                        kind: .unknown,
                        message: json.string("result").flatMap(Self.explainUnrecognisedModel)
                            ?? json.string("result") ?? json.string("subtype") ?? "run failed"
                    )),
                ]
            }
            return [
                .usage(usage),
                .done(Outcome(
                    summary: json.string("result"),
                    conversationID: conversation,
                    usage: usage
                )),
            ]

        default:
            return [.unknown(raw: json.raw)]
        }
    }

    /// Reads the usage block, summing everything that was actually sent.
    ///
    /// `input_tokens` alone counts only the uncached remainder of a turn. On a thread of any
    /// length the cache fields carry almost all of it, so a total built from `input_tokens`
    /// understates the real figure by orders of magnitude — measured at 2 against a true 37,156.
    static func usage(from json: JSONLine) -> Usage {
        let fields = json.dictionary("usage") ?? [:]
        func count(_ key: String) -> Int? { (fields[key] as? NSNumber)?.intValue }

        let cached = [count("cache_creation_input_tokens"), count("cache_read_input_tokens")]
            .compactMap { $0 }
        // nil when the engine said nothing, which is a different fact from a turn that sent zero.
        let sent: Int? = count("input_tokens").map { $0 + cached.reduce(0, +) }
            ?? (cached.isEmpty ? nil : cached.reduce(0, +))

        return Usage(
            inputTokens: sent,
            outputTokens: count("output_tokens"),
            cachedInputTokens: cached.isEmpty ? nil : cached.reduce(0, +),
            costUSD: json.double("total_cost_usd"),
            durationMS: json.int("duration_ms")
        )
    }

    /// Tool results arrive as a string or as content blocks depending on the tool.
    private static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return JSONLine.encode(content)
    }

    /// Heuristic, and only ever used to produce a friendlier message — never to make a
    /// security decision. Kept narrow on purpose so it fails as "unknown" rather than lying.
    static func looksLikeSignedOut(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signals = ["not logged in", "please run /login", "authentication", "unauthorized",
                       "invalid api key", "no credentials"]
        return signals.contains { lowered.contains($0) }
    }
}
