import Foundation

/// The slash commands a Claude Code bot can be sent.
///
/// Sent as the prompt, `claude -p "/name args"` runs the command exactly as typing it in the
/// terminal would: custom commands and skills expand, with `$ARGUMENTS` filled in, and the
/// built-ins below do their work. Checked against Claude Code 2.1 with `--resume`, so in the
/// middle of a bot's chat; Bupsy passes the text through unchanged.
public enum ClaudeCommands {
    /// The built-ins that do something useful in print mode, each tried there.
    ///
    /// Left out on purpose: `/model` (lasts one run, and Bupsy passes the bot's model on every
    /// run; Bupsy's own /model changes it for good), `/clear` (starts an empty chat with no notes;
    /// Bupsy's /fresh carries the work over), and the ones that only change the terminal's own
    /// screen or settings (`/color`, `/focus`, `/config`, `/effort`…), which have none to change.
    public static let builtIns: [SlashCommand] = [
        SlashCommand(name: "compact", description: "Shrink the chat to a summary, so each message costs less",
                     argumentHint: "what to keep", source: .claude),
        SlashCommand(name: "context", description: "What's taking up room in the chat's context window", source: .claude),
        SlashCommand(name: "usage", description: "How much of your plan's limits you've used", source: .claude),
        SlashCommand(name: "review", description: "Review the changes in this folder for bugs",
                     argumentHint: "pr number, branch or path", source: .claude),
        SlashCommand(name: "security-review", description: "Check this branch's changes for security problems (needs Git)",
                     source: .claude),
        SlashCommand(name: "init", description: "Write a CLAUDE.md that explains this folder's code", source: .claude),
    ]

    /// The person's commands and skills, then the project's, as Claude Code finds them.
    ///
    /// Commands are Markdown files under `.claude/commands`; a subfolder becomes part of the name
    /// (`frontend/component.md` is `/frontend:component`). Skills are `SKILL.md` files one folder
    /// down under `.claude/skills`, and run as `/name` too unless they say `user-invocable: false`.
    /// When two share a name the first wins: skills over commands, the person's over the project's,
    /// which is Claude Code's own order.
    public static func discover(home: URL, workdir: URL?) -> [SlashCommand] {
        let personal = home.appendingPathComponent(".claude", isDirectory: true)
        // A bot working in the home folder would otherwise list the person's commands twice.
        let project = workdir.map { $0.appendingPathComponent(".claude", isDirectory: true) }
            .flatMap { $0.standardizedFileURL == personal.standardizedFileURL ? nil : $0 }
        var found = skills(in: personal, source: .personal)
        if let project { found += skills(in: project, source: .project) }
        found += commands(in: personal, source: .personal)
        if let project { found += commands(in: project, source: .project) }
        var seen = Set(builtIns.map(\.name))
        return found.filter { seen.insert($0.name).inserted }
    }

    static func commands(in claudeFolder: URL, source: SlashCommand.Source) -> [SlashCommand] {
        let root = claudeFolder.appendingPathComponent("commands", isDirectory: true).resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let rootParts = root.standardizedFileURL.pathComponents
        var found: [SlashCommand] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            let parts = Array(url.standardizedFileURL.deletingPathExtension().pathComponents.dropFirst(rootParts.count))
            let name = parts.joined(separator: ":")
            guard SlashInput.isName(name), let text = readHead(url) else { continue }
            let (fields, body) = CommandFile.parse(text)
            found.append(SlashCommand(name: name, description: CommandFile.summary(fields: fields, body: body),
                                      argumentHint: fields["argument-hint"], source: source, path: url.path))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func skills(in claudeFolder: URL, source: SlashCommand.Source) -> [SlashCommand] {
        let root = claudeFolder.appendingPathComponent("skills", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        var found: [SlashCommand] = []
        for folder in folders {
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = readHead(file) else { continue }
            let (fields, body) = CommandFile.parse(text)
            if fields["user-invocable"]?.lowercased() == "false" { continue }
            let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            guard SlashInput.isName(name) else { continue }
            found.append(SlashCommand(name: name, description: CommandFile.summary(fields: fields, body: body),
                                      argumentHint: fields["argument-hint"], source: source, path: file.path))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The start of a file, enough for its frontmatter. A skill can be long, and the menu opens on
    /// every `/` typed, so nothing past the first 16 KB is read.
    static func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Codex custom prompts, which Bupsy expands itself.
///
/// The Codex terminal turns `/prompts:name args` into the file's text, but `codex exec` does not:
/// tried with codex-cli 0.160, the model got the literal `/prompts:name` and went looking for it.
/// So Bupsy reads the file and sends what Codex would have, following Codex's documented rules
/// (https://developers.openai.com/codex/custom-prompts). Its built-ins (`/compact`, `/review`…)
/// are not offered: `exec` passes them to the model as plain words, which then claims to have
/// compacted a chat it has not. Custom prompts are the person's own: Codex has no project ones.
public enum CodexPrompts {
    public static let prefix = "prompts:"

    /// `$CODEX_HOME/prompts`, which is `~/.codex/prompts` unless the person moved it.
    public static func folder(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("prompts", isDirectory: true)
    }

    /// Every `.md` file directly in the folder, as `/prompts:<file name>`.
    public static func discover(in folder: URL) -> [SlashCommand] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url -> SlashCommand? in
            let name = prefix + url.deletingPathExtension().lastPathComponent
            guard SlashInput.isName(name), let text = ClaudeCommands.readHead(url) else { return nil }
            let (fields, body) = CommandFile.parse(text)
            return SlashCommand(name: name, description: CommandFile.summary(fields: fields, body: body),
                                argumentHint: fields["argument-hint"], source: .codex, path: url.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public enum ExpansionError: Error, Equatable, CustomStringConvertible {
        /// The prompt names values (`$FILE`) that were not given as `FILE=…`.
        case missing([String])
        /// A prompt with named values was given something that is not `KEY=value`.
        case notKeyValue(String)

        public var description: String {
            switch self {
            case .missing(let keys):
                "This prompt needs " + keys.map { "\($0)=…" }.joined(separator: " ") + "."
            case .notKeyValue(let token):
                "This prompt takes values as KEY=value, and \u{201C}\(token)\u{201D} isn't one."
            }
        }
    }

    /// A prompt file's text, without its frontmatter, with the arguments put in.
    public static func expand(file text: String, arguments: String) throws(ExpansionError) -> String {
        let body = CommandFile.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
        return try expand(body, arguments: arguments)
    }

    /// The prompt's text with what was typed after its name put in.
    ///
    /// Arguments split like a shell's, so `FOCUS="loading state"` is one value. `$1`…`$9` are the
    /// arguments in order and `$ARGUMENTS` all of them; an uppercase name such as `$TICKET_ID` is
    /// filled from `TICKET_ID=…`, and once a prompt has one, every argument must be `KEY=value`
    /// and every name given. `$$` is a literal dollar sign.
    public static func expand(_ content: String, arguments: String) throws(ExpansionError) -> String {
        let tokens = shellSplit(arguments)
        let names = namedPlaceholders(in: content)
        var values: [String: String] = [:]
        if !names.isEmpty {
            for token in tokens {
                guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
                    throw .notKeyValue(token)
                }
                values[String(token[..<equals])] = String(token[token.index(after: equals)...])
            }
            let missing = names.filter { values[$0] == nil }
            if !missing.isEmpty { throw .missing(missing) }
        }

        var out = ""
        var rest = Substring(content)
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            if after.hasPrefix("$") {
                out += "$"
                rest = after.dropFirst()
            } else if let digit = after.first, let index = digit.wholeNumberValue, (1...9).contains(index),
                      digit.isASCII {
                if names.isEmpty, index <= tokens.count { out += tokens[index - 1] }
                rest = after.dropFirst()
            } else if after.hasPrefix("ARGUMENTS") {
                out += tokens.joined(separator: " ")
                rest = after.dropFirst("ARGUMENTS".count)
            } else if let name = leadingName(after), let value = values[name] {
                out += value
                rest = after.dropFirst(name.count)
            } else {
                out += "$"
                rest = after
            }
        }
        return out + rest
    }

    /// `$NAME` placeholders, in order of first use, leaving out `$ARGUMENTS` and escaped `$$NAME`.
    static func namedPlaceholders(in content: String) -> [String] {
        var names: [String] = []
        var rest = Substring(content)
        while let dollar = rest.firstIndex(of: "$") {
            let after = rest[rest.index(after: dollar)...]
            if after.hasPrefix("$") { rest = after.dropFirst(); continue }
            if let name = leadingName(after), name != "ARGUMENTS", !names.contains(name) { names.append(name) }
            rest = after
        }
        return names
    }

    /// An uppercase letter, then uppercase letters, digits or underscores.
    private static func leadingName(_ text: Substring) -> String? {
        guard let first = text.first, first.isASCII, first.isUppercase else { return nil }
        let name = text.prefix { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
        return String(name)
    }

    /// Words split on spaces, with single and double quotes grouping and a backslash escaping the
    /// next character outside single quotes: how Codex splits a prompt's arguments.
    static func shellSplit(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; inToken = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\" && open == "\"" { escaped = true }
                else { current.append(character) }
                continue
            }
            switch character {
            case "\\": escaped = true; inToken = true
            case "\"", "'": quote = character; inToken = true
            case _ where character.isWhitespace:
                if inToken { tokens.append(current); current = ""; inToken = false }
            default: current.append(character); inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
