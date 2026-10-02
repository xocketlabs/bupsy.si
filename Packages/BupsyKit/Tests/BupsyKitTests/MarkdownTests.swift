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
}
