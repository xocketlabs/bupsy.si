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

    /// Authenticated, but the account cannot actually run a model.
    ///
    /// Found the hard way in M0: `codex login status` reports "Logged in using ChatGPT" while
    /// every model returns HTTP 400 "not supported when using Codex with a ChatGPT account".
    /// A status command alone is therefore a **false positive** — the only honest check is to
    /// try a real turn. Surfacing this distinctly lets onboarding say "signed in, but your plan
    /// can't run Codex" instead of letting a bot fail at 3am.
    case signedInWithoutModelAccess(detail: String)

    case signedOut
    case unknown(String)

    public enum Method: String, Sendable, Codable {
        case subscription
        case apiKey
    }

    /// True only when a run would actually be expected to work.
    public var isUsable: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// How an engine enforces a permission decision.
///
/// This exists because the two engines are categorically different, and the UI must not promise
/// behaviour an engine cannot deliver.
public enum GateMechanism: Sendable, Equatable {
    /// Can pause mid-run and wait for a human. Claude Code's `PreToolUse` hooks do this.
    case blockingHook
    /// Policy is fixed before the run and enforced by the OS sandbox; no mid-run human decision.
    /// Codex `exec --sandbox` works this way — strong enforcement, zero interactivity.
    case sandboxPolicy
    /// No enforcement available. Such an engine must never be offered above `.ask`.
    case none

    /// Whether `.ask` can mean "pause and ask me" rather than "pre-authorise narrowly".
    public var canAskMidRun: Bool { self == .blockingHook }
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

    /// The highest autonomy this engine can honestly enforce.
    var maximumEnforceableAutonomy: Autonomy { get }

    /// How this engine enforces, which decides what the UI is allowed to promise. An engine
    /// with `.sandboxPolicy` cannot stop to ask, so `.ask` means "run narrowly" rather than
    /// "wait for me" — and the approval UI must say which it is.
    var gateMechanism: GateMechanism { get }

    /// Translates one line of engine output into canonical events. Stateful adapters may
    /// buffer internally; this is called in order and must never drop input.
    func normalise(_ output: HostOutput) -> [AgentEvent]
}
