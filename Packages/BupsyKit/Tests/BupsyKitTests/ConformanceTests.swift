import Foundation
import Testing
@testable import BupsyKit

/// Runs the shared conformance cases against this implementation.
///
/// These cases live outside the package, in `conformance/`, because they belong to the *product*
/// rather than to the Swift port of it. `bupsy-run` is Go, and a cross-platform core would be too;
/// the moment there is a second implementation the two drift, and they drift silently in exactly
/// the places where a comment explains why something is subtle. Running one set of cases from
/// every implementation turns that from invisible into a red build.
///
/// If this suite is ever hard to satisfy from another language, that is a signal the canonical
/// shape has drifted toward Swift — which is itself worth knowing.
@Suite("Conformance")
struct ConformanceTests {

    /// Walks up from the test file to the repository, since the cases are not package resources.
    static var casesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("conformance/cases")
    }

    static func cases(ofKind kind: String) throws -> [(name: String, directory: URL)] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: casesDirectory, includingPropertiesForKeys: nil)
        return directories.compactMap { directory in
            let meta = directory.appendingPathComponent("case.json")
            guard let data = try? Data(contentsOf: meta),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["kind"] as? String == kind
            else { return nil }
            return (directory.lastPathComponent, directory)
        }.sorted { $0.name < $1.name }
    }

    private static func expected(_ directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("expected.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: - Streams

    @Test("engine streams normalise to the canonical events")
    func streams() throws {
        for (name, directory) in try Self.cases(ofKind: "stream") {
            let meta = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("case.json")))
                as? [String: Any] ?? [:]
            let engine = (meta["options"] as? [String: Any])?["engine"] as? String ?? "claude"
            let adapter: any EngineAdapter = engine == "codex" ? CodexAdapter() : ClaudeAdapter()

            let input = try String(
                contentsOf: directory.appendingPathComponent("input.ndjson"), encoding: .utf8)
            let produced = input
                .split(separator: "\n", omittingEmptySubsequences: true)
                .flatMap { adapter.normalise(.stdout(String($0))) }

            let expected = try Self.expected(directory)

            #expect(produced.count == expected.count,
                    "\(name): produced \(produced.count) events, case expects \(expected.count)")

            for (index, want) in expected.enumerated() where index < produced.count {
                check(produced[index], against: want, case: name, index: index)
            }
        }
    }

    /// Compares only the fields a case names. A case pins what matters about an event rather than
    /// every field of it, so adding a field to `AgentEvent` does not invalidate every case.
    private func check(
        _ event: AgentEvent, against want: [String: Any], case name: String, index: Int
    ) {
        let kind = want["type"] as? String ?? ""
        let where_ = "\(name)[\(index)]"

        switch (kind, event) {
        case ("started", .started(let id)):
            if let expected = want["conversationID"] as? String {
                #expect(id.rawValue == expected, "\(where_) conversation id")
            }
        case ("text", .text(let text)):
            if let expected = want["text"] as? String { #expect(text == expected, "\(where_) text") }
        case ("thinking", .thinking(let text)):
            if let expected = want["text"] as? String { #expect(text == expected, "\(where_) thinking") }
        case ("toolCall", .toolCall(let call)):
            if let expected = want["name"] as? String { #expect(call.name == expected, "\(where_) tool name") }
            if let expected = want["arguments"] as? String {
                #expect(call.argumentsJSON == expected, "\(where_) tool arguments")
            }
        case ("toolResult", .toolResult(let result)):
            if let expected = want["callID"] as? String { #expect(result.callID == expected, "\(where_) call id") }
            if let expected = want["isError"] as? Bool { #expect(result.isError == expected, "\(where_) isError") }
        case ("usage", .usage(let usage)):
            if let expected = want["inputTokens"] as? Int { #expect(usage.inputTokens == expected, "\(where_) input tokens") }
            if let expected = want["outputTokens"] as? Int { #expect(usage.outputTokens == expected, "\(where_) output tokens") }
        case ("rateLimit", .rateLimit(let limit)):
            if let expected = want["status"] as? String { #expect(limit.status == expected, "\(where_) status") }
            for (window, utilisation) in (want["windows"] as? [String: Double] ?? [:]) {
                #expect(limit.windows[window]?.utilization == utilisation, "\(where_) \(window)")
            }
        case ("done", .done(let outcome)):
            if let expected = want["conversationID"] as? String {
                #expect(outcome.conversationID?.rawValue == expected, "\(where_) done conversation")
            }
            if let expected = want["inputTokens"] as? Int { #expect(outcome.usage?.inputTokens == expected, "\(where_) done input tokens") }
            if let expected = want["outputTokens"] as? Int { #expect(outcome.usage?.outputTokens == expected, "\(where_) done output tokens") }
        case ("failed", .failed), ("unknown", .unknown), ("connectors", .connectors):
            break
        default:
            Issue.record("\(where_) expected \(kind), got \(event)")
        }
    }

    // MARK: - Objectives

    /// The asymmetry this product turns on, pinned where any implementation can read it.
    @Test("objective replies read to the same outcome")
    func objectives() throws {
        for (name, directory) in try Self.cases(ofKind: "objective") {
            for (index, want) in try Self.expected(directory).enumerated() {
                let reply = want["reply"] as? String ?? ""
                let outcome = ObjectiveCheck.outcome(from: reply)
                let expected = want["outcome"] as? String ?? ""
                let where_ = "\(name)[\(index)] \(reply.prefix(44).debugDescription)"

                switch (expected, outcome) {
                case ("met", .met), ("unclear", .unclear):
                    break
                case ("needsYou", .needsYou(let question)):
                    if let detail = want["detail"] as? String {
                        #expect(question == detail, "\(where_) question")
                    }
                case ("acted", .acted(let summary)):
                    if let detail = want["detail"] as? String {
                        #expect(summary == detail, "\(where_) summary")
                    }
                default:
                    Issue.record("\(where_): expected \(expected), got \(outcome)")
                }
            }
        }
    }

    // MARK: - Cron

    /// What a schedule accepts, and — more importantly — what it refuses.
    @Test("cron expressions are accepted or refused identically")
    func cron() throws {
        for (name, directory) in try Self.cases(ofKind: "cron") {
            for want in try Self.expected(directory) {
                let expression = want["expression"] as? String ?? ""
                let shouldParse = want["valid"] as? Bool ?? false
                let parsed = try? CronExpression(expression)

                if (parsed != nil) != shouldParse {
                    let why = (want["why"] as? String).map { " — \($0)" } ?? ""
                    Issue.record("""
                        \(name): '\(expression)' should \(shouldParse ? "parse" : "be refused")\(why)
                        """)
                }

                guard let parsed else { continue }
                if let minutes = want["minutes"] as? [Int] {
                    #expect(parsed.minutes == Set(minutes), "\(name): '\(expression)' minutes")
                }
                if let hours = want["hours"] as? [Int] {
                    #expect(parsed.hours == Set(hours), "\(name): '\(expression)' hours")
                }
                if let weekdays = want["weekdays"] as? [Int] {
                    #expect(parsed.weekdays == Set(weekdays), "\(name): '\(expression)' weekdays")
                }
            }
        }
    }


    // MARK: - Command lines

    /// Pins the argv an engine is actually invoked with.
    ///
    /// Worth its own kind because a wrong flag fails *before* a single event exists, so none of the
    /// stream cases can see it. Two implementations drifted here within an hour of the second one
    /// being written: one passed `--model` where the other passed `-m`, and one forwarded MCP
    /// config paths to an engine that has no such flag.
    @Test("engines are invoked with the same arguments")
    func commands() throws {
        for (name, directory) in try Self.cases(ofKind: "command") {
            let meta = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("case.json")))
                as? [String: Any] ?? [:]
            let engine = (meta["options"] as? [String: Any])?["engine"] as? String ?? "claude"
            let adapter: any EngineAdapter = engine == "codex" ? CodexAdapter() : ClaudeAdapter()

            for (index, want) in try Self.expected(directory).enumerated() {
                let spec = want["request"] as? [String: Any] ?? [:]
                let request = RunRequest(
                    prompt: spec["prompt"] as? String ?? "",
                    workingDirectory: (spec["workingDir"] as? String).map {
                        URL(fileURLWithPath: $0)
                    },
                    resume: (spec["resume"] as? String).map { ConversationID($0) },
                    model: spec["model"] as? String,
                    // An unrecognised name deliberately falls to `.ask`: a case exercising a trust
                    // level this implementation does not know must not be read as more trust.
                    autonomy: Autonomy(rawValue: spec["autonomy"] as? String ?? "") ?? .ask,
                    mcpConfigPaths: spec["mcpConfigs"] as? [String] ?? [],
                    gateSettingsPath: spec["gateSettings"] as? String
                )

                let produced = adapter.invocation(for: request).arguments
                let expected = want["argv"] as? [String] ?? []
                if produced != expected {
                    let why = (want["why"] as? String).map { "\n  why: \($0)" } ?? ""
                    Issue.record("""
                        \(name)[\(index)] arguments differ
                          got:  \(produced)
                          want: \(expected)\(why)
                        """)
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// What stderr lines mean — and, as much, what they do not.
    ///
    /// Most lines here must produce *nothing*. The expensive mistake on this channel is a routine
    /// diagnostic read as a failure, which is exactly what happened: codex prints "Reading
    /// additional input from stdin..." on every run, and treating it as a protocol error failed
    /// every codex run before it produced a single event.
    @Test("stderr lines are read the same way")
    func diagnostics() throws {
        for (name, directory) in try Self.cases(ofKind: "stderr") {
            let meta = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("case.json")))
                as? [String: Any] ?? [:]
            let engine = (meta["options"] as? [String: Any])?["engine"] as? String ?? "claude"
            let adapter: any EngineAdapter = engine == "codex" ? CodexAdapter() : ClaudeAdapter()

            for (index, want) in try Self.expected(directory).enumerated() {
                let line = want["line"] as? String ?? ""
                let produced = adapter.normalise(.stderr(line))
                let expected = want["events"] as? [[String: Any]] ?? []
                let why = (want["why"] as? String).map { "\n  why: \($0)" } ?? ""

                guard produced.count == expected.count else {
                    Issue.record("""
                        \(name)[\(index)] \(line.prefix(44).debugDescription): \
                        produced \(produced.count) events, case expects \(expected.count)\(why)
                        """)
                    continue
                }
                for (offset, event) in produced.enumerated() {
                    check(event, against: expected[offset], case: name, index: index)
                    // The failure kind is the whole point of a stderr case, and `check` does not
                    // look at it, so assert it here.
                    if let kind = expected[offset]["failureKind"] as? String,
                       case .failed(let failure) = event {
                        #expect(failure.kind.rawValue == kind,
                                "\(name)[\(index)] failure kind\(why)")
                    }
                }
            }
        }
    }


    // MARK: - The approval gate

    /// Pins the gate's fail-closed behaviour.
    ///
    /// The timing *is* the safety argument, so it is asserted as numbers **and** by running the
    /// generated script — a core could agree on both constants and still emit shell that defaults
    /// to allow.
    @Test("the approval gate fails closed in every implementation")
    func gate() throws {
        for (name, directory) in try Self.cases(ofKind: "gate") {
            for (index, want) in try Self.expected(directory).enumerated() {
                let where_ = "\(name)[\(index)]"
                let why = (want["why"] as? String).map { "\n  why: \($0)" } ?? ""

                if let expected = want["hookTimeoutSeconds"] as? Int {
                    #expect(GateInstaller.hookTimeoutSeconds == expected, "\(where_) hook timeout\(why)")
                }
                if let expected = want["scriptTimeoutSeconds"] as? Int {
                    #expect(GateInstaller.scriptTimeoutSeconds == expected, "\(where_) script timeout\(why)")
                }
                if want["scriptDecidesFirst"] as? Bool == true,
                   GateInstaller.scriptTimeoutSeconds >= GateInstaller.hookTimeoutSeconds {
                    Issue.record("""
                        \(where_): the gate fails OPEN — script \
                        \(GateInstaller.scriptTimeoutSeconds)s is not below hook \
                        \(GateInstaller.hookTimeoutSeconds)s\(why)
                        """)
                }

                if want["refusesTimeoutAtOrAboveHookTimeout"] as? Bool == true {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    #expect(throws: GateError.self, "\(where_) install guard\(why)") {
                        _ = try GateInstaller.install(
                            gateDirectory: directory,
                            timeoutSeconds: GateInstaller.hookTimeoutSeconds)
                    }
                }

                if let expected = want["timeoutDecision"] as? String {
                    try checkUnansweredGate(decides: expected, case: where_, why: why)
                }

                if let expected = want["settings"] as? [String: Any] {
                    let path = want["scriptPath"] as? String ?? ""
                    let raw = GateInstaller.settingsJSON(scriptPath: path)
                    let parsed = try JSONSerialization.jsonObject(
                        with: Data(raw.utf8)) as? [String: Any] ?? [:]
                    // Structure, not bytes. JSONSerialization writes `"key" : value` and escapes
                    // forward slashes where Go's encoder does neither; both are valid JSON the
                    // engine reads identically, so pinning the text would make one core fight its
                    // own standard library for nothing.
                    #expect(NSDictionary(dictionary: parsed) == NSDictionary(dictionary: expected),
                            "\(where_) settings structure\(why)\n  got: \(raw)")
                }
            }
        }
    }

    /// Generates the script with a zero-second wait and actually runs it. Matching the text would
    /// pass on a script that never executes.
    private func checkUnansweredGate(decides expected: String, case where_: String, why: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("gate.sh")
        try Data(GateInstaller.shellScript(gateDirectory: directory, timeoutSeconds: 0).utf8)
            .write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"tool_name":"Bash"}"#.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = parsed["hookSpecificOutput"] as? [String: Any],
              let decision = specific["permissionDecision"] as? String
        else {
            Issue.record("""
                \(where_): the gate printed something the engine cannot read: \
                \(String(decoding: data, as: UTF8.self))\(why)
                """)
            return
        }
        #expect(decision == expected, "\(where_) unanswered gate decision\(why)")
    }

    /// Every kind on disk has a runner here.
    ///
    /// This suite iterates by kind, so a case of a kind nobody implemented would be skipped in
    /// silence — and a case nobody runs is worse than no case at all, because it reads as coverage.
    /// Adding a kind must break every implementation until each one handles it, which is the point.
    @Test("no case is silently skipped")
    func everyKindHasARunner() throws {
        let known: Set<String> = ["stream", "stderr", "command", "objective", "cron", "gate"]
        let directories = try FileManager.default.contentsOfDirectory(
            at: Self.casesDirectory, includingPropertiesForKeys: nil)

        for directory in directories where directory.hasDirectoryPath {
            let meta = directory.appendingPathComponent("case.json")
            guard let data = try? Data(contentsOf: meta),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Issue.record("\(directory.lastPathComponent): unreadable case.json")
                continue
            }
            let kind = object["kind"] as? String ?? ""
            if !known.contains(kind) {
                Issue.record("""
                    \(directory.lastPathComponent): kind '\(kind)' has no runner in the Swift \
                    core. Add one — a case that no implementation runs reads as coverage it is not.
                    """)
            }
        }
    }

    /// A suite that silently finds nothing would pass forever.
    @Test("the cases are actually found and loaded")
    func casesExist() throws {
        #expect(try Self.cases(ofKind: "stream").count >= 3)
        #expect(try Self.cases(ofKind: "objective").count >= 1)
        #expect(try Self.cases(ofKind: "cron").count >= 1)
        #expect(try Self.cases(ofKind: "command").count >= 2)
        #expect(try Self.cases(ofKind: "stderr").count >= 1)
        #expect(try Self.cases(ofKind: "gate").count >= 1)
    }
}

@Suite("Apps from the engine account")
struct OnlyGivenAppsTests {
    @Test("a bot kept to bupsy's apps runs Claude with --strict-mcp-config")
    func strictFlag() {
        let plain = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", mcpConfigPaths: ["/x.json"]))
        #expect(!plain.arguments.contains("--strict-mcp-config"))
        let kept = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", mcpConfigPaths: ["/x.json"], onlyGivenApps: true))
        #expect(kept.arguments.contains("--strict-mcp-config"))
        #expect(kept.arguments.contains("/x.json"))
    }
}

@Suite("The person's own browser")
struct UseBrowserTests {
    @Test("a bot given the browser runs Claude with --chrome, and only then")
    func claudeChrome() {
        let plain = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi"))
        #expect(!plain.arguments.contains("--chrome"))
        let browsing = ClaudeAdapter().invocation(for: RunRequest(prompt: "hi", useBrowser: true))
        #expect(browsing.arguments.contains("--chrome"))
    }

    @Test("a dashed prompt still goes last, after --chrome")
    func claudeChromeBeforeDashedPrompt() {
        let args = ClaudeAdapter().invocation(for: RunRequest(prompt: "- be terse", useBrowser: true)).arguments
        #expect(args.suffix(2) == ["--", "- be terse"])
        #expect(args.contains("--chrome"))
    }

    @Test("a bot given the browser turns on Codex's browser use, and only then")
    func codexBrowserUse() {
        let plain = CodexAdapter().invocation(for: RunRequest(prompt: "hi"))
        #expect(!plain.arguments.contains("--enable"))
        let args = CodexAdapter().invocation(for: RunRequest(prompt: "hi", useBrowser: true)).arguments
        #expect(args.contains("browser_use_external"))
        #expect(args.last == "hi")
    }
}
