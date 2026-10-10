#if DEBUG
import AppKit
import BupsyKit
import Foundation

/// Debug-only: starts a demo (see `DemoMode`), and with `--autoplay` plays the whole story by
/// itself, through the same observable hooks the tour uses, so a take needs nobody at the
/// keyboard and comes out the same every time.
///
/// The story, about 31 seconds: a calm hold on the lead's chat; a new bot made from the start
/// palette, which says hi; its job typed in; it names itself Scout, searches, and hands the
/// findings to Writer, who starts on its own and drafts a post; then the lead's "Daily brief"
/// routine is run from its page and the lead reads the team's chats and posts the brief; a hold.
///
/// For recording, `BUPSY_DEMO_START_FILE` holds the story until that file exists (the recorder
/// is rolling by then) and `BUPSY_DEMO_DONE_FILE` is written when the last hold ends.
/// `BUPSY_DEMO_SNAPSHOTS=<folder>` saves a picture of the window every half second, to check a
/// take frame by frame without recording the screen.
@MainActor
enum DemoAutoplay {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Everything the demo does at launch in place of the real start-up: no auth probes, no
    /// remote access, no linked Macs, no routine timer, no Notification Centre.
    static func launch(model: AppModel) async {
        model.startOutbox()
        await model.refreshEngineStatus()
        // The window may not be on screen yet when this starts.
        for _ in 0..<100 {
            if DemoMode.prepareWindow() { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The first chat was laid out before the window took its size; opening it again puts it
        // at its latest message, as it would be after any launch.
        if let lead = model.bots.first(where: { $0.id.rawValue == DemoWorld.leadID }),
           let other = model.bots.first(where: { $0.id != lead.id }) {
            model.open(other.id)
            try? await Task.sleep(for: .milliseconds(300))
            model.open(lead.id)
        }
        guard DemoMode.autoplay else { return }
        await waitForCue()
        let snapshots = startSnapshots()
        await play(model)
        snapshots?.cancel()
        if let done = environment["BUPSY_DEMO_DONE_FILE"] {
            try? "done\n".write(toFile: done, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - The story

    static func play(_ model: AppModel) async {
        guard let lead = model.bots.first(where: { $0.id.rawValue == DemoWorld.leadID }),
              let writer = model.bots.first(where: { $0.id.rawValue == DemoWorld.writerID }),
              let routine = model.routines.first(where: { $0.id == DemoWorld.routineID })
        else {
            FileHandle.standardError.write(Data("bupsy demo: this home has no demo roster; use a fresh BUPSY_HOME\n".utf8))
            return
        }
        model.open(lead.id)
        await pause(2.0)

        // A new bot, from the plus: the palette, "New bot", and it says hi.
        model.tourPalette = false
        await pause(1.3)
        model.tourPalette = nil
        guard let scoutID = model.quickCreateBot() else { return }
        if let scout = model.bots.first(where: { $0.id == scoutID }) {
            // Its own face every take, and filed with the team, where the camera can see it.
            model.setAvatar(scout, shape: DemoWorld.newBotShape, colour: DemoWorld.newBotColour)
            model.setFolder(scout, "Launch")
        }
        model.open(scoutID)
        await until { !model.isRunning(scoutID) }
        await pause(0.9)

        // Its job, typed in. It names itself, researches, and hands over to Writer.
        await type(DemoScript.job, into: model)
        await pause(0.45)
        model.tourDraft = ""
        if let scout = model.bots.first(where: { $0.id == scoutID }) { model.send(DemoScript.job, to: scout) }
        // It proposes its own job, which waits for a yes.
        await until(limit: 6) { !model.pendingJobChanges.isEmpty }
        await pause(1.5)
        if let change = model.pendingJobChanges.first { model.decideJobChange(change, allow: true) }
        await until { model.isRunning(writer.id) }
        await pause(1.6)

        // Writer picks it up by itself.
        model.open(writer.id)
        await until { !model.isRunning(writer.id) }
        await pause(2.0)

        // The lead's morning routine, run from its page, then the brief arriving in the chat.
        model.open(lead.id)
        await pause(0.7)
        model.tourRoutine = routine.id
        await pause(1.8)
        model.runRoutineNow(routine)
        await pause(1.7)
        model.tourRoutine = nil
        await until { !model.isRunning(lead.id) }
        await pause(3.4)
    }

    /// Into the open bot's message box, a character at a time.
    private static func type(_ text: String, into model: AppModel) async {
        var typed = ""
        for character in text {
            typed.append(character)
            model.tourDraft = typed
            await pause(character == " " ? 0.06 : 0.038)
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Waits for something to become true, checking often, for at most `limit` seconds, so a
    /// take that goes wrong ends instead of hanging the recorder.
    private static func until(limit: Double = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(limit)
        while !condition() && Date() < deadline { await pause(0.05) }
    }

    private static func waitForCue() async {
        guard let cue = environment["BUPSY_DEMO_START_FILE"] else { await pause(1); return }
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: cue) && Date() < deadline { await pause(0.05) }
    }

    // MARK: - Checking a take

    private static func startSnapshots() -> Task<Void, Never>? {
        guard let folder = environment["BUPSY_DEMO_SNAPSHOTS"] else { return nil }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = Date()
        return Task { @MainActor in
            var index = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                snapshot(to: dir.appendingPathComponent(String(format: "%03d-%05.1fs.png", index, elapsed)))
                index += 1
                await pause(0.5)
            }
        }
    }

    /// The window, and any sheet over it to a file of its own (sheets are windows of their own).
    private static func snapshot(to file: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = index == 0 ? file : file.deletingPathExtension().appendingPathExtension("sheet.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: name)
        }
    }
}
#endif
