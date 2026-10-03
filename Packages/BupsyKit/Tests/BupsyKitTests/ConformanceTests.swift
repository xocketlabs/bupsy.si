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
        return try directories.compactMap { directory in
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

    /// A suite that silently finds nothing would pass forever.
    @Test("the cases are actually found and loaded")
    func casesExist() throws {
        #expect(try Self.cases(ofKind: "stream").count >= 3)
        #expect(try Self.cases(ofKind: "objective").count >= 1)
        #expect(try Self.cases(ofKind: "cron").count >= 1)
    }
}
