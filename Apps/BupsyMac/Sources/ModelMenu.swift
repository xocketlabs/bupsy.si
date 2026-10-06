import BupsyKit
import SwiftUI

/// The model choices for a bot, used by every menu that offers them.
///
/// Newest-in-family aliases first, exact versions after, then a custom entry for anything the list
/// does not have yet. A new model should never have to wait for a bupsy update.
struct ModelMenuItems: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        let options = model.models(for: bot)
        ForEach(options.filter { $0.section == .standard }) { item($0) }
        section("Latest", options.filter { $0.section == .latest })
        section("Versions", options.filter { $0.section == .version })
        Divider()
        // A model typed in earlier stays visible and ticked, so it never looks like "Default".
        if let custom = bot.model, !options.contains(where: { $0.id == custom }) {
            Button { } label: { Label(custom, systemImage: "checkmark") }
        }
        Button("Custom model…") { model.customModelBot = bot }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ModelOption]) -> some View {
        if !items.isEmpty {
            Section(title) { ForEach(items) { item($0) } }
        }
    }

    private func item(_ option: ModelOption) -> some View {
        Button {
            model.setModel(bot, option.id)
        } label: {
            Label(option.label, systemImage: bot.model == option.id ? "checkmark" : "")
        }
    }
}

/// Type in any model ID the bot's CLI accepts.
struct CustomModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var id = ""

    var body: some View {
        SheetFrame(
            title: "Custom model",
            icon: "slider.horizontal.3",
            subtitle: "Any model ID \(bot.engine.displayName) accepts. Passed to it exactly as typed.",
            width: 440
        ) {
            Field(label: "Model ID",
                  hint: "If the CLI is older than the model, it says so on the first run. "
                      + "Updating the CLI fixes it.") {
                TextField("", text: $id, prompt: Text(bot.engine == .codex ? "gpt-5.6" : "claude-opus-5-5"))
                    .bupsyField()
                    .onSubmit(save)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Use model", action: save)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        }
        .onAppear { id = bot.model ?? "" }
    }

    private var trimmed: String { id.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.setModel(bot, trimmed)
        dismiss()
    }
}
