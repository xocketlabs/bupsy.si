import Foundation

/// "When files change in this folder, do this." The watch kind of trigger.
///
/// Runs while Bupsy is open: the app watches the folder with FSEvents, gathers changes for a few
/// seconds so a burst of saves is one run, and hands the bot the list of what changed.
public struct FolderWatch: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var botID: String
    public var name: String
    public var prompt: String
    public var path: String
    public var enabled: Bool
    /// File extensions to react to, lowercased and without the dot. Empty means every file.
    public var fileTypes: [String]

    public init(id: String = UUID().uuidString, botID: String, name: String, prompt: String,
                path: String, enabled: Bool = true, fileTypes: [String] = []) {
        self.id = id; self.botID = botID; self.name = name
        self.prompt = prompt; self.path = path; self.enabled = enabled
        self.fileTypes = fileTypes
    }

    public static let kind = "watch"

    public func record() -> TriggerRecord {
        var config = ["name": name, "prompt": prompt, "path": path]
        // Only written when set, so a watch on every file stores exactly what it always did.
        if !fileTypes.isEmpty { config["fileTypes"] = fileTypes.joined(separator: ",") }
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
                  enabled: record.enabled,
                  fileTypes: Self.fileTypes(from: config["fileTypes"] as? String ?? ""))
    }

    /// Reads what someone typed in "File types": "pdf, png, jpg", ".PDF", "*.png" all work.
    /// Lowercased, without dots or stars, each once, in the order typed.
    public static func fileTypes(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" })
            .map { part -> String in
                var type = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                while type.hasPrefix("*") || type.hasPrefix(".") { type.removeFirst() }
                return type
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether a changed file is one this watch reacts to.
    public func matches(_ changed: String) -> Bool {
        // A watch saved before folders were checked, or written to the store by hand, still never
        // fires on a folder that would set itself off.
        guard Self.refusal(forFolder: path) == nil,
              !Self.isIgnored(changed, watching: path) else { return false }
        guard !fileTypes.isEmpty else { return true }
        return fileTypes.contains((changed as NSString).pathExtension.lowercased())
    }

    // MARK: - Folders that would set themselves off

    /// Where the person's agents and Bupsy itself write during every run. A change in one of these
    /// is almost always a run's own doing, so reacting to it starts another run, which writes
    /// there again: a loop that spends the person's quota until someone notices.
    ///
    /// A local model's runtime counts too: Ollama logs to `~/.ollama` and LM Studio to
    /// `~/.lmstudio` while a local-model bot works.
    ///
    /// `~/Library` is only left out when the watch is above it: a folder picked inside it on
    /// purpose (iCloud Drive and the cloud-storage folders live there) is watched normally.
    static func busyFolders(home: String, appData: String) -> (always: [String], library: String) {
        (always: [appData, home + "/.claude", home + "/.codex", home + "/.ollama", home + "/.lmstudio"],
         library: home + "/Library")
    }

    /// Bupsy's data folder (bots' own folders live in it), read once: the environment that can move
    /// it does not change while the app runs.
    static let appData = standard(AppHome.directory.path)

    /// Why a folder cannot be watched, in words for the sheet, or nil when it can.
    ///
    /// The whole disk, the home folder and `~/Library` see a change somewhere nearly every second,
    /// including the agent's own session logs, so a watch on one runs again after every run.
    public static func refusal(forFolder folder: String, home: String = NSHomeDirectory()) -> String? {
        refusal(forFolder: folder, home: home, appData: appData)
    }

    static func refusal(forFolder folder: String, home: String, appData: String) -> String? {
        let folder = standard(folder), home = standard(home)
        let busy = busyFolders(home: home, appData: standard(appData))
        if folder == "/" || folder.isEmpty {
            return "Bupsy can't watch the whole disk. Pick the folder files actually arrive in."
        }
        // Anything that holds the home folder is at least as busy as home itself (`/Users`, say).
        if folder == home || isInside(home, folder) {
            return "Bupsy can't watch your whole home folder: something changes in it every few seconds. Pick the folder files actually arrive in."
        }
        if folder == busy.library {
            return "Bupsy can't watch ~/Library: apps write to it constantly. Pick the folder inside it you mean."
        }
        if busy.always.contains(where: { folder == $0 || isInside(folder, $0) }) {
            return "That folder is where Bupsy and your agents write while they work, so the watch would keep setting itself off."
        }
        return nil
    }

    /// Whether a change is one no watch should react to, whatever its file types: hidden files and
    /// anything in a hidden folder below the watched one (`.git`, `.DS_Store`, an editor's swap
    /// files), and anything in the folders agents and Bupsy write while they work.
    public static func isIgnored(_ changed: String, watching root: String,
                                 home: String = NSHomeDirectory()) -> Bool {
        isIgnored(changed, watching: root, home: home, appData: appData)
    }

    static func isIgnored(_ changed: String, watching root: String, home: String, appData: String) -> Bool {
        let changed = standard(changed), home = standard(home)
        let busy = busyFolders(home: home, appData: standard(appData))
        if busy.always.contains(where: { changed == $0 || isInside(changed, $0) }) { return true }
        // FSEvents reports real paths (/private/tmp/…) even for a watch saved as /tmp/…, so try
        // both spellings of the root before giving up on finding the path's place under it.
        let roots = [standard(root), (standard(root) as NSString).resolvingSymlinksInPath]
        guard let base = roots.first(where: { isInside(changed, $0) }) else {
            // Not under the root as far as we can tell: judge the file by its own name only, as
            // checking every component would ignore everything in a watch inside a hidden folder.
            return (changed as NSString).lastPathComponent.hasPrefix(".")
        }
        if isInside(changed, busy.library) && !(base == busy.library || isInside(base, busy.library)) {
            return true
        }
        let relative = changed.dropFirst(base == "/" ? 1 : base.count + 1)
        return relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// `path` is strictly below `folder`, by whole components (`/a/bc` is not inside `/a/b`).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path.count > 1 && path.hasPrefix("/") : path.hasPrefix(folder + "/")
    }

    /// Tilde expanded, `..` and `.` gone, no trailing slash: one spelling for comparing.
    static func standard(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
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
