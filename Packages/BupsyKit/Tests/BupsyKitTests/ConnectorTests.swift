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

    /// Splitting on spaces broke any path with a space in it, which on a Mac is most of them.
    @Test("arguments split the way a shell would")
    func splitsArgumentsLikeAShell() {
        #expect(MCPServer.splitArguments(#"-y @acme/server "/Users/me/My Folder""#)
            == ["-y", "@acme/server", "/Users/me/My Folder"])
        #expect(MCPServer.splitArguments(#"/Users/me/My\ Folder --flag"#)
            == ["/Users/me/My Folder", "--flag"])
        #expect(MCPServer.splitArguments("--name 'two words'") == ["--name", "two words"])
        #expect(MCPServer.splitArguments("\"a \\\"b\\\"\"") == ["a \"b\""])
        #expect(MCPServer.splitArguments("  a   b  ") == ["a", "b"])
        #expect(MCPServer.splitArguments("\"\" x") == ["", "x"])
        #expect(MCPServer.splitArguments("$HOME ~") == ["$HOME", "~"], "no expansion")
        #expect(MCPServer.splitArguments("") == [])
    }

    @Test("server names read the way the product spells them")
    func displayNames() {
        #expect(MCPServer.displayName(of: "github") == "GitHub")
        #expect(MCPServer.displayName(of: "filesystem") == "Files")
        #expect(MCPServer.displayName(of: "executor") == "Executor")
        #expect(MCPServer.displayName(of: "my-tools") == "My Tools")
    }

    @Test("joined arguments split back into the same list")
    func joinRoundTrips() {
        let args = ["-y", "a b", "it's", "", "q\"\\", "plain"]
        #expect(MCPServer.splitArguments(MCPServer.joinArguments(args)) == args)
        #expect(MCPServer.joinArguments(["-y", "pkg"]) == "-y pkg")
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

@Suite("Login shell environment")
struct LoginShellEnvironmentTests {
    @Test("reads back only the names asked for, with values intact")
    func parsesNamedValues() {
        var data = Data("LINEAR_API_KEY=lin_abc=def\nline2".utf8)
        data.append(0)
        data.append(contentsOf: Data("EMPTY=".utf8))
        data.append(0)
        data.append(contentsOf: Data("OTHER=nope".utf8))
        data.append(0)
        let parsed = LoginShellEnvironment.parse(data, names: ["LINEAR_API_KEY", "EMPTY", "MISSING"])
        #expect(parsed == ["LINEAR_API_KEY": "lin_abc=def\nline2"])
    }

    /// A name goes into a shell command, so anything that is not a plain identifier is refused
    /// rather than quoted.
    @Test("never puts an unsafe name into the shell command")
    func refusesUnsafeNames() {
        #expect(LoginShellEnvironment.isValidName("GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(LoginShellEnvironment.isValidName("_x1"))
        #expect(!LoginShellEnvironment.isValidName("1X"))
        #expect(!LoginShellEnvironment.isValidName(""))
        #expect(!LoginShellEnvironment.isValidName("A;rm -rf ~"))
        #expect(!LoginShellEnvironment.isValidName("$(id)"))

        let script = LoginShellEnvironment.script(for: ["OK_NAME", "bad name", "A`b`"])
        #expect(script == #"printf '%s\0' "OK_NAME=$OK_NAME""#)
    }

    /// The process's own value wins, so a Bupsy started from a terminal behaves as it always did.
    @Test("prefers a value this process already has")
    func prefersCurrentEnvironment() {
        let values = LoginShellEnvironment.resolved(["BUPSY_TEST_SET"], current: ["BUPSY_TEST_SET": "here"])
        #expect(values == ["BUPSY_TEST_SET": "here"])
    }

    /// The script really runs in a POSIX shell and round-trips a value with awkward characters.
    @Test("the generated script prints values a shell set")
    func scriptRuns() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "BUPSY_T='a=b c'; export BUPSY_T; "
            + LoginShellEnvironment.script(for: ["BUPSY_T", "BUPSY_UNSET_\(UUID().uuidString.prefix(4))"])]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(LoginShellEnvironment.parse(data, names: ["BUPSY_T"]) == ["BUPSY_T": "a=b c"])
    }
}
