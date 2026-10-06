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

    @Test("file types are read leniently and kept through the store")
    func fileTypes() throws {
        #expect(FolderWatch.fileTypes(from: "pdf, PNG .jpg;*.pdf") == ["pdf", "png", "jpg"])
        #expect(FolderWatch.fileTypes(from: "  ").isEmpty)

        let store = try Store.inMemory()
        let bot = BotRecord(name: "Sorter", engine: "claude")
        try store.save(bot)
        let watch = FolderWatch(botID: bot.id, name: "Invoices", prompt: "File these.",
                                path: "/Users/x/Downloads", fileTypes: ["pdf", "png"])
        try store.save(watch)
        #expect(try store.folderWatches() == [watch])
    }

    @Test("only the chosen file types set a watch off; none chosen means every file")
    func matchesTypes() {
        let some = FolderWatch(botID: "b", name: "n", prompt: "p", path: "/w", fileTypes: ["pdf"])
        #expect(some.matches("/w/Invoice.PDF"))
        #expect(!some.matches("/w/photo.png"))
        #expect(!some.matches("/w/README"))
        let every = FolderWatch(botID: "b", name: "n", prompt: "p", path: "/w")
        #expect(every.matches("/w/anything.bin"))
        #expect(every.matches("/w/README"))
    }
}
