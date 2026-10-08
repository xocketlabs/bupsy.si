import Foundation

/// Talks to Bupsy on the person's Mac, over their tailnet.
///
/// Every call is one short HTTPS request, the same ones the web app makes, and the Mac runs each
/// through the same code its own buttons use, so an approval answered here is gated, recorded and
/// expired exactly like one answered at the desk.
///
/// The client sends the pairing key as a cookie it writes itself. Its session has no cookie store
/// at all: the key lives in the Keychain and nowhere else on the phone.
struct RemoteClient: Sendable {
    let pairing: Pairing
    var session: URLSession = .remote

    func mac() async throws -> MacInfo {
        try await get(["session"])
    }

    func bots() async throws -> BotList {
        try await get(["bots"])
    }

    func thread(_ botID: String) async throws -> BotThread {
        try await get(["bots", botID, "messages"])
    }

    func send(_ text: String, to botID: String) async throws {
        try await post(["bots", botID, "messages"], ["text": text])
    }

    func decide(_ approvalID: String, allow: Bool, for botID: String) async throws {
        try await post(["bots", botID, "approvals", approvalID], ["allow": allow])
    }

    func answer(_ questionID: String, with answer: String, for botID: String) async throws {
        try await post(["bots", botID, "questions", questionID], ["answer": answer])
    }

    func stop(_ botID: String) async throws {
        try await post(["bots", botID, "stop"], [:])
    }

    /// Trades a pairing code for this device's key.
    ///
    /// - Parameter name: what the Mac's list of paired devices will call this phone.
    static func pair(_ link: PairingLink, name: String, session: URLSession = .remote) async throws -> Pairing {
        let url = Self.url(link.address, ["pair"])
        let body: [String: Any] = ["code": link.code ?? "", "name": name]
        let (_, response) = try await Self.send(Self.request("POST", url, body: body, cookie: nil), session)
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie"),
              let key = DeviceCookie.key(fromSetCookie: header)
        else { throw RemoteError.unreadable }
        return Pairing(address: link.address, key: key)
    }

    // MARK: - Plumbing

    private func get<Value: Decodable>(_ path: [String]) async throws -> Value {
        let request = Self.request("GET", Self.url(pairing.address, path), body: nil, cookie: pairing.cookieHeader)
        let (data, _) = try await Self.send(request, session)
        do {
            return try Self.decoder().decode(Value.self, from: data)
        } catch {
            throw RemoteError.unreadable
        }
    }

    private func post(_ path: [String], _ body: [String: Any]) async throws {
        let request = Self.request("POST", Self.url(pairing.address, path), body: body, cookie: pairing.cookieHeader)
        _ = try await Self.send(request, session)
    }

    /// `/api/` and then each part percent-encoded on its own, so an id can never add a path segment.
    static func url(_ address: URL, _ path: [String]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return URL(string: address.absoluteString + "/api/" + encoded.joined(separator: "/")) ?? address
    }

    private static func request(_ method: String, _ url: URL, body: [String: Any]?, cookie: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func send(_ request: URLRequest, _ session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A poll cancelled because the screen went away is not the Mac being unreachable.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteError.unreadable }
        if let error = RemoteError(status: http.statusCode, body: data) { throw error }
        return (data, http)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension URLSession {
    /// No cookie store, no cache: the key is sent by hand, and every answer must be fresh.
    static let remote: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Short, because a poll that hangs is worse than one that fails and tries again.
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()
}

/// Everything that can go wrong talking to the Mac, in the terms the person needs.
enum RemoteError: LocalizedError, Equatable {
    /// 401. For ordinary requests: this phone was never paired, or was removed on the Mac. For
    /// pairing: the code was wrong or has expired. The Mac's own words say which.
    case unpaired(String)
    /// The Mac understood and said no, with its reason: too many tries (429), already answered
    /// (409), a bot that's gone (404).
    case refused(status: Int, message: String)
    /// Nothing answered: the Mac is asleep, Bupsy is closed, or Tailscale is off on one end.
    case unreachable
    /// Something answered, but not in a shape this app understands.
    case unreadable

    /// Nil for a success. Otherwise the error, using the `{ "error": "…" }` message the Mac sends.
    init?(status: Int, body: Data) {
        guard !(200..<300).contains(status) else { return nil }
        let message = (try? JSONDecoder().decode(ServerMessage.self, from: body))?.error
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let said = message.flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case 401:
            self = .unpaired(said ?? "This iPhone isn't paired with Bupsy.")
        case 500...:
            // Tailscale answers 502 for a Mac whose Bupsy isn't running; only the app itself
            // explains a failure in words.
            self = said.map { .refused(status: status, message: $0) } ?? .unreachable
        default:
            self = .refused(status: status, message: said ?? "Something went wrong (\(status)).")
        }
    }

    var errorDescription: String? {
        switch self {
        case .unpaired(let message), .refused(_, let message):
            message
        case .unreachable:
            "Couldn't reach your Mac. Check it's awake with Bupsy open, and that Tailscale is on here and there."
        case .unreadable:
            "Your Mac answered in a way this app doesn't understand. Update Bupsy on both."
        }
    }

    /// The approval or question was answered already, on the Mac or another device.
    var isAlreadyAnswered: Bool {
        if case .refused(409, _) = self { return true }
        return false
    }

    var isGone: Bool {
        if case .refused(404, _) = self { return true }
        return false
    }

    private struct ServerMessage: Decodable {
        let error: String
    }
}
