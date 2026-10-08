import CryptoKit
import Foundation

/// Everything about a bot that travels when it moves to another of the person's Macs, as one JSON
/// document the old Mac sends and the new one reads.
///
/// What it does not carry is as deliberate as what it does. The engine's own session stays
/// behind: Claude Code and Codex keep it under the folder the bot worked in, on that Mac, and a
/// copy elsewhere would point at paths that are not there. The bot writes itself hand-off notes
/// instead, and its first turn on the new Mac starts from them, the way a fresh chat does. Its
/// recent messages come too, so the person still sees what was said.
public struct BotMoveManifest: Codable, Sendable, Equatable {
    /// Raised when the document changes in a way an older Bupsy cannot read.
    public static let currentVersion = 1

    public var version: Int
    /// The Mac it is leaving, by the name the person knows it by.
    public var fromMac: String
    public var profile: BotMoveProfile
    public var routines: [Routine]
    public var objectives: [Objective]
    public var folderWatches: [FolderWatch]
    /// Its recent visible chat, oldest first.
    public var history: [MovedEntry]
    /// What the bot wrote itself before leaving. Nil when it had no conversation to leave.
    public var notes: String?
    /// The bot's own folder, zipped and sent ahead, when it had anything in it.
    public var files: BotMoveFiles?
    /// Where its own folder was on the old Mac, so a folder watch on it follows it.
    public var oldFolder: String?

    public init(version: Int = currentVersion, fromMac: String, profile: BotMoveProfile,
                routines: [Routine] = [], objectives: [Objective] = [], folderWatches: [FolderWatch] = [],
                history: [MovedEntry] = [], notes: String? = nil, files: BotMoveFiles? = nil,
                oldFolder: String? = nil) {
        self.version = version; self.fromMac = fromMac; self.profile = profile
        self.routines = routines; self.objectives = objectives; self.folderWatches = folderWatches
        self.history = history; self.notes = notes; self.files = files; self.oldFolder = oldFolder
    }
}

/// Who the bot is and how it is set up: the same things Duplicate copies, plus where it is filed.
public struct BotMoveProfile: Codable, Sendable, Equatable {
    public var name: String
    public var engine: String
    public var model: String?
    public var autonomy: String
    public var job: String?
    /// A folder the person chose. Nil means the bot's own folder, whose files travel with it.
    public var workdir: String?
    public var avatarHue: Double
    public var avatarShape: String?
    public var avatarColour: Int?
    public var role: String?
    /// The sidebar section.
    public var section: String?
    public var pinned: Bool
    public var hidden: Bool
    public var onlyBupsyApps: Bool
    public var useBrowser: Bool
    public var sharedWithDevices: Bool
    public var toolAllowlist: [String]

    public init(name: String, engine: String, model: String? = nil, autonomy: String = "ask",
                job: String? = nil, workdir: String? = nil, avatarHue: Double = 0,
                avatarShape: String? = nil, avatarColour: Int? = nil, role: String? = nil,
                section: String? = nil, pinned: Bool = false, hidden: Bool = false,
                onlyBupsyApps: Bool = false, useBrowser: Bool = false, sharedWithDevices: Bool = true,
                toolAllowlist: [String] = []) {
        self.name = name; self.engine = engine; self.model = model; self.autonomy = autonomy
        self.job = job; self.workdir = workdir; self.avatarHue = avatarHue
        self.avatarShape = avatarShape; self.avatarColour = avatarColour; self.role = role
        self.section = section; self.pinned = pinned; self.hidden = hidden
        self.onlyBupsyApps = onlyBupsyApps; self.useBrowser = useBrowser
        self.sharedWithDevices = sharedWithDevices; self.toolAllowlist = toolAllowlist
    }
}

/// One line of a moving bot's chat: what you said, what it said, a message from another bot, or a
/// step it took. Approvals, questions and notes stay behind: they were about runs on the old Mac.
public struct MovedEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case you, bot, from, tool
    }

    public var kind: Kind
    /// The words, or for a step, its arguments as JSON.
    public var text: String
    /// Who sent a message from another bot, and that bot's id on the old Mac.
    public var author: String?
    public var authorID: String?
    /// The tool a step used.
    public var tool: String?
    public var at: Date

    public init(kind: Kind, text: String, author: String? = nil, authorID: String? = nil,
                tool: String? = nil, at: Date) {
        self.kind = kind; self.text = text; self.author = author; self.authorID = authorID
        self.tool = tool; self.at = at
    }
}

/// The zipped folder sent ahead of the manifest, so the new Mac can tell it arrived whole.
public struct BotMoveFiles: Codable, Sendable, Equatable {
    public var bytes: Int64
    public var sha256: String

    public init(bytes: Int64, sha256: String) {
        self.bytes = bytes; self.sha256 = sha256
    }
}

/// What the new Mac says once the bot is there.
public struct BotMoveReceipt: Codable, Sendable, Equatable {
    /// Its id on the new Mac.
    public let id: String
    /// Its name there, which differs when a bot there already had it ("Scout 2").
    public let name: String

    public init(id: String, name: String) {
        self.id = id; self.name = name
    }
}

/// The rules both Macs follow when a bot moves, kept here so they can be tested.
public enum BotMove {
    /// The most recent chat lines that go with it. Enough to read back over; older ones stay in
    /// the old Mac's history only while it has the bot, which is no longer.
    public static let historyLimit = 300
    /// The largest folder that moves with a bot. A folder bigger than this is work that belongs
    /// in a folder both Macs share, and copying it would tie up both Macs for minutes.
    /// In the decimal megabytes Finder counts in, so "200 MB" here is 200 MB there.
    public static let maxFolderBytes: Int64 = 200_000_000
    /// The largest zip of such a folder. Files that do not compress (video, say) come out a
    /// little bigger zipped than they were.
    public static let maxArchiveBytes: Int64 = maxFolderBytes + 32_000_000
    /// The folder goes in pieces this size, each its own request: a request has 30 seconds to
    /// finish on the other side, and a slow link moves a piece well within that.
    public static let partBytes = 8 * 1024 * 1024
    /// The largest manifest. History is text, but a step's arguments can hold a whole file.
    public static let maxManifestBytes = 16 * 1024 * 1024
    /// Each history line and step is cut to this, so one huge paste does not sink the move.
    public static let maxTextLength = 40_000
    public static let maxArgumentsLength = 8_000

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// `name`, or the first of "name 2", "name 3"… that no bot on this Mac has, since bots are
    /// addressed by name and two with the same one would misroute messages.
    public static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Bot" : name.trimmingCharacters(in: .whitespaces)
        guard isTaken(base) else { return base }
        var number = 2
        while isTaken("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Why a folder is too big to move, or nil when it fits.
    public static func sizeRefusal(botName: String, bytes: Int64) -> String? {
        guard bytes > maxFolderBytes else { return nil }
        return "\(botName)'s folder holds \(formatted(bytes)), more than the \(formatted(maxFolderBytes)) "
            + "that can move with it. Make it smaller, or point \(botName) at a folder both Macs share, "
            + "then try again."
    }

    public static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The total size of the files in a folder, hidden ones included, without following links
    /// out of it. Zero for a folder that is not there.
    public static func folderSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Whether a folder has any files in it at all, so an empty one is not zipped and sent.
    public static func hasFiles(_ folder: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return !contents.isEmpty
    }

    /// A line of text cut to the limit, saying so.
    public static func capped(_ text: String, limit: Int = maxTextLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[cut short when it moved]"
    }

    /// A step's arguments, kept readable when they are long: each long value is cut, rather than
    /// the JSON itself, which would no longer parse and would show as a raw blob.
    public static func cappedArguments(_ json: String, limit: Int = maxArgumentsLength) -> String {
        guard json.utf8.count > limit else { return json }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return "{}"
        }
        let each = max(200, limit / max(object.count, 1))
        var trimmed: [String: Any] = [:]
        for (key, value) in object {
            if let text = value as? String {
                trimmed[key] = text.count > each ? String(text.prefix(each)) + "…" : text
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      data.count > each {
                trimmed[key] = "…"
            } else {
                trimmed[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: trimmed, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A folder watch's path on the new Mac: inside the bot's old folder, the same place inside
    /// its new one; anywhere else, unchanged.
    public static func followFolder(_ path: String, from old: String?, to new: String) -> String {
        guard let old, !old.isEmpty else { return path }
        let standardOld = (old as NSString).standardizingPath
        let standardPath = (path as NSString).standardizingPath
        if standardPath == standardOld { return new }
        guard standardPath.hasPrefix(standardOld + "/") else { return path }
        return (new as NSString).appendingPathComponent(String(standardPath.dropFirst(standardOld.count + 1)))
    }

    /// A move's id, which also names its file on the new Mac, so only a UUID is accepted.
    public static func isMoveID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The pieces a file of `bytes` goes in, as offset and length.
    public static func parts(of bytes: Int64, size: Int = partBytes) -> [(offset: Int64, length: Int)] {
        guard bytes > 0 else { return [] }
        var parts: [(Int64, Int)] = []
        var offset: Int64 = 0
        while offset < bytes {
            let length = Int(min(Int64(size), bytes - offset))
            parts.append((offset, length))
            offset += Int64(length)
        }
        return parts
    }

    /// SHA-256 of a file, hex, read a piece at a time so a large one is never all in memory.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public struct ArchiveFailure: LocalizedError {
        public let errorDescription: String?
    }

    /// Zips a folder's contents, with macOS's own `ditto`, off the calling thread.
    public static func zip(_ folder: URL, to archive: URL) async throws {
        try await ditto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", folder.path, archive.path],
                        failure: "Couldn't pack the folder to send")
    }

    /// Unpacks an archive made by `zip` into a folder, which is created if needed.
    public static func unzip(_ archive: URL, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ditto(["-x", "-k", archive.path, folder.path], failure: "Couldn't unpack the folder that was sent")
    }

    private static func ditto(_ arguments: [String], failure: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let wait = try process.launchForWaiting()
            let said = errors.fileHandleForReading.readDataToEndOfFile()
            wait()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ArchiveFailure(errorDescription: detail.isEmpty ? "\(failure)." : "\(failure): \(detail)")
            }
        }.value
    }
}
