import Testing
@testable import BupsyKit

@Suite("Folder watches")
struct FolderWatchTests {
    @Test("round-trips through the store, apart from routines")
    func storeRoundTrip() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Sorter", engine: "claude")
        try store.save(bot)
        let watch = FolderWatch(botID: bot.id, name: "New downloads", prompt: "File these.", path: "/Users/x/Downloads")
        try store.save(watch)
        #expect(try store.folderWatches() == [watch])
        #expect(try store.routines().isEmpty)
        try store.deleteTrigger(id: watch.id)
        #expect(try store.folderWatches().isEmpty)
    }

    @Test("the bot is told what changed, relative to the folder, capped")
    func prompt() {
        let watch = FolderWatch(botID: "b", name: "n", prompt: "Sort these.", path: "/w")
        let text = watch.prompt(for: ["/w/b.pdf", "/w/a.png", "/w/a.png"])
        #expect(text == "Sort these.\n\n(Files changed in /w:\n- a.png\n- b.pdf)")
        let many = watch.prompt(for: (0..<25).map { "/w/f\($0)" }, limit: 3)
        #expect(many.contains("…and 22 more"))
    }
}
