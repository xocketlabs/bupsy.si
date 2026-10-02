import BupsyKit
import SwiftUI

/// The menu bar item.
///
/// This is what makes an always-on app feel always-on. Bots work for minutes at a time and
/// occasionally stop to ask something; having to open a window to find out is the friction that
/// stops people leaving the app running at all. From up here you can see who is busy, see what is
/// waiting, and answer it — without the window ever coming forward.
///
/// The icon itself carries the state, because the point is to glance rather than click.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = model.attentionItems
        let busy = model.bots.filter { model.isRunning($0.id) }

        if !waiting.isEmpty {
            Section("Waiting on you") {
                ForEach(waiting.prefix(5)) { item in
                    MenuBarApproval(item: item)
                }
            }
            Divider()
        }

        if busy.isEmpty {
            Text(model.bots.isEmpty ? "No bots yet" : "Nothing running")
        } else {
            Section("Working") {
                ForEach(busy) { bot in
                    Button("\(bot.name) — stop") { model.stop(bot.id) }
                }
            }
        }

        Divider()

        // Every bot, so a message can be started without the window. Opening the app to say one
        // sentence is the most common thing someone does, and the slowest.
        ForEach(model.bots) { bot in
            Button(bot.name) {
                model.selectedBotID = bot.id
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()
        Button("Stop everything") { model.stopEverything() }
            .disabled(busy.isEmpty)
        Button("Open bupsy") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// An approval answered from the menu bar.
///
/// Both answers are offered here rather than only a link into the app. If a decision can be made
/// from a glance, making someone open a window to make it is the difference between a gate people
/// use and a gate people switch off.
struct MenuBarApproval: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    private var bot: Bot? { model.bots.first { $0.name == item.botName } }

    var body: some View {
        if item.kind == .approval, let bot, let approval = pending(for: bot) {
            Menu("\(item.botName): \(short(item.detail.isEmpty ? item.title : item.detail))") {
                Button("Allow") { model.decide(approval, allow: true, for: bot) }
                Button("Deny") { model.decide(approval, allow: false, for: bot) }
            }
        } else {
            Button("\(item.botName): \(short(item.title))") {
                model.selectedBotID = bot?.id
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func pending(for bot: Bot) -> PendingApproval? {
        model.thread(for: bot.id).entries.compactMap {
            if case .approval(let approval) = $0.kind, approval.id == item.id { return approval }
            return nil
        }.first
    }

    /// Menu items have no room to wrap, and a truncated command is still recognisable.
    private func short(_ text: String, limit: Int = 44) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }
}

/// The icon, which is the whole point: state without opening anything.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.attentionItems.count
        let busy = model.bots.contains { model.isRunning($0.id) }

        if waiting > 0 {
            // A count, because "something needs you" is useless without "how much".
            Label("\(waiting)", systemImage: "hand.raised.fill")
        } else if busy {
            Image(systemName: "circle.dotted")
        } else {
            Image(systemName: "circle")
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
