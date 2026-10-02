import Foundation

/// A permissive view over one line of JSON.
///
/// Deliberately not `Codable`: engine stream schemas are undocumented in places and change
/// between releases. A strict decoder turns a new field into a crash or a dropped message;
/// this turns it into `.unknown`, which is visible in the transcript and the audit log.
/// Fixtures in Tests/Fixtures lock in the shapes we have actually observed.
///
/// Not `Sendable`: it wraps `[String: Any]` from `JSONSerialization`. That is fine, and
/// intentional — a `JSONLine` is created and consumed inside one synchronous `normalise`
/// call and never crosses an isolation boundary. Only `AgentEvent` leaves the adapter.
public struct JSONLine {
    public let raw: String
    private let object: [String: Any]

    public init?(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        self.raw = trimmed
        self.object = parsed
    }

    public func string(_ key: String) -> String? { object[key] as? String }
    public func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
    public func double(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
    public func bool(_ key: String) -> Bool? { object[key] as? Bool }
    public func dictionary(_ key: String) -> [String: Any]? { object[key] as? [String: Any] }
    public func array(_ key: String) -> [[String: Any]]? { object[key] as? [[String: Any]] }

    /// Re-encodes a nested value for display and audit. Sorted keys so transcripts diff cleanly.
    public static func encode(_ value: Any?) -> String {
        guard let value else { return "{}" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return string
    }
}
