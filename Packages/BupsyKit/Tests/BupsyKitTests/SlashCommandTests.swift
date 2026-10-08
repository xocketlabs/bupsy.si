import Foundation
import Testing
@testable import BupsyKit

@Suite("Slash commands")
struct SlashCommandTests {
    /// A folder with files at the given relative paths.
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - Reading what was typed

    @Test("a command is a slash and a name, and a path is not one")
    func parsing() {
        #expect(SlashInput.parse("/review 42")! == ("review", "42"))
        #expect(SlashInput.parse("  /frontend:component  Button big ")! == ("frontend:component", "Button big"))
        #expect(SlashInput.parse("/compact")! == ("compact", ""))
        // A dropped file puts its path first; it must never be read as a command.
        #expect(SlashInput.parse("/Users/me/photo.png what is this") == nil)
        #expect(SlashInput.parse("/ hello") == nil)
        #expect(SlashInput.parse("hello /review") == nil)
        #expect(SlashInput.looksLikeCommand("/prompts:draftpr FILES=a.swift"))
        #expect(!SlashInput.looksLikeCommand("/tmp/x"))
    }

    @Test("the menu filters only while the name is still being typed")
    func typedName() {
        #expect(SlashInput.typedName("/") == "")
        #expect(SlashInput.typedName("/rev") == "rev")
        #expect(SlashInput.typedName("/review ") == nil)
        #expect(SlashInput.typedName("/Users/me") == nil)
        #expect(SlashInput.typedName("review") == nil)
    }

    @Test("names starting with what was typed come first, then a part after a colon, then any match")
    func ranking() {
        let commands = ["compact", "frontend:component", "init", "prompts:draftpr", "recompile", "context"]
            .map { SlashCommand(name: $0, description: "", source: .project) }
        #expect(SlashCommandMatch.rank(commands, query: "comp").map(\.name)
                == ["compact", "frontend:component", "recompile"])
        #expect(SlashCommandMatch.rank(commands, query: "DRAFT").map(\.name) == ["prompts:draftpr"])
        #expect(SlashCommandMatch.rank(commands, query: "").count == commands.count)
        #expect(SlashCommandMatch.rank(commands, query: "zzz").isEmpty)
    }

    // MARK: - Files

    @Test("frontmatter gives the description and hint, quotes and folded lines included")
    func frontmatter() {
        let (fields, body) = CommandFile.parse("""
            ---
            description: "Make a component"
            argument-hint: [name]
            notes: >
              one
              two
            ---
            Build $ARGUMENTS.
            """)
        #expect(fields["description"] == "Make a component")
        #expect(fields["argument-hint"] == "[name]")
        #expect(fields["notes"] == "one two")
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "Build $ARGUMENTS.")
        // No frontmatter: the first line says what it does, without a heading's hashes.
        let plain = CommandFile.parse("\n# Fix the flaky test\n\nThen run it.")
        #expect(plain.fields.isEmpty)
        #expect(CommandFile.summary(fields: plain.fields, body: plain.body) == "Fix the flaky test")
    }

    @Test("Claude commands and skills, the person's and the project's, with folders as namespaces")
    func claudeDiscovery() throws {
        let home = try folder([
            ".claude/commands/standup.md": "---\ndescription: Write my standup\n---\nList what I did.",
            ".claude/skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Read and fill PDFs\n---\nSteps.",
            ".claude/skills/hidden/SKILL.md": "---\nname: hidden\nuser-invocable: false\ndescription: x\n---\n",
            ".claude/skills/notaskill/README.md": "nothing",
        ])
        let project = try folder([
            ".claude/commands/frontend/component.md": "Create a React component named $ARGUMENTS",
            ".claude/commands/standup.md": "The project's own standup",
            ".claude/commands/review.md": "Shadows a built-in",
            ".claude/skills/deploy/SKILL.md": "---\ndescription: Ship it\nargument-hint: <env>\n---\n",
        ])
        let found = ClaudeCommands.discover(home: home, workdir: project)
        #expect(found.map(\.name) == ["pdf", "deploy", "standup", "frontend:component"])
        #expect(found.map(\.source) == [.personal, .project, .personal, .project])
        #expect(found[1].argumentHint == "<env>")
        #expect(found[2].description == "Write my standup")
        #expect(found[3].description == "Create a React component named $ARGUMENTS")
        // A bot working in the home folder does not list everything twice.
        #expect(ClaudeCommands.discover(home: home, workdir: home).map(\.name) == ["pdf", "standup"])
        #expect(ClaudeCommands.discover(home: home, workdir: nil).count == 2)
    }

    @Test("Codex prompts are listed as prompts:name, from CODEX_HOME when it is set")
    func codexDiscovery() throws {
        let home = try folder([
            ".codex/prompts/draftpr.md": "---\ndescription: Draft a PR\nargument-hint: [FILES=<paths>]\n---\nBody",
            ".codex/prompts/notes.txt": "not a prompt",
        ])
        let prompts = CodexPrompts.discover(in: CodexPrompts.folder(home: home, environment: [:]))
        #expect(prompts.map(\.name) == ["prompts:draftpr"])
        #expect(prompts[0].description == "Draft a PR")
        #expect(prompts[0].argumentHint == "[FILES=<paths>]")
        #expect(CodexPrompts.folder(home: home, environment: ["CODEX_HOME": "/elsewhere"]).path == "/elsewhere/prompts")
    }

    // MARK: - Codex placeholders

    @Test("positional arguments and $ARGUMENTS, quoted values kept whole")
    func positional() throws {
        #expect(try CodexPrompts.expand("Fix $1 then $2. All: $ARGUMENTS", arguments: #"login "the sign up""#)
                == "Fix login then the sign up. All: login the sign up")
        // Missing positions are empty; $$ is a dollar sign.
        #expect(try CodexPrompts.expand("Costs $$5 for $1 and $3", arguments: "a b") == "Costs $5 for a and ")
        #expect(try CodexPrompts.expand("No placeholders", arguments: "ignored") == "No placeholders")
    }

    @Test("named values come as KEY=value, and every one must be given")
    func named() throws {
        let prompt = "Review $FILE focusing on $FOCUS. Keep $$HOME and $lower as they are."
        #expect(try CodexPrompts.expand(prompt, arguments: #"FILE=src/a.swift FOCUS="loading state""#)
                == "Review src/a.swift focusing on loading state. Keep $HOME and $lower as they are.")
        #expect(throws: CodexPrompts.ExpansionError.missing(["FOCUS"])) {
            try CodexPrompts.expand(prompt, arguments: "FILE=a")
        }
        #expect(throws: CodexPrompts.ExpansionError.notKeyValue("a.swift")) {
            try CodexPrompts.expand(prompt, arguments: "a.swift")
        }
    }

    @Test("a prompt file loses its frontmatter before it is sent")
    func fileExpansion() throws {
        let text = "---\ndescription: Draft a PR\n---\n\nDraft a PR for $1.\n"
        #expect(try CodexPrompts.expand(file: text, arguments: "#12") == "Draft a PR for #12.")
    }

    @Test("arguments split like a shell's")
    func splitting() {
        #expect(CodexPrompts.shellSplit(#"a "b c" 'd e' f\ g KEY="x y""#) == ["a", "b c", "d e", "f g", "KEY=x y"])
        #expect(CodexPrompts.shellSplit("   ").isEmpty)
        #expect(CodexPrompts.shellSplit(#""""#) == [""])
    }

    // MARK: - What a built-in command prints

    @Test("a built-in's wrapped output becomes the reply, and other user text does not")
    func localCommandOutput() throws {
        func events(_ content: String) -> [AgentEvent] {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: [
                "type": "user", "message": ["role": "user", "content": content]]), as: UTF8.self)
            return ClaudeAdapter().normalise(.stdout(line))
        }
        #expect(events("<local-command-stdout>Compacted </local-command-stdout>") == [.text("Compacted")])
        #expect(events("<local-command-stderr>git &lt;command&gt; failed</local-command-stderr>")
                == [.text("git <command> failed")])
        #expect(events("This session is being continued from a previous conversation.").isEmpty)
        #expect(events("<local-command-stdout></local-command-stdout>").isEmpty)
    }
}
