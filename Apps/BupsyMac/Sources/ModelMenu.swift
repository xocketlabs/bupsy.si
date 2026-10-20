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
        if bot.engine == .local { localHeader(options) }
        ForEach(options.filter { $0.section == .standard }) { item($0) }
        section("Latest", options.filter { $0.section == .latest })
        section("Versions", options.filter { $0.section == .version })
        Divider()
        if bot.engine == .local {
            // The list is what Ollama and LM Studio had when last asked; a model pulled since
            // shows up after asking again.
            Button("Check for models") { Task { await model.refreshLocalModels() } }
        }
        // A model typed in earlier stays visible and ticked, so it never looks like "Default".
        if let custom = bot.model, !options.contains(where: { $0.id == custom }) {
            Button { } label: { Label(custom, systemImage: "checkmark") }
        }
        Button("Custom model…") { model.customModelBot = bot }
    }

    /// With nothing installed there is nothing safe to pick, and the menu says why.
    @ViewBuilder
    private func localHeader(_ options: [ModelOption]) -> some View {
        if options.isEmpty {
            Text("No models found. Start Ollama or LM Studio and get a model.")
        }
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
            MenuCheckLabel(option.label, checked: bot.model == option.id)
        }
    }
}

/// A menu item's label with a tick when it is the current choice.
///
/// Unticked items are plain text. `Label` with an empty system image logs a missing-symbol
/// warning on every menu open and nudges the title sideways, so the image is only there when it
/// is a real one.
struct MenuCheckLabel: View {
    let text: String
    let checked: Bool

    init(_ text: String, checked: Bool) {
        self.text = text
        self.checked = checked
    }

    var body: some View {
        if checked {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
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
            subtitle: bot.engine == .local
                ? "A model you have in Ollama or LM Studio. Bupsy checks it is installed before each run."
                : "Any model ID \(bot.engine.displayName) accepts. Passed to it exactly as typed.",
            width: 440
        ) {
            Field(label: "Model ID",
                  hint: bot.engine == .local
                      ? "ollama:<name> or lmstudio:<id>. A name on its own is looked up in both."
                      : "If the CLI is older than the model, it says so on the first run. "
                          + "Updating the CLI fixes it.") {
                TextField("", text: $id, prompt: Text(placeholder))
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

    private var placeholder: String {
        switch bot.engine {
        case .codex: "gpt-5.6"
        case .local: "ollama:qwen3:8b"
        default: "claude-opus-5-5"
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.setModel(bot, trimmed)
        dismiss()
    }
}
