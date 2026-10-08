import Foundation
import Network

/// One HTTP request, as `LocalHTTPServer` read it.
public struct HTTPRequest: Sendable {
    public let method: String
    /// The path without its query, percent-decoding left to the router.
    public let path: String
    public let query: [String: String]
    /// Header names lowercased, so lookups need not care how the client spelled them.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query
        self.headers = headers; self.body = body
    }

    /// A cookie's value, from the Cookie header.
    public func cookie(_ name: String) -> String? {
        guard let header = headers["cookie"] else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0] == name { return pair[1] }
        }
        return nil
    }

    /// The body as a JSON object, or nil when it is not one.
    public var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// One HTTP response. Always closes the connection: the clients are a page polling every second
/// or two, and a server that never keeps a connection open has no idle connections to manage.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    public static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: status < 400 ? "OK" : (status < 500 ? "Bad Request" : "Internal Server Error")
        }
    }

    /// The bytes on the wire. Every response says not to cache it and not to be framed or sniffed:
    /// what it carries is someone's conversations and the controls for their bots.
    public func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = all["Cache-Control"] ?? "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        all["X-Frame-Options"] = "DENY"
        all["Referrer-Policy"] = "no-referrer"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

/// Reads HTTP/1.1 requests out of a byte buffer.
public enum HTTPParser {
    public enum Failure: Error, Equatable { case malformed, tooLarge }

    /// Limits that keep a misbehaving client from making the app hold a large buffer.
    public static let maxHeaderBytes = 32 * 1024
    public static let maxBodyBytes = 1024 * 1024

    /// A complete request at the start of `buffer`, or nil when more bytes are needed.
    public static func parse(_ buffer: Data) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes { throw Failure.tooLarge }
            return nil
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
        else { throw Failure.malformed }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Failure.malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Chunked uploads are not something this server's own page ever sends.
        if headers["transfer-encoding"] != nil { throw Failure.malformed }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw Failure.malformed }
        guard length <= maxBodyBytes else { throw Failure.tooLarge }

        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                if let key = kv.first { query[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return HTTPRequest(method: String(requestLine[0]), path: String(parts.first ?? "/"),
                           query: query, headers: headers, body: Data(body))
    }
}

/// A small HTTP server that only this Mac can reach.
///
/// Bound to the loopback interface: nothing on the Wi-Fi, or anywhere else, can connect to it.
/// It is meant to sit behind Tailscale Serve, which carries the person's own devices to it over
/// their private network with HTTPS; on its own it is unreachable from any other machine. Every
/// request still has to prove itself to the handler, since other programs on this Mac (the
/// person's bots among them) can reach loopback too.
public final class LocalHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "bupsy.remote-http")
    private var listener: NWListener?
    /// The port actually listened on, once started.
    public private(set) var port: UInt16?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on `preferredPort` if it is free, else on any free port. Returns the port.
    @discardableResult
    public func start(preferredPort: UInt16) async throws -> UInt16 {
        do {
            return try await listen(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        } catch {
            return try await listen(on: .any)
        }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                    listener.cancel()
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.port = ready
        return ready
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
        // A client that opens a connection and never finishes a request is let go.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try HTTPParser.parse(buffer) {
                    Task {
                        let response = await self.handler(request)
                        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            } catch let failure as HTTPParser.Failure {
                let status = failure == .tooLarge ? 413 : 400
                connection.send(content: HTTPResponse.error("Bad request", status: status).serialized(),
                                completion: .contentProcessed { _ in connection.cancel() })
            } catch {
                connection.cancel()
            }
        }
    }
}

/// Runs a block at most once, from whichever callback gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
