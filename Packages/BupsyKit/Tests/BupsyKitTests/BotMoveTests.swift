import Foundation
import Testing
@testable import BupsyKit

@Suite("Moving a bot to another Mac")
struct BotMoveTests {
    @Test("the manifest survives the trip whole")
    func manifestRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000.123)
        let manifest = BotMoveManifest(
            fromMac: "MacBook Pro",
            profile: BotMoveProfile(name: "Video Producer", engine: "claude", model: "sonnet",
                                    autonomy: "trusted", job: "Cut the weekly video.", workdir: nil,
                                    avatarHue: 0.4, avatarShape: "cat", avatarColour: 3, role: "Video",
                                    section: "Site Factory", pinned: true, sharedWithDevices: false,
                                    toolAllowlist: ["Bash", "Edit"]),
            routines: [Routine(botID: "old", name: "Monday cut", prompt: "Cut it", cron: "0 9 * * 1",
                               tier: .launchAgent, lastFiredAt: at)],
            objectives: [Objective(botID: "old", goal: "Ship weekly", doneWhen: "A video is up",
                                   notes: "Fridays are busy", lastOutcome: .acted(summary: "Posted"))],
            folderWatches: [FolderWatch(botID: "old", name: "Footage", prompt: "Log it",
                                        path: "/Users/a/ws/old/in", fileTypes: ["mov"])],
            history: [MovedEntry(kind: .you, text: "Make it shorter", at: at),
                      MovedEntry(kind: .tool, text: #"{"command":"ls"}"#, tool: "Bash", at: at),
                      MovedEntry(kind: .from, text: "Here are the clips", author: "Lead", authorID: "l1", at: at),
                      MovedEntry(kind: .bot, text: "Done, 2:30 now.", at: at)],
            notes: "Working on episode 12.",
            files: BotMoveFiles(bytes: 1234, sha256: "ab"),
            oldFolder: "/Users/a/ws/old")
        let data = try BotMove.encoder.encode(manifest)
        let back = try BotMove.decoder.decode(BotMoveManifest.self, from: data)
        #expect(back == manifest)
        #expect(back.history.map(\.kind) == [.you, .tool, .from, .bot])
        #expect(back.routines.first?.lastFiredAt == at)
    }

    @Test("a name already used here gets the next free number")
    func names() {
        let here: Set<String> = ["scout", "scout 2", "lead"]
        let taken = { (name: String) in here.contains(name.lowercased()) }
        #expect(BotMove.freeName("Video Producer", isTaken: taken) == "Video Producer")
        #expect(BotMove.freeName("Scout", isTaken: taken) == "Scout 3")
        #expect(BotMove.freeName("Lead", isTaken: taken) == "Lead 2")
        #expect(BotMove.freeName("  ", isTaken: taken) == "Bot")
    }

    @Test("a folder over the limit is refused, saying how big it is")
    func sizeCap() {
        #expect(BotMove.sizeRefusal(botName: "Scout", bytes: 10 * 1024 * 1024) == nil)
        #expect(BotMove.sizeRefusal(botName: "Scout", bytes: BotMove.maxFolderBytes) == nil)
        let refusal = BotMove.sizeRefusal(botName: "Scout", bytes: BotMove.maxFolderBytes + 1)
        #expect(refusal?.contains("Scout's folder holds") == true)
        #expect(refusal?.contains("folder both Macs share") == true)
        // Counted the way Finder counts, so the limit reads as a round number.
        #expect(refusal?.contains("than the 200 MB") == true)
    }

    @Test("a folder's size counts hidden files and nested ones")
    func measuresFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bupsy-move-size-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: folder.appendingPathComponent("one.txt"))
        try Data(count: 500).write(to: folder.appendingPathComponent(".hidden"))
        try Data(count: 250).write(to: folder.appendingPathComponent("a/b/deep.bin"))
        #expect(BotMove.folderSize(folder) == 1750)
        #expect(BotMove.hasFiles(folder))
        #expect(BotMove.folderSize(folder.appendingPathComponent("missing")) == 0)
    }

    @Test("long steps stay readable JSON, and long text says it was cut")
    func capping() throws {
        let long = String(repeating: "x", count: 50_000)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["file_path": "/a.txt", "content": long]), as: UTF8.self)
        let capped = BotMove.cappedArguments(arguments)
        #expect(capped.utf8.count < 9_000)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(capped.utf8)) as? [String: Any])
        #expect(object["file_path"] as? String == "/a.txt")
        #expect(BotMove.cappedArguments(#"{"command":"ls"}"#) == #"{"command":"ls"}"#)
        #expect(BotMove.capped("short") == "short")
        #expect(BotMove.capped(long, limit: 10).hasSuffix("[cut short when it moved]"))
    }

    @Test("a folder watch inside its own folder follows it; one elsewhere stays put")
    func watchPaths() {
        #expect(BotMove.followFolder("/old/ws/b1/in", from: "/old/ws/b1", to: "/new/ws/b9") == "/new/ws/b9/in")
        #expect(BotMove.followFolder("/old/ws/b1", from: "/old/ws/b1", to: "/new/ws/b9") == "/new/ws/b9")
        #expect(BotMove.followFolder("/old/ws/b10/in", from: "/old/ws/b1", to: "/new/ws/b9") == "/old/ws/b10/in")
        #expect(BotMove.followFolder("/Users/a/Footage", from: nil, to: "/new") == "/Users/a/Footage")
    }

    @Test("pieces cover the file exactly once")
    func parts() {
        #expect(BotMove.parts(of: 0).isEmpty)
        let parts = BotMove.parts(of: 25, size: 10)
        #expect(parts.map(\.offset) == [0, 10, 20])
        #expect(parts.map(\.length) == [10, 10, 5])
        #expect(BotMove.isMoveID(UUID().uuidString))
        #expect(!BotMove.isMoveID("../../etc"))
    }

    @Test("a folder zipped here unpacks the same there")
    func archives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bupsy-move-zip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.md"))
        try Data("clip".utf8).write(to: source.appendingPathComponent("Attachments/clip one.mov"))
        let archive = root.appendingPathComponent("move.zip")
        try await BotMove.zip(source, to: archive)
        let hash = try BotMove.sha256(of: archive)
        #expect(hash.count == 64)

        let target = root.appendingPathComponent("target")
        try await BotMove.unzip(archive, into: target)
        #expect(try String(contentsOf: target.appendingPathComponent("notes.md"), encoding: .utf8) == "notes")
        #expect(try String(contentsOf: target.appendingPathComponent("Attachments/clip one.mov"), encoding: .utf8) == "clip")

        await #expect(throws: BotMove.ArchiveFailure.self) {
            try await BotMove.unzip(root.appendingPathComponent("missing.zip"), into: target)
        }
    }

    @Test("the bot goes in order: begin, the folder in pieces, then the bot itself")
    func clientFlow() async throws {
        let log = RemoteClientTests.Log()
        let received = Received()
        let server = LocalHTTPServer(bodyLimit: { _, _ in 20 * 1024 * 1024 }) { request in
            guard request.cookie("bupsy_device") == "K" else { return .error("Not paired.", status: 401) }
            log.add("\(request.method) \(request.path) offset=\(request.query["offset"] ?? "-") bytes=\(request.body.count)")
            if request.path.hasSuffix("/files") { received.append(request.body) }
            if request.path.hasSuffix("/begin") { return .json(["ok": true]) }
            if request.path.hasSuffix("/files") { return .json(["ok": true]) }
            guard let manifest = try? BotMove.decoder.decode(BotMoveManifest.self, from: request.body) else {
                return .error("bad", status: 400)
            }
            return .json(["id": "new-1", "name": manifest.profile.name + " 2"])
        }
        let port = try await server.start(preferredPort: 0)
        defer { server.stop() }

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("bupsy-move-\(UUID()).zip")
        let bytes = Data((0..<(BotMove.partBytes + 100)).map { UInt8($0 % 251) })
        try bytes.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        let client = RemoteClient(address: URL(string: "http://127.0.0.1:\(port)")!, key: "K")
        let move = UUID().uuidString
        try await client.beginMove(move, bytes: Int64(bytes.count))
        try await client.sendMoveFiles(move, archive: archive)
        let receipt = try await client.finishMove(move, manifest: BotMoveManifest(
            fromMac: "MacBook", profile: BotMoveProfile(name: "Scout", engine: "claude")))
        #expect(receipt == BotMoveReceipt(id: "new-1", name: "Scout 2"))
        #expect(received.data == bytes)
        let calls = log.all
        #expect(calls.count == 4)
        #expect(calls[0].hasPrefix("POST /api/moves/\(move)/begin offset=-"))
        #expect(calls[1] == "POST /api/moves/\(move)/files offset=0 bytes=\(BotMove.partBytes)")
        #expect(calls[2] == "POST /api/moves/\(move)/files offset=\(BotMove.partBytes) bytes=100")
        #expect(calls[3].hasPrefix("POST /api/moves/\(move) offset=-"))
    }

    @Test("a Mac on an older Bupsy says it needs updating")
    func olderMac() async throws {
        let server = LocalHTTPServer { _ in .error("Not found", status: 404) }
        let port = try await server.start(preferredPort: 0)
        defer { server.stop() }
        let client = RemoteClient(address: URL(string: "http://127.0.0.1:\(port)")!, key: "K")
        await #expect(throws: RemoteClient.Failure.refused(
            "That Mac's Bupsy is too old to take a bot. Update Bupsy there, then try again.")) {
            try await client.beginMove(UUID().uuidString, bytes: 0)
        }
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func append(_ data: Data) { lock.lock(); stored.append(data); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
