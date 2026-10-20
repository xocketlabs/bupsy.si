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
    /// Settings file installing the approval hook, from `GateInstaller`. When absent the engine
    /// runs ungated, which is only correct for a probe.
    public var gateSettingsPath: String?
    /// Use only the MCP servers in `mcpConfigPaths`, ignoring every other server the engine
    /// would load — above all the apps connected to the person's own engine account.
    public var onlyGivenApps: Bool
    /// Let the engine drive the person's own browser through its extension: Claude in Chrome for
    /// Claude, Codex's browser use for Codex. Only meaningful on this Mac, where that browser is.
    public var useBrowser: Bool
    /// Continue `resume` as a new conversation of its own, leaving the original as it was: how a
    /// conversation carried over from Claude Code is copied rather than moved.
    public var forkSession: Bool

    public init(prompt: String, workingDirectory: URL? = nil, resume: ConversationID? = nil,
                model: String? = nil, autonomy: Autonomy = .ask, mcpConfigPaths: [String] = [],
                gateSettingsPath: String? = nil, onlyGivenApps: Bool = false,
                useBrowser: Bool = false, forkSession: Bool = false) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.resume = resume
        self.model = model
        self.autonomy = autonomy
        self.mcpConfigPaths = mcpConfigPaths
        self.gateSettingsPath = gateSettingsPath
        self.onlyGivenApps = onlyGivenApps
        self.useBrowser = useBrowser
        self.forkSession = forkSession
    }
}

/// Whether a bot holds the Mac awake while it works.
///
/// Per bot rather than global: a research bot grinding for ten minutes is exactly the case worth
/// protecting from idle sleep, while a quick chat bot has no business touching power management.
public enum KeepAwake: String, Sendable, Codable, CaseIterable {
    /// Never hold the Mac awake. Runs may be cut short by idle sleep.
    case never
    /// Hold it only while this bot is actually working, released the moment it finishes.
    case whileWorking

    public var label: String {
        switch self {
        case .never: "Let the Mac sleep"
        case .whileWorking: "Stay awake while working"
        }
    }

    public var detail: String {
        switch self {
        case .never:
            "A long run may be cut short if your Mac goes to sleep."
        case .whileWorking:
            "Stops idle sleep from interrupting a run. Closing the lid still sleeps."
        }
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

/// A model a bot can be pointed at.
public struct ModelOption: Sendable, Hashable, Identifiable {
    /// Passed verbatim to the engine's model flag. `nil` means "whatever the CLI already
    /// defaults to", which is the right default: the user may have configured one themselves and
    /// we should not quietly override it.
    public let id: String?
    public let label: String
    public let detail: String?
    /// Where the picker lists it.
    public let section: Section

    /// A family alias that follows the newest model, or one exact version that never changes.
    /// Both matter: the alias is the right default, a pinned version is what someone picks when
    /// a routine must behave tomorrow the way it did today.
    public enum Section: Sendable, Hashable { case standard, latest, version }

    public init(id: String?, label: String, detail: String? = nil, section: Section = .standard) {
        self.id = id; self.label = label; self.detail = detail; self.section = section
    }
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
    /// The CLI itself is not on this Mac: not in the usual install folders and not on the login
    /// shell's PATH. Told apart from `.signedOut` because the fix is installing it, not signing in.
    case notInstalled
    /// Installed, but something outside Bupsy has to happen before it can run, and the message
    /// says what in plain words: for a local model, starting Ollama or LM Studio, or pulling a
    /// model. Told apart from `.signedOut` because there is no account to sign in to.
    case notReady(String)
    case unknown(String)

    public enum Method: String, Sendable, Codable {
        case subscription
        case apiKey
        /// No account at all: the model runs on this Mac, in the person's own runtime.
        case onThisMac
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

    /// Models this engine can be pointed at, for a per-bot picker.
    var models: [ModelOption] { get }

    /// How this engine enforces, which decides what the UI is allowed to promise. An engine
    /// with `.sandboxPolicy` cannot stop to ask, so `.ask` means "run narrowly" rather than
    /// "wait for me" — and the approval UI must say which it is.
    var gateMechanism: GateMechanism { get }

    /// Translates one line of engine output into canonical events. Stateful adapters may
    /// buffer internally; this is called in order and must never drop input.
    func normalise(_ output: HostOutput) -> [AgentEvent]

    /// Called just before a run starts, off the main thread. Returns the request to run, possibly
    /// with its model made exact, or throws `RunRefused` to stop the run before anything is
    /// spawned. Most engines take the request as it is; a local model checks that the model it
    /// names is really installed, because Codex would otherwise download one on its own.
    func prepare(_ request: RunRequest) async throws -> RunRequest
}

extension EngineAdapter {
    public func prepare(_ request: RunRequest) async throws -> RunRequest { request }
}

/// A run stopped before it began, with the failure to show for it.
public struct RunRefused: Error, Sendable, Equatable, LocalizedError {
    public let failure: EngineFailure
    public init(_ failure: EngineFailure) { self.failure = failure }
    public var errorDescription: String? { failure.message }
}
