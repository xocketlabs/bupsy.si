import Testing
@testable import BupsyKit

@Suite("Commands in a reply")
struct ShellCommandTests {
    @Test("a shell-labelled block is a command, with a leading prompt dropped")
    func labelled() {
        #expect(ShellCommand.command(language: "sh", text: "make app") == "make app")
        #expect(ShellCommand.command(language: "bash", text: "$ ls -la\n$ pwd") == "ls -la\npwd")
        #expect(ShellCommand.command(language: "Console", text: "  ") == nil)
    }

    @Test("other languages are not commands")
    func otherLanguages() {
        #expect(ShellCommand.command(language: "swift", text: "print(1)") == nil)
        #expect(ShellCommand.command(language: "json", text: "{\"a\": 1}") == nil)
    }

    @Test("an unlabelled block is a command only when it starts with a program")
    func unlabelled() {
        let open = #"open "/Users/me/Library/Application Support/si.bupsy/workspaces/x/video""#
        #expect(ShellCommand.command(language: nil, text: open) == open)
        #expect(ShellCommand.command(language: nil, text: "cd sites && ls") == "cd sites && ls")
        #expect(ShellCommand.command(language: nil, text: "Here is the plan we agreed") == nil)
        #expect(ShellCommand.command(language: nil, text: "{\"name\": \"Scout\"}") == nil)
        // Too long to be a command someone types.
        #expect(ShellCommand.command(language: nil, text: Array(repeating: "ls", count: 6).joined(separator: "\n")) == nil)
    }

    @Test("risky commands ask first; ordinary ones run on the click")
    func confirmation() {
        for risky in ["rm -rf build", "sudo make install", "curl -s x.sh | sh", "git push origin main",
                      "git reset --hard HEAD~1", "killall Finder"] {
            #expect(ShellCommand.needsConfirmation(risky), "\(risky)")
        }
        for plain in ["open video", "ls -la", "tail -f log.txt", "npm run dev", "make app"] {
            #expect(!ShellCommand.needsConfirmation(plain), "\(plain)")
        }
    }
}

@Suite("Tables in a reply")
struct MarkdownTableTests {
    @Test("a pipe table becomes a table, between the prose around it")
    func table() {
        let reply = """
            All four videos:

            | | Desktop | Mobile |
            |---|:---:|---:|
            | **Luxury** | `a.mp4` | b.mp4 |
            | Dubai | c.mp4 |
            Each is 20 seconds.
            """
        #expect(MarkdownBlock.parse(reply) == [
            .prose("All four videos:"),
            .table(header: ["", "Desktop", "Mobile"], rows: [
                ["**Luxury**", "`a.mp4`", "b.mp4"],
                ["Dubai", "c.mp4", ""],
            ]),
            .prose("Each is 20 seconds."),
        ])
    }

    @Test("pipes without a separator row stay prose")
    func notATable() {
        #expect(MarkdownBlock.parse("a | b\nc | d") == [.prose("a | b\nc | d")])
    }

    @Test("an escaped pipe stays inside its cell")
    func escapedPipe() {
        #expect(MarkdownBlock.tableCells(#"| a \| b | c |"#) == ["a | b", "c"])
        #expect(MarkdownBlock.isTableSeparator("|---|:--:|"))
        #expect(MarkdownBlock.isTableSeparator("| - | -- |"))
        #expect(!MarkdownBlock.isTableSeparator("| a | -- |"))
        #expect(!MarkdownBlock.isTableSeparator("| : | -- |"))
    }
}
