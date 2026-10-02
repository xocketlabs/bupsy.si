import BupsyKit
import SwiftUI

/// One bot, as a page: who it is, the conversation, and what it does on its own.
///
/// Everything about a bot on one surface, in the order someone would ask about it — rather than
/// a chat box with the rest behind icons. Goals and routines sit below the conversation as card
/// rows, so they are part of the page instead of somewhere you have to know to look.
struct BotPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot

    @State private var draft = ""
    @State private var showsRoutines = false
    @State private var showsObjectives = false

    private var thread: Thread { model.thread(for: bot.id) }
    private var routines: [Routine] { model.routines.filter { $0.botID == bot.id.rawValue } }
    private var objectives: [Objective] { model.objectives.filter { $0.botID == bot.id.rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: ["Bots", bot.name]) { EmptyView() }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    header
                    chips
                    Rule()
                    conversation
                    Rule()
                    goals
                    routineSection
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, Theme.Space.section)
                .frame(maxWidth: Theme.Size.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }

            Composer(draft: $draft, bot: bot, isRunning: thread.isRunning,
                     onSend: send, onStop: { model.stop(bot.id) })
        }
        .sheet(isPresented: $showsRoutines) { RoutinesSheet(bot: bot) }
        .sheet(isPresented: $showsObjectives) { ObjectivesSheet(bot: bot) }
    }

    // MARK: - Head

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bot.name)
                .font(Theme.Typography.title)
                .foregroundStyle(palette.foreground)
            if let job = bot.personaPrompt {
                Text(job).font(Theme.Typography.body).foregroundStyle(palette.mutedForeground)
            }
        }
    }

    /// The facts that change what a bot can do, at a glance and in one row.
    private var chips: some View {
        HStack(spacing: Theme.Space.snug) {
            MenuChip(icon: "cpu", text: bot.engine.displayName, emphasised: true) {
                ForEach([EngineID.claude, .codex], id: \.self) { engine in
                    Button {
                        model.setEngine(bot, engine)
                    } label: {
                        Label(engine.displayName,
                              systemImage: bot.engine == engine ? "checkmark" : "")
                    }
                }
            }

            MenuChip(icon: "slider.horizontal.3", text: modelLabel ?? "Default model") {
                ForEach(model.models(for: bot)) { option in
                    Button {
                        model.setModel(bot, option.id)
                    } label: {
                        Label(option.label, systemImage: bot.model == option.id ? "checkmark" : "")
                    }
                }
            }

            MenuChip(icon: bot.machineID == nil ? "laptopcomputer" : "server.rack",
                     text: machineName) {
                Button("This Mac") { model.assign(bot, to: nil) }
                if !model.machines.isEmpty {
                    Divider()
                    ForEach(model.machines) { machine in
                        Button(machine.name) { model.assign(bot, to: machine.id) }
                    }
                }
            }

            MenuChip(icon: "folder", text: folderLabel,
                     tone: bot.workdir == nil ? nil : nil) {
                Button("Choose folder…") { model.chooseWorkdir(for: bot) }
                if bot.workdir != nil {
                    Button("No folder") { model.setWorkdir(bot, nil) }
                }
            }

            MenuChip(icon: "hand.raised", text: trustLabel, tone: trustTone) {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    Button {
                        model.setAutonomy(bot, level)
                    } label: {
                        Label(label(for: level), systemImage: bot.autonomy == level ? "checkmark" : "")
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Trust levels in the words they mean to a person, not their internal names.
    private func label(for level: Autonomy) -> String {
        switch level {
        case .ask: "Ask before everything"
        case .allowlist: "Ask unless I've allowed it"
        case .trusted: "Ask before anything leaves the machine"
        case .auto: "Never ask"
        }
    }

    private var modelLabel: String? {
        guard bot.model != nil else { return nil }
        return model.models(for: bot).first { $0.id == bot.model }?.label
    }

    /// Shows the folder's own name rather than a path — the path is long and the name is what
    /// anyone actually recognises.
    private var folderLabel: String {
        guard let path = bot.workdir else { return "No folder" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var machineName: String {
        guard let id = bot.machineID,
              let machine = model.machines.first(where: { $0.id == id })
        else { return "This Mac" }
        return machine.name
    }

    private var trustLabel: String {
        switch bot.autonomy {
        case .ask: "Asks before everything"
        case .allowlist: "Asks unless allowed"
        case .trusted: "Asks before leaving the machine"
        case .auto: "Never asks"
        }
    }

    /// Only the setting that removes the brakes gets the accent. The others are ordinary facts.
    private var trustTone: Color? { bot.autonomy == .auto ? palette.destructive : nil }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SectionHeader(
                icon: "bubble.left.and.text.bubble.right",
                title: "Conversation",
                badge: limitBadge,
                subtitle: "Running \(bot.engine.displayName) under your own sign-in"
            ) { EmptyView() }

            if thread.entries.isEmpty {
                EmptyConversation(bot: bot)
            } else {
                // The transcript scrolls inside its own box rather than growing the page.
                //
                // Sharing one scroll with the sections below seemed simpler and is wrong in use:
                // after a few exchanges, standing goals and routines sit under an unbounded
                // conversation and effectively cease to exist. A bounded transcript keeps the
                // whole page reachable no matter how long a thread runs.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.step) {
                            ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
                                if showsDaySeparator(at: index) { DaySeparator(date: entry.at) }
                                Bubble(entry: entry, bot: bot, showsAvatar: showsAvatar(at: index))
                                    .id(entry.id)
                            }
                            if thread.isRunning { TypingIndicator(bot: bot) }
                        }
                        .padding(.vertical, Theme.Space.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Tall enough to read, short enough that what is below it stays in view.
                    .frame(minHeight: 180, maxHeight: 460)
                    .onChange(of: thread.entries.count) {
                        guard let last = thread.entries.last else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var limitBadge: String? {
        guard let tightest = thread.latestLimits?.tightest else { return nil }
        let window = tightest.name.replacingOccurrences(of: "_", with: "-")
        return "\(Int(tightest.window.utilization * 100))% of \(window) limit"
    }

    private func showsDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            thread.entries[index].at, inSameDayAs: thread.entries[index - 1].at)
    }

    private func showsAvatar(at index: Int) -> Bool {
        guard thread.entries[index].isFromBot else { return false }
        guard index > 0 else { return true }
        return !thread.entries[index - 1].isFromBot
    }

    // MARK: - On its own

    private var goals: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SectionHeader(
                icon: "target",
                title: "Standing goals",
                badge: objectives.isEmpty ? nil : "\(objectives.filter(\.enabled).count) active",
                subtitle: "Things \(bot.name) keeps true, checked on a schedule"
            ) {
                Button("New goal") { showsObjectives = true }
                    .buttonStyle(QuietButton())
            }

            if objectives.isEmpty {
                EmptyRow(text: "No standing goals yet.") { showsObjectives = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(objectives) { objective in
                        CardRow {
                            IconTile(systemName: objective.lastOutcome?.needsAttention == true
                                     ? "exclamationmark.triangle" : "checkmark.circle")
                        } content: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(objective.goal)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.foreground)
                                    .lineLimit(1)
                                HStack(spacing: Theme.Space.snug) {
                                    Text(checkedLabel(objective))
                                    MetaDot()
                                    Text(Schedule.describe(objective.checkCron))
                                    if let outcome = objective.lastOutcome {
                                        MetaDot()
                                        Text(outcome.label)
                                            .foregroundStyle(outcome.needsAttention
                                                             ? palette.primary : Color.green)
                                    }
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                            }
                        } trailing: {
                            Button("Check now") { model.checkObjective(objective) }
                                .buttonStyle(QuietButton(compact: true))
                        }
                    }
                }
            }
        }
    }

    private func checkedLabel(_ objective: Objective) -> String {
        guard let at = objective.lastCheckedAt else { return "Never checked" }
        return "Checked \(Theme.stamp(at))"
    }

    private var routineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SectionHeader(
                icon: "clock",
                title: "Routines",
                badge: routines.isEmpty ? nil : "\(routines.filter(\.enabled).count)",
                subtitle: "Jobs \(bot.name) does on a schedule"
            ) {
                Button("New routine") { showsRoutines = true }
                    .buttonStyle(QuietButton())
            }

            if routines.isEmpty {
                EmptyRow(text: "No routines yet.") { showsRoutines = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(routines) { routine in
                        CardRow {
                            IconTile(systemName: "calendar")
                        } content: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(routine.name)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.foreground)
                                HStack(spacing: Theme.Space.snug) {
                                    Text(Schedule.describe(routine.cron))
                                    MetaDot()
                                    Text(routine.tier.label)
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                            }
                        } trailing: {
                            Button("Edit") { showsRoutines = true }
                                .buttonStyle(QuietButton(compact: true))
                        }
                    }
                }
            }
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        model.send(prompt, to: bot)
    }
}

// MARK: - Shell pieces

/// Breadcrumbs rather than a title. A page in a dashboard says where you are, not just what
/// you are looking at.
struct Topbar<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let trail: [String]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.snug) {
                Text("bupsy").foregroundStyle(palette.mutedForeground)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, part in
                    Text("/").foregroundStyle(palette.border)
                    Text(part)
                        .foregroundStyle(index == trail.count - 1
                                         ? palette.foreground : palette.mutedForeground)
                        .fontWeight(index == trail.count - 1 ? .medium : .regular)
                }
            }
            .font(Theme.Typography.body)

            Spacer(minLength: Theme.Space.step)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

struct MachineButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot

    var body: some View {
        Menu {
            Button("This Mac") { model.assign(bot, to: nil) }
            if !model.machines.isEmpty {
                Divider()
                ForEach(model.machines) { machine in
                    Button(machine.name) { model.assign(bot, to: machine.id) }
                }
            }
        } label: {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: bot.machineID == nil ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 11))
                Text(label).font(Theme.Typography.body)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(palette.foreground)
    }

    private var label: String {
        guard let id = bot.machineID,
              let machine = model.machines.first(where: { $0.id == id })
        else { return "This Mac" }
        return machine.name
    }
}

struct Rule: View {
    @Environment(\.palette) private var palette
    var body: some View { Rectangle().fill(palette.border).frame(height: 1) }
}

struct QuietButton: ButtonStyle {
    @Environment(\.palette) private var palette
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, compact ? 10 : Theme.Space.gutter)
            .frame(height: compact ? 32 : Theme.Size.control)
            .background(configuration.isPressed ? palette.cardHover : palette.secondary,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(palette.border)
            }
    }
}

struct EmptyRow: View {
    @Environment(\.palette) private var palette
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text).font(Theme.Typography.body).foregroundStyle(palette.mutedForeground)
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.system(size: 11))
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(Theme.Space.gutter)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyConversation: View {
    @Environment(\.palette) private var palette
    let bot: Bot

    var body: some View {
        VStack(spacing: Theme.Space.step) {
            BotFace(hue: bot.avatarHue, mood: .idle, size: 56)
            Text("Say something to \(bot.name)")
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            Text("Asks before it acts. Nothing beyond reading runs without you.")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.section)
    }
}
