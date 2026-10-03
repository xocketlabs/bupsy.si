import Foundation
import Testing
@testable import BupsyKit

@Suite("Markdown blocks")
struct MarkdownTests {
    @Test("separates prose from fenced code")
    func separates() {
        let blocks = MarkdownBlock.parse("""
            Here is the fix.

            ```swift
            let x = 1
            print(x)
            ```

            That should do it.
            """)

        #expect(blocks.count == 3)
        #expect(blocks[0] == .prose("Here is the fix."))
        #expect(blocks[1] == .code(language: "swift", text: "let x = 1\nprint(x)"))
        #expect(blocks[2] == .prose("That should do it."))
    }

    /// The bug this exists to fix: newlines inside code must survive, because a diff or a shell
    /// script collapsed onto one line is unreadable at exactly the moment it matters.
    @Test("keeps the line breaks inside code")
    func keepsLineBreaks() {
        let blocks = MarkdownBlock.parse("```\na\nb\nc\n```")
        #expect(blocks == [.code(language: nil, text: "a\nb\nc")])
    }

    /// Replies stream in, so a fence is often still open when the view renders. Holding the
    /// block back until it closes would make a long answer appear to stall.
    @Test("renders an unclosed fence rather than waiting for it to close")
    func handlesStreamingFence() {
        let blocks = MarkdownBlock.parse("Working on it.\n\n```python\nimport os\nprint(")
        #expect(blocks.count == 2)
        #expect(blocks[1] == .code(language: "python", text: "import os\nprint("))
    }

    @Test("a fence with no language is still code")
    func noLanguage() {
        #expect(MarkdownBlock.parse("```\nls -la\n```")
            == [.code(language: nil, text: "ls -la")])
    }

    @Test("plain prose stays one block")
    func plainProse() {
        #expect(MarkdownBlock.parse("Just a sentence.") == [.prose("Just a sentence.")])
        #expect(MarkdownBlock.parse("") == [])
    }

    @Test("handles several code blocks in one reply")
    func multipleBlocks() {
        let blocks = MarkdownBlock.parse("""
            First:
            ```sh
            one
            ```
            Then:
            ```sh
            two
            ```
            """)
        let code = blocks.compactMap { if case .code(_, let t) = $0 { t } else { nil } }
        #expect(code == ["one", "two"])
    }

    // MARK: - Lists

    /// Captured from a real reply, which rendered every item as a line starting with a literal
    /// hyphen. The exact shape that broke.
    @Test("a bulleted list becomes one bullets block")
    func bulletsFromARealReply() {
        let blocks = MarkdownBlock.parse("""
            No repository or file was provided, so here is a minimal Swift value type.

            - `struct` chosen over `class` — value semantics.
            - Both properties are `let`.
            - `Codable` and `Equatable` come free.
            """)
        #expect(blocks.count == 2)
        #expect(blocks.last == .bullets([
            "`struct` chosen over `class` — value semantics.",
            "Both properties are `let`.",
            "`Codable` and `Equatable` come free.",
        ]))
    }

    /// A hyphen in a sentence is a dash, and a leading minus is a number. Neither is a list.
    @Test("a hyphen without a space after it stays prose")
    func dashesAreNotBullets() {
        #expect(MarkdownBlock.parse("-5 degrees overnight") == [.prose("-5 degrees overnight")])
        #expect(MarkdownBlock.parse("--verbose is required") == [.prose("--verbose is required")])
    }

    /// Models routinely leave a blank line between items. Splitting there would turn one list
    /// into several stacked lists with gaps.
    @Test("blank lines between items do not break a list")
    func looseListsStayTogether() {
        let blocks = MarkdownBlock.parse("- one\n\n- two\n\n- three")
        #expect(blocks == [.bullets(["one", "two", "three"])])
    }

    /// Order is preserved: prose, list, prose, code. Hoisting lists to the end — the easy bug in
    /// a two-pass approach — would reorder an answer.
    @Test("lists keep their place between prose and code")
    func orderIsPreserved() {
        let blocks = MarkdownBlock.parse("""
            Before.
            - item
            After.
            ```swift
            let x = 1
            ```
            """)
        #expect(blocks == [
            .prose("Before."),
            .bullets(["item"]),
            .prose("After."),
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    /// A `- ` inside a fence is code, not a list. A diff is the case that matters.
    @Test("hyphens inside a code fence are left alone")
    func codeIsNotParsedAsAList() {
        let blocks = MarkdownBlock.parse("```diff\n- old line\n+ new line\n```")
        #expect(blocks == [.code(language: "diff", text: "- old line\n+ new line")])
    }
}
