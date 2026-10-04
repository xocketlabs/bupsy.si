import Testing
@testable import BupsyKit

@Suite("Queued messages")
struct QueuedMessagesTests {
    @Test("one queued message goes as itself; several go together, in order")
    func joins() {
        #expect(QueuedMessages.prompt(["Make it rhyme."]) == "Make it rhyme.")
        #expect(QueuedMessages.prompt(["Make it rhyme.", "  ", "Add a title."])
                == "I sent these while you were working:\n\n- Make it rhyme.\n- Add a title.")
        #expect(QueuedMessages.prompt([" "]) == nil)
    }
}
