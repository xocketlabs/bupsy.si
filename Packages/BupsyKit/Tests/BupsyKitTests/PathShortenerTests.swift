import Testing
@testable import BupsyKit

@Suite("Readable approvals")
struct PathShortenerTests {
    @Test("the bot's own folder disappears and home becomes ~")
    func shortens() {
        let work = "/private/tmp/x/workspaces/ABC"
        #expect(PathShortener.shorten("printf 'hi' > /private/tmp/x/workspaces/ABC/hello.txt && cat /tmp/x/workspaces/ABC/hello.txt",
                                      workingDirectory: work, home: "/Users/v")
                == "printf 'hi' > hello.txt && cat hello.txt")
        #expect(PathShortener.shorten("ls /Users/v/Desktop", workingDirectory: work, home: "/Users/v") == "ls ~/Desktop")
        #expect(PathShortener.shorten("cd /private/tmp/x/workspaces/ABC", workingDirectory: work, home: "/Users/v") == "cd .")
    }
}
