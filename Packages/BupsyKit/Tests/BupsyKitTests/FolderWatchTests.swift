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

    /// A watch on a folder that changes on its own every few seconds runs again after every run.
    @Test("refuses folders that would keep setting themselves off")
    func refusesBusyFolders() {
        let home = "/Users/x", data = "/Users/x/Library/Application Support/si.bupsy"
        func refused(_ folder: String) -> Bool {
            FolderWatch.refusal(forFolder: folder, home: home, appData: data) != nil
        }
        #expect(refused("/"))
        #expect(refused("/Users"))
        #expect(refused("/Users/x"))
        #expect(refused("/Users/x/"))
        #expect(refused("/Users/x/Library"))
        #expect(refused(data + "/workspaces/ABC"))
        #expect(refused("/Users/x/.claude"))
        #expect(refused("/Users/x/.codex/sessions"))
        #expect(refused("/Users/x/.ollama/logs"), "a local model's runtime logs every run")
        #expect(!refused("/Users/x/Downloads"))
        #expect(!refused("/Users/x/Library/Mobile Documents/com~apple~CloudDocs"))
        #expect(!refused("/Users/xavier"), "a different home that merely starts the same")
    }

    @Test("hidden paths and the agents' own folders never set a watch off")
    func ignoresNoise() {
        let home = "/Users/x", data = "/Users/x/Library/Application Support/si.bupsy"
        func ignored(_ changed: String, in root: String) -> Bool {
            FolderWatch.isIgnored(changed, watching: root, home: home, appData: data)
        }
        #expect(ignored("/w/.DS_Store", in: "/w"))
        #expect(ignored("/w/.git/index", in: "/w"))
        #expect(ignored("/w/src/.cache/a.pdf", in: "/w"))
        #expect(!ignored("/w/src/a.pdf", in: "/w"))
        // A watch chosen inside a hidden folder still sees what is in it.
        #expect(!ignored("/Users/x/.config/app/a.json", in: "/Users/x/.config/app"))

        #expect(ignored("/Users/x/Library/Logs/a.log", in: "/Users/x/Documents/.."))
        #expect(ignored("/Users/x/.claude/projects/a.jsonl", in: "/Users"))
        #expect(ignored(data + "/workspaces/ABC/out.txt", in: "/Users/x/Library/Application Support"))
        // Picked inside ~/Library on purpose: iCloud Drive is watched normally.
        let icloud = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(!ignored(icloud + "/Scans/a.pdf", in: icloud))
    }

    @Test("a refused folder never matches, even if it was saved before the check")
    func refusedNeverMatches() {
        let everything = FolderWatch(botID: "b", name: "n", prompt: "p", path: "/")
        #expect(!everything.matches("/Users/somebody/Downloads/a.pdf"))
        let hidden = FolderWatch(botID: "b", name: "n", prompt: "p", path: "/w")
        #expect(!hidden.matches("/w/.git/HEAD"))
    }
}
