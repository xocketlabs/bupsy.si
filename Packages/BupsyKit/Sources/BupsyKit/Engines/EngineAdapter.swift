import Foundation

public struct RunRequest: Sendable {
    public var prompt: String
    public var workingDirectory: URL?
    /// Resume an existing thread instead of starting one.
    public var resume: ConversationID?
    public var model: String?
    /// The highest autonomy this bot is trusted with. See PLAN.md §6.
    public var autonomy: Autonomy
    /// Paths to MCP server config, passed through to engines that speak MCP.
    public var mcpConfigPaths: [String]

    public init(prompt: String, workingDirectory: URL? = nil, resume: ConversationID? = nil,
                model: String? = nil, autonomy: Autonomy = .ask, mcpConfigPaths: [String] = []) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.resume = resume
        self.model = model
        self.autonomy = autonomy
        self.mcpConfigPaths = mcpConfigPaths
    }
}

/// The trust ladder. `ask` is the default for every new bot, and `auto` requires a typed
/// confirmation — an agent holding real logins is dangerous in proportion to its usefulness.
public enum Autonomy: String, Sendable, Codable, CaseIterable, Comparable {
    case ask
    case allowlist
    case trusted
    case auto

    private var rank: Int {
        switch self {
        case .ask: 0; case .allowlist: 1; case .trusted: 2; case .auto: 3
        }
    }
    public static func < (a: Autonomy, b: Autonomy) -> Bool { a.rank < b.rank }
}

public struct LoginCommand: Sendable, Equatable {
    /// Run in a PTY we render but never parse. The user completes the vendor's own flow;
    /// the credential lands in their own files and we learn only that it worked.
    public var command: String
    public var hint: String
    public init(command: String, hint: String) { self.command = command; self.hint = hint }
}

public enum AuthStatus: Sendable, Equatable {
    case signedIn(method: Method)
    case signedOut
    case unknown(String)

    public enum Method: String, Sendable, Codable {
        case subscription
        case apiKey
    }
}

/// One adapter per engine harness.
///
/// Adapters build invocations and translate output. They never touch credentials, and never
/// embed a vendor SDK under subscription auth — we shell out to the published binary.
public protocol EngineAdapter: Sendable {
    var id: EngineID { get }
    /// The binary name we resolve on PATH. Overridable by the user in Settings → Engines;
    /// we must never hide or restrict an engine's own auth methods.
    var binaryName: String { get }

    /// Returns a verdict, never a credential. Implementations use the engine's own status
    /// command and keep only its answer.
    func authStatus(on host: any ExecutionHost) async -> AuthStatus

    func loginCommand() -> LoginCommand

    func invocation(for request: RunRequest) -> EngineInvocation

    /// The highest autonomy this engine can honestly enforce. An engine with no blocking
    /// gate must not be offered above `.ask`, and the UI shows why.
    var maximumEnforceableAutonomy: Autonomy { get }

    /// Translates one line of engine output into canonical events. Stateful adapters may
    /// buffer internally; this is called in order and must never drop input.
    func normalise(_ output: HostOutput) -> [AgentEvent]
}
