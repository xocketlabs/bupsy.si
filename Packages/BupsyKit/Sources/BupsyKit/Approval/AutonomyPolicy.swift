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

    public static func decide(
        tool: String,
        autonomy: Autonomy,
        allowlist: Set<String> = []
    ) -> Outcome {
        switch autonomy {
        case .auto:
            return .allow(rule: "autonomy: auto")

        case .trusted:
            if readOnlyTools.contains(tool) { return .allow(rule: "read-only tool") }
            if allowlist.contains(tool) { return .allow(rule: "on this bot's allowlist") }
            if isMCP(tool) || outboundTools.contains(tool) {
                return .ask(reason: "\(tool) can act outside this machine")
            }
            return .allow(rule: "autonomy: trusted")

        case .allowlist:
            if allowlist.contains(tool) { return .allow(rule: "on this bot's allowlist") }
            if readOnlyTools.contains(tool) { return .allow(rule: "read-only tool") }
            return .ask(reason: "\(tool) is not on this bot's allowlist")

        case .ask:
            return .ask(reason: "this bot asks before every action")
        }
    }

    /// Connector tools reach the user's real accounts, so they are never silently safe.
    static func isMCP(_ tool: String) -> Bool { tool.hasPrefix("mcp__") }
}
