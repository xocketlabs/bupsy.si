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

    /// A folder whose name merely starts with the bot's folder or home is a different place, and
    /// shortening it would show a path that does not exist.
    @Test("only whole path components are shortened")
    func respectsPathBoundaries() {
        let work = "/x/proj"
        #expect(PathShortener.shorten("ls /x/proj-other", workingDirectory: work, home: "/Users/v") == "ls /x/proj-other")
        #expect(PathShortener.shorten("ls /Users/vanshika/a", workingDirectory: nil, home: "/Users/vansh")
                == "ls /Users/vanshika/a")
        #expect(PathShortener.shorten("cd /x/proj && ls /x/proj/src", workingDirectory: work, home: "/Users/v")
                == "cd . && ls src")
        #expect(PathShortener.shorten("cat '/Users/vansh' /Users/vansh", workingDirectory: nil, home: "/Users/vansh")
                == "cat '~' ~")
        #expect(PathShortener.shorten("ls /private/tmp/w/a", workingDirectory: "/tmp/w", home: "/Users/v") == "ls a")
    }
}
