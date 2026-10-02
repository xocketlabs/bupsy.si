import Foundation

/// The canonical event every engine is normalised into.
///
/// Everything above this type — chat UI, transcript, audit log, approval queue — is written
/// once. Every engine and host plugs in beneath it. Adding a case here is a deliberate act:
/// it means every consumer must handle it.
public enum AgentEvent: Sendable, Equatable {
    /// Assistant prose intended for the user.
    case text(String)
    /// Visible reasoning, where the engine exposes it.
    case thinking(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// The engine wants to do something gated. See docs/00-compliance-and-auth.md and PLAN.md §6.
    case approvalRequired(ApprovalRequest)
    case usage(Usage)
    /// How much of the user's own subscription window they have burned. The engine volunteers
    /// this; we only display it. See `RateLimit`.
    case rateLimit(RateLimit)
    case done(Outcome)
    case failed(EngineFailure)
    /// A line we recognised as valid JSON but whose shape we do not model yet.
    ///
    /// Never drop input. An unknown event is a schema change we want visible in the audit log
    /// rather than silently swallowed.
    case unknown(raw: String)
}

public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// Rendered for display and audit. Never re-executed, and never a source of file paths
    /// we would hand to Process — see the security posture section of the compliance doc.
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct ToolResult: Sendable, Equatable, Codable {
    public var callID: String
    public var content: String
    public var isError: Bool
    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID; self.content = content; self.isError = isError
    }
}

public struct ApprovalRequest: Sendable, Equatable, Codable {
    public var id: String
    public var tool: String
    public var summary: String
    public var argumentsJSON: String
    public init(id: String, tool: String, summary: String, argumentsJSON: String) {
        self.id = id; self.tool = tool; self.summary = summary; self.argumentsJSON = argumentsJSON
    }
}

public enum ApprovalDecision: Sendable, Equatable, Codable {
    case allow
    case allowAlways
    case deny(reason: String?)
}

public struct Usage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Notional equivalent-API cost, when the engine reports it.
    ///
    /// **Never present this as "what you paid."** Spike 3 measured $0.36 of `total_cost_usd`
    /// for a two-token prompt, because cache creation dominates — and a subscription user paid
    /// none of it. Usage is the user's own, billed under their own agreement with the vendor;
    /// we never compute from this or bill against it. Label it plainly if shown at all.
    public var costUSD: Double?
    public var durationMS: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil,
                costUSD: Double? = nil, durationMS: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.costUSD = costUSD; self.durationMS = durationMS
    }
}

/// A live view of the user's subscription headroom, as reported by the engine itself.
///
/// Discovered in M0 spike 3: `claude` emits an undocumented `rate_limit_event` carrying
/// per-window utilisation. This matters more than it looks. Advertised Pro and Max limits
/// "assume ordinary, individual usage", and an objective that checks hourly forever is not
/// obviously ordinary — so the honest thing is to show users what their own agents are
/// spending of their own quota, before a routine silently eats a week of it.
///
/// Undocumented means unstable: every field is optional and a missing one degrades the gauge
/// rather than breaking the run.
public struct RateLimit: Sendable, Equatable, Codable {
    public struct Window: Sendable, Equatable, Codable {
        /// Fraction of the window consumed, 0...1.
        public var utilization: Double
        public var resetsAt: Date?
        public init(utilization: Double, resetsAt: Date? = nil) {
            self.utilization = utilization; self.resetsAt = resetsAt
        }
    }

    /// Engine-reported, e.g. "allowed". Not interpreted — shown, and logged.
    public var status: String?
    /// Keyed by the engine's own window names, e.g. "five_hour", "seven_day".
    public var windows: [String: Window]
    public var isUsingOverage: Bool

    public init(status: String? = nil, windows: [String: Window] = [:],
                isUsingOverage: Bool = false) {
        self.status = status; self.windows = windows; self.isUsingOverage = isUsingOverage
    }

    /// The window closest to exhaustion — what a warning should be driven from.
    public var tightest: (name: String, window: Window)? {
        windows.max { $0.value.utilization < $1.value.utilization }
            .map { (name: $0.key, window: $0.value) }
    }
}

public struct Outcome: Sendable, Equatable, Codable {
    public var summary: String?
    public var conversationID: ConversationID?
    public var usage: Usage?
    public init(summary: String? = nil, conversationID: ConversationID? = nil, usage: Usage? = nil) {
        self.summary = summary; self.conversationID = conversationID; self.usage = usage
    }
}

public struct EngineFailure: Sendable, Equatable, Codable, Error {
    public enum Kind: String, Sendable, Codable {
        case notSignedIn
        case rateLimited
        case binaryNotFound
        case launchFailed
        case protocolError
        case nonZeroExit
        case cancelled
        case unknown
    }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}
