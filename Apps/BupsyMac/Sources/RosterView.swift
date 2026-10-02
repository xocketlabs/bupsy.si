import BupsyKit
import SwiftUI

/// The bot list, as a messaging app's conversation list.
///
/// Rows carry what a chat list carries: who, what they last said, when, and whether they need you.
/// A configuration-shaped row ("Claude Code · this Mac") tells you about the software; a
/// message-shaped row tells you about the conversation, which is what someone actually came for.
struct RosterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var isAddingBot = false
    @State private var showsMachines = false
    @State private var showsConnectors = false
    @State private var showsAttention = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.tight) {
                ForEach(model.bots) { bot in
                    BotRow(bot: bot, selected: model.selectedBotID == bot.id)
                        .contentShape(.rect)
                        .onTapGesture { model.selectedBotID = bot.id }
                        .contextMenu { BotMenu(bot: bot) }
                }
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
        }
        // The sidebar is the darkest surface, so it recedes and the content reads as lifted
        // above it. The opposite of the usual Mac arrangement, and the whole reason this
        // palette has depth without borders or shadows.
        .background(palette.sidebar)
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
    @Environment(\.palette) private var palette
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
                .font(Theme.Typography.body)
                .foregroundStyle(palette.primary)
                .padding(.horizontal, Theme.Space.step)
                .frame(height: Theme.Size.control)
                .frame(maxWidth: .infinity)
                .background(palette.primary.opacity(0.12),
                            in: .rect(cornerRadius: Theme.Radius.control))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.step)
            .padding(.top, Theme.Space.step)
        }
    }
}

struct BotRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    let selected: Bool
    @State private var hovering = false

    private var thread: Thread { model.thread(for: bot.id) }

    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.step) {
            BotFace(hue: bot.avatarHue, mood: mood, size: Theme.Size.rosterAvatar)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.tight) {
                    Text(bot.name)
                        .font(Theme.Typography.heading)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let at = thread.lastActivity {
                        Text(Theme.stamp(at))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.sidebarMuted)
                    }
                }

                Text(preview)
                    .font(Theme.Typography.label)
                    // The pink is the only saturated colour in the palette, so spending it on
                    // "needs you" means that state is the one thing the eye finds in a list.
                    .foregroundStyle(mood == .waitingForYou
                                     ? palette.primary
                                     : palette.sidebarMutedForeground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.step)
        .background(rowBackground, in: .rect(cornerRadius: Theme.Radius.card))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var rowBackground: Color {
        if selected { return palette.sidebarAccent }
        return hovering ? palette.sidebarAccent.opacity(0.5) : .clear
    }

    /// What the row says when there is nothing to quote yet — the bot's job, not its settings.
    private var preview: String {
        if mood == .waitingForYou { return "Waiting for you to decide" }
        if model.isRunning(bot.id) { return "Working…" }
        if let last = thread.preview { return last }
        return bot.personaPrompt?.split(separator: ".").first.map(String.init)
            ?? "No messages yet"
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
