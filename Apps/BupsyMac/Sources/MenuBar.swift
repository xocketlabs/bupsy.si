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
/// face and what it is doing, then New bot, Open Bupsy, Pause all bots and Quit. This is the
/// native-menu version (the default `MenuBarExtra` style), so the faces are drawn to images and
/// each status rides in the item's title. `MenuBarPanel` below is the same content as a drawn
/// panel, for `.menuBarExtraStyle(.window)`.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let bots = model.bots.filter { !$0.hidden }
        let status = MenuBarStatus(model: model)

        Text(model.isPaused ? "Paused. \(status.headline)" : status.headline)

        ForEach(bots) { bot in
            MenuBarBotItem(bot: bot)
        }

        Divider()

        Button {
            MenuBarNavigation.show(model.quickCreateBot(), model: model, openWindow: openWindow)
        } label: {
            Label("New bot", systemImage: "plus")
        }
        .keyboardShortcut("n")

        Button {
            MenuBarNavigation.show(nil, model: model, openWindow: openWindow)
        } label: {
            Label("Open Bupsy", systemImage: "macwindow")
        }
        .keyboardShortcut("o")

        // Not disabled when nothing is running: pausing also holds routines, goals and folder
        // watches, which is worth doing on a quiet roster too.
        Button {
            model.togglePause()
        } label: {
            Label(model.isPaused ? "Resume bots" : "Pause all bots",
                  systemImage: model.isPaused ? "play.fill" : "pause.fill")
        }

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
    let paused: Bool

    init(model: AppModel) {
        paused = model.isPaused
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

    /// The one mood every view shows, from `AppModel.mood(for:)`.
    static func mood(for bot: Bot, in model: AppModel) -> BotMood {
        model.mood(for: bot)
    }

    /// The fallback word for a mood, where there is nothing more specific to say.
    static func text(for mood: BotMood) -> String {
        switch mood {
        case .waitingForYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .sleeping: "Asleep"
        case .failed: "Last run failed"
        case .idle: "Idle"
        }
    }

    /// What a bot's row says: what it is doing while it works ("Reading 3 files"), and when it
    /// wakes while it sleeps ("Asleep until 2:00 AM"), or "Paused" while bots are paused.
    static func text(for bot: Bot, mood: BotMood, in model: AppModel) -> String {
        switch mood {
        case .working:
            return model.liveStatus(for: bot)
        case .sleeping:
            // Paused: the next routine is skipped, so "asleep until" would be a promise it breaks.
            if model.isPaused { return "Paused" }
            guard let next = model.nextRoutineDate(for: bot) else { return "Asleep" }
            if Calendar.current.isDateInToday(next) {
                return "Asleep until \(next.formatted(date: .omitted, time: .shortened))"
            }
            return "Asleep until \(RoutineRunStats.nextLabel(next))"
        default:
            return text(for: mood)
        }
    }

    /// What VoiceOver says for the menu bar icon.
    var accessibilityLabel: String {
        let needs = "\(waiting) \(waiting == 1 ? "needs" : "need") you"
        if paused { return waiting > 0 ? "Bupsy, paused, \(needs)" : "Bupsy, paused" }
        if waiting > 0 { return "Bupsy, \(needs)" }
        if working > 0 { return "Bupsy, \(working) working" }
        return "Bupsy, all quiet"
    }
}

/// Brings the main window forward from the menu bar, reopening it if it was closed, then goes
/// to a bot when there is one. Activating the app alone did nothing once the window was closed.
@MainActor
enum MenuBarNavigation {
    static func show(_ botID: BotID?, model: AppModel, openWindow: OpenWindowAction) {
        // `Window` scene: brings the existing window forward, or reopens it, never a second one.
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
        if let botID { model.open(botID) }
    }
}

/// One bot in the native menu: its face, its name and what it is doing.
///
/// A bot waiting on an approval opens a submenu with both answers. If a decision can be made from
/// a glance, making someone open a window to make it is the difference between a gate people use
/// and a gate people switch off.
struct MenuBarBotItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let bot: Bot

    var body: some View {
        let mood = MenuBarStatus.mood(for: bot, in: model)
        // A paused group borrows its lead's face in the inbox, but is not that bot waiting.
        let items = model.attentionItems.filter { $0.botID == bot.id && !$0.kind.isPausedGroup }

        if items.isEmpty {
            Button {
                open()
            } label: {
                Label {
                    Text("\(bot.name), \(MenuBarStatus.text(for: bot, mood: mood, in: model).lowercased())")
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
        MenuBarNavigation.show(bot.id, model: model, openWindow: openWindow)
    }
}

/// An approval answered from the menu bar: Allow and Deny when it is a tool request, otherwise a
/// way into the bot.
struct MenuBarApproval: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: AttentionItem

    private var bot: Bot? { model.bots.first { $0.id == item.botID } }

    var body: some View {
        if item.kind.isApproval, let bot, let approval = model.pendingApproval(id: item.id, for: bot.id) {
            Section(short(item.detail.isEmpty ? item.title : item.detail)) {
                Button("Allow") { model.decide(approval, allow: true, for: bot) }
                Button("Deny") { model.decide(approval, allow: false, for: bot) }
            }
        } else {
            Button(short(item.title)) {
                switch item.kind {
                case .pausedGroup(let groupID), .groupApproval(let groupID):
                    MenuBarNavigation.show(nil, model: model, openWindow: openWindow)
                    model.open(.group(groupID))
                default:
                    MenuBarNavigation.show(bot?.id, model: model, openWindow: openWindow)
                }
            }
        }
    }

    /// Menu items have no room to wrap, and a truncated command is still recognisable.
    private func short(_ text: String, limit: Int = 44) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }
}

/// A bot's face drawn to an image, because a native menu item can only hold an image, not a view.
/// Drawn each time the menu opens rather than cached: a handful of 18pt faces is cheap, and it
/// keeps the mood current without any stored state. The colour scheme is passed in, because an
/// image render has no window to read it from.
@MainActor
enum MenuBarFaces {
    static func image(for bot: Bot, mood: BotMood, size: CGFloat = 18) -> Image {
        let shape = bot.avatarShape ?? BotFace.derivedShape(forHue: bot.avatarHue)
        let colour = bot.avatarColour ?? BotFace.derivedColour(forHue: bot.avatarHue)
        let renderer = ImageRenderer(content: StillBotFace(shape: shape, colour: colour, size: size, mood: mood,
                                                           scheme: StillBotFace.appScheme))
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
    @Environment(\.openWindow) private var openWindow

    /// The roster's height before it scrolls, so a long roster cannot push New bot and Quit off
    /// the bottom of the screen.
    private static let rosterCap: CGFloat = 360

    var body: some View {
        let bots = model.bots.filter { !$0.hidden }
        let status = MenuBarStatus(model: model)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Text(status.headline)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                Spacer(minLength: Theme.Space.snug)
                // Quiet on purpose: paused is a choice, not something wrong.
                if model.isPaused {
                    Badge(text: "Paused", tone: .neutral)
                        .help("Routines and goals won't start on their own until you resume")
                }
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.top, Theme.Space.snug)
            .padding(.bottom, Theme.Space.xs)

            if bots.isEmpty {
                Text("Make one and it shows up here.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.tight)
            } else if estimatedHeight(of: bots) > Self.rosterCap {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(bots) { bot in
                            MenuBarPanelBotRow(bot: bot)
                        }
                    }
                }
                .frame(height: Self.rosterCap)
            } else {
                ForEach(bots) { bot in
                    MenuBarPanelBotRow(bot: bot)
                }
            }

            separator

            MenuBarPanelAction(icon: "plus", title: "New bot", shortcut: "Cmd N") {
                MenuBarNavigation.show(model.quickCreateBot(), model: model, openWindow: openWindow)
            }
            .keyboardShortcut("n")
            MenuBarPanelAction(icon: "macwindow", title: "Open Bupsy", shortcut: "Cmd O") {
                MenuBarNavigation.show(nil, model: model, openWindow: openWindow)
            }
            .keyboardShortcut("o")
            // Pausing stops what is running and holds routines, goals and folder watches, so it
            // is never disabled; a message you send still goes while paused.
            MenuBarPanelAction(icon: model.isPaused ? "play.fill" : "pause.fill",
                               title: model.isPaused ? "Resume bots" : "Pause all bots",
                               shortcut: nil) {
                model.togglePause()
            }

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

    /// Rows are 32pt, plus about 34 for the Allow and Deny line under a bot waiting on a tool.
    /// Measured from the row's own layout rather than read back, so short rosters never scroll.
    private func estimatedHeight(of bots: [Bot]) -> CGFloat {
        bots.reduce(CGFloat(0)) { total, bot in
            total + 32 + (MenuBarPanelBotRow.pendingApproval(for: bot, in: model) == nil ? 0 : 34)
        }
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
    @Environment(\.openWindow) private var openWindow
    let bot: Bot
    @State private var hovering = false

    init(bot: Bot) { self.bot = bot }

    var body: some View {
        let mood = MenuBarStatus.mood(for: bot, in: model)
        let approval = firstPendingApproval

        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button {
                MenuBarNavigation.show(bot.id, model: model, openWindow: openWindow)
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    // Only a bot with something going on moves; a quiet roster costs no frames.
                    BotFace(bot: bot, mood: mood, size: 22, still: mood == .idle || mood == .sleeping)
                    Text(bot.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.snug)
                    if mood == .waitingForYou {
                        Badge(text: "Needs you", tone: .primary, dot: true)
                    } else {
                        Text(MenuBarStatus.text(for: bot, mood: mood, in: model))
                            .font(Theme.Typography.label)
                            .foregroundStyle(mood == .failed ? palette.destructiveText : palette.mutedForeground)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Theme.Space.tight)
                .frame(height: 32)
                .background(hovering ? palette.cardHover : Color.clear,
                            in: .rect(cornerRadius: Theme.Radius.sm))
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
        Self.pendingApproval(for: bot, in: model)
    }

    /// The first undecided approval wherever the bot raised it, its own chat or a group.
    static func pendingApproval(for bot: Bot, in model: AppModel) -> PendingApproval? {
        for thread in model.approvalThreads(for: bot.id) {
            for entry in thread.entries {
                if case .approval(let approval) = entry.kind, approval.decided == nil { return approval }
            }
        }
        return nil
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
                        in: .rect(cornerRadius: Theme.Radius.sm))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The icon, which is the whole point: state without opening anything.
///
/// The Bupsy glyph (rounded body, two eye holes, antenna with its bulb) as a template image, so
/// it follows the menu bar's colour like every other icon there. When something needs you it
/// gains a small pink dot, the one place colour is allowed up here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = MenuBarStatus(model: model)
        Image(nsImage: MenuBarGlyph.image(badged: status.waiting > 0))
            .accessibilityLabel(status.accessibilityLabel)
            .help(status.accessibilityLabel)
    }
}

/// Draws the menu bar glyph from `bupsy-menubar-template.svg` (a 36 unit box) at 18pt.
@MainActor
enum MenuBarGlyph {
    static let size: CGFloat = 18
    private static var cache: [Bool: NSImage] = [:]

    /// Plain: a template image, tinted by the system. Badged: the glyph drawn in the menu bar's
    /// own label colour (resolved when drawn, so it follows light and dark menu bars) with a pink
    /// dot, which a template image cannot carry because the system flattens it to one colour.
    static func image(badged: Bool) -> NSImage {
        if let cached = cache[badged] { return cached }
        // Sendable and nonisolated: AppKit may call a drawing handler whenever it redraws.
        let handler: @Sendable (NSRect) -> Bool = { rect in
            MenuBarGlyph.draw(in: rect, badged: badged)
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true, drawingHandler: handler)
        image.isTemplate = !badged
        image.accessibilityDescription = badged ? "Bupsy, something needs you" : "Bupsy"
        cache[badged] = image
        return image
    }

    /// The drawing itself, in the SVG's 36 unit box scaled to `rect`, y pointing down.
    nonisolated private static func draw(in rect: NSRect, badged: Bool) -> Bool {
        let k = rect.width / 36
        let ink: NSColor = badged ? .labelColor : .black
        ink.setFill()
        ink.setStroke()

        // Antenna: M18 9.5 Q17.2 5.6 20 3.5, as a cubic with the same shape.
        let start = NSPoint(x: 18 * k, y: 9.5 * k)
        let control = NSPoint(x: 17.2 * k, y: 5.6 * k)
        let end = NSPoint(x: 20 * k, y: 3.5 * k)
        let antenna = NSBezierPath()
        antenna.move(to: start)
        antenna.curve(to: end,
                      controlPoint1: NSPoint(x: start.x + 2 / 3 * (control.x - start.x),
                                             y: start.y + 2 / 3 * (control.y - start.y)),
                      controlPoint2: NSPoint(x: end.x + 2 / 3 * (control.x - end.x),
                                             y: end.y + 2 / 3 * (control.y - end.y)))
        antenna.lineWidth = 2 * k
        antenna.lineCapStyle = .round
        antenna.stroke()

        // Bulb.
        NSBezierPath(ovalIn: NSRect(x: (20.6 - 2.4) * k, y: (3.4 - 2.4) * k,
                                    width: 4.8 * k, height: 4.8 * k)).fill()

        // Body with two eye holes.
        let body = NSBezierPath(roundedRect: NSRect(x: 4.5 * k, y: 9.5 * k, width: 27 * k, height: 24 * k),
                                xRadius: 9 * k, yRadius: 9 * k)
        body.append(NSBezierPath(ovalIn: NSRect(x: 10 * k, y: 17.7 * k, width: 6 * k, height: 7.2 * k)))
        body.append(NSBezierPath(ovalIn: NSRect(x: 20 * k, y: 17.7 * k, width: 6 * k, height: 7.2 * k)))
        body.windingRule = .evenOdd
        body.fill()

        if badged {
            // A clear ring first, so the dot stands off the body's corner.
            let centre = NSPoint(x: 30 * k, y: 9 * k)
            let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 6 * k, y: centre.y - 6 * k,
                                                   width: 12 * k, height: 12 * k))
            NSGraphicsContext.current?.compositingOperation = .clear
            ring.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // The app's pink (`palette.primary`, light).
            NSColor(srgbRed: 224 / 255, green: 117 / 255, blue: 200 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 4.4 * k, y: centre.y - 4.4 * k,
                                        width: 8.8 * k, height: 8.8 * k)).fill()
        }
        return true
    }
}

#if canImport(AppKit)
import AppKit
#endif
