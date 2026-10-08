import Testing
@testable import BupsyKit

@Suite("Plain previews")
struct PlainPreviewTests {
    @Test("markdown is reduced to its words")
    func strips() {
        #expect(PlainPreview.of("Created `hello.txt` containing **hi**.") == "Created hello.txt containing hi.")
        #expect(PlainPreview.of("## Plan\n- step *one*\n- see [docs](https://x.y)") == "Plan step one see docs")
        #expect(PlainPreview.of("Here:\n```swift\nlet x = 1\n```\nDone") == "Here: Done")
        #expect(PlainPreview.of("2 * 3 = 6") == "2 * 3 = 6")
    }

    @Test("a long reply is flattened only as far as a preview line needs")
    func stopsEarly() {
        let long = (1...500).map { "Line **\($0)** of the report." }.joined(separator: "\n")
        let preview = PlainPreview.of(long)
        #expect(preview.hasPrefix("Line 1 of the report. Line 2 of the report."))
        #expect(preview.count < PlainPreview.enough + 40)
    }
}

@Suite("Replies read aloud")
struct SpokenTextTests {
    @Test("words without marks, code and tables named rather than read")
    func spoken() {
        let reply = """
            ## Done
            I pushed **the fix** and checked `main`.

            - Tests pass
            - Docs updated!

            ```sh
            git push origin main
            ```

            | a | b |
            |---|---|
            | 1 | 2 |
            | 3 | 4 |
            """
        #expect(SpokenText.from(reply) == """
            Done.
            I pushed the fix and checked main.
            Tests pass.
            Docs updated!
            There's some code here, on screen.
            There's a table with 2 rows, on screen.
            """)
    }
}
