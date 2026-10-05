import Foundation

/// "When files change in this folder, do this." The watch kind of trigger.
///
/// Runs while bupsy is open: the app watches the folder with FSEvents, gathers changes for a few
/// seconds so a burst of saves is one run, and hands the bot the list of what changed.
public struct FolderWatch: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var botID: String
    public var name: String
    public var prompt: String
    public var path: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, botID: String, name: String, prompt: String,
                path: String, enabled: Bool = true) {
        self.id = id; self.botID = botID; self.name = name
        self.prompt = prompt; self.path = path; self.enabled = enabled
    }

    public static let kind = "watch"

    public func record() -> TriggerRecord {
        let config = ["name": name, "prompt": prompt, "path": path]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
                                encoding: .utf8)) ?? "{}"
        return TriggerRecord(id: id, botID: botID, kind: Self.kind, config: json, enabled: enabled)
    }

    public init?(record: TriggerRecord) {
        guard record.kind == Self.kind,
              let data = record.config.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = config["name"] as? String,
              let prompt = config["prompt"] as? String,
              let path = config["path"] as? String else { return nil }
        self.init(id: record.id, botID: record.botID, name: name, prompt: prompt, path: path,
                  enabled: record.enabled)
    }

    /// What the bot is told when the watch fires: the instruction, then what changed.
    ///
    /// Paths are shown relative to the folder and capped, so a big copy-in does not become a
    /// prompt of ten thousand file names on the person's quota.
    public func prompt(for changed: [String], limit: Int = 20) -> String {
        let root = (path as NSString).standardizingPath
        var seen = Set<String>()
        let relative = changed.map { (($0 as NSString).standardizingPath) }
            .map { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
        let shown = relative.prefix(limit).map { "- \($0)" }.joined(separator: "\n")
        let more = relative.count > limit ? "\n- …and \(relative.count - limit) more" : ""
        return "\(prompt)\n\n(Files changed in \(path):\n\(shown)\(more))"
    }
}

extension Store {
    public func folderWatches() throws -> [FolderWatch] {
        try triggers().compactMap(FolderWatch.init(record:))
    }

    public func save(_ watch: FolderWatch) throws {
        try save(watch.record())
    }

    public func deleteTrigger(id: String) throws {
        try deleteRoutine(id: id)
    }
}
