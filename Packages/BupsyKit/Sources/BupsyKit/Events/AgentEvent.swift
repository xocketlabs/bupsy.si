import Foundation

/// The canonical event every engine is normalised into.
///
/// Everything above this type — chat UI, transcript, audit log, approval queue — is written
/// once. Every engine and host plugs in beneath it. Adding a case here is a deliberate act:
/// it means every consumer must handle it.
public enum AgentEvent: Sendable, Equatable {
    /// The run has a resumable handle.
    ///
    /// Engines disagree on when this is knowable: Codex emits `thread.started` before any work,
    /// Claude reports `session_id` on its init banner and again in the final result. Emitting it
    /// as its own event means a thread stays resumable even if the run then fails — which is the
    /// case that matters, because a failed 3am routine is exactly what someone wants to retry.
    case started(conversationID: ConversationID)

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
    /// Which connectors actually came up, reported by the engine at the start of a run.
    case connectors([ConnectorState])
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
    /// Everything the turn sent, including the cached part.
    ///
    /// **Not** the engine's `input_tokens` field, which counts only the uncached remainder. A
    /// real measured turn reported `input_tokens: 2` alongside `cache_creation: 14089` and
    /// `cache_read: 23065` — so the honest figure for "what this turn sent" is 37,156, and
    /// reporting the raw field understates it by four orders of magnitude. A usage panel saying
    /// "2" looks like fabricated data because it effectively is.
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The cached share of `inputTokens`, which is why cost stays low on a long thread. Kept
    /// separate so the total can be honest without the cost looking wrong.
    public var cachedInputTokens: Int?
    /// Notional equivalent-API cost, when the engine reports it.
    ///
    /// **Never present this as "what you paid."** Spike 3 measured $0.36 of `total_cost_usd`
    /// for a two-token prompt, because cache creation dominates — and a subscription user paid
    /// none of it. Usage is the user's own, billed under their own agreement with the vendor;
    /// we never compute from this or bill against it. Label it plainly if shown at all.
    public var costUSD: Double?
    public var durationMS: Int?
    /// What the context window held at the end of the run, when the engine says.
    ///
    /// Not derivable from the totals above: those add up every model call in a run, and an agent
    /// run re-sends its whole context on each call, so twenty tool steps counted the same context
    /// twenty times. Measured at "3.8M / 200k (1,917%)" on a real bot before this existed.
    public var context: ContextUse?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedInputTokens: Int? = nil,
                costUSD: Double? = nil, durationMS: Int? = nil, context: ContextUse? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD; self.durationMS = durationMS
        self.context = context
    }
}

/// The last model call of a run: how full its context window was, and how big that window is.
public struct ContextUse: Sendable, Equatable, Codable {
    /// Read back from the cache: what earlier turns already put there.
    public var cachedTokens: Int
    /// Sent fresh on this call, cache writes included.
    public var newTokens: Int
    /// The reply, which the next turn carries forward.
    public var replyTokens: Int
    /// The window's size as the engine reports it, or nil when it does not say.
    public var window: Int?

    public var total: Int { cachedTokens + newTokens + replyTokens }

    public init(cachedTokens: Int, newTokens: Int, replyTokens: Int, window: Int? = nil) {
        self.cachedTokens = cachedTokens; self.newTokens = newTokens
        self.replyTokens = replyTokens; self.window = window
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

/// A connector as the engine found it, not as we configured it.
///
/// Discovered in M0: Claude Code's init line carries an `mcp_servers` array with a live status
/// per server. That is worth far more than inferring readiness from whether an environment
/// variable is set — a server can be configured perfectly and still fail to start, and the user
/// should see "failed" rather than a tick next to something that is about to break a run.
public struct ConnectorState: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case connected
        case failed
        case needsAuth = "needs-auth"
        case pending
        case unknown
    }

    public var id: String { name }
    public var name: String
    public var status: Status

    public init(name: String, status: Status) {
        self.name = name; self.status = status
    }

    public var isUsable: Bool { status == .connected }
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
        /// The engine refused to run in the chosen folder. Codex does this outside a git
        /// repository, so its edits stay recoverable.
        case untrustedDirectory
        case cancelled
        case unknown
    }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
}
