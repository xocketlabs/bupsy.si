import BupsyKit
import Foundation

/// Picks up messages bots have asked to send each other.
///
/// `bupsy-mcp` runs inside the engine's sandbox and can only drop a file here; it never delivers
/// anything itself. Delivery is decided on this side, out of the model's reach, which is what
/// makes "first contact asks a person" a rule the bot cannot route around rather than a courtesy
/// it is asked to observe.
///
/// A polled directory rather than a socket or a shared database: it needs no dependencies,
/// survives either side restarting, and works the same on a rented Linux machine as it does here.
/// The same shape as the approval gate's pending/decisions folders, for the same reasons.
@MainActor
final class OutboxWatcher {
    /// Where `bupsy-mcp` drops messages. Passed to it by value in the MCP config.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        // Beside the database, under the app's own bundle id, rather than a second folder
        // called "bupsy" that nothing else uses.
        return base
            .appendingPathComponent("si.bupsy", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }

    /// What a bot can ask for. Both are requests: bupsy decides, and asks a person where it must.
    enum Request {
        case message(from: String, toName: String, text: String)
        case createBot(from: String, name: String, job: String)
    }

    /// The roster `list_bots` reads, beside the outbox rather than in it — the outbox is drained
    /// and emptied every second.
    static var rosterFile: URL {
        directory.deletingLastPathComponent().appendingPathComponent("roster.json")
    }

    private var timer: Timer?
    private let onRequest: (Request) -> Void

    init(onRequest: @escaping (Request) -> Void) {
        self.onRequest = onRequest
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)

        // One second is well under the time anyone notices, and this reads an almost always empty
        // directory. A file-system event source would be tidier and is worth doing if this ever
        // sits on a network volume, where polling is the wrong shape.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []

        // Oldest first, so a burst from one bot arrives in the order it was sent.
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            defer { try? FileManager.default.removeItem(at: file) }

            // Deleted rather than retried when unreadable. A file we cannot read will not become
            // readable, and leaving it here would mean parsing it again every second forever.
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let from = payload["from"] as? String
            else { continue }

            if payload["kind"] as? String == "create_bot" {
                guard let name = payload["name"] as? String, !name.isEmpty,
                      let job = payload["job"] as? String, !job.isEmpty else { continue }
                onRequest(.createBot(from: from, name: name, job: job))
            } else {
                guard let to = payload["to"] as? String,
                      let text = payload["text"] as? String, !text.isEmpty else { continue }
                onRequest(.message(from: from, toName: to, text: text))
            }
        }
    }
}
