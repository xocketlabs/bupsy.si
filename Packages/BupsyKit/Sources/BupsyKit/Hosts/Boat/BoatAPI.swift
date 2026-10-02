import Foundation

/// Thin client over boat.dev's v1 REST API.
///
/// **The key is the user's own.** bupsy never ships, pools, or holds a compute key of its own;
/// the user pastes theirs and it lives in their Keychain. That is the same principle as model
/// credentials, for the same reason — see docs/00-compliance-and-auth.md.
///
/// Written against boat's published API documentation and **not yet run against the live
/// service**. Every response shape below is read from docs rather than observed, so decoding is
/// deliberately forgiving: unknown fields are ignored and absent optionals degrade rather than
/// throw. Expect a round of corrections the first time it meets the real server.
public struct BoatAPI: Sendable {
    public static let defaultBaseURL = URL(string: "https://boat.dev/api/v1")!

    let baseURL: URL
    let apiKey: String
    let session: URLSession

    public init(apiKey: String, baseURL: URL = BoatAPI.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Lifecycle

    public func create(_ options: CreateOptions) async throws -> Sandbox {
        try await send("sandboxes", method: "POST", body: options).sandbox()
    }

    public func get(_ id: String) async throws -> Sandbox {
        try await send("sandboxes/\(id)", method: "GET").sandbox()
    }

    public func stop(_ id: String, force: Bool = false) async throws -> Sandbox {
        var body = JSONObject(); body.set("force", force)
        return try await send("sandboxes/\(id)/stop", method: "POST", body: body).sandbox()
    }

    public func resume(_ id: String, size: MachineSize? = nil, ttlSeconds: Int?? = nil)
        async throws -> Sandbox
    {
        var body = JSONObject()
        if let size { body.set("type", size.rawValue) }
        // Double optional: `.some(nil)` means "send an explicit null", which disables auto-stop.
        if let ttl = ttlSeconds {
            if let ttl { body.set("ttlSeconds", ttl) } else { body.setNull("ttlSeconds") }
        }
        return try await send("sandboxes/\(id)/resume", method: "POST", body: body).sandbox()
    }

    public func fork(_ id: String, size: MachineSize? = nil, noEnv: Bool = true)
        async throws -> Sandbox
    {
        var body = JSONObject(); body.set("noEnv", noEnv)
        if let size { body.set("type", size.rawValue) }
        return try await send("sandboxes/\(id)/fork", method: "POST", body: body).sandbox()
    }

    // MARK: - Work

    public func command(_ id: String, _ request: CommandRequest) async throws -> CommandResult {
        try await send("sandboxes/\(id)/commands", method: "POST", body: request)
            .decode(CommandResult.self)
    }

    public func readFile(_ id: String, path: String) async throws -> String {
        let query = [URLQueryItem(name: "path", value: path),
                     URLQueryItem(name: "encoding", value: "utf8")]
        return try await send("sandboxes/\(id)/files", method: "GET", query: query)
            .decode(FilePayload.self).content
    }

    public func writeFile(_ id: String, path: String, content: String) async throws {
        _ = try await send("sandboxes/\(id)/files", method: "PUT",
                           body: FilePayload(path: path, content: content, encoding: "utf8"))
    }

    public func desktopURL(_ id: String) async throws -> DesktopSession {
        var body = JSONObject(); body.set("publicAccess", false)
        return try await send("sandboxes/\(id)/desktop", method: "POST",
                              query: [URLQueryItem(name: "vnc", value: "1")],
                              body: body).decode(DesktopSession.self)
    }

    public func usage(_ id: String) async throws -> MachineUsage {
        try await send("sandboxes/\(id)/usage", method: "GET").decode(MachineUsage.self)
    }

    // MARK: - Transport

    private func send(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) async throws -> Envelope {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = Envelope(data: data)

        guard (200..<300).contains(status), envelope.ok else {
            throw BoatError(
                status: status,
                code: envelope.string("code"),
                // Never include the request body or headers here: the Authorization header
                // carries the user's key and errors end up in logs.
                message: envelope.string("message") ?? "boat request failed (\(status))"
            )
        }
        return envelope
    }
}

// MARK: - Types

public enum MachineSize: String, Sendable, Codable, CaseIterable {
    case small, `default`, large

    /// Billing multiplier against boat's 1x (4 vCPU / 8 GB) rate. Used to show cost before a
    /// user commits to an always-on machine. PLAN.md §4.
    public var rateMultiplier: Double {
        switch self {
        case .small: 0.5
        case .default: 1.0
        case .large: 2.0
        }
    }

    /// Rough monthly cost of leaving one of these running, given boat's $20 / 2,000,000
    /// VM-second minimum. Arithmetic, not measured — spike 2c.
    public var alwaysOnMonthlyUSD: Double {
        (30.0 * 86_400.0 * rateMultiplier) / 2_000_000.0 * 20.0
    }
}

public struct CreateOptions: Encodable, Sendable {
    /// `nil` disables auto-stop, which an always-on machine needs. The default is one hour and
    /// it counts from **creation, not last activity** — a machine meant to stay up will
    /// otherwise vanish mid-afternoon.
    public var ttlSeconds: Int?
    public var type: MachineSize
    /// Withholds the account's own secrets from the sandbox. boat's multi-tenant guidance is to
    /// always set this for machines a user controls, so default it to true and make turning it
    /// off deliberate.
    public var noEnv: Bool
    public var from: String?
    public var env: [String: String]?

    public init(size: MachineSize = .small, ttlSeconds: Int? = 3600,
                noEnv: Bool = true, from: String? = nil, env: [String: String]? = nil) {
        self.type = size
        self.ttlSeconds = ttlSeconds
        self.noEnv = noEnv
        self.from = from
        self.env = env
    }

    /// A machine that stays up for scheduled work. Small by default because it is the only size
    /// whose always-on cost fits inside boat's $20 minimum.
    public static func alwaysOn(size: MachineSize = .small) -> CreateOptions {
        CreateOptions(size: size, ttlSeconds: nil)
    }

    enum CodingKeys: String, CodingKey {
        case ttlSeconds, type, noEnv, from, env
    }

    /// Hand-written because the synthesized encoder would silently break always-on machines.
    ///
    /// Swift synthesises `encodeIfPresent` for optional properties, which **omits** a nil key
    /// rather than sending `null`. Here nil does not mean "unset" — it means "disable auto-stop",
    /// and omitting it makes boat apply its one-hour default instead. The machine would then
    /// disappear mid-afternoon and every routine on it would stop without an error anywhere.
    /// Caught by `alwaysOnDisablesAutoStop`, which is why that test exists.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(noEnv, forKey: .noEnv)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)   // encode, not encodeIfPresent
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(env, forKey: .env)
    }
}

public struct Sandbox: Decodable, Sendable {
    public let id: String
    public let state: String?
    public let createdAt: String?

    public var isRunning: Bool { state == "running" }
    public var isStopped: Bool { state == "archived" || state == "archiving" || state == "stopped" }
}

public struct CommandRequest: Encodable, Sendable {
    public var command: String
    public var cwd: String?
    public var timeoutSeconds: Int?

    public init(command: String, cwd: String? = "/home/user", timeoutSeconds: Int? = 600) {
        self.command = command
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CommandResult: Decodable, Sendable {
    public let exitCode: Int32?
    public let stdout: String?
    public let stderr: String?
    public let timedOut: Bool?
    public let stdoutTruncated: Bool?
    public let stderrTruncated: Bool?

    public var success: Bool { (exitCode ?? 1) == 0 }
}

struct FilePayload: Codable, Sendable {
    var path: String?
    var content: String
    var encoding: String?
}

public struct DesktopSession: Decodable, Sendable {
    public let desktopUrl: String?
    /// boat's docs: if true, poll again. Also: treat the URL as a secret.
    public let provisioning: Bool?
}

/// Compute consumed by a machine. Named to avoid colliding with `Usage`, which means *token*
/// usage — a distinction worth keeping sharp, since one is billed to the user by boat and the
/// other is their model subscription.
public struct MachineUsage: Decodable, Sendable {
    public let vmSeconds: Double?
    public let costCents: Double?
}

public struct BoatError: Error, Sendable, LocalizedError {
    public let status: Int
    public let code: String?
    public let message: String

    public var errorDescription: String? { message }

    /// A key problem is worth a specific message: it is the most likely first failure, and the
    /// user fixes it somewhere other than in bupsy.
    public var isAuthFailure: Bool { status == 401 || status == 403 }
}

// MARK: - Forgiving decoding

/// Boat wraps every response in `{ ok, type, ... }`. This reads that envelope without demanding
/// a generated model for each `type` discriminator.
struct Envelope {
    private let object: [String: Any]
    private let data: Data

    init(data: Data) {
        self.data = data
        self.object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var ok: Bool { object["ok"] as? Bool ?? true }

    func string(_ key: String) -> String? { object[key] as? String }

    func sandbox() throws -> Sandbox {
        // Sometimes nested under `sandbox`, sometimes the envelope itself carries the fields.
        let source = (object["sandbox"] as? [String: Any]) ?? object
        guard let id = source["id"] as? String else {
            throw BoatError(status: 0, code: "malformed",
                            message: "boat response contained no sandbox id")
        }
        return Sandbox(
            id: id,
            state: source["state"] as? String,
            createdAt: source["createdAt"] as? String
        )
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // Prefer a nested payload keyed by the type's own name where boat nests it, else decode
        // the envelope directly. Unknown keys are ignored either way.
        for key in ["result", "file", "desktop", "usage", "command"] {
            if let nested = object[key],
               let nestedData = try? JSONSerialization.data(withJSONObject: nested),
               let decoded = try? JSONDecoder().decode(T.self, from: nestedData) {
                return decoded
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Lets heterogeneous JSON bodies be assembled without a bespoke type per request.
///
/// The closure is not `@Sendable` because `any Encodable` is not: a value is wrapped and encoded
/// on one task, never shared. `@unchecked Sendable` keeps that unsafety confined to this type
/// rather than forcing every caller to reason about it.
struct AnyEncodable: Encodable, @unchecked Sendable {
    private let encodeTo: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        encodeTo = { encoder in try wrapped.encode(to: encoder) }
    }

    init<T: Encodable>(_ wrapped: T?) {
        encodeTo = { encoder in
            var container = encoder.singleValueContainer()
            if let wrapped { try container.encode(wrapped) } else { try container.encodeNil() }
        }
    }

    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}

/// A JSON object assembled at the call site.
///
/// Deliberately a named type rather than a retroactive `Encodable` conformance on `Dictionary`:
/// conforming a standard-library type you do not own is a trap in a library, because another
/// module doing the same thing makes both ambiguous.
struct JSONObject: Encodable {
    private var fields: [String: AnyEncodable] = [:]

    init(_ fields: [String: AnyEncodable] = [:]) { self.fields = fields }

    subscript(key: String) -> AnyEncodable? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    mutating func set(_ key: String, _ value: some Encodable) {
        fields[key] = AnyEncodable(value)
    }

    /// Sends an explicit JSON null, which is how boat is told to disable auto-stop.
    mutating func setNull(_ key: String) {
        fields[key] = AnyEncodable(Optional<Int>.none)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in fields {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
