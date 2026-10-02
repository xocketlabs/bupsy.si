import BupsyKit
import SwiftUI

// The bot list now lives in NavRail. What remains here is the right-click menu and the
// new-bot sheet, both of which the rail uses.

/// Right-click. Everything here is also in the bot's profile, where it is visible rather than
/// hidden — this is the shortcut, not the only route.
struct BotMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
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
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Text("New bot").font(.headline)

            HStack(spacing: Theme.Space.step) {
                BotFace(hue: previewHue, mood: .idle, size: 52)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $name, prompt: Text("Scout"))
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $engine) {
                        ForEach([EngineID.claude, .codex], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What's its job?").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $job,
                          prompt: Text("Research things and report back plainly."),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Text("Starts fully gated — it asks before doing anything beyond reading.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.addBot(
                        name: name.trimmingCharacters(in: .whitespaces),
                        engine: engine,
                        job: job.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.section)
        .frame(width: 400)
    }

    /// Shows the colour the bot will get as you type its name, since the hue is derived from it.
    private var previewHue: Double {
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return name.isEmpty ? 0.55 : Double(abs(hash) % 360) / 360
    }
}
