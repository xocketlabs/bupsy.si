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
    @State private var showsDetails = false
    /// The message being replied to, shown above the composer until sent or dismissed.
    @State private var replyingTo: ReplyTarget?
    @State private var tab = DetailTab.details

    private var thread: Thread { model.thread(for: bot.id) }
    private var routines: [Routine] { model.routines.filter { $0.botID == bot.id.rawValue } }
    private var objectives: [Objective] { model.objectives.filter { $0.botID == bot.id.rawValue } }

    var body: some View {
        HStack(spacing: 0) {
            PanelSurface {
                VStack(spacing: 0) {
                    conversation
                    Composer(draft: $draft, bot: bot, isRunning: thread.isRunning,
                             replyingTo: $replyingTo,
                             onSend: send, onStop: { model.stop(bot.id) })
                }
                // The pill floats over the transcript rather than sitting in a bar above it, so
                // the conversation reaches the top of the window instead of starting below a
                // strip of chrome that never changes.
                .overlay(alignment: .top) { titlePill }
            }
            .padding(.vertical, 8)
            // Flush to the details panel when it is open, exactly as the card is flush to the rail.
            .padding(.trailing, showsDetails ? 0 : 8)

            // Outside the card, on the window, full height — the mirror of the rail. It used to be
            // inside the card, so opening it filled the card's right side with the rail's colour,
            // swallowed the rounded corner on that edge, and made the two sides of the window
            // different shapes.
            if showsDetails {
                details
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsRoutines) { RoutinesSheet(bot: bot) }
        .sheet(isPresented: $showsObjectives) { ObjectivesSheet(bot: bot) }
    }

    // MARK: - Title

    /// Names the bot, and opens everything else about it.
    ///
    /// Replaces a breadcrumb and a page header that together cost about 160pt at the top of every
    /// conversation to say something the sidebar already showed in bold. What a bot *said* is the
    /// reason to be on this screen; what it is configured to do is a question you ask occasionally,
    /// so it lives one click away rather than above the thing you came for.
    private var titlePill: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { showsDetails.toggle() } } label: {
            HStack(spacing: Theme.Space.tight) {
                BotFace(bot: bot, mood: mood, size: Theme.scaled(20))
                Text(bot.name)
                    .font(Theme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.foreground)
                if let badge = limitBadge {
                    Text(badge)
                        .font(Theme.Typography.badge)
                        .foregroundStyle(palette.mutedForeground)
                }
                Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: Theme.scaled(8), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.leading, Theme.Space.snug)
            .padding(.trailing, Theme.Space.step)
            .padding(.vertical, 7)
            .background(palette.card, in: .capsule)
            .overlay(Capsule().stroke(palette.border, lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Settings, goals and routines for \(bot.name)")
        .padding(.top, Theme.Space.step)
    }

    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        return thread.isRunning ? .working : .idle
    }

    // MARK: - Everything that is not the conversation

    /// The bot's setup, beside the conversation rather than above it.
    ///
    /// A panel rather than a sheet: changing a bot's trust level or reading why a routine failed
    /// is something you do *while* looking at what it said, and a sheet would cover exactly the
    /// evidence you are deciding from.
    private var details: some View {
        VStack(spacing: 0) {
            detailsHead

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    switch tab {
                    case .details:
                        settings
                        goals
                        routineSection
                    case .activity:
                        usage
                        history
                    case .computer:
                        computer
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, Theme.Space.section)
            }
        }
        .frame(width: 340)
        // Clipped, because a card wider than the panel should truncate rather than draw over the
        // conversation beside it.
        .clipped()
        .background(palette.sidebar)
    }

    /// Who the bot is, then what you want to know about it.
    ///
    /// The identity sits above the tabs rather than inside one of them: it is the answer to
    /// "which bot am I looking at", which stays true whichever tab is open.
    private var detailsHead: some View {
        VStack(spacing: Theme.Space.snug) {
            BotFace(bot: bot, mood: mood, size: 64)
            Text(bot.name)
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            if let job = bot.personaPrompt, !job.isEmpty {
                Text(job)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, Theme.Space.tight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.gutter)
        // The same clearance as the rail, which also runs up under the title bar.
        .padding(.top, 30)
        .padding(.bottom, Theme.Space.gutter)
    }

    /// Where this bot's work actually happens.
    ///
    /// Grok Bot shows a live screen here. bupsy cannot yet — a cloud machine has no screen to
    /// stream and the local host has no window of its own — so this says what is true rather than
    /// drawing an empty frame labelled as one.
    private var computer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SettingsGroup(title: "Runs on") {
                SettingRow(label: "Machine", value: machineName,
                           icon: bot.machineID == nil ? "laptopcomputer" : "server.rack",
                           showsDivider: false) {
                    Button("This Mac") { model.assign(bot, to: nil) }
                    if !model.machines.isEmpty {
                        Divider()
                        ForEach(model.machines) { machine in
                            Button(machine.name) { model.assign(bot, to: machine.id) }
                        }
                    }
                }
                FactRow(label: "Survives sleep",
                        value: bot.scheduleTier == .alwaysOn ? "Yes" : "No")
                SettingRow(label: "Folder", value: folderLabel, icon: "folder") {
                    Button("Choose folder…") { model.chooseWorkdir(for: bot) }
                    if bot.workdir != nil {
                        Button("Use its own folder") { model.setWorkdir(bot, nil) }
                    }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [model.workingDirectory(for: bot)])
                    }
                }
            }

            Text(bot.machineID == nil
                 ? "Running on this Mac, under your own sign-in. Routines only fire while the Mac "
                   + "is awake."
                 : "Running on a cloud machine on your own boat.dev account.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What this bot has actually used, and nothing it has not.
    ///
    /// Every number here is reported by the engine: the windows come from Claude's
    /// `rate_limit_event`, the tokens from each run's own result line. Deliberately missing is any
    /// "context window" percentage — the engine reports what a turn *sent*, never how large the
    /// window is, so a percentage would mean hardcoding a limit per model and watching it rot into
    /// a confident wrong number. "Largest turn" says the same thing without pretending.
    ///
    /// The section is absent, not empty, until something is known. A usage panel full of zeroes
    /// reads as broken, and worse, as real.
    @ViewBuilder
    private var usage: some View {
        let runs = model.recentRuns(for: bot)
        let windows = thread.latestLimits?.windows ?? [:]
        let counted = runs.compactMap(\.inputTokens)

        if !windows.isEmpty || !counted.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                if !windows.isEmpty {
                    SettingsGroup(title: "Your \(bot.engine.displayName) limits") {
                        ForEach(windows.sorted(by: { $0.key < $1.key }), id: \.key) { name, window in
                            LimitBar(name: Self.windowLabel(name), window: window,
                                     showsDivider: name != windows.keys.sorted().first)
                        }
                    }
                }

                if !counted.isEmpty {
                    SettingsGroup(title: "Tokens") {
                        FactRow(label: "Runs", value: "\(runs.count)", showsDivider: false)
                        FactRow(label: "Sent", value: Self.compact(counted.reduce(0, +)))
                        FactRow(label: "Received",
                                value: Self.compact(runs.compactMap(\.outputTokens).reduce(0, +)))
                        // Says why a long thread is cheaper than its token count suggests, and
                        // why "sent" is so much larger than anything that was typed.
                        FactRow(label: "Largest turn", value: Self.compact(counted.max() ?? 0))
                        // Labelled as a value, never a bill: on a subscription nobody pays per
                        // token. Absent rather than "$0" for engines that report no figure.
                        if let cost = model.usage(for: bot)?.costUSD {
                            FactRow(label: "API-equivalent", value: UsageFormat.dollars(cost))
                        }
                    }
                }
            }
        }
    }

    /// Engine window names are snake_case and internal. These are not.
    static func windowLabel(_ name: String) -> String {
        switch name {
        case "five_hour": "Five hours"
        case "seven_day": "This week"
        case "seven_day_opus": "This week, Opus"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }

    /// What this bot is set to, as rows rather than chips.
    ///
    /// Chips read fine across a wide page and fall apart in a column: they cannot wrap, their
    /// labels truncate first, and there is nowhere to say what the setting is called. A row keeps
    /// the name on the left at full width and truncates only the value.
    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SettingsGroup(title: "Runs with") {
                SettingRow(label: "Engine", value: bot.engine.displayName,
                           icon: "cpu", showsDivider: false) {
                    ForEach([EngineID.claude, .codex], id: \.self) { engine in
                        Button {
                            model.setEngine(bot, engine)
                        } label: {
                            Label(engine.displayName,
                                  systemImage: bot.engine == engine ? "checkmark" : "")
                        }
                    }
                }
                SettingRow(label: "Model", value: modelLabel ?? "Default",
                           icon: "slider.horizontal.3") {
                    ForEach(model.models(for: bot)) { option in
                        Button {
                            model.setModel(bot, option.id)
                        } label: {
                            Label(option.label,
                                  systemImage: bot.model == option.id ? "checkmark" : "")
                        }
                    }
                }
                SettingRow(label: "Runs on", value: machineName,
                           icon: bot.machineID == nil ? "laptopcomputer" : "server.rack") {
                    Button("This Mac") { model.assign(bot, to: nil) }
                    if !model.machines.isEmpty {
                        Divider()
                        ForEach(model.machines) { machine in
                            Button(machine.name) { model.assign(bot, to: machine.id) }
                        }
                    }
                }
            }

            SettingsGroup(title: "Can touch") {
                SettingRow(label: "Folder", value: folderLabel,
                           icon: "folder", showsDivider: false) {
                    Button("Choose folder…") { model.chooseWorkdir(for: bot) }
                    if bot.workdir != nil {
                        Button("Use its own folder") { model.setWorkdir(bot, nil) }
                    }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [model.workingDirectory(for: bot)])
                    }
                }
                SettingRow(label: "Trust", value: trustLabel,
                           icon: "hand.raised", tone: trustTone) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Button {
                            model.setAutonomy(bot, level)
                        } label: {
                            Label(label(for: level),
                                  systemImage: bot.autonomy == level ? "checkmark" : "")
                        }
                    }
                }
                SettingRow(label: "Folder in sidebar", value: bot.folder ?? "None",
                           icon: "tray.2") {
                    ForEach(model.folders, id: \.self) { folder in
                        Button {
                            model.setFolder(bot, folder)
                        } label: {
                            Label(folder, systemImage: bot.folder == folder ? "checkmark" : "")
                        }
                    }
                    if bot.folder != nil {
                        Divider()
                        Button("Remove from folder") { model.setFolder(bot, nil) }
                    }
                }
            }
        }
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
    /// "Its own folder" rather than "No folder", because there is one: a private, empty folder
    /// that keeps the bot's tools off the rest of the disk. "No folder" read as harmless and
    /// hid that the alternative had been the root of the drive.
    private var folderLabel: String {
        guard let path = bot.workdir else { return "Its own folder" }
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
        Group {
            if thread.entries.isEmpty {
                EmptyConversation(bot: bot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.step) {
                            ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
                                if showsDaySeparator(at: index) { DaySeparator(date: entry.at) }
                                Bubble(entry: entry, bot: bot, showsAvatar: showsAvatar(at: index),
                                       onReply: { author, text in
                                           replyingTo = ReplyTarget(author: author, text: text)
                                       })
                                    .id(entry.id)
                            }
                            // Not while it is waiting on you. The dots say "the bot is working" —
                            // under an approval card that is false, and it is false at exactly
                            // the moment the person needs to understand that nothing will happen
                            // until they answer.
                            if thread.isRunning && !model.isWaitingForApproval(bot.id) {
                                TypingIndicator(bot: bot)
                            }
                        }
                        // Top padding clears the floating title pill, which overlays this.
                        .padding(.top, 56)
                        .padding(.bottom, Theme.Space.gutter)
                        .padding(.horizontal, Theme.Space.section)
                        .frame(maxWidth: Theme.Size.contentMaxWidth)
                        // Centred, not leading: the composer is centred in the pane, and a
                        // transcript hugging the left edge while the box you type into sits in
                        // the middle reads as two unrelated panels.
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Short threads sit on the composer rather than floating at the top of an
                        // empty pane. Every messaging app does this, and the first reply in a new
                        // conversation is exactly when the difference is most obvious.
                        .frame(minHeight: geometry.size.height, alignment: .bottom)
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// What a bot has actually done, including while nobody was watching.
    ///
    /// Every run and its events have been stored since the first commit; nothing read them back,
    /// so unattended work was invisible even after it happened — which is most of the reason to
    /// have done it unattended.
    @ViewBuilder
    private var history: some View {
        let runs = model.recentRuns(for: bot)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                SectionHeader(
                    icon: "clock.arrow.circlepath",
                    title: "Recent runs",
                    badge: nil,
                    subtitle: "Including the ones that happened while you were away"
                ) { EmptyView() }

                VStack(spacing: Theme.Space.snug) {
                    ForEach(runs.prefix(8)) { run in
                        CardRow {
                            IconTile(systemName: run.succeeded
                                     ? "checkmark" : (run.endedAt == nil ? "ellipsis" : "xmark"))
                        } content: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(run.prompt ?? "No prompt recorded")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(palette.foreground)
                                    .lineLimit(1)
                                HStack(spacing: Theme.Space.snug) {
                                    Text(Theme.stamp(run.startedAt))
                                    if let duration = run.duration {
                                        MetaDot()
                                        Text(durationLabel(duration))
                                    }
                                    if run.toolCalls > 0 {
                                        MetaDot()
                                        Text(run.toolCalls == 1
                                             ? "1 action" : "\(run.toolCalls) actions")
                                    }
                                    if run.host != "local" {
                                        MetaDot()
                                        Text("on a machine")
                                    }
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                            }
                        } trailing: { EmptyView() }
                    }
                }
            }
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(Int(seconds))s"
            : "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        // A reply carries its quote to the engine, so "this" means the message you pointed at.
        let prompt = replyingTo.map {
            Reply.compose(quoting: $0.text, from: $0.author, message: message)
        } ?? message
        draft = ""
        replyingTo = nil
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
                    .font(.system(size: Theme.scaled(11)))
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
                Image(systemName: "plus").font(.system(size: Theme.scaled(11)))
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
            BotFace(bot: bot, mood: .idle, size: 56)
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


/// A message someone has chosen to reply to.
struct ReplyTarget: Equatable {
    let author: String
    let text: String
}

/// The three questions worth asking about a bot, in the order people ask them.
///
/// Named for what each holds rather than copied wholesale from Grok Bot, which has a "Library"
/// tab for a concept bupsy does not have. An empty tab is the same mistake as a dead menu item.
enum DetailTab: CaseIterable {
    case details
    case activity
    case computer

    var label: String {
        switch self {
        case .details: "Details"
        case .activity: "Activity"
        case .computer: "Computer"
        }
    }
}
