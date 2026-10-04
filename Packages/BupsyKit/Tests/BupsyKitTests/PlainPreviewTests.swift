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
}
