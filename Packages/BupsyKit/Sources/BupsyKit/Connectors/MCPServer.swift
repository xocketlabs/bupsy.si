import Foundation

/// An MCP server a bot can use as tools.
///
/// Connectors are *the user's* MCP servers, not integrations we wrote. That is the whole design:
/// we never have to build or maintain a Gmail integration, and more importantly we never hold a
/// Gmail token. The server does its own authentication, wherever it keeps it, and we only ever
/// know whether it is configured.
public struct MCPServer: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    /// The key in `mcpServers`, and what tool names are prefixed with: `mcp__<name>__<tool>`.
    public var name: String
    public var command: String
    public var args: [String]
    /// Names of environment variables this server needs — **names only, never values.**
    ///
    /// bupsy does not store connector secrets, the same way it does not store model credentials.
    /// `KeychainStore` only accepts keys prefixed `compute.`, and a test enforces it, so this is
    /// a constraint the codebase imposes rather than a promise someone has to remember.
    ///
    /// The cost is real and worth naming: the user sets these in their own environment, which is
    /// more setup than a paste box would be. The benefit is that a bupsy breach leaks nobody's
    /// mail.
    public var requiredEnvNames: [String]
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, command: String,
                args: [String] = [], requiredEnvNames: [String] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.command = command
        self.args = args; self.requiredEnvNames = requiredEnvNames; self.enabled = enabled
    }

    /// Environment variables this server needs that are missing.
    ///
    /// With no environment given, a name counts as set if this process has it or the person's
    /// login shell does (`LoginShellEnvironment`), which is where the setup copy tells them to
    /// put it. The first check for a name may wait on a shell; later ones are answered from
    /// memory.
    public func missingEnv(in environment: [String: String]? = nil) -> [String] {
        let source = environment ?? LoginShellEnvironment.resolved(requiredEnvNames)
        return requiredEnvNames.filter { (source[$0] ?? "").isEmpty }
    }

    /// The values to hand an engine so this server's `${NAME}` references resolve. Never write
    /// these anywhere: they are passed in the spawned process's environment only.
    public func resolvedEnv() -> [String: String] {
        LoginShellEnvironment.resolved(requiredEnvNames)
    }

    /// The prefix every tool from this server carries, which is what per-bot allowlists match on.
    public var toolPrefix: String { "mcp__\(name)__" }

    /// How a server's name reads in a sentence: "GitHub" for `github`, "Files" for `filesystem`.
    ///
    /// The common ones take their title from the suggestions, and a few brands keep their own
    /// capitals. Anything else has its words capitalised (`my-tools` reads "My Tools"), which
    /// is a guess, but a better one than `.capitalized`, which turned "github" into "Github".
    public static func displayName(of serverName: String) -> String {
        if let suggestion = MCPSuggestions.all.first(where: { $0.server.name == serverName }) {
            return suggestion.title
        }
        let brands = ["github": "GitHub", "gitlab": "GitLab", "executor": "Executor",
                      "linear": "Linear", "gmail": "Gmail", "postgres": "Postgres"]
        if let brand = brands[serverName.lowercased()] { return brand }
        let words = serverName
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? serverName : words.joined(separator: " ")
    }

    /// Splits an arguments line the way a shell would, so a path with a space survives.
    ///
    /// Whitespace separates arguments except inside quotes. Single quotes keep everything
    /// literally; double quotes keep everything except `\"` and `\\`; outside quotes a backslash
    /// escapes the next character (`My\ Folder`). An unclosed quote runs to the end of the line
    /// rather than failing, and `""` is kept as an empty argument. No expansion of any kind:
    /// `$HOME` or `~` reach the server as typed.
    public static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaping = false

        for character in line {
            if escaping {
                if inDouble, character != "\"", character != "\\" { current.append("\\") }
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }
            if inSingle {
                if character == "'" { inSingle = false } else { current.append(character) }
                continue
            }
            if inDouble {
                if character == "\"" {
                    inDouble = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'":
                inSingle = true
                hasToken = true
            case "\"":
                inDouble = true
                hasToken = true
            case "\\":
                escaping = true
                hasToken = true
            default:
                if character.isWhitespace {
                    if hasToken {
                        result.append(current)
                        current = ""
                        hasToken = false
                    }
                } else {
                    current.append(character)
                    hasToken = true
                }
            }
        }
        if escaping { current.append("\\") }
        if hasToken { result.append(current) }
        return result
    }

    /// The reverse of `splitArguments`: one line that splits back into exactly these arguments.
    /// Used to show a saved server's arguments for editing.
    public static func joinArguments(_ args: [String]) -> String {
        args.map { argument in
            if argument.isEmpty { return "\"\"" }
            let plain = argument.allSatisfy { character in
                !character.isWhitespace && character != "'" && character != "\""
                    && character != "\\"
            }
            if plain { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }
}

/// Starting points, not a maintained catalog.
///
/// Deliberately short and clearly someone else's software. A long built-in directory would rot —
/// MCP server packages move, get renamed and get archived — and would imply we vouch for code we
/// do not maintain. The real feature is the "add any server" path; these just save typing for the
/// most common ones.
public enum MCPSuggestions {
    public struct Suggestion: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let server: MCPServer
    }

    public static let all: [Suggestion] = [
        Suggestion(
            id: "github",
            title: "GitHub",
            detail: "Issues, pull requests, code search. Needs a personal access token.",
            server: MCPServer(
                name: "github", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                requiredEnvNames: ["GITHUB_PERSONAL_ACCESS_TOKEN"])),
        Suggestion(
            id: "filesystem",
            title: "Files",
            detail: "Read and write a folder you choose. No account needed.",
            server: MCPServer(
                name: "filesystem", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem",
                       FileManager.default.homeDirectoryForCurrentUser.path])),
        Suggestion(
            id: "slack",
            title: "Slack",
            detail: "Channels and messages. Needs a bot token from your workspace.",
            server: MCPServer(
                name: "slack", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-slack"],
                requiredEnvNames: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"])),
        Suggestion(
            id: "notion",
            title: "Notion",
            detail: "Pages and databases. Needs an integration token.",
            server: MCPServer(
                name: "notion", command: "npx",
                args: ["-y", "@notionhq/notion-mcp-server"],
                requiredEnvNames: ["NOTION_API_KEY"])),
    ]
}

/// Writes the `mcpServers` document an engine is pointed at with `--mcp-config`.
public enum MCPConfig {
    /// Builds the config for a set of servers.
    ///
    /// Env **names** are emitted with a `${NAME}` reference rather than a resolved value, so a
    /// secret never passes through a file we wrote. If a server's variable is missing from the
    /// environment the server will fail to start, which is the honest outcome — better than us
    /// quietly holding the token to avoid it.
    /// bupsy's own server, which lets this bot message other bots.
    ///
    /// Its env carries literal values rather than `${NAME}` references, and that is not a breach
    /// of the credential rule: an outbox path and a bot id are addressing, not secrets. The rule
    /// exists so a *model credential* never passes through a file we wrote, and neither of these
    /// is one. Attribution in particular has to be a value — a server that could be told which
    /// bot it speaks for by the surrounding environment could be made to lie about who sent a
    /// message, and attribution is the only thing making an inter-bot message auditable.
    /// `roster` is the file `list_bots` reads — names and jobs, the same things the sidebar shows.
    public static func bupsyServer(binary: String, outbox: String, botID: String,
                                   roster: String? = nil) -> [String: Any] {
        // The run token is a reference the engine fills in from its own environment, so the
        // secret is never written into this file, which other bots' tools could read.
        var env = ["BUPSY_OUTBOX": outbox, "BUPSY_BOT_ID": botID,
                   "BUPSY_RUN_TOKEN": "${BUPSY_RUN_TOKEN}"]
        if let roster { env["BUPSY_ROSTER"] = roster }
        return ["command": binary, "env": env]
    }

    public static func document(for servers: [MCPServer],
                                including builtIn: [String: Any]? = nil) -> [String: Any] {
        var entries: [String: Any] = [:]
        for server in servers where server.enabled {
            var entry: [String: Any] = ["command": server.command, "args": server.args]
            if !server.requiredEnvNames.isEmpty {
                entry["env"] = Dictionary(
                    uniqueKeysWithValues: server.requiredEnvNames.map { ($0, "${\($0)}") })
            }
            entries[server.name] = entry
        }
        // Last, so a user-configured server named "bupsy" cannot shadow the built-in one and
        // quietly take over where messages between bots are sent.
        if let builtIn { entries["bupsy"] = builtIn }
        return ["mcpServers": entries]
    }

    /// Writes the config to a temporary file and returns its path, or nil when there is nothing
    /// to configure — passing an empty config is noise on the command line.
    @discardableResult
    public static func write(_ servers: [MCPServer], to directory: URL? = nil,
                             including builtIn: [String: Any]? = nil) throws -> String? {
        let enabled = servers.filter(\.enabled)
        guard !enabled.isEmpty || builtIn != nil else { return nil }

        let folder = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bupsy-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent("mcp.json")
        let data = try JSONSerialization.data(
            withJSONObject: document(for: enabled, including: builtIn),
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url.path
    }
}
