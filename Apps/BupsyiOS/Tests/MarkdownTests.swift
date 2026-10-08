import Foundation
import Testing
@testable import Bupsy

@Suite("Markdown blocks")
struct MarkdownTests {
    @Test("paragraphs, headings, lists and code come apart")
    func blocks() {
        let source = """
            # Plan
            First **bold** line
            second line

            - one
            - two
              wrapped
              - nested
            1. first
            ```swift
            let x = 1

            print(x)
            ```
            > quoted
            ---
            | a | b |
            |---|---|
            | 1 | 2 |
            """
        #expect(MarkdownBlock.parse(source) == [
            .heading("Plan"),
            .paragraph("First **bold** line\nsecond line"),
            .list([
                .init(marker: "•", text: "one", depth: 0),
                .init(marker: "•", text: "two wrapped", depth: 0),
                .init(marker: "•", text: "nested", depth: 1),
                .init(marker: "1.", text: "first", depth: 0),
            ]),
            .code("let x = 1\n\nprint(x)"),
            .quote("quoted"),
            .rule,
            .table(["| a | b |", "| 1 | 2 |"]),
        ])
    }

    @Test("a code block the bot never closed runs to the end")
    func unclosed() {
        #expect(MarkdownBlock.parse("Look:\n```\nls -la") == [.paragraph("Look:"), .code("ls -la")])
    }

    @Test("inline markdown is parsed down to its text")
    func inline() {
        let parsed = MarkdownBlock.inline("Run `npm test` **now**")
        #expect(String(parsed.characters) == "Run npm test now")
    }
}
