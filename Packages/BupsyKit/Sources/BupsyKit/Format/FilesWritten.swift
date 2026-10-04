import Foundation

/// The files a bot changed, read back from its own recorded tool calls.
///
/// Grok Bot calls this a Library. bupsy has no separate store of artefacts — a bot's work is files
/// on the person's disk — so this lists exactly those: every path a write or edit tool touched,
/// newest first. Built from the audit trail rather than by watching the folder, so it shows what
/// this bot did and nothing that merely happened nearby.
public enum FilesWritten {
    /// Paths a single tool call wrote to. Empty for anything that does not write a file.
    public static func paths(tool: String, argumentsJSON: String) -> [String] {
        guard let data = argumentsJSON.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else { return [] }

        switch tool {
        // Claude Code's file tools.
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let object = decoded as? [String: Any] else { return [] }
            return [object["file_path"], object["notebook_path"]].compactMap { $0 as? String }
        // Codex reports a patch as a list of changes, or a map of path to change.
        case "edit":
            if let list = decoded as? [[String: Any]] {
                return list.compactMap { $0["path"] as? String }
            }
            if let map = decoded as? [String: Any] {
                return map.keys.filter { $0.hasPrefix("/") || $0.contains(".") }.sorted()
            }
            return []
        default:
            return []
        }
    }
}

/// A file a bot changed, and when it last did.
public struct WrittenFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let at: Date
    public var id: String { path }
    public init(path: String, at: Date) { self.path = path; self.at = at }
}
