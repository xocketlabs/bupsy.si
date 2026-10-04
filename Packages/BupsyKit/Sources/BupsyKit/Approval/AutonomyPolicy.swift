import Foundation

/// Decides, without asking anyone, whether a tool call needs a human.
///
/// Policy lives here rather than in the hook or the UI so there is exactly one place to read
/// when answering "why was this allowed?". Every call passes through it, including ones that are
/// auto-allowed, so the audit trail has no holes — an agent on `.auto` still produces a complete
/// record of what it did and under which rule.
public enum AutonomyPolicy {
    public enum Outcome: Sendable, Equatable {
        case allow(rule: String)
        case ask(reason: String)
    }

    /// Tools that only read. Safe to run unattended once a bot is trusted at all.
    public static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "NotebookRead", "TodoWrite", "Task",
    ]

    /// Tools whose effects leave the machine or cannot be undone.
    ///
    /// `Bash` is here even though most commands are harmless: its danger lives in the argument,
    /// not the name, and a policy that reasons about tool names cannot tell `ls` from
    /// `rm -rf ~`. Treating the whole tool as outbound is the honest reading. Narrowing it is
    /// what the per-bot allowlist is for, where the user makes that judgement knowingly.
    public static let outboundTools: Set<String> = [
        "Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch",
    ]

    /// Whether an allowlist covers a tool.
    ///
    /// An entry ending in `__` is a prefix, so allowing `mcp__github__` covers every GitHub tool
    /// without listing them — which matters because a connector's tool names are the server's to
    /// choose and change. Anything else is an exact match, so `Bash` never accidentally allows
    /// `BashOutput`.
    static func covers(_ allowlist: Set<String>, tool: String) -> Bool {
        if allowlist.contains(tool) { return true }
        return allowlist.contains { $0.hasSuffix("__") && tool.hasPrefix($0) }
    }

    public static func decide(
        tool: String,
        autonomy: Autonomy,
        allowlist: Set<String> = []
    ) -> Outcome {
        // bupsy's own tools decide for themselves, out of the model's reach: a new bot asks the
        // person every time, first contact between two bots asks once, and the roster is names
        // and jobs. Gating them here as well asked the same question twice. A user-added server
        // cannot borrow the name — MCPConfig writes the built-in "bupsy" entry last.
        if tool.hasPrefix(bupsyToolPrefix) { return .allow(rule: "bupsy asks about these itself") }
        // The engine's own plumbing, not an action: ToolSearch only loads the definitions of tools
        // the bot already has. Asking about it put a card before every first use of any app.
        if engineInternalTools.contains(tool) { return .allow(rule: "engine plumbing, touches nothing") }

        switch autonomy {
        case .auto:
            return .allow(rule: "autonomy: auto")

        case .trusted:
            if readOnlyTools.contains(tool) { return .allow(rule: "read-only tool") }
            if covers(allowlist, tool: tool) { return .allow(rule: "on this bot's allowlist") }
            if isMCP(tool) || outboundTools.contains(tool) {
                return .ask(reason: "This could reach beyond your Mac, so it always asks.")
            }
            return .allow(rule: "autonomy: trusted")

        case .allowlist:
            if covers(allowlist, tool: tool) { return .allow(rule: "on this bot's allowlist") }
            if readOnlyTools.contains(tool) { return .allow(rule: "read-only tool") }
            return .ask(reason: "Not on the list of things this bot may do without asking.")

        case .ask:
            // "Asks before everything" means everything you have not already said yes to for
            // good. Ignoring the person's own "always allow" made the button a lie.
            if covers(allowlist, tool: tool) { return .allow(rule: "you said always allow") }
            return .ask(reason: "This bot asks before every action.")
        }
    }

    /// Engine-internal tools that read or change nothing outside the engine itself.
    static let engineInternalTools: Set<String> = ["ToolSearch"]

    /// The prefix of bupsy's own tools: message_bot, create_bot, list_bots.
    static let bupsyToolPrefix = "mcp__bupsy__"

    /// Connector tools reach the user's real accounts, so they are never silently safe.
    static func isMCP(_ tool: String) -> Bool { tool.hasPrefix("mcp__") }
}
