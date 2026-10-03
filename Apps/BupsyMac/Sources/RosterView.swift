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
        Button("Rename…", action: onRename)
        Button(bot.pinned ? "Unpin" : "Pin to top") { model.togglePin(bot) }
        Divider()
        Menu("Engine") {
            ForEach([EngineID.claude, .codex], id: \.self) { engine in
                Button {
                    model.setEngine(bot, engine)
                } label: {
                    Label(engine.displayName, systemImage: bot.engine == engine ? "checkmark" : "")
                }
            }
        }
        Menu("Model") {
            ForEach(model.models(for: bot)) { option in
                Button {
                    model.setModel(bot, option.id)
                } label: {
                    Label(option.label, systemImage: bot.model == option.id ? "checkmark" : "")
                }
            }
        }
        Menu("Folder") {
            ForEach(model.folders, id: \.self) { folder in
                Button {
                    model.setFolder(bot, folder)
                } label: {
                    Label(folder, systemImage: bot.folder == folder ? "checkmark" : "")
                }
            }
            if !model.folders.isEmpty { Divider() }
            Button("New folder…", action: onNewFolder)
            if bot.folder != nil {
                Button("Remove from folder") { model.setFolder(bot, nil) }
            }
        }
        Divider()
        Button("Duplicate") { model.duplicate(bot) }
        Button("Copy conversation") { model.copyTranscript(of: bot) }
        Divider()
        Button("Delete bot", role: .destructive) { model.deleteBot(bot) }
    }
}

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engine = EngineID.claude
    @State private var job = ""

    var body: some View {
        SheetFrame(title: "New bot",
                   subtitle: "It starts fully gated — it asks before doing anything beyond reading.") {
            HStack(spacing: Theme.Space.step) {
                BotFace(hue: previewHue, mood: .idle, size: 52)
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    TextField("", text: $name, prompt: Text("Scout"))
                        .textFieldStyle(BupsyFieldStyle())
                    Picker("", selection: $engine) {
                        ForEach([EngineID.claude, .codex], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Field(label: "What's its job?",
                  hint: "Written to the bot as standing instructions, every time you talk to it.") {
                TextField("", text: $job,
                          prompt: Text("Research things and report back plainly. Be concise."),
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
                    job: job.trimmingCharacters(in: .whitespaces))
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Shows the colour the bot will get as you type its name, since the hue is derived from it.
    private var previewHue: Double {
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return name.isEmpty ? 0.55 : Double(abs(hash) % 360) / 360
    }
}
