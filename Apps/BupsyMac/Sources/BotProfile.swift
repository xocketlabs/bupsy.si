import BupsyKit
import SwiftUI

/// Everything about one bot, on a surface you can see.
///
/// The same gesture as tapping a name in Messages. Before this, a bot's engine, model, trust
/// level, machine, apps, routines and goals lived across two toolbars and three right-click
/// menus, which meant a new user met a chat box and no indication that any of it existed.
///
/// Settings are grouped by the question they answer — who it is, what it runs on, what it may do,
/// what it does on its own — rather than by which subsystem implements them.
struct BotProfile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot

    @State private var showsRoutines = false
    @State private var showsObjectives = false

    private var routineCount: Int {
        model.routines.filter { $0.botID == bot.id.rawValue && $0.enabled }.count
    }
    private var objectiveCount: Int {
        model.objectives.filter { $0.botID == bot.id.rawValue && $0.enabled }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header

                section("Brain") {
                    picker("Engine", selection: Binding(
                        get: { bot.engine },
                        set: { model.setEngine(bot, $0) }
                    )) {
                        ForEach([EngineID.claude, .codex], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    picker("Model", selection: Binding(
                        get: { bot.model },
                        set: { model.setModel(bot, $0) }
                    )) {
                        ForEach(model.models(for: bot)) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    if let detail = model.models(for: bot).first(where: { $0.id == bot.model })?.detail {
                        note(detail)
                    }
                }

                section("Computer") {
                    picker("Runs on", selection: Binding(
                        get: { bot.machineID },
                        set: { model.assign(bot, to: $0) }
                    )) {
                        Text("This Mac").tag(String?.none)
                        ForEach(model.machines) { machine in
                            Text(machine.name).tag(String?.some(machine.id))
                        }
                    }
                    note(bot.machineID == nil
                         ? "Scheduled work only runs while your Mac is awake."
                         : "Scheduled work runs even with your Mac closed.")

                    picker("While working", selection: Binding(
                        get: { bot.keepAwake },
                        set: { model.setKeepAwake(bot, $0) }
                    )) {
                        ForEach(KeepAwake.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                section("What it may do") {
                    picker("Asks me", selection: Binding(
                        get: { bot.autonomy },
                        set: { model.setAutonomy(bot, $0) }
                    )) {
                        ForEach(Autonomy.allCases, id: \.self) {
                            Text(trustLabel($0)).tag($0)
                        }
                    }
                    note(trustDetail(bot.autonomy))

                    if !model.connectors.isEmpty {
                        ForEach(model.connectors) { server in
                            Toggle(isOn: Binding(
                                get: { bot.toolAllowlist.contains(server.toolPrefix) },
                                set: { model.setConnectorAllowed(bot, server, $0) }
                            )) {
                                Text("\(server.name) without asking").font(.callout)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }

                section("On its own") {
                    row("Routines", count: routineCount) { showsRoutines = true }
                    row("Standing goals", count: objectiveCount) { showsObjectives = true }
                }
            }
            .padding(Theme.Space.gutter)
        }
        .background(palette.sidebar)
        .sheet(isPresented: $showsRoutines) { RoutinesSheet(bot: bot) }
        .sheet(isPresented: $showsObjectives) { ObjectivesSheet(bot: bot) }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.snug) {
            BotFace(hue: bot.avatarHue, mood: .idle, size: Theme.Size.profileAvatar)
            Text(bot.name)
                .font(Theme.Typography.title)
                .foregroundStyle(palette.foreground)
            if let job = bot.personaPrompt {
                Text(job)
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.snug)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(title.uppercased())
                .font(Theme.Typography.badge)
                .foregroundStyle(palette.sidebarMuted)
                .tracking(0.7)
            content()
        }
    }

    private func picker<T: Hashable, Content: View>(
        _ label: String, selection: Binding<T>, @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(label, selection: selection, content: content)
            .pickerStyle(.menu)
            .controlSize(.small)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Spacer()
                if count > 0 {
                    Badge(text: "\(count)")
                } else {
                    Text("None")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.sidebarMuted)
            }
            .padding(.horizontal, Theme.Space.step)
            .frame(height: Theme.Size.control)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Trust levels described by what they mean to the person, not by their internal names.
    private func trustLabel(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Before everything"
        case .allowlist: "Unless I've allowed it"
        case .trusted: "Before anything leaves this machine"
        case .auto: "Never"
        }
    }

    private func trustDetail(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Every command and file change stops and waits for you."
        case .allowlist: "Reads run free. Everything else asks unless you've allowed it."
        case .trusted: "Works freely here, but asks before touching anything outside."
        case .auto: "Does whatever it decides to. Everything is still written down."
        }
    }
}
