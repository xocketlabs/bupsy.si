import Foundation
import Testing
@testable import BupsyKit

@Suite("MCP connectors")
struct ConnectorTests {

    /// The rule the whole connector design turns on: a secret never passes through a file we
    /// wrote. Values are emitted as `${NAME}` references resolved by the server's own process
    /// from the user's environment.
    @Test("config references environment variables by name, never by value")
    func neverWritesSecrets() throws {
        let server = MCPServer(
            name: "github", command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            requiredEnvNames: ["GITHUB_PERSONAL_ACCESS_TOKEN"])

        let document = MCPConfig.document(for: [server])
        let json = try String(
            data: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
            encoding: .utf8)!

        #expect(json.contains("${GITHUB_PERSONAL_ACCESS_TOKEN}"))
        // If a real token ever appeared here it would be written to a file on disk, in plain
        // text, by us — exactly what bupsy promises not to do.
        #expect(!json.contains("ghp_"))
        #expect(!json.contains("secret"))
    }

    @Test("produces the shape an engine expects")
    func documentShape() throws {
        let document = MCPConfig.document(for: [
            MCPServer(name: "files", command: "npx", args: ["-y", "server-filesystem", "/tmp"]),
        ])
        let servers = try #require(document["mcpServers"] as? [String: Any])
        let files = try #require(servers["files"] as? [String: Any])
        #expect(files["command"] as? String == "npx")
        #expect((files["args"] as? [String])?.contains("/tmp") == true)
        // No env key at all when none is needed, rather than an empty object.
        #expect(files["env"] == nil)
    }

    @Test("a disabled server is left out entirely")
    func disabledIsExcluded() {
        let document = MCPConfig.document(for: [
            MCPServer(name: "on", command: "x", enabled: true),
            MCPServer(name: "off", command: "x", enabled: false),
        ])
        let servers = document["mcpServers"] as? [String: Any]
        #expect(servers?.count == 1)
        #expect(servers?["off"] == nil)
    }

    /// Passing an empty config is noise on a command line, so there is nothing to pass.
    @Test("writes nothing when there is nothing to configure")
    func writesNothingWhenEmpty() throws {
        #expect(try MCPConfig.write([]) == nil)
        #expect(try MCPConfig.write([MCPServer(name: "x", command: "y", enabled: false)]) == nil)
    }

    @Test("reports which environment variables are missing")
    func reportsMissingEnv() {
        let server = MCPServer(name: "slack", command: "npx",
                               requiredEnvNames: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"])
        #expect(server.missingEnv(in: [:]).count == 2)
        #expect(server.missingEnv(in: ["SLACK_BOT_TOKEN": "x"]) == ["SLACK_TEAM_ID"])
        // An empty value is missing, not present — a half-set variable fails confusingly later.
        #expect(server.missingEnv(in: ["SLACK_BOT_TOKEN": "", "SLACK_TEAM_ID": "t"])
            == ["SLACK_BOT_TOKEN"])
    }

    @Test("tool names carry the server prefix allowlists match on")
    func toolPrefix() {
        #expect(MCPServer(name: "github", command: "x").toolPrefix == "mcp__github__")
    }
}

@Suite("Allowlist matching")
struct AllowlistTests {
    /// Allowing a connector means allowing its tools, whatever they turn out to be called —
    /// the names belong to the server and can change under us.
    @Test("a trailing __ allows a whole connector")
    func prefixCoversConnector() {
        let allowlist: Set<String> = ["mcp__github__"]
        #expect(AutonomyPolicy.covers(allowlist, tool: "mcp__github__create_issue"))
        #expect(AutonomyPolicy.covers(allowlist, tool: "mcp__github__search_code"))
        #expect(!AutonomyPolicy.covers(allowlist, tool: "mcp__slack__post_message"))
    }

    /// Anything without the trailing `__` is exact, so allowing `Bash` never also allows
    /// `BashOutput` by accident.
    @Test("a plain entry matches exactly")
    func plainEntryIsExact() {
        #expect(AutonomyPolicy.covers(["Bash"], tool: "Bash"))
        #expect(!AutonomyPolicy.covers(["Bash"], tool: "BashOutput"))
    }

    @Test("an allowed connector runs unattended at allowlist level")
    func allowedConnectorRuns() {
        let outcome = AutonomyPolicy.decide(
            tool: "mcp__github__create_issue",
            autonomy: .allowlist,
            allowlist: ["mcp__github__"])
        if case .allow = outcome {} else { Issue.record("expected allow, got \(outcome)") }
    }

    @Test("an unallowed connector still asks, even for a trusted bot")
    func unallowedConnectorAsks() {
        let outcome = AutonomyPolicy.decide(
            tool: "mcp__gmail__send", autonomy: .trusted, allowlist: ["mcp__github__"])
        if case .ask = outcome {} else { Issue.record("expected ask, got \(outcome)") }
    }
}
