import BupsyKit
import SwiftUI

/// The home screen: bots as contacts. The chat metaphor only works if this reads like a list of
/// people rather than a list of configurations.
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
            Section("Bots") {
                ForEach(model.bots) { bot in
                    BotRow(bot: bot, isRunning: model.isRunning(bot.id))
                        .tag(bot.id)
                        .contextMenu { BotMenu(bot: bot) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { EngineStatusBar() }
        .toolbar {
            ToolbarItem {
                Button { isAddingBot = true } label: {
                    Label("New bot", systemImage: "plus")
                }
                .help("New bot")
            }
            ToolbarItem {
                Button { showsMachines = true } label: {
                    Label("Machines", systemImage: "server.rack")
                }
                .help("Cloud machines your bots can use")
            }
            ToolbarItem {
                Button { showsConnectors = true } label: {
                    Label("Apps", systemImage: "puzzlepiece.extension")
                }
                .help("Apps your bots can use")
            }
            ToolbarItem {
                Button { showsAttention = true } label: {
                    Label("Waiting on you", systemImage: model.attentionItems.isEmpty
                          ? "tray" : "tray.full.fill")
                }
                .help(model.attentionItems.isEmpty
                      ? "Nothing needs you"
                      : "\(model.attentionItems.count) waiting on you")
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.attentionItems.isEmpty ? Color.secondary : Color.orange)
            }
        }
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
        .sheet(isPresented: $showsMachines) { MachinesSheet() }
        .sheet(isPresented: $showsConnectors) { ConnectorsSheet() }
        .sheet(isPresented: $showsAttention) { AttentionInbox() }
    }
}

/// Right-click a bot. Assigning a machine lives here rather than behind a settings screen,
/// because it is the one setting that changes what a bot can actually promise.
struct BotMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        Menu("Machine") {
            Button {
                model.assign(bot, to: nil)
            } label: {
                Label("This Mac", systemImage: bot.machineID == nil ? "checkmark" : "")
            }
            if model.machines.isEmpty {
                Text("No machines yet")
            } else {
                Divider()
                ForEach(model.machines) { machine in
                    Button {
                        model.assign(bot, to: machine.id)
                    } label: {
                        Label(machine.name,
                              systemImage: bot.machineID == machine.id ? "checkmark" : "")
                    }
                }
            }
        }

        Menu("Engine") {
            ForEach([EngineID.claude, .codex], id: \.self) { engine in
                Button {
                    model.setEngine(bot, engine)
                } label: {
                    Label(engine.displayName,
                          systemImage: bot.engine == engine ? "checkmark" : "")
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

        if !model.connectors.isEmpty {
            Menu("Apps") {
                ForEach(model.connectors) { server in
                    Button {
                        model.setConnectorAllowed(
                            bot, server, !bot.toolAllowlist.contains(server.toolPrefix))
                    } label: {
                        Label("\(server.name) — no need to ask",
                              systemImage: bot.toolAllowlist.contains(server.toolPrefix)
                                  ? "checkmark" : "")
                    }
                }
            }
        }

        Menu("Trust") {
            ForEach(Autonomy.allCases, id: \.self) { level in
                Button {
                    model.setAutonomy(bot, level)
                } label: {
                    Label(label(for: level),
                          systemImage: bot.autonomy == level ? "checkmark" : "")
                }
            }
        }

        Menu("While working") {
            ForEach(KeepAwake.allCases, id: \.self) { setting in
                Button {
                    model.setKeepAwake(bot, setting)
                } label: {
                    Label(setting.label, systemImage: bot.keepAwake == setting ? "checkmark" : "")
                }
            }
        }

        Divider()
        Button("Delete bot", role: .destructive) { model.deleteBot(bot) }
    }

    private func label(for level: Autonomy) -> String {
        switch level {
        case .ask: "Ask me everything"
        case .allowlist: "Ask unless I've allowed it"
        case .trusted: "Ask before anything leaves this machine"
        case .auto: "Never ask"
        }
    }
}

struct BotRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let isRunning: Bool

    /// A glance at the roster should say which bot is busy and which is stuck on you, without
    /// reading a word. Waiting beats working: a bot blocked on a decision is the one that needs
    /// attention, even though it is also technically running.
    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if isRunning { return .working }
        return .idle
    }

    var body: some View {
        HStack(spacing: 10) {
            BotFace(hue: bot.avatarHue, mood: mood)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(bot.engine.displayName)
                    if let model = bot.model {
                        Text("· \(model)")
                    }
                    if bot.machineID == nil {
                        Text("· this Mac")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRunning && !model.isWaitingForApproval(bot.id) {
                ThinkingOrbs(hue: bot.avatarHue)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Shows whether each engine can actually run, not merely whether it is signed in.
struct EngineStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            ForEach(EngineID.allCases.filter { model.engineStatus[$0] != nil }, id: \.self) { engine in
                if let status = model.engineStatus[engine] {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.isUsable ? .green : .orange)
                            .frame(width: 6, height: 6)
                        Text(engine.displayName)
                            .font(.caption)
                        Spacer(minLength: 0)
                        Text(label(for: status))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help(detail(for: status))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func label(for status: AuthStatus) -> String {
        switch status {
        case .signedIn(let method): method == .apiKey ? "API key" : "subscription"
        case .signedInWithoutModelAccess: "no model access"
        case .signedOut: "signed out"
        case .unknown: "unknown"
        }
    }

    /// The distinction worth surfacing: a signed-in engine whose plan cannot run a model would
    /// otherwise look healthy and fail at 3am. See docs/01-spikes.md spike 6b.
    private func detail(for status: AuthStatus) -> String {
        switch status {
        case .signedIn: "Ready."
        case .signedInWithoutModelAccess(let detail):
            "Signed in, but this account cannot run a model.\n\(detail)"
        case .signedOut: "Sign in from Settings → Engines."
        case .unknown(let reason): reason
        }
    }
}

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engine = EngineID.claude

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New bot").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Engine", selection: $engine) {
                ForEach([EngineID.claude, .codex], id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("New bots start fully gated and have no cloud machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.addBot(name: name.trimmingCharacters(in: .whitespaces), engine: engine)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
