import BupsyKit
import Foundation

/// Taking in a bot that another of the person's Macs is moving here.
///
/// Three steps, each a request from that Mac with its device key, like every other /api route:
/// `begin` says how big its folder is, so a Mac without room says so before anything is sent;
/// `files` brings the zipped folder in pieces; and the bot itself comes last, as a manifest. Only
/// once this Mac has set the bot up and answered does the other Mac remove it. A move that fails
/// anywhere along the way leaves the bot where it was, and nothing half-made here.
extension RemoteAccess {
    struct IncomingMove {
        let file: URL
        let expected: Int64
        var received: Int64
        let began: Date
    }

    /// A move not finished within this long is let go, and its piece of folder deleted.
    static let incomingMoveLifetime: TimeInterval = 60 * 60

    static var incomingMovesDirectory: URL {
        AppHome.directory.appendingPathComponent("incoming-moves", isDirectory: true)
    }

    func receiveMove(_ request: HTTPRequest) async -> HTTPResponse {
        // "/api/moves/<id>/files" becomes ["moves", "<id>", "files"].
        let parts = request.path.split(separator: "/").dropFirst().map(String.init)
        guard request.method == "POST", parts.count == 2 || parts.count == 3, parts[0] == "moves",
              BotMove.isMoveID(parts[1]) else { return .error("Not found", status: 404) }
        let id = parts[1]
        switch parts.count == 3 ? parts[2] : "" {
        case "begin": return beginMove(id, request)
        case "files": return receiveMovePart(id, request)
        case "": return await finishMove(id, request)
        default: return .error("Not found", status: 404)
        }
    }

    private var thisMac: String { Host.current().localizedName ?? "This Mac" }

    private func beginMove(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        forgetStaleMoves()
        let bytes = (request.json?["bytes"] as? NSNumber)?.int64Value ?? -1
        guard bytes >= 0 else { return .error("That move didn't say how big it is.", status: 400) }
        guard bytes <= BotMove.maxArchiveBytes else {
            return .error("That folder is bigger than the \(BotMove.formatted(BotMove.maxFolderBytes)) that can move with a bot.", status: 413)
        }
        // Room for the zip and for what it unpacks to, with some to spare.
        let free = (try? AppHome.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free > bytes * 3 + 100 * 1024 * 1024 else {
            return .error("\(thisMac) doesn't have room for its files. Free up some space there, then try again.", status: 507)
        }
        let file = Self.incomingMovesDirectory.appendingPathComponent("\(id).zip")
        do {
            try FileManager.default.createDirectory(at: Self.incomingMovesDirectory, withIntermediateDirectories: true)
            try Data().write(to: file)
        } catch {
            return .error("\(thisMac) couldn't make room for its files: \(error.localizedDescription)", status: 500)
        }
        incomingMoves[id] = IncomingMove(file: file, expected: bytes, received: 0, began: Date())
        return .json(["ok": true])
    }

    /// A piece of the zipped folder, appended where the last one ended. A piece out of place
    /// means one went missing, and the move fails rather than unpacking a damaged folder.
    private func receiveMovePart(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var incoming = incomingMoves[id] else {
            return .error("That move took too long or wasn't started. Try again.", status: 409)
        }
        guard let offset = request.query["offset"].flatMap(Int64.init), offset == incoming.received else {
            return .error("A piece of its folder went missing on the way. Try again.", status: 409)
        }
        guard incoming.received + Int64(request.body.count) <= incoming.expected else {
            return .error("More of its folder arrived than was announced. Try again.", status: 413)
        }
        do {
            let handle = try FileHandle(forWritingTo: incoming.file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: request.body)
        } catch {
            return .error("\(thisMac) couldn't save its files: \(error.localizedDescription)", status: 500)
        }
        incoming.received += Int64(request.body.count)
        incomingMoves[id] = incoming
        return .json(["ok": true])
    }

    private func finishMove(_ id: String, _ request: HTTPRequest) async -> HTTPResponse {
        if let started = finishedMoves[id] { return await started.value }
        guard let manifest = try? BotMove.decoder.decode(BotMoveManifest.self, from: request.body) else {
            return .error("That bot didn't arrive whole. Try again.", status: 400)
        }
        let work = Task { [weak self] () -> HTTPResponse in
            guard let self else { return .error("Bupsy is closing", status: 503) }
            return await self.importMove(id, manifest)
        }
        finishedMoves[id] = work
        return await work.value
    }

    private func importMove(_ id: String, _ manifest: BotMoveManifest) async -> HTTPResponse {
        let incoming = incomingMoves.removeValue(forKey: id)
        defer { if let incoming { try? FileManager.default.removeItem(at: incoming.file) } }
        let name = manifest.profile.name
        var archive: URL?
        if let files = manifest.files {
            guard let incoming, incoming.received == files.bytes, incoming.expected == files.bytes else {
                return .error("\(name)'s files didn't all arrive. Try again.", status: 409)
            }
            let file = incoming.file
            let hash = await Task.detached { try? BotMove.sha256(of: file) }.value
            guard hash == files.sha256 else {
                return .error("\(name)'s files arrived damaged. Try again.", status: 409)
            }
            archive = file
        }
        guard let model else { return .error("Bupsy is closing", status: 503) }
        do {
            let receipt = try await model.receiveMovedBot(manifest, archive: archive)
            return .json(["id": receipt.id, "name": receipt.name])
        } catch {
            return .error("\(thisMac) couldn't set up \(name): \(error.localizedDescription)", status: 500)
        }
    }

    /// Moves begun and never finished: the other Mac went to sleep, or gave up. Also any piece
    /// of folder left from before Bupsy last quit, which nothing here remembers any more.
    private func forgetStaleMoves() {
        let cutoff = Date().addingTimeInterval(-Self.incomingMoveLifetime)
        for (id, move) in incomingMoves where move.began < cutoff {
            try? FileManager.default.removeItem(at: move.file)
            incomingMoves[id] = nil
        }
        let known = Set(incomingMoves.values.map(\.file.lastPathComponent))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: Self.incomingMovesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in leftovers where !known.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
