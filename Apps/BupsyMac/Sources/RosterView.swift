import BupsyKit
import SwiftUI

// The bot list now lives in NavRail. What remains here is the right-click menu and the
// new-bot sheet, both of which the rail uses.

/// Right-click. Everything here is also in the bot's profile, where it is visible rather than
/// hidden. This is the shortcut, not the only route.
struct BotMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    /// Opens the "new folder" sheet. A closure rather than a binding because a context menu is
    /// torn down the instant it is clicked, so the sheet has to belong to the view behind it.
    var onNewFolder: () -> Void
    /// Same reason as `onNewFolder`: a context menu is gone the moment it is clicked, so the
    /// sheet has to belong to the view behind it.
    var onRename: () -> Void = {}

    var body: some View {
        Button("Pin to top", systemImage: bot.pinned ? "pin.slash" : "pin") {
            model.togglePin(bot)
        }
        Menu("Move to") {
            ForEach(model.folders, id: \.self) { folder in
                Button {
                    model.setFolder(bot, folder)
                } label: {
                    Label(folder, systemImage: bot.folder == folder ? "checkmark" : "rectangle.stack")
                }
            }
            Button {
                model.setFolder(bot, nil)
            } label: {
                Label("Unassigned",
                      systemImage: (bot.folder ?? "").isEmpty ? "checkmark" : "tray")
            }
            Divider()
            Button("Create section…", action: onNewFolder)
        }
        Button("Mark as unread") { model.markUnread(bot) }
        Divider()
        Button("Rename bot…", action: onRename)
        Button("Shuffle face") { model.shuffleFace(bot) }
        Menu("Engine") {
            ForEach(EngineID.supported, id: \.self) { engine in
                Button {
                    model.setEngine(bot, engine)
                } label: {
                    Label(engine.displayName, systemImage: bot.engine == engine ? "checkmark" : "")
                }
            }
        }
        Menu("Model") { ModelMenuItems(bot: bot) }
        Menu("Trust") {
            ForEach(Autonomy.allCases, id: \.self) { level in
                Button {
                    model.setAutonomy(bot, level)
                } label: {
                    Label(level.menuLabel, systemImage: bot.autonomy == level ? "checkmark" : "")
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
        Button("Delete bot", role: .destructive) { model.deleteBot(bot) }
    }
}

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engine = EngineID.claude
    @State private var job = ""
    @State private var shape = BotShape.bup
    @State private var colour = 0
    /// Until the face is touched, it follows the name: the automatic face, kept distinct from the
    /// rest of the roster. Once someone picks, their pick stays put while they keep typing.
    @State private var faceChosen = false

    var body: some View {
        SheetFrame(title: "New bot", icon: "sparkles",
                   subtitle: "It starts fully gated. It asks before doing anything beyond reading.",
                   primaryVerb: "create") {
            HStack(spacing: Theme.Space.step) {
                BotFace(hue: previewHue, mood: .idle, size: 56,
                        shape: faceChosen ? shape : nil, colour: faceChosen ? colour : nil)
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    // Not "Scout": that is a starter bot's name, and suggesting it invited a
                    // duplicate of a bot the person already has.
                    TextField("", text: $name, prompt: Text("Give it a name"))
                        .textFieldStyle(BupsyFieldStyle())
                    if model.isNameTaken(name) {
                        Text("You already have a bot called that.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.destructive)
                    }
                    Picker("", selection: $engine) {
                        ForEach(EngineID.supported, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            AvatarPicker(
                // Each setter seeds the *other* half from the automatic face before taking over.
                // Without it, picking only a colour flipped the face to "chosen" with the shape
                // still at its placeholder, so the bot jumped to a circle you never picked.
                shape: Binding(
                    get: { faceChosen ? shape : BotFace.derivedShape(forHue: previewHue) },
                    set: { new in
                        if !faceChosen {
                            colour = BotFace.derivedColour(forHue: previewHue)
                            faceChosen = true
                        }
                        shape = new
                    }),
                colour: Binding(
                    get: { faceChosen ? colour : BotFace.derivedColour(forHue: previewHue) },
                    set: { new in
                        if !faceChosen {
                            shape = BotFace.derivedShape(forHue: previewHue)
                            faceChosen = true
                        }
                        colour = new
                    }),
                taken: Set(model.bots.map(\.effectiveShape)))

            Field(label: "What's its job?",
                  hint: "Written to the bot as standing instructions, every time you talk to it.") {
                TextField("", text: $job,
                          prompt: Text("What should it do? e.g. watch my inbox and flag anything urgent"),
                          axis: .vertical)
                    .textFieldStyle(BupsyFieldStyle())
                    .lineLimit(3...5)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create") {
                model.addBot(
                    name: name.trimmingCharacters(in: .whitespaces),
                    engine: engine,
                    job: job.trimmingCharacters(in: .whitespaces),
                    shape: faceChosen ? shape : nil,
                    colour: faceChosen ? colour : nil)
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isNameTaken(name))
        }
    }

    /// The face the bot will actually get, as you type its name.
    ///
    /// Run through the same "nobody else has this shape" step as creation. Previewing the raw
    /// name-derived hue would show one character and then create a different one.
    private var previewHue: Double {
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let raw = name.isEmpty ? 0.55 : Double(abs(hash) % 360) / 360
        return model.distinctHue(near: raw)
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
                           meta: ["Works best with a mail app connected", "Asks before it acts"]),
        RosterEmptyStarter(name: "Researcher", shape: .pill, colour: 1,
                           title: "Research a topic and send me a summary",
                           job: "Research the topics I give you and send me a short, plain summary with sources.",
                           meta: ["Searches the web", "Reports back in its thread"]),
        RosterEmptyStarter(name: "Builder", shape: .cat, colour: 2,
                           title: "Fix my builds when CI goes red",
                           job: "When a build fails, find out why and propose a fix.",
                           meta: ["Works in a repo folder", "Asks before running commands"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: ["Roster"]) { EmptyView() }
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 40) {
                        hero
                        starters
                    }
                    .padding(32)
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
                    model.quickCreateBot(engine: preferredEngine)
                } label: {
                    Label("New bot", systemImage: "plus")
                }
                .buttonStyle(PrimaryButton())
                Button {
                    settingUp = true
                } label: {
                    Label("Set it up yourself", systemImage: "slider.horizontal.3")
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
                            .frame(width: 44, height: 44)
                            .background(BotShape.palette[starter.colour].opacity(0.14),
                                        in: .rect(cornerRadius: Theme.Radius.control))
                    } content: {
                        VStack(alignment: .leading, spacing: 3) {
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

    /// The first engine that is signed in, so a starter bot can actually run.
    private var preferredEngine: EngineID {
        EngineID.supported.first { model.engineStatus[$0]?.isUsable == true } ?? .claude
    }

    private func start(_ starter: RosterEmptyStarter) {
        var name = starter.name
        var counter = 2
        while model.isNameTaken(name) {
            name = "\(starter.name) \(counter)"
            counter += 1
        }
        model.addBot(name: name, engine: preferredEngine, job: starter.job,
                     shape: starter.shape, colour: starter.colour)
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
