import Testing
@testable import BupsyKit

@Suite("Replying to a message")
struct ReplyTests {
    @Test("a reply round-trips: compose then split gives back the parts")
    func roundTrip() {
        let sent = Reply.compose(quoting: "Hey! What can I look into for you?", from: "Scout",
                                 message: "what does this mean?")
        #expect(sent == "> Scout: Hey! What can I look into for you?\n\nwhat does this mean?")

        let parts = Reply.split(sent)
        #expect(parts.author == "Scout")
        #expect(parts.quote == "Hey! What can I look into for you?")
        #expect(parts.body == "what does this mean?")
    }

    /// A multi-line answer is flattened into one quote line, so the stored message still splits
    /// cleanly and the bubble shows a one-line snippet rather than a wall.
    @Test("a multi-line message is quoted on one line")
    func multiLineQuote() {
        let sent = Reply.compose(quoting: "line one\nline two", from: "Builder", message: "ok")
        #expect(Reply.split(sent).quote == "line one line two")
    }

    /// Quoting must not re-send a long answer in full on every reply.
    @Test("long quotes are clipped")
    func longQuotesAreClipped() {
        let long = String(repeating: "a", count: 2000)
        let quote = Reply.split(Reply.compose(quoting: long, from: "X", message: "y")).quote ?? ""
        #expect(quote.count == Reply.quoteLimit + 1)
        #expect(quote.hasSuffix("…"))
    }

    /// Plain messages, and messages that merely contain a quote further down, are not replies.
    @Test("an ordinary message is not mistaken for a reply")
    func plainMessages() {
        #expect(Reply.split("hello").quote == nil)
        #expect(Reply.split("hello").body == "hello")
        let quotingSomething = "look at this:\n> some line\n\nthoughts?"
        #expect(Reply.split(quotingSomething).quote == nil)
        #expect(Reply.split(quotingSomething).body == quotingSomething)
    }
}
