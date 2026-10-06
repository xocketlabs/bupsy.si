import Foundation

/// A tool call waiting on a human.
public struct GateRequest: Sendable, Identifiable, Equatable {
    public let id: String
    public let tool: String
    /// The raw `tool_input` object, for display and for the audit log.
    public let inputJSON: String
    public let sessionID: String?
    public let receivedAt: Date

    /// A one-line rendering for the approval card — the field that actually says what will happen.
    public var summary: String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return tool }
        for key in ["command", "file_path", "path", "url", "pattern", "description"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return tool
    }
}

public enum GateVerdict: Sendable, Equatable {
    case allow(reason: String?)
    case deny(reason: String)
}

/// Holds tool calls open until something decides.
///
/// **File-based on purpose.** The hook writes a request file and polls for a decision file,
/// rather than talking to a socket. One mechanism then serves both hosts: on the Mac the app
/// watches a local directory, and on a rented machine the same files sit in `~/.bupsy/` for a
/// routine to park against while the Mac is asleep (PLAN.md §4). A socket would have needed a
/// second, entirely different design for the cloud case.
public actor ApprovalGate {
    /// `nonisolated` because it is set once at init and never mutated — callers need the path
    /// to write the hook settings before any actor work happens.
    public nonisolated let directory: URL
    private var decisions: [String: GateVerdict] = [:]
    private var continuation: AsyncStream<GateRequest>.Continuation?
    private var expiryContinuation: AsyncStream<String>.Continuation?
    private var seen: Set<String> = []
    private var expiredSeen: Set<String> = []
    private var pollTask: Task<Void, Never>?

    public init(directory: URL) throws {
        self.directory = directory
        for sub in ["pending", "decisions", "expired"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// Creates a gate under a unique temporary directory, for one run.
    public static func temporary() throws -> ApprovalGate {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bupsy-gate-\(UUID().uuidString)", isDirectory: true)
        return try ApprovalGate(directory: url)
    }

    /// Requests arrive here as the agent makes tool calls.
    public func requests() -> AsyncStream<GateRequest> {
        AsyncStream { continuation in
            self.continuation = continuation
            pollTask = Task { await self.poll() }
            continuation.onTermination = { _ in Task { await self.stop() } }
        }
    }

    /// Ids of requests the hook script gave up on and denied by itself, because nobody answered
    /// before `GateInstaller.scriptTimeoutSeconds`. The app uses this to settle the card, so it
    /// does not sit there offering Allow for a call that has already been refused.
    ///
    /// Read by the same poll loop as `requests()`, so call `requests()` too.
    public func expirations() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.expiryContinuation = continuation
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
        expiryContinuation?.finish()
        expiryContinuation = nil
    }

    /// Answers a waiting call. The hook is polling for this file and will pick it up.
    public func decide(_ id: String, _ verdict: GateVerdict) throws {
        decisions[id] = verdict
        let url = directory.appendingPathComponent("decisions/\(id).json")
        try Data(Self.hookResponse(for: verdict).utf8).write(to: url, options: .atomic)
    }

    /// Polling rather than FSEvents: a 200 ms loop over a directory that holds at most a handful
    /// of files is cheap, and it behaves identically over a network filesystem — which is what
    /// reading a rented machine's gate directory will eventually be.
    private func poll() async {
        let pending = directory.appendingPathComponent("pending")
        let expired = directory.appendingPathComponent("expired")
        while !Task.isCancelled {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: pending, includingPropertiesForKeys: nil)) ?? []

            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                if let request = Self.parse(id: id, at: file) {
                    continuation?.yield(request)
                }
            }

            let expiredFiles = (try? FileManager.default.contentsOfDirectory(
                at: expired, includingPropertiesForKeys: nil)) ?? []
            for file in expiredFiles {
                let id = file.lastPathComponent
                guard !id.hasPrefix("."), !expiredSeen.contains(id) else { continue }
                expiredSeen.insert(id)
                expiryContinuation?.yield(id)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    static func parse(id: String, at url: URL) -> GateRequest? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool_name"] as? String
        else { return nil }

        let input = object["tool_input"].map {
            (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        } ?? "{}"

        return GateRequest(
            id: id, tool: tool, inputJSON: input,
            sessionID: object["session_id"] as? String, receivedAt: Date())
    }

    /// The exact JSON Claude Code reads back from a `PreToolUse` hook.
    static func hookResponse(for verdict: GateVerdict) -> String {
        let (decision, reason) = switch verdict {
        case .allow(let reason): ("allow", reason ?? "approved in bupsy")
        case .deny(let reason): ("deny", reason)
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            ]
        ]
        return (try? String(
            data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8)) ?? ""
    }
}
