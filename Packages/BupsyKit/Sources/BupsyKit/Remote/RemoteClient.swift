import Foundation

/// A bot on another of the person's Macs, as that Mac describes it.
public struct RemoteBotSummary: Decodable, Equatable, Sendable, Identifiable {
    public struct Face: Decodable, Equatable, Sendable {
        public let shape: String
        public let colour: Int
        public let hue: Double
    }

    public let id: String
    public let name: String
    public let role: String?
    public let section: String?
    public let mood: String
    public let running: Bool
    public let needsYou: Bool
    public let unread: Bool
    public let preview: String?
    /// Missing from a Mac on an older Bupsy, which is drawn with a face from the name instead.
    public let face: Face?
}

/// One item in a remote bot's chat, as the remote Mac sends it.
public struct RemoteEntry: Decodable, Equatable, Sendable, Identifiable {
    public struct Tool: Decodable, Equatable, Sendable {
        public let verb: String
        public let target: String
        public let failed: Bool
    }

    public struct Approval: Decodable, Equatable, Sendable {
        public let id: String
        public let tool: String
        public let summary: String
        public let reason: String
        public let decided: String?
    }

    public struct Question: Decodable, Equatable, Sendable {
        public let id: String
        public let question: String
        public let options: [String]
        public let answer: String?
    }

    public let id: String
    public let kind: String
    public let at: Date
    public let text: String?
    public let author: String?
    public let tool: Tool?
    public let approval: Approval?
    public let question: Question?
}

/// What a remote Mac says about itself.
public struct RemoteSession: Decodable, Equatable, Sendable {
    public let mac: String
    /// "laptop" or "desktop"; missing from an older Bupsy.
    public let kind: String?
}

/// Talks to another of the person's Macs running Bupsy, over their Tailscale network.
///
/// The same API the phone and the browser use (`RemoteAccess` on the other Mac): a device key in
/// the `bupsy_device` cookie on every request, set by hand rather than through a cookie store, so
/// the key lives in exactly one place, the Keychain, and nowhere a bot could read it.
public struct RemoteClient: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The Mac answered, but this device is not paired with it (or was removed).
        case notPaired(String)
        /// The Mac could not be reached: asleep, off, or off the tailnet.
        case unreachable
        /// The Mac answered with an error to show as it is.
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .notPaired(let message), .refused(let message): message
            case .unreachable: "Couldn't reach that Mac. Is it awake and on Tailscale?"
            }
        }
    }

    public let address: URL
    public let key: String?
    private let session: URLSession

    public init(address: URL, key: String?, session: URLSession = .shared) {
        self.address = address
        self.key = key
        self.session = session
    }

    /// The address a person typed or picked, made whole: a bare Tailscale name gets HTTPS and
    /// Bupsy's port, and a pairing link loses its code.
    public static func normalisedAddress(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        if components.port == nil, components.scheme == "https" { components.port = Tailscale.httpsPort }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Pairs this Mac and returns the key the other Mac set, to keep in the Keychain.
    public func pair(code: String, name: String) async throws -> String {
        let (data, response) = try await send("POST", "/api/pair", body: ["code": code, "name": name], authenticated: false)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
        guard let cookie = http.value(forHTTPHeaderField: "Set-Cookie"), let key = Self.deviceKey(fromSetCookie: cookie) else {
            throw Failure.refused("That Mac paired, but didn't hand back a key.")
        }
        return key
    }

    public func sessionInfo() async throws -> RemoteSession {
        try await get("/api/session")
    }

    public func bots() async throws -> [RemoteBotSummary] {
        struct List: Decodable { let bots: [RemoteBotSummary] }
        return try await (get("/api/bots") as List).bots
    }

    public func entries(bot: String) async throws -> [RemoteEntry] {
        struct Chat: Decodable { let entries: [RemoteEntry] }
        return try await (get("/api/bots/\(Self.escape(bot))/messages") as Chat).entries
    }

    public func send(_ text: String, to bot: String) async throws {
        try await post("/api/bots/\(Self.escape(bot))/messages", ["text": text])
    }

    public func decide(_ approval: String, allow: Bool, bot: String) async throws {
        try await post("/api/bots/\(Self.escape(bot))/approvals/\(Self.escape(approval))", ["allow": allow])
    }

    public func answer(_ question: String, with answer: String, bot: String) async throws {
        try await post("/api/bots/\(Self.escape(bot))/questions/\(Self.escape(question))", ["answer": answer])
    }

    public func stop(bot: String) async throws {
        try await post("/api/bots/\(Self.escape(bot))/stop", [:])
    }

    /// The largest file sent to another Mac's bot. Big enough for documents, screenshots and
    /// short clips; a whole video project belongs in a shared folder instead.
    public static let maxUpload = 50 * 1024 * 1024

    /// Copies a file to the bot's own Mac and returns where it landed there, which is the path
    /// to put in a message: a path on this Mac means nothing to a bot on another one.
    public func upload(_ file: URL, to bot: String) async throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxUpload else {
            throw Failure.refused("\(file.lastPathComponent) is over 50 MB. Share a folder for big files instead.")
        }
        let data = try Data(contentsOf: file)
        var request = URLRequest(url: address.appendingPathComponent("api/bots/\(Self.escape(bot))/files"),
                                 timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        if let key { request.setValue("bupsy_device=\(key)", forHTTPHeaderField: "Cookie") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file",
                         forHTTPHeaderField: "X-File-Name")
        request.httpBody = data
        let (body, response): (Data, URLResponse)
        do { (body, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, body) }
        guard let path = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["path"] as? String else {
            throw Failure.refused("That Mac took the file but didn't say where it put it.")
        }
        return path
    }

    // MARK: - Moving a bot there

    /// Tells the other Mac a bot is coming, with the size of the folder to follow, so a Mac
    /// without room, or with a Bupsy too old to take bots, says so before anything is sent.
    public func beginMove(_ move: String, bytes: Int64) async throws {
        let (data, response) = try await send("POST", "/api/moves/\(Self.escape(move))/begin",
                                              body: ["bytes": bytes], authenticated: true)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        // An older Bupsy has no such route and answers as it does for anything it does not know.
        if http.statusCode == 404 {
            throw Failure.refused("That Mac's Bupsy is too old to take a bot. Update Bupsy there, then try again.")
        }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
    }

    /// Sends the zipped folder in pieces (`BotMove.partBytes`), each saying where it starts, so
    /// the other Mac can tell a piece that went missing from one that arrived twice.
    public func sendMoveFiles(_ move: String, archive: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let size = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        for part in BotMove.parts(of: size) {
            try handle.seek(toOffset: UInt64(part.offset))
            let data = try handle.read(upToCount: part.length) ?? Data()
            var request = URLRequest(
                url: Self.url(address, "/api/moves/\(Self.escape(move))/files", query: ["offset": String(part.offset)]),
                timeoutInterval: 120)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            if let key { request.setValue("bupsy_device=\(key)", forHTTPHeaderField: "Cookie") }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let (body, response): (Data, URLResponse)
            do { (body, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            guard http.statusCode == 200 else { throw Self.failure(http.statusCode, body) }
            progress?(Double(part.offset + Int64(part.length)) / Double(max(size, 1)))
        }
    }

    /// Hands over the bot itself. Asked again once if the answer is lost on the way back: the
    /// other Mac remembers a move it finished and answers the same, rather than making a second
    /// copy, so a retry is safe.
    public func finishMove(_ move: String, manifest: BotMoveManifest) async throws -> BotMoveReceipt {
        let body = try BotMove.encoder.encode(manifest)
        var lastFailure: Error = Failure.unreachable
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            var request = URLRequest(url: address.appendingPathComponent("api/moves/\(Self.escape(move))"),
                                     timeoutInterval: 300)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            if let key { request.setValue("bupsy_device=\(key)", forHTTPHeaderField: "Cookie") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastFailure = Failure.unreachable
                continue
            }
            guard let http = response as? HTTPURLResponse else { lastFailure = Failure.unreachable; continue }
            guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
            do {
                return try JSONDecoder().decode(BotMoveReceipt.self, from: data)
            } catch {
                throw Failure.refused("That Mac took the bot but didn't say what it called it.")
            }
        }
        throw lastFailure
    }

    // MARK: - Plumbing

    static func url(_ address: URL, _ path: String, query: [String: String]) -> URL {
        let base = address.appendingPathComponent(String(path.dropFirst()))
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url ?? base
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await send("GET", path, body: nil, authenticated: true)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        let (data, response) = try await send("POST", path, body: body, authenticated: true)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, authenticated: Bool) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: address.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 8)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if authenticated, let key { request.setValue("bupsy_device=\(key)", forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
    }

    static func failure(_ status: Int, _ data: Data) -> Failure {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            ?? "That Mac answered with an error (\(status))."
        return status == 401 ? .notPaired(message) : .refused(message)
    }

    /// The key from a `Set-Cookie: bupsy_device=<key>; Path=/; …` header.
    static func deviceKey(fromSetCookie header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "bupsy_device", !pair[1].isEmpty { return pair[1] }
        }
        return nil
    }

    static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }
}
