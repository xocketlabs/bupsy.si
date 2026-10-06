import BupsyKit
import SwiftUI

// The bot list now lives in NavRail. What remains here is the right-click menu, which the rail
// uses, and the empty roster.

/// The one menu for a bot, wherever it is offered: the sidebar row's right-click and the Team
/// card's "..." button both build it from here, so the two can never drift apart.
///
/// The order follows the board: open, edit, face; where it lives; pin; stop and delete. The
/// rarer settings (engine, model, trust, copying) sit one level down under More rather than
/// making a seventeen-row menu. Everything here is also in the bot's profile, where it is
/// visible rather than hidden. This is the shortcut, not the only route.
struct BotMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    /// Opens the bot's chat. Nil where the menu sits on the chat already.
    var onOpen: (() -> Void)? = nil
    /// Opens the "new folder" sheet. A closure rather than a binding because a context menu is
    /// torn down the instant it is clicked, so the sheet has to belong to the view behind it.
    var onNewFolder: () -> Void
    /// Same reason as `onNewFolder`: a context menu is gone the moment it is clicked, so the
    /// sheet has to belong to the view behind it.
    var onRename: () -> Void = {}
    /// Asks before deleting. Same reason again: the confirmation has to live on the view behind
    /// the menu, so the menu only says which bot.
    var onDelete: () -> Void

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { Label("Open chat", systemImage: "bubble.left") }
        }
        // It opens the full editor, so it says so rather than promising only a new name.
        Button(action: onRename) { Label("Edit bot…", systemImage: "pencil") }
        Button { model.shuffleFace(bot) } label: { Label("Change face", systemImage: "sparkles") }

        Divider()

        Section("Move to") {
            ForEach(model.allSections, id: \.self) { folder in
                Button {
                    model.setFolder(bot, folder)
                } label: {
                    Label(folder, systemImage: bot.folder == folder ? "checkmark" : "rectangle.stack")
                }
            }
            Button {
                model.setFolder(bot, nil)
            } label: {
                Label("Unassigned", systemImage: (bot.folder ?? "").isEmpty ? "checkmark" : "tray")
            }
            Button(action: onNewFolder) { Label("New section…", systemImage: "plus") }
        }

        Divider()

        Button { model.togglePin(bot) } label: {
            Label(bot.pinned ? "Unpin" : "Pin to top", systemImage: bot.pinned ? "pin.slash" : "pin")
        }

        Menu {
            Button("Mark as unread") { model.markUnread(bot) }
            Divider()
            Menu("Engine") {
                ForEach(EngineID.supported, id: \.self) { engine in
                    // A Toggle, so the menu draws its own checkmark and the other rows stay aligned.
                    Toggle(isOn: Binding(
                        get: { bot.engine == engine },
                        set: { if $0 { model.setEngine(bot, engine) } })) {
                        Text(engine.displayName)
                    }
                }
            }
            Menu("Model") { ModelMenuItems(bot: bot) }
            Menu("Trust") {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    Toggle(isOn: Binding(
                        get: { bot.autonomy == level },
                        set: { if $0 { model.setAutonomy(bot, level) } })) {
                        Text(level.trustLabel)
                    }
                }
            }
            Divider()
            Button("Duplicate") { model.duplicate(bot) }
            Button("Copy conversation") { model.copyTranscript(of: bot) }
            // The engine's own resume handle. Useful when you want to pick a thread up in the CLI
            // directly, which is a thing this app should never make harder.
            Button("Copy conversation ID") { model.copyConversationID(of: bot) }
            Divider()
            // Not destructive, and worded so it cannot be mistaken for one.
            Button(bot.hidden ? "Show in sidebar" : "Hide from sidebar") {
                model.toggleHidden(bot)
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }

        Divider()

        // Only while it is doing something. Stops the run in progress; it does not hold the bot's
        // routines, so it is called Stop rather than Pause.
        if model.isRunning(bot.id) {
            Button { model.stop(bot.id) } label: { Label("Stop", systemImage: "stop.fill") }
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete bot…", systemImage: "trash")
        }
    }
}

// MARK: - Asking before deleting

/// The one way Bupsy asks before deleting something. A confirmation dialog with a red button
/// named for the action, and a message that says exactly what goes.
///
/// Hosted on a stable view, never inside a menu: a context menu is torn down the moment it is
/// clicked, and a dialog attached to it would go with it. Set `item` to ask; it is cleared when
/// the dialog closes, whichever button was pressed.
extension View {
    func confirmsDeletion<Item>(
        of item: Binding<Item?>,
        title: @escaping (Item) -> String,
        button: String,
        message: @escaping (Item) -> String,
        perform: @escaping (Item) -> Void
    ) -> some View {
        let current = item.wrappedValue
        return confirmationDialog(
            current.map(title) ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: current
        ) { value in
            Button(button, role: .destructive) { perform(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(message(value))
        }
    }

    /// Asks before deleting a bot, in the same words wherever it is offered.
    func confirmsBotDeletion(
        _ bot: Binding<Bot?>, perform: @escaping (Bot) -> Void
    ) -> some View {
        confirmsDeletion(
            of: bot,
            title: { "Delete \($0.name)?" },
            button: "Delete bot",
            message: { _ in
                "Its conversation, routines and folder watches are deleted too. This can't be undone."
            },
            perform: perform)
    }

    /// Asks before deleting a section, in the same words wherever it is offered. Only the
    /// section goes: its bots move to Unassigned.
    func confirmsSectionDeletion(
        _ section: Binding<String?>, perform: @escaping (String) -> Void
    ) -> some View {
        confirmsDeletion(
            of: section,
            title: { "Delete the \($0) section?" },
            button: "Delete section",
            message: { _ in
                "Its bots move to Unassigned. No bots, chats or routines are deleted."
            },
            perform: perform)
    }

    /// Asks before deleting a group chat, in the same words wherever it is offered.
    func confirmsGroupDeletion(
        _ group: Binding<ChatGroup?>, perform: @escaping (ChatGroup) -> Void
    ) -> some View {
        confirmsDeletion(
            of: group,
            title: { "Delete \($0.name)?" },
            button: "Delete group",
            message: { _ in
                "Its conversation is deleted. The bots in it stay as they are. This can't be undone."
            },
            perform: perform)
    }
}

/// The main area when there are no bots at all.
///
/// Bupsy waving, two ways to make the first bot (one click, where the bot asks what it is for,
/// or the full creator), and three ordinary jobs to start from. Self-contained: it makes bots
/// through the model, and making one selects it, which is what navigates to it.
struct RosterEmpty: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var settingUp = false

    init() {}

    /// Jobs a first bot is commonly given. Picking one makes a bot with that job, gated as usual.
    private static let starters: [RosterEmptyStarter] = [
        RosterEmptyStarter(name: "Inbox", shape: .bear, colour: 6,
                           title: "Keep my inbox under a day old",
                           job: "Watch my inbox and flag anything urgent. Keep it under a day old.",
                           meta: ["Gmail through Executor", "Checks hourly on weekdays"]),
        RosterEmptyStarter(name: "Researcher", shape: .pill, colour: 1,
                           title: "Research a topic and send me a summary",
                           job: "Research the topics I give you and send me a short, plain summary with sources.",
                           meta: ["Searches the web", "Writes notes to its folder"]),
        RosterEmptyStarter(name: "Builder", shape: .cat, colour: 2,
                           title: "Fix my builds when CI goes red",
                           job: "When a build fails, find out why and propose a fix.",
                           meta: ["Watches a repo folder", "Asks before running commands"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: ["Roster"]) { EmptyView() }
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Theme.Space.page) {
                        hero
                        starters
                    }
                    .padding(Theme.Space.pageSide)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .sheet(isPresented: $settingUp) { BotCreatorSheet() }
    }

    private var hero: some View {
        VStack(spacing: 20) {
            BotFace(hue: 0, mood: .waitingForYou, size: 150, shape: .bup, colour: 0)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.snug) {
                Text("No bots yet")
                    .font(.system(size: Theme.scaled(22), weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(palette.foreground)
                Text("Make your first one. It asks what it's for, names itself and gets to work.")
                    .font(.system(size: Theme.scaled(14)))
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: Theme.Space.snug) {
                Button {
                    model.quickCreateBot(engine: model.defaultNewBotEngine)
                } label: {
                    Label("New bot", systemImage: "plus")
                }
                .buttonStyle(PrimaryButton())
                Button {
                    settingUp = true
                } label: {
                    Label("Set up a bot yourself", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(QuietButton())
            }
            Text("Or press Cmd N from anywhere")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Text("Jobs people start with")
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(palette.mutedForeground)
            ForEach(Self.starters, id: \.title) { starter in
                Button { start(starter) } label: {
                    CardRow {
                        StillBotFace(shape: starter.shape, colour: starter.colour, size: 40)
                            .frame(width: Theme.Size.tile, height: Theme.Size.tile)
                            .background(BotShape.palette[starter.colour].opacity(0.14),
                                        in: .rect(cornerRadius: Theme.Radius.control))
                    } content: {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(starter.title)
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.foreground)
                            HStack(spacing: Theme.Space.snug) {
                                ForEach(Array(starter.meta.enumerated()), id: \.offset) { index, part in
                                    if index > 0 { MetaDot() }
                                    Text(part)
                                }
                            }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                        }
                    } trailing: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.scaled(10), weight: .semibold))
                            .foregroundStyle(palette.mutedForeground)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Make a bot with this job")
            }
        }
        .frame(maxWidth: 560)
    }

    private func start(_ starter: RosterEmptyStarter) {
        var name = starter.name
        var counter = 2
        while model.isNameTaken(name) {
            name = "\(starter.name) \(counter)"
            counter += 1
        }
        model.addBot(name: name, engine: model.defaultNewBotEngine, job: starter.job,
                     shape: starter.shape, colour: starter.colour)
        // The same hello a one-click bot gives, told the job it was made for, so it confirms
        // the job and asks what it needs rather than sitting silent.
        if let bot = model.bots.first(where: { $0.name == name }) {
            model.greet(bot, job: starter.job)
        }
    }
}

/// One suggested first job on the empty roster.
struct RosterEmptyStarter: Sendable {
    let name: String
    let shape: BotShape
    let colour: Int
    let title: String
    let job: String
    let meta: [String]
}
