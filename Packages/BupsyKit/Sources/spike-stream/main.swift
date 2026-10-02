import BupsyKit
import Foundation

/// M0 spike 3, as a runnable tool rather than a scratch script.
///
///   swift run --package-path Packages/BupsyKit spike-stream "list the files here"
///
/// Proves three things the plan depends on: the engine binary resolves from a non-login
/// environment, events arrive incrementally rather than all at once on exit, and the
/// normaliser maps a real stream without dropping lines. Writes the raw stream to
/// docs/samples/ so it becomes a test fixture.
@main
struct SpikeStream {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())

        // M0 spike 4: prove the PreToolUse gate actually blocks, against the real binary.
        //   spike-stream --gate deny  "Run: ls"
        //   spike-stream --gate allow "Run: ls"
        var gateMode: String?
        if let index = arguments.firstIndex(of: "--gate"), index + 1 < arguments.count {
            gateMode = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        let prompt = arguments.joined(separator: " ")
        guard !prompt.isEmpty else {
            print("usage: spike-stream <prompt>")
            exit(2)
        }

        let host = LocalHost()
        let adapter = ClaudeAdapter()

        do {
            let resolved = try BinaryResolver.resolve(adapter.binaryName)
            print("binary:     \(resolved.path)")
        } catch {
            print("binary:     NOT FOUND — \(error)")
            print("spike 3c FAILED: cannot resolve \(adapter.binaryName)")
            exit(1)
        }

        print("prompt:     \(prompt)")
        print("host:       local (survivesSleep: \(host.survivesSleep))")
        print("")

        let started = Date()
        var firstEventAt: Date?
        var rawLines: [String] = []
        var counts: [String: Int] = [:]

        var gateSettings: String?
        var gate: ApprovalGate?
        if let gateMode {
            do {
                let created = try ApprovalGate.temporary()
                gate = created
                gateSettings = try GateInstaller.install(gateDirectory: created.directory).path
                print("gate:       \(gateMode) · \(created.directory.path)")
                Task {
                    for await request in await created.requests() {
                        print("  GATE →     \(request.tool): \(oneLine(request.summary, limit: 70))")
                        let verdict: GateVerdict = gateMode == "allow"
                            ? .allow(reason: "spike auto-allow")
                            : .deny(reason: "spike auto-deny")
                        try? await created.decide(request.id, verdict)
                        print("  GATE ←     \(gateMode)")
                    }
                }
            } catch {
                print("gate:       FAILED to install — \(error)")
                exit(1)
            }
        }

        do {
            let invocation = adapter.invocation(
                for: RunRequest(prompt: prompt, gateSettingsPath: gateSettings))
            for try await output in try await host.spawn(invocation) {
                if case .stdout(let line) = output, !line.isEmpty { rawLines.append(line) }

                for event in adapter.normalise(output) {
                    if firstEventAt == nil { firstEventAt = Date() }
                    counts[label(event), default: 0] += 1
                    render(event)
                }
            }
        } catch {
            print("stream failed: \(error)")
            exit(1)
        }

        let elapsed = Date().timeIntervalSince(started)
        let latency = firstEventAt.map { $0.timeIntervalSince(started) }

        print("")
        print("— spike 3 results —")
        print(String(format: "total:          %.2fs", elapsed))
        if let latency {
            // Only a multi-step run can demonstrate incremental delivery. A one-line reply
            // legitimately produces everything at once, so say "inconclusive" rather than
            // reporting a failure the test cannot actually detect.
            let verdict: String
            if rawLines.count < 5 {
                verdict = "← inconclusive: too few events. Re-run with a multi-step task."
            } else if latency < elapsed * 0.8 {
                verdict = "← incremental ✅"
            } else {
                verdict = "← arrived late; check for buffering ⚠️"
            }
            print(String(format: "first event:    %.2fs  %@", latency, verdict))
        }
        print("raw lines:      \(rawLines.count)")
        print("events:         \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        if let unknown = counts["unknown"], unknown > 0 {
            print("⚠️  \(unknown) unmodelled line(s) — add them to the normaliser and a fixture")
        }

        if let gate { await gate.stop() }
        if !rawLines.isEmpty { writeFixture(rawLines) }
    }

    static func label(_ event: AgentEvent) -> String {
        switch event {
        case .started: "started"
        case .text: "text"
        case .thinking: "thinking"
        case .toolCall: "toolCall"
        case .toolResult: "toolResult"
        case .approvalRequired: "approval"
        case .usage: "usage"
        case .rateLimit: "rateLimit"
        case .done: "done"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }

    static func render(_ event: AgentEvent) {
        switch event {
        case .started(let id):            print("  started    conversation=\(id.rawValue)")
        case .text(let text):             print("  text       \(oneLine(text))")
        case .thinking(let text):         print("  thinking   \(oneLine(text))")
        case .toolCall(let call):         print("  tool →     \(call.name) \(oneLine(call.argumentsJSON))")
        case .toolResult(let result):     print("  tool ←     \(result.isError ? "ERROR " : "")\(oneLine(result.content))")
        case .approvalRequired(let req):  print("  approval?  \(req.tool) — \(req.summary)")
        case .usage(let usage):           print("  usage      in=\(usage.inputTokens.map(String.init) ?? "?") out=\(usage.outputTokens.map(String.init) ?? "?")")
        case .rateLimit(let limit):
            let windows = limit.windows
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Int($0.value.utilization * 100))%" }
                .joined(separator: " ")
            print("  limits     \(limit.status ?? "?") \(windows)")
        case .done(let outcome):          print("  done       conversation=\(outcome.conversationID?.rawValue ?? "none")")
        case .failed(let failure):        print("  failed     \(failure.kind.rawValue): \(failure.message)")
        case .unknown(let raw):           print("  unknown    \(oneLine(raw))")
        }
    }

    static func oneLine(_ text: String, limit: Int = 100) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎ ")
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }

    /// Lands next to the repo's other spike artefacts so the normaliser gets a real fixture.
    static func writeFixture(_ lines: [String]) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/samples")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("claude-stream.ndjson")
        try? (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        print("fixture:        \(path.path)")
    }
}
