import BupsyKit
import SwiftUI

/// The bot list, as a messaging app's conversation list.
///
/// Rows carry what a chat list carries: who, what they last said, when, and whether they need you.
/// A configuration-shaped row ("Claude Code · this Mac") tells you about the software; a
/// message-shaped row tells you about the conversation, which is what someone actually came for.
struct RosterView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingBot = false
    @State private var showsMachines = false
    @State private var showsConnectors = false
    @State private var showsAttention = false

    var body: some View {
        List(selection: Binding(
            get: { model.selectedBotID },
            set: { model.selectedBotID = $0 }
        )) {
            ForEach(model.bots) { bot in
                BotRow(bot: bot)
                    .tag(bot.id)
                    .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                    .contextMenu { BotMenu(bot: bot) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { AttentionBanner(showing: $showsAttention) }
        .toolbar {
            ToolbarItem {
                Button { isAddingBot = true } label: { Label("New bot", systemImage: "square.and.pencil") }
                    .help("New bot")
            }
            ToolbarItem {
                Menu {
                    Button("Machines…") { showsMachines = true }
                    Button("Apps…") { showsConnectors = true }
                } label: {
                    Label("Setup", systemImage: "ellipsis.circle")
                }
                .help("Machines and apps")
            }
        }
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
        .sheet(isPresented: $showsMachines) { MachinesSheet() }
        .sheet(isPresented: $showsConnectors) { ConnectorsSheet() }
        .sheet(isPresented: $showsAttention) { AttentionInbox() }
    }
}

/// Only appears when something is actually waiting.
///
/// A permanent tray icon with a zero badge is furniture people stop seeing. A banner that is
/// absent until it matters gets noticed the one time it does.
struct AttentionBanner: View {
    @Environment(AppModel.self) private var model
    @Binding var showing: Bool

    var body: some View {
        let count = model.attentionItems.count
        if count > 0 {
            Button { showing = true } label: {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "hand.raised.fill")
                    Text(count == 1 ? "1 thing needs you" : "\(count) things need you")
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, Theme.Space.snug)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.chip))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

struct BotRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    private var thread: Thread { model.thread(for: bot.id) }

    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.snug) {
            BotFace(hue: bot.avatarHue, mood: mood, size: Theme.Size.rosterAvatar)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.tight) {
                    Text(bot.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let at = thread.lastActivity {
                        Text(Theme.stamp(at))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: Theme.Space.tight) {
                    Text(preview)
                        .font(.callout)
                        // Orange is the one state worth a colour; the rest are weights of grey,
                        // so "needs you" is the only thing that catches the eye in a long list.
                        .foregroundStyle(mood == .waitingForYou
                                         ? AnyShapeStyle(Color.orange)
                                         : AnyShapeStyle(previewColor))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// What the row says when there is nothing to quote yet — the bot's job, not its settings.
    private var preview: String {
        if mood == .waitingForYou { return "Waiting for you to decide" }
        if model.isRunning(bot.id) { return "Working…" }
        if let last = thread.preview { return last }
        return bot.personaPrompt?.split(separator: ".").first.map(String.init)
            ?? "No messages yet"
    }

    private var previewColor: HierarchicalShapeStyle {
        switch mood {
        case .waitingForYou: .primary
        case .working: .secondary
        default: thread.preview == nil ? .tertiary : .secondary
        }
    }
}

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
        .padding(Theme.Space.wide)
        .frame(width: 400)
    }

    /// Shows the colour the bot will get as you type its name, since the hue is derived from it.
    private var previewHue: Double {
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return name.isEmpty ? 0.55 : Double(abs(hash) % 360) / 360
    }
}
