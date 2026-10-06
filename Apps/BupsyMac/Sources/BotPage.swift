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
    @Environment(\.colorScheme) private var colorScheme
    let bot: Bot

    @State private var draft = ""
    @State private var showsRoutines = false
    /// The routine open as a page in place of the conversation, if any.
    @State private var openRoutineID: String?
    @State private var editingRoutine: Routine?
    @State private var showsObjectives = false
    @State private var showsNewWatch = false
    /// Kept outside the page, because the page is rebuilt for each bot (see BupsyApp's panel):
    /// opening the details for one bot leaves them open as you move to the next, as before.
    @AppStorage("bupsy.botPage.showsDetails", store: AppHome.defaults) private var showsDetails = false
    @State private var editingBot: Bot?
    /// The message being replied to, shown above the composer until sent or dismissed.
    @State private var replyingTo: ReplyTarget?
    @State private var tab = DetailTab.details
    @State private var awayFromBottom = false
    /// The goal whose "what it's learned" notes are open under its row, if any.
    @State private var notesObjectiveID: String?
    /// Set to ask before deleting. Owned by the page, never by a menu, which is gone on click.
    @State private var deletingObjective: Objective?
    @State private var deletingWatch: FolderWatch?

    private var thread: Thread { model.thread(for: bot.id) }
    private var routines: [Routine] { model.routines.filter { $0.botID == bot.id.rawValue } }
    /// Looked up live, so a deleted routine closes its page by itself.
    private var openRoutine: Routine? {
        guard let openRoutineID else { return nil }
        return routines.first { $0.id == openRoutineID }
    }
    private var objectives: [Objective] { model.objectives.filter { $0.botID == bot.id.rawValue } }

    var body: some View {
        // One card, like every page: the chat on the left and, when open, the bot's details on
        // the right behind a hairline, so the two read as one object rather than two windows.
        PanelSurface {
            HStack(spacing: 0) {
                // A routine opened from the panel takes the conversation's place, so its history
                // and schedule have the room they need. Back returns to the chat as it was.
                if let routine = openRoutine {
                    RoutineDetailView(routine: routine, bot: bot, onClose: { openRoutineID = nil })
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        topbar
                        conversation
                        Composer(draft: $draft, bot: bot, isRunning: thread.isRunning,
                                 replyingTo: $replyingTo,
                                 onSend: send, onStop: { model.stop(bot.id) })
                    }
                    .frame(maxWidth: .infinity)
                }

                if showsDetails {
                    Rectangle().fill(palette.border).frame(width: 1)
                    details
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding([.top, .bottom, .trailing], 8)
        // Each sheet on its own view: two sheets on one view and SwiftUI silently shows only one.
        // The panel already lists routines and goals, so "New" opens the form itself rather than
        // a second list with its own New button.
        .background { Color.clear.sheet(isPresented: $showsRoutines) { NewRoutineSheet(bot: bot) } }
        .background { Color.clear.sheet(isPresented: $showsObjectives) { NewObjectiveSheet(bot: bot) } }
        .background { Color.clear.sheet(item: $editingRoutine) { NewRoutineSheet(bot: bot, editing: $0) } }
        .background { Color.clear.sheet(item: $editingBot) { BotCreatorSheet(editing: $0) } }
        // The folder watch form is the new-routine sheet opened on its Folder watch tab.
        .background { Color.clear.sheet(isPresented: $showsNewWatch) { NewRoutineSheet(bot: bot, kind: .folderWatch) } }
        .background {
            Color.clear.confirmsObjectiveDeletion($deletingObjective) { model.deleteObjective($0) }
        }
        .background {
            Color.clear.confirmsDeletion(
                of: $deletingWatch,
                title: { "Delete the folder watch \u{201C}\($0.name)\u{201D}?" },
                button: "Delete watch",
                message: { _ in
                    "\(bot.name) stops running when files in that folder change. The folder and its files are not touched. This can't be undone."
                },
                perform: { model.deleteFolderWatch($0) })
        }
        // A routine open for one bot must not stay open, unrelated, on the next.
        .onChange(of: bot.id) { openRoutineID = nil }
        .onChange(of: model.tourDetails, initial: true) { old, new in
            // Only a tour ending closes the panel. On appear there is no tour, and closing it then
            // would undo the remembered choice every time you switch bots.
            if let new { tab = new; showsDetails = true } else if old != nil { showsDetails = false }
        }
        .onChange(of: model.tourSheet, initial: true) { _, new in
            showsRoutines = new == "newRoutine"
            if new == "editBot" { editingBot = bot } else { editingBot = nil }
        }
    }

    // MARK: - Title

    /// Where you are, what the bot is up to, and the way into everything else about it.
    ///
    /// What a bot *said* is the reason to be on this screen; what it is configured to do is a
    /// question you ask occasionally, so it lives one click away rather than above the thread.
    private var topbar: some View {
        Topbar(trail: crumbs) {
            statusBadge
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showsDetails.toggle() }
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    BotFace(bot: bot, mood: mood, size: Theme.scaled(18))
                    Text(showsDetails ? "Hide details" : "Details")
                }
            }
            .buttonStyle(ThreadButtonStyle(kind: .secondary, height: Theme.Size.control))
            .help("Settings, goals and routines for \(bot.name)")
        }
    }

    private var crumbs: [String] {
        if showsDetails { return [bot.name, "Details"] }
        if let folder = bot.folder, !folder.isEmpty { return [folder, bot.name] }
        return [bot.name, "Chat"]
    }

    /// At most one status at a time, in order of how much it needs you.
    @ViewBuilder
    private var statusBadge: some View {
        if model.isWaitingForApproval(bot.id) {
            ThreadStatusBadge(text: "Needs you", tone: palette.primary, dot: true)
        } else if thread.isRunning {
            // What it is doing right now ("Running npm test", "Editing login.ts"), not just
            // that it is busy. Same words as the line under the thread.
            ThreadStatusBadge(text: ChatLiveStatus.text(for: thread.entries),
                              tone: palette.infoText, dot: true)
        } else if let badge = limitBadge {
            ThreadStatusBadge(text: badge, tone: limitIsHigh ? palette.warning : nil)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailsHead
                tabBar

                switch tab {
                case .details:
                    settings
                    goals
                    routineSection
                    watchSection
                case .activity:
                    usage
                    history
                case .files:
                    BotFilesList(bot: bot)
                case .computer:
                    computer
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, Theme.Space.section)
        }
        .frame(width: 340)
        // Clipped, because a card wider than the panel should truncate rather than draw over the
        // conversation beside it.
        .clipped()
    }

    private var isDark: Bool { colorScheme == .dark }

    /// Who the bot is: its face, its name and label, and its job in a sentence.
    private var detailsHead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            BotFace(bot: bot, mood: mood, size: 64)
            HStack(spacing: Theme.Space.snug) {
                Text(bot.name)
                    .font(.system(size: Theme.scaled(16), weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.foreground)
                InlineLabelField(bot: bot)
            }
            if let job = bot.personaPrompt, !job.isEmpty {
                Text(job)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The four questions worth asking about a bot, as a segmented strip.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.label)
                        .font(Theme.Typography.label.weight(tab == item ? .medium : .regular))
                        .foregroundStyle(tab == item ? palette.foreground : palette.mutedForeground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(tab == item ? (isDark ? palette.cardHover : palette.background) : Color.clear,
                                    in: .rect(cornerRadius: Theme.Radius.control))
                        .shadow(color: tab == item ? Color.black.opacity(0.06) : Color.clear, radius: 1, y: 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
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
                // The live figure if a run reported one this session, else the last saved run's.
                let lastUsage = thread.latestUsage ?? runs.first.flatMap { run in
                    run.inputTokens.map { Usage(inputTokens: $0, outputTokens: run.outputTokens) }
                }
                if lastUsage != nil || !windows.isEmpty {
                    AgentLimitsCard(bot: bot, usage: lastUsage, limits: thread.latestLimits)
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
        VStack(alignment: .leading, spacing: 20) {
            // What it runs with, as label and value. Each value is its own menu, so the fact you
            // can see is the control that changes it; "Change" opens the full editor.
            ThreadNestedCard(base: isDark ? palette.sidebar : palette.card) {
                BotPanelMenuRow(label: "Engine", value: bot.engine.displayName) {
                    ForEach(EngineID.supported, id: \.self) { engine in
                        Button {
                            model.setEngine(bot, engine)
                        } label: {
                            Label(engine.displayName,
                                  systemImage: bot.engine == engine ? "checkmark" : "")
                        }
                    }
                }
                BotPanelMenuRow(label: "Model", value: modelLabel ?? "Default") {
                    ModelMenuItems(bot: bot)
                }
                BotPanelMenuRow(label: "Runs on", value: machineName) {
                    Button("This Mac") { model.assign(bot, to: nil) }
                    if !model.machines.isEmpty {
                        Divider()
                        ForEach(model.machines) { machine in
                            Button(machine.name) { model.assign(bot, to: machine.id) }
                        }
                    }
                }
                BotPanelMenuRow(label: "Trust", value: trustLabel, tone: trustTone) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Button {
                            model.setAutonomy(bot, level)
                        } label: {
                            Label(label(for: level),
                                  systemImage: bot.autonomy == level ? "checkmark" : "")
                        }
                    }
                }
                // Claude only: Codex has no way to leave out the apps on its account.
                if bot.engine == .claude {
                    BotPanelMenuRow(label: "Apps", value: bot.onlyBupsyApps ? "Only bupsy's" : "All of yours") {
                        Button {
                            model.setOnlyBupsyApps(bot, false)
                        } label: {
                            Label("Everything on your Claude account",
                                  systemImage: bot.onlyBupsyApps ? "" : "checkmark")
                        }
                        Button {
                            model.setOnlyBupsyApps(bot, true)
                        } label: {
                            Label("Only apps added in bupsy",
                                  systemImage: bot.onlyBupsyApps ? "checkmark" : "")
                        }
                    }
                }
                BotPanelMenuRow(label: "Section", value: bot.folder ?? "Unassigned") {
                    ForEach(model.folders, id: \.self) { folder in
                        Button {
                            model.setFolder(bot, folder)
                        } label: {
                            Label(folder, systemImage: bot.folder == folder ? "checkmark" : "")
                        }
                    }
                    if bot.folder != nil {
                        Divider()
                        Button("Move to Unassigned") { model.setFolder(bot, nil) }
                    }
                }
            } footer: {
                Button { editingBot = bot } label: {
                    Text("Change")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.mutedForeground)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Edit \(bot.name)'s face, job, engine and trust")
            }

            folderField
        }
    }

    /// The folder it can touch, as a field you can copy from, with the ways to change it.
    private var folderField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Folder")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
            HStack(spacing: Theme.Space.snug) {
                Text(folderPath)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(model.workingDirectory(for: bot).path)
                Spacer(minLength: Theme.Space.snug)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.workingDirectory(for: bot).path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: Theme.scaled(11)))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Copy the path")
                Menu {
                    Button("Choose folder...") { model.chooseWorkdir(for: bot) }
                    if bot.workdir != nil {
                        Button("Use its own folder") { model.setWorkdir(bot, nil) }
                    }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [model.workingDirectory(for: bot)])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Theme.scaled(11), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change folder")
            }
            .padding(.leading, Theme.Space.gutter)
            .padding(.trailing, Theme.Space.snug)
            .frame(height: Theme.Size.control + 4)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border)
            }
        }
    }

    private var folderPath: String {
        guard let path = bot.workdir else { return "Its own folder" }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// A small heading with its New button, the way the panel's sections start.
    private func panelHeader(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(palette.foreground)
            Spacer(minLength: Theme.Space.snug)
            Button(action: action) {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(ThreadButtonStyle(kind: .ghost, height: 32))
            .help(help)
        }
    }

    // MARK: - Head

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.tight) {
                Text(bot.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(palette.foreground)
                if let role = bot.role { RoleTag(text: role) }
            }
            if let job = bot.personaPrompt {
                Text(job).font(Theme.Typography.body).foregroundStyle(palette.mutedForeground)
            }
        }
    }

    /// Trust levels in the words they mean to a person, not their internal names.
    private func label(for level: Autonomy) -> String { level.menuLabel }

    private var modelLabel: String? {
        guard bot.model != nil else { return nil }
        // A custom model has no label of its own; its ID is the most honest name for it.
        return model.models(for: bot).first { $0.id == bot.model }?.label ?? bot.model
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
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
                                VStack(alignment: .leading, spacing: Theme.Space.step) {
                                    if showsDaySeparator(at: index) { DaySeparator(date: entry.at) }
                                    if index == firstUnreadIndex { NewDivider().id(NewDivider.anchor) }
                                    Bubble(entry: entry, bot: bot, showsAvatar: showsAvatar(at: index),
                                           onReply: { author, text in
                                               replyingTo = ReplyTarget(author: author, text: text)
                                           })
                                }
                                .padding(.top, gap(before: index))
                                .id(entry.id)
                            }
                            // Not while it is waiting on you. The dots say "the bot is working" —
                            // under an approval card that is false, and it is false at exactly
                            // the moment the person needs to understand that nothing will happen
                            // until they answer.
                            if thread.isRunning && !model.isWaitingForApproval(bot.id) {
                                AgentThinking(bot: bot, thread: thread)
                                    .padding(.top, Theme.Space.step)
                                    .id("thinking")
                            }
                        }
                        .padding(.top, Theme.Space.gutter)
                        .padding(.bottom, Theme.Space.section)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: ThreadLayout.columnMaxWidth)
                        // Centred, not leading: the composer is centred in the pane, and a
                        // transcript hugging the left edge while the box you type into sits in
                        // the middle reads as two unrelated panels.
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Short threads sit on the composer rather than floating at the top of an
                        // empty pane. Every messaging app does this, and the first reply in a new
                        // conversation is exactly when the difference is most obvious.
                        .frame(minHeight: geometry.size.height, alignment: .bottom)
                        // Where the end of the thread is, relative to the visible pane — so the
                        // jump-to-latest button shows only once you have scrolled away from it.
                        .background(alignment: .bottom) {
                            GeometryReader { end in
                                Color.clear.preference(
                                    key: ThreadEndKey.self,
                                    value: end.frame(in: .named("thread")).maxY - geometry.size.height)
                            }
                        }
                    }
                    // Starts at the latest message, like every chat app — scrolling there after
                    // load lost the race with layout and stopped short.
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: "thread")
                    .onPreferenceChange(ThreadEndKey.self) { distance in
                        awayFromBottom = distance > 120
                    }
                    .overlay(alignment: .bottom) {
                        if awayFromBottom {
                            Button {
                                guard let last = thread.entries.last else { return }
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: Theme.scaled(12), weight: .semibold))
                                    .foregroundStyle(palette.foreground)
                                    .frame(width: 32, height: 32)
                                    .background(palette.background, in: .circle)
                                    .overlay(Circle().strokeBorder(palette.border))
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .help("Jump to the latest message")
                            .padding(.bottom, Theme.Space.step)
                            .transition(.opacity)
                        }
                    }
                    // Open where you left off: at the first unread message if there is one,
                    // otherwise at the end.
                    // After a beat, not in onAppear: scrolled before the bubbles were laid out, it
                    // stopped short and left the latest message half under the composer.
                    .task(id: bot.id) {
                        try? await Task.sleep(for: .milliseconds(60))
                        if firstUnreadIndex != nil {
                            proxy.scrollTo(NewDivider.anchor, anchor: .top)
                        } else if let last = thread.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    // Keep the "what it's doing" line in view as it appears and changes.
                    .onChange(of: thread.isRunning) { _, running in
                        guard running else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                    .onChange(of: thread.entries.count) {
                        guard let last = thread.entries.last else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            if thread.isRunning && !model.isWaitingForApproval(bot.id) {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            } else {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
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
        let window: String
        switch tightest.name {
        case "five_hour": window = "5-hour"
        case "seven_day": window = "weekly"
        case "seven_day_opus": window = "weekly Opus"
        default: window = tightest.name.replacingOccurrences(of: "_", with: "-")
        }
        return "\(Int(tightest.window.utilization * 100))% of \(window) limit"
    }

    /// Worth an amber wash once more than half a window is gone.
    private var limitIsHigh: Bool {
        (thread.latestLimits?.tightest?.window.utilization ?? 0) >= 0.6
    }

    /// Room between entries: a bot's tool lines stack tight under its words, separate turns
    /// breathe.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let current = thread.entries[index].kind
        // Entries that draw nothing take no room.
        switch current {
        case .finished: return 0
        case .tool(let name, let arguments, _, _):
            if case .hidden = BupsyToolLine(tool: name, argumentsJSON: arguments) { return 0 }
        default: break
        }
        let previous = thread.entries[index - 1].kind
        if Self.isAside(current) && Self.isAside(previous) { return 4 }
        if Self.isAside(current) { return Theme.Space.step }
        switch current {
        case .approval, .question, .failure, .limits: return Theme.Space.gutter
        default: return 20
        }
    }

    private static func isAside(_ kind: TranscriptEntry.Kind) -> Bool {
        switch kind {
        case .tool, .thinking: true
        default: false
        }
    }

    /// The first message from the bot that arrived after you last read it, or nil when there is
    /// none — nothing new, or a bot you are opening for the first time, where everything is new
    /// and a line above the first message would say nothing.
    private var firstUnreadIndex: Int? {
        guard let seenEntry = model.readBeforeOpening[bot.id], let seen = seenEntry else { return nil }
        guard let index = thread.entries.firstIndex(where: { $0.isFromBot && $0.at > seen }),
              index > 0 else { return nil }
        return index
    }

    private func showsDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            thread.entries[index].at, inSameDayAs: thread.entries[index - 1].at)
    }

    /// A bot's words open with its face, name and time, unless they carry straight on from its
    /// previous words.
    private func showsAvatar(at index: Int) -> Bool {
        guard case .assistantText = thread.entries[index].kind else { return false }
        guard index > 0 else { return true }
        if case .assistantText = thread.entries[index - 1].kind { return false }
        return true
    }

    // MARK: - On its own

    private var goals: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("Standing goals", help: "New goal") { showsObjectives = true }

            if objectives.isEmpty {
                EmptyRow(text: "No standing goals yet.") { showsObjectives = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(objectives) { objective in
                        goalRow(objective)
                    }
                }
            }
        }
    }

    /// The same anatomy as a routine row: what and when on the left, then on and off and the
    /// rest of what you can do with it on the right, all visible rather than behind a right-click.
    private func goalRow(_ objective: Objective) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
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
                                                 ? palette.primary : palette.success)
                        }
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                }
            } trailing: {
                HStack(spacing: Theme.Space.tight) {
                    ObjectiveToggle(objective: objective)
                    ObjectiveMenu(
                        objective: objective,
                        showsNotes: Binding(
                            get: { notesObjectiveID == objective.id },
                            set: { notesObjectiveID = $0 ? objective.id : nil }),
                        onDelete: { deletingObjective = objective })
                }
            }
            .opacity(objective.enabled ? 1 : 0.6)

            if notesObjectiveID == objective.id {
                ObjectiveNotesEditor(objective: objective)
            }
        }
    }

    private func checkedLabel(_ objective: Objective) -> String {
        guard let at = objective.lastCheckedAt else { return "Never checked" }
        return "Checked \(Theme.stamp(at))"
    }

    private var routineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader("Routines", help: "New routine") { showsRoutines = true }

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
                                // Two short lines, not one long one: side by side in a 340pt
                                // panel they wrapped into a three-line jumble.
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Schedule.describe(routine.cron))
                                    Text(routine.tier.shortLabel)
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                                .lineLimit(1)
                            }
                        } trailing: {
                            // On and off right here, without opening anything.
                            Toggle("", isOn: Binding(
                                get: { routine.enabled },
                                set: { model.setRoutineEnabled(routine, $0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        .opacity(routine.enabled ? 1 : 0.6)
                        .contentShape(Rectangle())
                        .onTapGesture { openRoutineID = routine.id }
                        .help("Open \(routine.name)")
                    }
                }
            }
        }
    }

    /// Folders this bot watches: it runs when files in them change.
    private var watchSection: some View {
        let watches = model.folderWatches.filter { $0.botID == bot.id.rawValue }
        return VStack(alignment: .leading, spacing: 10) {
            panelHeader("Folder watches", help: "New folder watch") { showsNewWatch = true }
            if watches.isEmpty {
                EmptyRow(text: "No folder watches yet.") { showsNewWatch = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(watches) { watch in
                        CardRow {
                            IconTile(systemName: "folder")
                        } content: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(watch.name).font(Theme.Typography.body).foregroundStyle(palette.foreground)
                                Text(watch.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        } trailing: {
                            Toggle("", isOn: Binding(get: { watch.enabled },
                                                     set: { model.setFolderWatchEnabled(watch, $0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        .opacity(watch.enabled ? 1 : 0.6)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: watch.path)]) }
                            Button("Delete watch…", role: .destructive) { deletingWatch = watch }
                        }
                    }
                }
                Text("Runs while bupsy is open. Changes \(bot.name) makes itself don't set it off again.")
                    .font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
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
/// you are looking at: Bupsy, then the bot or page, then the view, the last one in full weight.
struct Topbar<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let trail: [String]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.tight) {
                Text("Bupsy").foregroundStyle(palette.mutedForeground)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, part in
                    Text("|").foregroundStyle(palette.border)
                    Text(part)
                        .foregroundStyle(index == trail.count - 1
                                         ? palette.foreground.opacity(0.8) : palette.mutedForeground)
                        .fontWeight(index == trail.count - 1 ? .medium : .regular)
                }
            }
            .font(.system(size: Theme.scaled(14)))
            .lineLimit(1)

            Spacer(minLength: Theme.Space.step)
            HStack(spacing: Theme.Space.step) { trailing }
        }
        .padding(.horizontal, Theme.Space.section)
        .frame(height: 64)
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
    case files
    case computer

    var label: String {
        switch self {
        case .details: "Details"
        case .activity: "Activity"
        case .files: "Files"
        case .computer: "Computer"
        }
    }
}

/// The files this bot changed, newest first. Click to show one in Finder.
struct BotFilesList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    @State private var files: [WrittenFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if files.isEmpty {
                Text("Files \(bot.name) writes or edits show up here.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.section)
            } else {
                SettingsGroup(title: "Files it changed") {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        FileRow(file: file, showsDivider: index > 0)
                    }
                }
            }
        }
        .task(id: model.thread(for: bot.id).entries.count) {
            files = model.filesWritten(by: bot)
        }
    }
}

private struct FileRow: View {
    @Environment(\.palette) private var palette
    let file: WrittenFile
    let showsDivider: Bool
    @State private var hovering = false

    private var url: URL { URL(fileURLWithPath: file.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider { Rectangle().fill(palette.border).frame(height: 1) }
            Button {
                // Gone files cannot be revealed; their row says so instead of doing nothing.
                if exists { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: exists ? file.path : "/"))
                        .resizable().frame(width: 18, height: 18)
                        .opacity(exists ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(Theme.Typography.body)
                            .foregroundStyle(exists ? palette.foreground : palette.mutedForeground)
                            .strikethrough(!exists)
                            .lineLimit(1)
                        Text(exists ? url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                    : "Deleted since")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    Text(file.at, format: .relative(presentation: .numeric))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.snug)
                .contentShape(Rectangle())
                .background(hovering && exists ? palette.foreground.opacity(0.05) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(file.path)
        }
    }
}

/// Where the unread messages begin.
struct NewDivider: View {
    static let anchor = "new-divider"
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Rectangle().fill(palette.primary.opacity(0.5)).frame(height: 1)
            Text("NEW")
                .font(.system(size: Theme.scaled(10), weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.primary)
            Rectangle().fill(palette.primary.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, Theme.Space.tight)
    }
}

private struct ThreadEndKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The bot's role label, edited where it is shown: click, type, Enter.
struct InlineLabelField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text, prompt: Text("PA, Finance, Research..."))
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.caption)
                    .frame(maxWidth: 160)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                Button {
                    text = bot.role ?? ""
                    editing = true
                    focused = true
                } label: {
                    if let role = bot.role {
                        ThreadStatusBadge(text: role, tone: palette.infoText)
                    } else {
                        // A small dashed pill, so it reads as a control rather than stray text
                        // squeezed between the name and the job.
                        Label("Add label", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: Theme.scaled(10), weight: .medium))
                            .foregroundStyle(palette.mutedForeground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                }
                .buttonStyle(.plain)
                .help("A word or two shown beside its name")
            }
        }
        .onChange(of: bot.id) { editing = false }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        model.setRole(bot, text)
    }
}

extension Autonomy {
    /// How a trust level reads in every menu that offers it.
    var menuLabel: String {
        switch self {
        case .ask: "Ask before everything"
        case .allowlist: "Ask unless I've allowed it"
        case .trusted: "Ask before anything leaves the machine"
        case .auto: "Never ask"
        }
    }
}

extension Routine.Tier {
    /// The same answer in fewer words, for a narrow row.
    var shortLabel: String {
        switch self {
        case .appOpen: "While bupsy's open"
        case .launchAgent: "Even when closed"
        case .machine: "On a machine"
        }
    }
}

/// Pick a folder and say what the bot should do when files in it change.
struct NewFolderWatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let bot: Bot
    /// Set when this is the Folder watch tab of the new-routine sheet: picking another tab hands
    /// the choice back to it. nil when opened on its own, and then it has no tabs.
    let onSwitchKind: ((RoutineSheetKind) -> Void)?
    @State private var path = ""
    @State private var name = ""
    @State private var prompt = ""
    /// Always "Folder watch" here; another tab is handed back and this resets.
    @State private var kindTab = RoutineSheetKind.folderWatch

    init(bot: Bot, onSwitchKind: ((RoutineSheetKind) -> Void)? = nil) {
        self.bot = bot
        self.onSwitchKind = onSwitchKind
    }

    var body: some View {
        SheetFrame(title: onSwitchKind == nil ? "New folder watch" : "New routine",
                   icon: onSwitchKind == nil ? "folder.badge.gearshape" : "clock.fill",
                   subtitle: "\(bot.name) runs when files in this folder change.",
                   width: onSwitchKind == nil ? 420 : 540,
                   tone: onSwitchKind == nil ? .primary : .info,
                   primaryVerb: "create") {
            if onSwitchKind != nil {
                RoutineKindPicker(selection: $kindTab)
            }
            Field(label: "Folder") {
                HStack(spacing: Theme.Space.snug) {
                    Text(path.isEmpty ? "No folder chosen" : path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(path.isEmpty ? palette.mutedForeground : palette.foreground)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: choose).buttonStyle(QuietButton(compact: true))
                }
            }
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("New downloads"))
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(label: "What should \(bot.name) do?",
                  hint: "It also gets the list of files that changed.") {
                TextField("", text: $prompt, prompt: Text("Rename new screenshots by what's in them and file them by month."),
                          axis: .vertical)
                    .textFieldStyle(BupsyFieldStyle())
                    .lineLimit(3...5)
            }
            if onSwitchKind != nil {
                Text("Runs while bupsy is open. Changes \(bot.name) makes itself don't set it off again.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
            Button("Create") {
                model.addFolderWatch(to: bot,
                                     name: name.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? URL(fileURLWithPath: path).lastPathComponent : name.trimmingCharacters(in: .whitespaces),
                                     prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), path: path)
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(path.isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onChange(of: kindTab) {
            guard kindTab != .folderWatch else { return }
            let picked = kindTab
            kindTab = .folderWatch
            onSwitchKind?(picked)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// A label on the left and its value on the right, where the value is a menu that changes it.
/// The rows of the details panel's setup card.
private struct BotPanelMenuRow<Items: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var tone: Color?
    @ViewBuilder var items: Items
    @State private var hovering = false

    init(label: String, value: String, tone: Color? = nil, @ViewBuilder items: () -> Items) {
        self.label = label
        self.value = value
        self.tone = tone
        self.items = items()
    }

    var body: some View {
        HStack(spacing: Theme.Space.step) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: Theme.Space.snug)
            Menu {
                items
            } label: {
                HStack(spacing: 4) {
                    // Coloured here rather than left to the enclosing style: a borderless menu
                    // adopts the app tint for its label otherwise.
                    Text(value)
                        .font(Theme.Typography.body)
                        .foregroundStyle(tone ?? palette.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: Theme.scaled(8), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground.opacity(hovering ? 1 : 0.45))
                }
                .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
        }
    }
}
