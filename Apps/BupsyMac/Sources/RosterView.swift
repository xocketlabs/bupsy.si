import BupsyKit
import SwiftUI

/// The home screen: bots as contacts. The chat metaphor only works if this reads like a list of
/// people rather than a list of configurations.
struct RosterView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingBot = false
    @State private var showsMachines = false

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
        }
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
        .sheet(isPresented: $showsMachines) { MachinesSheet() }
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
    let bot: Bot
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(hue: bot.avatarHue, isRunning: isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(bot.engine.displayName)
                    if bot.machineID == nil {
                        Text("· this Mac")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRunning {
                ThinkingOrb(hue: bot.avatarHue)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Status-driven avatar.
///
/// Placeholder for libraries.dev `bot-avatars`, which is React-only and needs a SwiftUI port
/// (docs/03-decisions.md #17). The shape of the API — a hue plus a status — is deliberately the
/// same, so swapping the implementation later does not touch the roster.
struct BotAvatar: View {
    let hue: Double
    let isRunning: Bool

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.95),
                        Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                              saturation: 0.7, brightness: 0.8),
                    ],
                    center: .center
                )
            )
            .frame(width: 26, height: 26)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                        .offset(x: 1, y: 1)
                }
            }
    }
}

/// Stand-in for libraries.dev `thinking-orbs`, which does ship a SwiftUI package — swap this for
/// the real one once the dependency is added. Runs are minutes long, so this is the most-seen
/// animation in the app and worth getting right.
struct ThinkingOrb: View {
    let hue: Double
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(hue: hue, saturation: 0.5, brightness: 0.9))
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.7)))
            }
        }
        .task {
            // A timer rather than a repeatForever animation: this view appears and disappears
            // with run state, and implicit animations on an unstable view flicker.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                phase += 0.22
            }
        }
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
