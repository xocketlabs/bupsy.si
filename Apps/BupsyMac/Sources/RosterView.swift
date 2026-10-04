import BupsyKit
import SwiftUI

// The bot list now lives in NavRail. What remains here is the right-click menu and the
// new-bot sheet, both of which the rail uses.

/// Right-click. Everything here is also in the bot's profile, where it is visible rather than
/// hidden — this is the shortcut, not the only route.
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
                    Label(folder, systemImage: bot.folder == folder ? "checkmark" : "folder")
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
            ForEach([EngineID.claude, .codex], id: \.self) { engine in
                Button {
                    model.setEngine(bot, engine)
                } label: {
                    Label(engine.displayName, systemImage: bot.engine == engine ? "checkmark" : "")
                }
            }
        }
        Menu("Model") { ModelMenuItems(bot: bot) }
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
    @State private var shape = BotShape.circle
    @State private var colour = 0
    /// Until the face is touched, it follows the name — the automatic face, kept distinct from the
    /// rest of the roster. Once someone picks, their pick stays put while they keep typing.
    @State private var faceChosen = false

    var body: some View {
        SheetFrame(title: "New bot", icon: "sparkles",
                   subtitle: "It starts fully gated — it asks before doing anything beyond reading.") {
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
                        ForEach([EngineID.claude, .codex], id: \.self) {
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
