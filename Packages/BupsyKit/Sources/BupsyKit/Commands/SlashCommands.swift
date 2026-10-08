import Foundation

/// A command offered when the person types `/` in a bot's message box.
public struct SlashCommand: Sendable, Equatable, Identifiable {
    /// Where a command comes from, which decides both its tag in the menu and what sending it does.
    public enum Source: String, Sendable {
        /// Bupsy's own, done by the app and never sent to the engine.
        case bupsy
        /// Built into Claude Code, and checked to work in the print mode bots run in.
        case claude
        /// The person's own, from `~/.claude`.
        case personal
        /// The project's, from `.claude` in the bot's folder.
        case project
        /// A Codex custom prompt, which Bupsy expands itself: `codex exec` does not.
        case codex
    }

    /// Without the slash: `review`, `frontend:component`, `prompts:draftpr`.
    public var name: String
    public var description: String
    /// How the arguments go, when the file says: `[pr-number]`, `FILES=<paths>`.
    public var argumentHint: String?
    public var source: Source
    /// The file it was read from, so a Codex prompt is read again, as it is now, when sent.
    public var path: String?

    public var id: String { name }

    public init(name: String, description: String, argumentHint: String? = nil, source: Source, path: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint
        self.source = source; self.path = path
    }
}

/// Reading what the person has typed as a command.
public enum SlashInput {
    /// `/name args` split into its name (no slash) and the rest, trimmed. Nil unless the text
    /// starts with a slash and a name, so a message that starts with a path is never a command.
    public static func parse(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard isName(name) else { return nil }
        let arguments = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, arguments)
    }

    /// The name typed so far while the caret could still be in it: the text is a slash and
    /// letters with nothing after them yet. `""` for a lone slash; nil once a space is typed.
    public static func typedName(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let name = String(text.dropFirst())
        guard !name.contains(where: \.isWhitespace) else { return nil }
        return name.isEmpty || isName(name) ? name : nil
    }

    /// Whether a prompt is a slash command as an engine would read it. Bupsy writes nothing in
    /// front of one (no job, no notes): Claude Code only runs a command at the very start.
    public static func looksLikeCommand(_ prompt: String) -> Bool {
        parse(prompt) != nil
    }

    /// Letters, digits and `-_.:`, starting with a letter or digit. A second slash means a path
    /// (`/Users/me/file.png`), which a dropped file puts at the start of a message.
    static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Ordering the menu as the person types.
public enum SlashCommandMatch {
    /// Commands whose name starts with what was typed first, then those where a part after a
    /// colon does (`comp` finds `frontend:component`, `draft` finds `prompts:draftpr`), then any
    /// that contain it. Each group keeps the order it was given. An empty query keeps them all.
    public static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let wanted = query.lowercased()
        guard !wanted.isEmpty else { return commands }
        var prefix: [SlashCommand] = [], part: [SlashCommand] = [], contains: [SlashCommand] = []
        for command in commands {
            let name = command.name.lowercased()
            if name.hasPrefix(wanted) {
                prefix.append(command)
            } else if name.split(separator: ":").dropFirst().contains(where: { $0.hasPrefix(wanted) }) {
                part.append(command)
            } else if name.contains(wanted) {
                contains.append(command)
            }
        }
        return prefix + part + contains
    }
}

/// A command file: optional `---` frontmatter, then the text the command stands for.
public enum CommandFile {
    /// The frontmatter's simple `key: value` fields and the body after it. Quotes around a value
    /// are dropped, and a folded (`>`) or literal (`|`) value is joined from its indented lines,
    /// which is as much YAML as a description needs.
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalised.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], normalised) }
        let header = Array(lines[1..<end])
        lines.removeSubrange(0...end)

        var fields: [String: String] = [:]
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") || value.isEmpty {
                var continued: [String] = []
                while index < header.count, header[index].hasPrefix(" ") || header[index].hasPrefix("\t") || header[index].isEmpty {
                    continued.append(header[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = continued.filter { !$0.isEmpty }.joined(separator: " ")
            }
            fields[key] = unquote(value)
        }
        return (fields, lines.joined(separator: "\n"))
    }

    /// What a command says it does: its `description`, or else its first line of text.
    public static func summary(fields: [String: String], body: String) -> String {
        if let description = fields["description"], !description.isEmpty { return description }
        let first = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let plain = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return plain.count > 200 ? String(plain.prefix(200)) + "…" : plain
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
