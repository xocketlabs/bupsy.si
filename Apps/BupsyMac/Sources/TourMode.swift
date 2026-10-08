#if DEBUG
import AppKit
import BupsyKit
import SwiftUI

/// Debug-only: walks every main screen and saves a picture of each, then quits.
///
/// Run with `--tour` and `BUPSY_TOUR_OUT=/some/folder` (plus `BUPSY_HOME` pointing at a home with
/// demo data, so no real conversation is ever pictured). It drives the UI through these observable
/// hooks rather than synthetic clicks, so it needs no focus and works behind other windows — up to
/// date screenshots for docs without anyone at the keyboard.
@MainActor
enum TourMode {
    static var isOn: Bool { CommandLine.arguments.contains("--tour") }

    struct Step { let name: String; let appearance: AppModel.Appearance; let apply: (AppModel) -> Void }

    static func run(model: AppModel) async {
        guard let out = ProcessInfo.processInfo.environment["BUPSY_TOUR_OUT"] else { return }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bot = model.bots.first { !$0.hidden }
        let group = model.groups.first
        func reset(_ m: AppModel) {
            m.tourPalette = nil; m.tourDetails = nil; m.tourSheet = nil
        }
        var steps: [Step] = []
        for look in [AppModel.Appearance.light, .dark] {
            let suffix = look == .light ? "light" : "dark"
            steps += [
                Step(name: "chat-\(suffix)", appearance: look) { m in reset(m); if let bot { m.tourDestination = .bot(bot.id) } },
                Step(name: "panel-details-\(suffix)", appearance: look) { m in reset(m); m.tourDetails = .details },
                Step(name: "palette-\(suffix)", appearance: look) { m in reset(m); m.tourPalette = false },
            ]
            if let group {
                steps.append(Step(name: "group-\(suffix)", appearance: look) { m in reset(m); m.tourDestination = .group(group.id) })
            }
        }
        steps += [
            Step(name: "panel-activity", appearance: .light) { m in reset(m); if let bot { m.tourDestination = .bot(bot.id) }; m.tourDetails = .activity },
            Step(name: "limits", appearance: .light) { m in
                reset(m)
                if let bot {
                    let thread = m.thread(for: bot.id)
                    thread.latestUsage = Usage(inputTokens: 84_000, outputTokens: 2_100, cachedInputTokens: 61_000,
                        context: ContextUse(cachedTokens: 61_000, newTokens: 23_000, replyTokens: 2_100, window: 200_000))
                    thread.latestLimits = RateLimit(windows: [
                        "five_hour": .init(utilization: 0.38, resetsAt: Date().addingTimeInterval(9_960)),
                        "seven_day": .init(utilization: 0.21, resetsAt: Date().addingTimeInterval(4 * 86_400)),
                        "seven_day_opus": .init(utilization: 0.05, resetsAt: Date().addingTimeInterval(4 * 86_400)),
                    ])
                }
                m.tourDetails = .activity
            },
            Step(name: "thinking", appearance: .light) { m in
                reset(m)
                if let bot {
                    let thread = m.thread(for: bot.id)
                    thread.entries.append(TranscriptEntry(kind: .userMessage("Find the three best Swift testing libraries.")))
                    thread.entries.append(TranscriptEntry(kind: .tool(name: "WebSearch",
                        arguments: #"{"query":"best Swift testing libraries 2026"}"#, result: nil, failed: false)))
                    thread.isRunning = true
                }
            },
            // A reply with every kind of prose in it, selected whole: one drag has to cross the
            // paragraphs, the heading and the list, and stop only at the code block.
            Step(name: "reply-selected", appearance: .light) { m in
                reset(m)
                guard let bot else { return }
                m.tourDestination = .bot(bot.id)
                let thread = m.thread(for: bot.id)
                thread.isRunning = false
                thread.entries.append(TranscriptEntry(kind: .userMessage("What changed in the release?")))
                thread.entries.append(TranscriptEntry(kind: .assistantText("""
                    Three things shipped, and **one** needs you. I checked with @\(bot.name) first.

                    ## What changed
                    - Bots can drive *your own* Chrome when you allow it
                    - Replies select across paragraphs, so a long answer copies whole, and a long \
                    list item wraps under its own text instead of under the bullet
                      - Nested items step in
                    1. Run `make app`
                    2. Open a [release note](https://github.com/xocketlabs/bupsy.si)

                    | | Desktop | Mobile |
                    |---|---|---|
                    | **Luxury** | `desktop.mp4` | mobile.mp4 |
                    | Dubai | desktop-dubai.mp4 | mobile-dubai.mp4 |

                    ```sh
                    make app
                    ```

                    That's it.
                    """)))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    func all(in view: NSView) -> [ReplyTextView] {
                        if let text = view as? ReplyTextView { return [text] }
                        return view.subviews.flatMap(all(in:))
                    }
                    for window in NSApp.windows {
                        // The longest is the run before the code block.
                        guard let root = window.contentView,
                              let text = all(in: root).max(by: { $0.string.count < $1.string.count })
                        else { continue }
                        window.makeFirstResponder(text)
                        text.selectAll(nil)
                    }
                }
            },
            // The same reply in dark, for the bubbles' contrast.
            Step(name: "reply-dark", appearance: .dark) { m in
                reset(m)
                guard let bot else { return }
                m.tourDestination = .bot(bot.id)
                let thread = m.thread(for: bot.id)
                thread.isRunning = false
                thread.entries.append(TranscriptEntry(kind: .userMessage("What changed in the release?")))
                thread.entries.append(TranscriptEntry(kind: .assistantText("""
                    Three things shipped, and **one** needs you. I checked with @\(bot.name) first.

                    ## What changed
                    - Bots can drive *your own* Chrome when you allow it
                    - Replies select across paragraphs, so a long answer copies whole, and a long \
                    list item wraps under its own text instead of under the bullet
                      - Nested items step in
                    1. Run `make app`
                    2. Open a [release note](https://github.com/xocketlabs/bupsy.si)

                    | | Desktop | Mobile |
                    |---|---|---|
                    | **Luxury** | `desktop.mp4` | mobile.mp4 |
                    | Dubai | desktop-dubai.mp4 | mobile-dubai.mp4 |

                    ```sh
                    make app
                    ```

                    That's it.
                    """)))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    func all(in view: NSView) -> [ReplyTextView] {
                        if let text = view as? ReplyTextView { return [text] }
                        return view.subviews.flatMap(all(in:))
                    }
                    for window in NSApp.windows {
                        // The longest is the run before the code block.
                        guard let root = window.contentView,
                              let text = all(in: root).max(by: { $0.string.count < $1.string.count })
                        else { continue }
                        window.makeFirstResponder(text)
                        text.selectAll(nil)
                    }
                }
            },
            // A bot from a linked Mac, when one is linked: the sidebar mark and its chat.
            Step(name: "remote-chat", appearance: .dark) { m in
                reset(m)
                if let remote = m.linked.remoteBots.first { m.tourDestination = .bot(remote.id) }
            },
            // A conversation carried over from Claude Code, when asked for: the newest one, copied.
            Step(name: "claude-import", appearance: .dark) { m in
                reset(m)
                guard ProcessInfo.processInfo.environment["BUPSY_TOUR_CLAUDE_IMPORT"] != nil else { return }
                let start = Date()
                let sessions = ClaudeSessions.recent(excluding: (try? m.store?.knownProviderConversationIDs()) ?? [],
                                                     excludingFolder: ProcessInfo.processInfo.environment["BUPSY_TOUR_BOT_FOLDERS"] ?? AppModel.workspacesDirectory.path)
                FileHandle.standardError.write("CLAUDE_LIST \(sessions.count) sessions in \(Int(Date().timeIntervalSince(start) * 1000))ms; sources \(Set(sessions.map(\.source.rawValue)))\n".data(using: .utf8)!)
                guard let session = sessions.first(where: { $0.source == .vscode }) ?? sessions.first,
                      let bot = m.continueClaudeSession(session, as: .copy) else { return }
                let thread = m.thread(for: bot.id)
                FileHandle.standardError.write("CLAUDE_IMPORT bot=\(bot.name) folder=\(bot.workdir ?? "-") private=\(!bot.sharedWithDevices) entries=\(thread.entries.count) conversation=\(thread.conversationID?.rawValue == session.id) fork=\(m.shouldFork(bot.id))\n".data(using: .utf8)!)
                m.tourDestination = .bot(bot.id)
            },
            Step(name: "panel-files", appearance: .light) { m in reset(m); m.tourDetails = .files },
            Step(name: "search", appearance: .light) { m in reset(m); m.tourDetails = nil; m.tourPalette = true },
            Step(name: "apps", appearance: .light) { m in reset(m); m.tourDestination = .connectors },
            Step(name: "usage", appearance: .light) { m in reset(m); m.tourDestination = .usage },
            Step(name: "machines", appearance: .light) { m in reset(m); m.tourDestination = .machines },
            Step(name: "permissions", appearance: .light) { m in reset(m); m.tourDestination = .permissions },
            Step(name: "new-bot", appearance: .light) { m in reset(m); if let bot { m.tourDestination = .bot(bot.id) }; m.tourSheet = "newBot" },
            Step(name: "new-group", appearance: .light) { m in reset(m); m.tourSheet = "newGroup" },
            Step(name: "new-routine", appearance: .light) { m in reset(m); m.tourSheet = "newRoutine" },
            Step(name: "edit-bot", appearance: .light) { m in reset(m); m.tourSheet = "editBot" },
            Step(name: "onboarding", appearance: .light) { m in reset(m); m.tourSheet = "onboarding" },
        ]

        try? await Task.sleep(for: .seconds(3))
        for step in steps {
            model.appearance = step.appearance
            step.apply(model)
            try? await Task.sleep(for: .seconds(1.8))
            snapshot(named: step.name, into: dir)
        }
        reset(model)
        NSApp.terminate(nil)
    }

    /// Every visible window of this app, each to its own file — sheets are their own windows.
    private static func snapshot(named name: String, into dir: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 150 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let file = dir.appendingPathComponent(index == 0 ? "\(name).png" : "\(name)-sheet.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
}
#endif
