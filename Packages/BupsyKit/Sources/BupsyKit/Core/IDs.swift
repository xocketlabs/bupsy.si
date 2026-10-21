import Foundation

/// Where a run executes. The distinction is load-bearing: only a cloud host keeps
/// working when the user's Mac is asleep, and the UI must be honest about that.
public enum HostID: Sendable, Hashable, Codable {
    case local
    case cloud(provider: CloudProvider)

    public var survivesSleep: Bool {
        switch self {
        case .local: false
        case .cloud: true
        }
    }
}

public enum CloudProvider: String, Sendable, Codable, CaseIterable {
    case boat
    case freestyle
}

public enum EngineID: String, Sendable, Codable, CaseIterable {
    case claude
    case codex
    case grok
    case opencode
    /// A model in the person's own Ollama or LM Studio, driven through Codex CLI's local mode
    /// (`codex exec --oss`). Not a vendor of its own: the harness is Codex, the model is theirs.
    case local

    /// Plain vendor names only. Never use these marks in product or feature names —
    /// see docs/00-compliance-and-auth.md §5.
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok CLI"
        case .opencode: "OpenCode"
        case .local: "Local model"
        }
    }

    /// Runs on the `codex` binary, so it shares Codex's session files (the context meter), its
    /// custom prompts and its slash commands.
    public var runsOnCodex: Bool { self == .codex || self == .local }

    /// Whether the engine has an account plan with usage limits to show. A local model has none:
    /// it runs on this Mac and costs nothing per turn.
    public var hasPlanLimits: Bool { self != .local }

    /// The engines bupsy can actually run today. The rest are named so stored data stays readable,
    /// but offering them anywhere — a picker, the onboarding check — showed choices that do nothing
    /// and an onboarding row stuck on "Checking…" forever.
    public static let supported: [EngineID] = [.claude, .codex, .local]
}

public struct BotID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
}

public struct RunID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }
}

/// A provider-native conversation handle, used to resume a thread.
public struct ConversationID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
}
