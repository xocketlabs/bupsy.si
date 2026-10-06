import BupsyKit
import SwiftUI

/// The menu bar item.
///
/// This is what makes an always-on app feel always-on. Bots work for minutes at a time and
/// occasionally stop to ask something; having to open a window to find out is the friction that
/// stops people leaving the app running at all. From up here you can see who is busy, see what is
/// waiting, and answer it, without the window ever coming forward.
///
/// Laid out like the design's menu: a status line ("2 working, 1 needs you"), every bot with its
/// face and what it is doing, then New bot, Open Bupsy, Stop all bots and Quit. This is the
/// native-menu version (the default `MenuBarExtra` style), so the faces are drawn to images and
/// each status rides in the item's title. `MenuBarPanel` below is the same content as a drawn
/// panel, for `.menuBarExtraStyle(.window)`.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let bots = model.bots.filter { !$0.hidden }
        let status = MenuBarStatus(model: model)

        Text(status.headline)

        ForEach(bots) { bot in
            MenuBarBotItem(bot: bot)
        }

        Divider()

        Button {
            if let id = model.quickCreateBot() { model.selectedBotID = id }
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("New bot", systemImage: "plus")
        }
        .keyboardShortcut("n")

        Button {
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Bupsy", systemImage: "macwindow")
        }
        .keyboardShortcut("o")

        Button {
            model.stopEverything()
        } label: {
            Label("Stop all bots", systemImage: "stop.fill")
        }
        .disabled(status.working == 0)

        Divider()

        Button("Quit Bupsy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The counts the menu's first line is made of. Pure: reads the model, holds nothing.
@MainActor
struct MenuBarStatus {
    let working: Int
    let waiting: Int
    let hasBots: Bool

    init(model: AppModel) {
        working = model.bots.filter { model.isRunning($0.id) }.count
        waiting = model.attentionItems.count
        hasBots = !model.bots.isEmpty
    }

    /// "2 working, 1 needs you". Only the parts that are true, so a quiet roster says so.
    var headline: String {
        guard hasBots else { return "No bots yet" }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) \(waiting == 1 ? "needs" : "need") you") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: ", ")
    }

    static func mood(for bot: Bot, in model: AppModel) -> BotMood {
        if model.attentionItems.contains(where: { $0.botID == bot.id }) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    static func text(for mood: BotMood) -> String {
        switch mood {
        case .waitingForYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .sleeping: "Asleep"
        case .failed: "Stopped"
        case .idle: "Idle"
        }
    }
}

/// One bot in the native menu: its face, its name and what it is doing.
///
/// A bot waiting on an approval opens a submenu with both answers. If a decision can be made from
/// a glance, making someone open a window to make it is the difference between a gate people use
/// and a gate people switch off.
struct MenuBarBotItem: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        let mood = MenuBarStatus.mood(for: bot, in: model)
        let items = model.attentionItems.filter { $0.botID == bot.id }

        if items.isEmpty {
            Button {
                open()
            } label: {
                Label {
                    Text("\(bot.name), \(MenuBarStatus.text(for: mood).lowercased())")
                } icon: {
                    MenuBarFaces.image(for: bot, mood: mood)
                }
            }
        } else {
            Menu {
                ForEach(items) { item in
                    MenuBarApproval(item: item)
                }
                Divider()
                Button("Open \(bot.name)") { open() }
            } label: {
                Label {
                    Text("\(bot.name), needs you")
                } icon: {
                    MenuBarFaces.image(for: bot, mood: mood)
                }
            }
        }
    }

    private func open() {
        model.selectedBotID = bot.id
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// An approval answered from the menu bar: Allow and Deny when it is a tool request, otherwise a
/// way into the bot.
struct MenuBarApproval: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    private var bot: Bot? { model.bots.first { $0.id == item.botID } }

    var body: some View {
        if item.kind == .approval, let bot, let approval = pending(for: bot) {
            Section(short(item.detail.isEmpty ? item.title : item.detail)) {
                Button("Allow") { model.decide(approval, allow: true, for: bot) }
                Button("Deny") { model.decide(approval, allow: false, for: bot) }
            }
        } else {
            Button(short(item.title)) {
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
        return flat.count <= limit ? flat : flat.prefix(limit) + "..."
    }
}

/// A bot's face drawn to an image, because a native menu item can only hold an image, not a view.
/// Drawn each time the menu opens rather than cached: a handful of 18pt faces is cheap, and it
/// keeps the mood current without any stored state.
@MainActor
enum MenuBarFaces {
    static func image(for bot: Bot, mood: BotMood, size: CGFloat = 18) -> Image {
        let shape = bot.avatarShape ?? BotFace.derivedShape(forHue: bot.avatarHue)
        let colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        let renderer = ImageRenderer(content: StillBotFace(shape: shape, colour: colour, size: size, mood: mood))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return Image(systemName: "circle.fill") }
        return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: size, height: size)))
    }
}

/// The same menu drawn as a panel, matching the design exactly: live faces, statuses
/// right-aligned, a pink "Needs you" pill, shortcut hints.
///
/// Only for `MenuBarExtra { MenuBarPanel() }.menuBarExtraStyle(.window)`. In the default menu
/// style a drawn view like this is flattened into plain items, so `MenuBarView` stays the one in
/// use until the scene opts in.
struct MenuBarPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MenuBarPanelContent()
            .withPalette(colorScheme)
    }
}

private struct MenuBarPanelContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let bots = model.bots.filter { !$0.hidden }
        let status = MenuBarStatus(model: model)

        VStack(alignment: .leading, spacing: 0) {
            Text(status.headline)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, Theme.Space.step)
                .padding(.top, Theme.Space.snug)
                .padding(.bottom, 4)

            if bots.isEmpty {
                Text("Make one and it shows up here.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.tight)
            } else {
                ForEach(bots) { bot in
                    MenuBarPanelBotRow(bot: bot)
                }
            }

            separator

            MenuBarPanelAction(icon: "plus", title: "New bot", shortcut: "Cmd N") {
                if let id = model.quickCreateBot() { model.selectedBotID = id }
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarPanelAction(icon: "macwindow", title: "Open Bupsy", shortcut: "Cmd O") {
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarPanelAction(icon: "stop.fill", title: "Stop all bots", shortcut: nil) {
                model.stopEverything()
            }
            .disabled(status.working == 0)

            separator

            MenuBarPanelAction(icon: nil, title: "Quit Bupsy", shortcut: "Cmd Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(Theme.Space.tight)
        .frame(width: 280)
        .background(palette.popover)
        .tint(palette.primary)
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, Theme.Space.tight)
    }
}

/// A bot in the panel. Waiting on a tool approval, it grows an Allow and a Deny under its name.
private struct MenuBarPanelBotRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    @State private var hovering = false

    init(bot: Bot) { self.bot = bot }

    var body: some View {
        let mood = MenuBarStatus.mood(for: bot, in: model)
        let approval = firstPendingApproval

        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.selectedBotID = bot.id
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    BotFace(bot: bot, mood: mood, size: 22)
                    Text(bot.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.snug)
                    if mood == .waitingForYou {
                        Text("Needs you")
                            .font(Theme.Typography.badge)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(palette.primary, in: .rect(cornerRadius: 5))
                    } else {
                        Text(MenuBarStatus.text(for: mood))
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.mutedForeground)
                    }
                }
                .padding(.horizontal, Theme.Space.tight)
                .frame(height: 32)
                .background(hovering ? palette.cardHover : Color.clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if let approval {
                HStack(spacing: Theme.Space.tight) {
                    Text(approval.summary.isEmpty ? approval.tool : approval.summary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.tight)
                    Button("Allow") { model.decide(approval, allow: true, for: bot) }
                        .buttonStyle(QuietButton(compact: true))
                    Button("Deny") { model.decide(approval, allow: false, for: bot) }
                        .buttonStyle(QuietButton(compact: true))
                }
                .padding(.leading, 22 + Theme.Space.snug + Theme.Space.tight)
                .padding(.trailing, Theme.Space.tight)
                .padding(.bottom, Theme.Space.tight)
            }
        }
    }

    private var firstPendingApproval: PendingApproval? {
        model.thread(for: bot.id).entries.compactMap { entry -> PendingApproval? in
            if case .approval(let approval) = entry.kind, approval.decided == nil { return approval }
            return nil
        }.first
    }
}

/// One action row in the panel: icon, title, and the shortcut written out on the right.
private struct MenuBarPanelAction: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let icon: String?
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(icon: String?, title: String, shortcut: String?, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: Theme.scaled(12)))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22, height: 16)
                Text(title)
                    .font(Theme.Typography.body)
                Spacer(minLength: Theme.Space.snug)
                if let shortcut {
                    Text(shortcut)
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .foregroundStyle(isEnabled ? palette.foreground : palette.mutedForeground)
            .padding(.horizontal, Theme.Space.tight)
            .frame(height: 30)
            .background(hovering && isEnabled ? palette.cardHover : Color.clear,
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
