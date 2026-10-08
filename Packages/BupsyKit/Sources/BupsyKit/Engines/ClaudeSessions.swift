import Foundation

/// A conversation the person had in Claude Code itself: in VS Code, or in the terminal.
public struct ClaudeSession: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable {
        case vscode = "VS Code"
        case terminal = "Terminal"
        case other = "Claude Code"
    }

    /// Claude Code's session id, which `--resume` takes.
    public let id: String
    public let title: String
    /// The folder it was started in. Claude Code keeps sessions per folder, so a resume has to
    /// run there.
    public let folder: String
    public let lastActive: Date
    public let source: Source
    public let file: URL
}

/// One message of an imported conversation, for the bot's chat to show.
public enum ImportedMessage: Equatable, Sendable {
    case you(String, at: Date)
    case bot(String, at: Date)
    case tool(name: String, argumentsJSON: String, at: Date)
}

/// Reads the conversations Claude Code keeps on this Mac, so one can be carried on in Bupsy.
///
/// Claude Code writes every conversation, from VS Code and from the terminal alike, to
/// `~/.claude/projects/<folder>/<session>.jsonl`. Only those files are read: never the sign-in,
/// which lives elsewhere and which Bupsy does not touch. And only their ends: a long session runs
/// to over a hundred megabytes, and the title, the folder and the latest messages are all at the
/// end, while Claude Code itself holds the whole history for the resume.
public enum ClaudeSessions {
    public static var projectsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// How much of a file's end is read to describe it, and to import from it.
    static let summaryTail = 512 * 1024
    static let summaryHead = 64 * 1024
    static let transcriptTail = 4 * 1024 * 1024

    /// The person's own Claude Code conversations, newest first. Runs Bupsy itself started (or
    /// any other program driving Claude Code headlessly) are left out: they are already somewhere.
    /// `excluding` holds conversation ids already known elsewhere (Bupsy's own bots), and
    /// `excludingFolder` a folder whose runs are all Bupsy's: neither is the person's to carry on.
    public static func recent(limit: Int = 40, in folder: URL = projectsFolder,
                              excluding known: Set<String> = [], excludingFolder botFolders: String? = nil) -> [ClaudeSession] {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        var sessions: [ClaudeSession] = []
        for (url, date) in files {
            if let session = summary(of: url, lastActive: date), !known.contains(session.id),
               !(botFolders.map { session.folder.hasPrefix($0) } ?? false) {
                sessions.append(session)
            }
            if sessions.count >= limit { break }
        }
        return sessions
    }

    /// What a session is: its title, folder and source, from the end of its file (and the start,
    /// for one too short to have a title yet).
    static func summary(of file: URL, lastActive: Date) -> ClaudeSession? {
        var title: String?
        var lastPrompt: String?
        var firstPrompt: String?
        var folder: String?
        var entrypoint: String?
        var sessionID: String?
        /// Whether any of it is the main conversation. A helper agent's conversation (a Task or
        /// a subagent Claude started) is all side-thread, and not something a person continues.
        var hasMainThread = false

        // The folder it started in, from the start of the file: Claude Code files a conversation
        // under that folder and resumes it only from there, whatever folder it moved to later.
        let head = records(headOf: file, bytes: summaryHead)
        folder = head.lazy.compactMap { $0["cwd"] as? String }.first
        for record in records(tailOf: file, bytes: summaryTail) + head {
            sessionID = sessionID ?? record["sessionId"] as? String
            folder = folder ?? record["cwd"] as? String
            entrypoint = entrypoint ?? record["entrypoint"] as? String
            switch record["type"] as? String {
            case "ai-title": title = record["aiTitle"] as? String ?? title
            case "last-prompt": lastPrompt = record["lastPrompt"] as? String ?? lastPrompt
            case "user":
                if record["isSidechain"] as? Bool != true { hasMainThread = true }
                if firstPrompt == nil, record["isSidechain"] as? Bool != true, let text = promptText(record) { firstPrompt = text }
            default: break
            }
        }
        // Headless runs (Bupsy's own, scripts) are not conversations the person had.
        guard hasMainThread, let folder, let sessionID = sessionID ?? Optional(file.deletingPathExtension().lastPathComponent),
              let entrypoint, !entrypoint.hasPrefix("sdk") else { return nil }
        let source: ClaudeSession.Source = entrypoint.contains("vscode") ? .vscode : entrypoint == "cli" ? .terminal : .other
        let name = [title, lastPrompt, firstPrompt].compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled conversation"
        return ClaudeSession(id: sessionID, title: oneLine(name), folder: folder, lastActive: lastActive,
                             source: source, file: file)
    }

    /// The latest messages, oldest first: what the person typed, what Claude said, and the tools it
    /// used. Thinking, side conversations and Claude Code's own bookkeeping are left out.
    public static func transcript(of session: ClaudeSession, limit: Int = 150) -> [ImportedMessage] {
        var messages: [ImportedMessage] = []
        for record in records(tailOf: session.file, bytes: transcriptTail) {
            guard record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true else { continue }
            let at = (record["timestamp"] as? String).flatMap(Self.date) ?? session.lastActive
            switch record["type"] as? String {
            case "user":
                if let text = promptText(record) { messages.append(.you(text, at: at)) }
            case "assistant":
                for block in (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messages.append(.bot(text, at: at))
                        }
                    case "tool_use":
                        let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]))
                            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        messages.append(.tool(name: block["name"] as? String ?? "tool", argumentsJSON: input, at: at))
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Reading

    /// What the person typed, if this user record is that and not a tool result or a command
    /// Claude Code ran on their behalf.
    static func promptText(_ record: [String: Any]) -> String? {
        let content = (record["message"] as? [String: Any])?["content"]
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if !texts.isEmpty, !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                text = texts.joined(separator: "\n")
            }
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    static func records(tailOf file: URL, bytes: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        // Starting mid-file lands mid-line; that first part is dropped.
        return parse(data, dropFirstLine: start > 0)
    }

    static func records(headOf file: URL, bytes: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return [] }
        return parse(data, dropFirstLine: false)
    }

    static func parse(_ data: Data, dropFirstLine: Bool) -> [[String: Any]] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 90 ? String(flat.prefix(89)) + "…" : flat
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
