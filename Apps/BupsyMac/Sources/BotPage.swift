import BupsyKit
import SwiftUI

/// One bot, as a page: who it is, the conversation, and what it does on its own.
///
/// Everything about a bot on one surface, in the order someone would ask about it, rather than
/// a chat box with the rest behind icons. Goals and routines sit below the conversation as card
/// rows, so they are part of the page instead of somewhere you have to know to look.
struct BotPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Messages that arrived while you were scrolled up reading, counted on the jump button
    /// instead of yanking you down to them.
    @State private var unseenCount = 0
    /// Briefly true after the folder path is copied, so the button says it worked.
    @State private var copiedPath = false
    /// The goal whose "what it's learned" notes are open under its row, if any.
    @State private var notesObjectiveID: String?
    /// Set to ask before deleting. Owned by the page, never by a menu, which is gone on click.
    @State private var deletingObjective: Objective?
    @State private var deletingWatch: FolderWatch?
    /// The folder watch open in its edit sheet, if any.
    @State private var editingWatch: FolderWatch?

    private var thread: Thread { model.thread(for: bot.id) }
    private var routines: [Routine] { model.routines.filter { $0.botID == bot.id.rawValue } }
    /// Looked up live, so a deleted routine closes its page by itself.
    private var openRoutine: Routine? {
        guard let openRoutineID else { return nil }
        return routines.first { $0.id == openRoutineID }
    }
    private var objectives: [Objective] { model.objectives.filter { $0.botID == bot.id.rawValue } }

    /// The details panel's width beside the chat: 340 in a small window, growing with the window
    /// up to 440, as on the board.
    private static func detailsWidth(for pageWidth: CGFloat) -> CGFloat {
        min(440, max(340, (pageWidth * 0.3).rounded()))
    }
    /// Narrower than this beside the panel and the chat is unreadable, so the panel floats over
    /// the chat instead of squeezing it.
    private static let minimumChatWidth: CGFloat = 420

    /// The details are shown unless a routine page is open: that page needs the room, and the
    /// remembered choice is left as it was, so Back brings the panel back.
    private var detailsVisible: Bool { showsDetails && openRoutine == nil }

    var body: some View {
        // One card, like every page: the chat on the left and, when open, the bot's details on
        // the right behind a hairline, so the two read as one object rather than two windows.
        PanelSurface {
            GeometryReader { proxy in
                pageContent(size: proxy.size)
            }
        }
        .padding([.top, .bottom, .trailing], Theme.Space.snug)
        // Each sheet on its own view: two sheets on one view and SwiftUI silently shows only one.
        // The panel already lists routines and goals, so "New" opens the form itself rather than
        // a second list with its own New button.
        .background { Color.clear.sheet(isPresented: $showsRoutines) { NewRoutineSheet(bot: bot) } }
        .background { Color.clear.sheet(isPresented: $showsObjectives) { NewObjectiveSheet(bot: bot) } }
        .background { Color.clear.sheet(item: $editingRoutine) { NewRoutineSheet(bot: bot, editing: $0) } }
        .background { Color.clear.sheet(item: $editingBot) { BotCreatorSheet(editing: $0) } }
        // The folder watch form is the new-routine sheet opened on its Folder watch tab.
        .background { Color.clear.sheet(isPresented: $showsNewWatch) { NewRoutineSheet(bot: bot, kind: .folderWatch) } }
        .background { Color.clear.sheet(item: $editingWatch) { NewFolderWatchSheet(bot: bot, editing: $0) } }
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

    /// The page laid out for the width it has: details beside the chat when both fit, and
    /// floating over the trailing edge of the chat, with a shadow and a close button, when not.
    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        let panelWidth = Self.detailsWidth(for: size.width)
        let floating = size.width - panelWidth - 1 < Self.minimumChatWidth
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

            if detailsVisible && !floating {
                Rectangle().fill(palette.border).frame(width: 1)
                details(width: panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .trailing) {
            if detailsVisible && floating {
                details(width: panelWidth)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { showsDetails = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: Theme.scaled(11), weight: .semibold))
                                .foregroundStyle(palette.mutedForeground)
                                .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Hide details")
                        .accessibilityLabel("Hide details")
                        .padding(Theme.Space.snug)
                    }
                    .frame(maxHeight: .infinity)
                    .background(palette.background)
                    .shadow(color: .black.opacity(0.22), radius: 24, x: -6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Title

    /// Where you are, what the bot is up to, and the way into everything else about it.
    ///
    /// What a bot *said* is the reason to be on this screen; what it is configured to do is a
    /// question you ask occasionally, so it lives one click away rather than above the thread.
    private var topbar: some View {
        Topbar(trail: crumbs) {
            if !hasJob {
                ThreadStatusBadge(text: "No job yet")
                    .help("\(bot.name) has no job description yet. Add one in Details.")
            }
            statusBadge
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { showsDetails.toggle() }
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

    private var hasJob: Bool {
        !(bot.personaPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var crumbs: [String] {
        if showsDetails { return [bot.name, "Details"] }
        if let folder = bot.folder, !folder.isEmpty { return [folder, bot.name] }
        return [bot.name, "Chat"]
    }

    /// At most one status at a time, in order of how much it needs you.
    @ViewBuilder
    private var statusBadge: some View {
        if model.needsYou(bot) {
            ThreadStatusBadge(text: "Needs you", tone: palette.primary, dot: true)
        } else if thread.isRunning {
            // What it is doing right now ("Running npm test", "Editing login.ts"), not just
            // that it is busy. Same words as the line under the thread.
            ThreadStatusBadge(text: ChatLiveStatus.text(for: thread.entries),
                              tone: palette.infoText, dot: true)
        } else if mood == .failed {
            ThreadStatusBadge(text: "Last run failed", tone: palette.destructive, dot: true)
        } else if mood == .sleeping {
            ThreadStatusBadge(text: "Asleep")
        } else if let tightest = thread.latestLimits?.tightest {
            ThreadStatusBadge(
                text: LimitScale.badge(name: tightest.name, utilization: tightest.window.utilization),
                tone: LimitScale.tone(tightest.window.utilization, palette))
        }
    }

    /// The model's one truth, so this page, the sidebar and the menu bar agree.
    private var mood: BotMood { model.mood(for: bot) }

    // MARK: - Everything that is not the conversation

    /// The bot's setup, beside the conversation rather than above it.
    ///
    /// A panel rather than a sheet: changing a bot's trust level or reading why a routine failed
    /// is something you do *while* looking at what it said, and a sheet would cover exactly the
    /// evidence you are deciding from.
    private func details(width: CGFloat) -> some View {
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
                    if hasActivity {
                        usage
                        history
                    } else {
                        EmptyState(title: "No runs yet",
                                   message: "\(bot.name)'s work shows up here.",
                                   faceSize: 48)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.section)
                    }
                case .files:
                    BotFilesList(bot: bot)
                case .computer:
                    computer
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, Theme.Space.section)
        }
        .frame(width: width)
        // Clipped, because a card wider than the panel should truncate rather than draw over the
        // conversation beside it.
        .clipped()
    }

    private var isDark: Bool { colorScheme == .dark }

    /// Whether the Activity tab has anything to show: a run, or a limit an engine reported.
    private var hasActivity: Bool {
        !model.recentRuns(for: bot).isEmpty || !(thread.latestLimits?.windows.isEmpty ?? true)
    }

    /// Who the bot is: its face, its name and label, and its job in a sentence.
    private var detailsHead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            BotFace(bot: bot, mood: mood, size: 64)
            HStack(spacing: Theme.Space.snug) {
                Text(bot.name)
                    .font(.system(size: Theme.scaled(18), weight: .semibold))
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

    /// The four questions worth asking about a bot, as the app's one segmented control.
    private var tabBar: some View {
        Segmented(selection: $tab, values: DetailTab.allCases, full: true) { $0.label }
    }

    /// Where this bot's work actually happens.
    ///
    /// Grok Bot shows a live screen here. bupsy cannot yet: a cloud machine has no screen to
    /// stream and the local host has no window of its own, so this says what is true rather than
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
    /// "context window" percentage: the engine reports what a turn *sent*, never how large the
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
                // The context half needs a known window size; without one the card shows only the
                // plan limits, and nothing at all when there are none.
                if (lastUsage != nil && AgentLimitsCard.contextCapacity(for: bot) != nil)
                    || !windows.isEmpty {
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
    static func windowLabel(_ name: String) -> String { LimitScale.label(name) }

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
                // Each engine keeps its own conversation, so switching mid-run would swap the
                // thread out from under the work in progress.
                .disabled(model.isRunning(bot.id))
                .help(model.isRunning(bot.id)
                      ? "Stop \(bot.name) or wait for it to finish to switch engines"
                      : "Each engine keeps its own conversation")
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
                BotPanelMenuRow(label: "Trust", value: bot.autonomy.trustLabel, tone: trustTone) {
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
                    BotPanelMenuRow(label: "Apps", value: bot.onlyBupsyApps ? "Only Bupsy's" : "All of yours") {
                        Button {
                            model.setOnlyBupsyApps(bot, false)
                        } label: {
                            Label("Everything on your Claude account",
                                  systemImage: bot.onlyBupsyApps ? "" : "checkmark")
                        }
                        Button {
                            model.setOnlyBupsyApps(bot, true)
                        } label: {
                            Label("Only apps added in Bupsy",
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
                Button("Change") { editingBot = bot }
                    .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
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
                    copiedPath = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copiedPath = false }
                } label: {
                    Group {
                        if copiedPath {
                            Text("Copied")
                                .font(Theme.Typography.caption)
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: Theme.scaled(11)))
                        }
                    }
                    .foregroundStyle(palette.mutedForeground)
                    .frame(minWidth: Theme.Size.controlSm, minHeight: Theme.Size.controlSm)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(copiedPath ? "Copied" : "Copy the path")
                .accessibilityLabel(copiedPath ? "Copied" : "Copy the path")
                Menu {
                    Button("Choose folder…") { model.chooseWorkdir(for: bot) }
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
                        .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change folder")
                .accessibilityLabel("Change folder")
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
            .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
            .help(help)
        }
    }

    // MARK: - Head

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
    private func label(for level: Autonomy) -> String { level.trustLabel }

    private var modelLabel: String? {
        guard bot.model != nil else { return nil }
        // A custom model has no label of its own; its ID is the most honest name for it.
        return model.models(for: bot).first { $0.id == bot.model }?.label ?? bot.model
    }

    /// Shows the folder's own name rather than a path: the path is long and the name is what
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
                        // Worked out once per update, not once per row: it scans the thread.
                        let unread = firstUnreadIndex
                        // What each row needs to know about its neighbours, in one pass, so no
                        // bubble reads the whole thread while it draws.
                        let rows = ThreadRowContext.rows(for: thread.entries, isRunning: thread.isRunning)
                        // Lazy, so a long thread only builds the rows on screen. Every row keeps
                        // its entry id, so scrollTo still finds rows that are not built yet.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(thread.entries.enumerated()), id: \.element.id) { index, entry in
                                VStack(alignment: .leading, spacing: Theme.Space.step) {
                                    if showsDaySeparator(at: index) { DaySeparator(date: entry.at) }
                                    if index == unread { NewDivider().id(NewDivider.anchor) }
                                    Bubble(entry: entry, bot: bot, showsAvatar: showsAvatar(at: index),
                                           context: rows.indices.contains(index) ? rows[index] : nil,
                                           onReply: { author, text in
                                               replyingTo = ReplyTarget(author: author, text: text)
                                           })
                                }
                                .padding(.top, gap(before: index))
                                .id(entry.id)
                            }
                            // Not while it is waiting on you. The dots say "the bot is working":
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
                        .padding(.horizontal, Theme.Space.pageSide)
                        .frame(maxWidth: ThreadLayout.columnMaxWidth)
                        // Centred, not leading: the composer is centred in the pane, and a
                        // transcript hugging the left edge while the box you type into sits in
                        // the middle reads as two unrelated panels.
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Short threads sit on the composer rather than floating at the top of an
                        // empty pane. Every messaging app does this, and the first reply in a new
                        // conversation is exactly when the difference is most obvious.
                        .frame(minHeight: geometry.size.height, alignment: .bottom)
                        // Where the end of the thread is, relative to the visible pane, so the
                        // jump-to-latest button shows only once you have scrolled away from it.
                        .background(alignment: .bottom) {
                            GeometryReader { end in
                                Color.clear.preference(
                                    key: ThreadEndKey.self,
                                    value: end.frame(in: .named("thread")).maxY - geometry.size.height)
                            }
                        }
                    }
                    // Starts at the latest message, like every chat app, scrolling there after
                    // load lost the race with layout and stopped short.
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: "thread")
                    .onPreferenceChange(ThreadEndKey.self) { distance in
                        awayFromBottom = distance > 120
                        if distance <= 120 { unseenCount = 0 }
                    }
                    .overlay(alignment: .bottom) {
                        if awayFromBottom {
                            Button {
                                guard let last = thread.entries.last else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                            } label: {
                                HStack(spacing: Theme.Space.tight) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: Theme.scaled(12), weight: .semibold))
                                    if unseenCount > 0 {
                                        Text(unseenCount == 1 ? "1 new" : "\(unseenCount) new")
                                            .font(Theme.Typography.caption.weight(.medium))
                                            .monospacedDigit()
                                    }
                                }
                                .foregroundStyle(palette.foreground)
                                .padding(.horizontal, unseenCount > 0 ? Theme.Space.step : 0)
                                .frame(minWidth: 32, minHeight: 32)
                                .background(palette.background, in: .capsule)
                                .overlay(Capsule().strokeBorder(palette.border))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .help("Jump to the latest message")
                            .accessibilityLabel(unseenCount > 0
                                                ? "Jump to the latest message, \(unseenCount) new"
                                                : "Jump to the latest message")
                            .padding(.bottom, Theme.Space.step)
                            .transition(.opacity)
                        }
                    }
                    // Open where you left off: at the first unread message if there is one,
                    // otherwise at the end.
                    // After a beat, not in onAppear: scrolled before the bubbles were laid out, it
                    // stopped short and left the latest message half under the composer.
                    .task(id: bot.id) {
                        unseenCount = 0
                        try? await Task.sleep(for: .milliseconds(60))
                        // To the row that holds the divider: a lazy stack can only scroll to its
                        // own rows' ids, not to a view inside a row it has not built yet.
                        if let unread = firstUnreadIndex, thread.entries.indices.contains(unread) {
                            proxy.scrollTo(thread.entries[unread].id, anchor: .top)
                        } else if let last = thread.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    // Keep the "what it's doing" line in view as it appears and changes.
                    // Only while you are at the end: scrolled up reading, you stay where you are.
                    .onChange(of: thread.isRunning) { _, running in
                        guard running, !awayFromBottom else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                    .onChange(of: thread.entries.count) { old, new in
                        guard let last = thread.entries.last else { return }
                        // Your own message always takes you to it; anything else waits for you
                        // on the jump button while you are reading further up.
                        var isYours = false
                        if case .userMessage = last.kind { isYours = true }
                        if awayFromBottom && !isYours {
                            let added = thread.entries.suffix(max(0, new - old))
                            unseenCount += added.filter { Self.countsAsNew($0.kind) }.count
                            return
                        }
                        unseenCount = 0
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
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

    /// Room between entries: a bot's tool lines stack tight under its words, separate turns
    /// breathe.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let current = thread.entries[index].kind
        // Entries that draw nothing take no room.
        // The queued note is drawn under your bubble, not as a row of its own.
        if ThreadRowContext.holdsQueuedNote(current) { return 0 }
        switch current {
        case .finished: return 0
        case .tool(let name, let arguments, _, _):
            if case .hidden = BupsyToolLine(tool: name, argumentsJSON: arguments) { return 0 }
        default: break
        }
        let previous = thread.entries[index - 1].kind
        if Self.isAside(current) && Self.isAside(previous) { return Theme.Space.xs }
        if Self.isAside(current) { return Theme.Space.step }
        switch current {
        case .approval, .question, .failure, .limits: return Theme.Space.gutter
        default: return 20
        }
    }

    /// What the jump button counts: things said or asked, not each tool line or thought.
    private static func countsAsNew(_ kind: TranscriptEntry.Kind) -> Bool {
        switch kind {
        case .assistantText, .messageFrom, .approval, .question, .failure: true
        default: false
        }
    }

    private static func isAside(_ kind: TranscriptEntry.Kind) -> Bool {
        switch kind {
        case .tool, .thinking: true
        default: false
        }
    }

    /// The first message from the bot that arrived after you last read it, or nil when there is
    /// none, nothing new, or a bot you are opening for the first time, where everything is new
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
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
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
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(objective.goal)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                        // Cut to one line here; the whole goal on hover.
                        .help(objective.goal)
                    HStack(spacing: Theme.Space.snug) {
                        outcomeBadge(objective)
                            .help(checkedLabel(objective))
                        Text(Schedule.describe(objective.checkCron))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                    }
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

    /// How the last check went, as one badge: on track, needs you, or not checked yet.
    private func outcomeBadge(_ objective: Objective) -> some View {
        guard let outcome = objective.lastOutcome else {
            return Badge(text: "Not checked yet", tone: .neutral)
        }
        return outcome.needsAttention
            ? Badge(text: "Needs you", tone: BadgeTone.primary, dot: true)
            : Badge(text: "On track", tone: .success)
    }

    private func checkedLabel(_ objective: Objective) -> String {
        guard let at = objective.lastCheckedAt else { return "Never checked" }
        return "Checked \(Theme.stamp(at))"
    }

    private var routineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.compact) {
            panelHeader("Routines", help: "New routine") { showsRoutines = true }

            if routines.isEmpty {
                EmptyRow(text: "No routines yet.") { showsRoutines = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(routines) { routine in
                        CardRow {
                            EmptyView()
                        } content: {
                            // A button rather than a tap gesture, so the row opens from the
                            // keyboard and VoiceOver too. The switch stays outside it.
                            Button { openRoutineID = routine.id } label: {
                                HStack(spacing: Theme.Space.step) {
                                    IconTile(systemName: "calendar")
                                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                        Text(routine.name)
                                            .font(Theme.Typography.body)
                                            .foregroundStyle(palette.foreground)
                                        // Two short lines, not one long one: side by side in a
                                        // narrow panel they wrapped into a three-line jumble.
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(Schedule.describe(routine.cron))
                                            Text(routine.tier.shortLabel)
                                        }
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(palette.mutedForeground)
                                        .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(routine.name)")
                            .accessibilityHint("Opens the routine")
                        } trailing: {
                            // On and off right here, without opening anything.
                            Toggle("Run \(routine.name)", isOn: Binding(
                                get: { routine.enabled },
                                set: { model.setRoutineEnabled(routine, $0) }))
                                .labelsHidden()
                                .bupsySwitch()
                        }
                        .opacity(routine.enabled ? 1 : 0.6)
                    }
                }
            }
        }
    }

    /// Folders this bot watches: it runs when files in them change.
    private var watchSection: some View {
        let watches = model.folderWatches.filter { $0.botID == bot.id.rawValue }
        return VStack(alignment: .leading, spacing: Theme.Space.compact) {
            panelHeader("Folder watches", help: "New folder watch") { showsNewWatch = true }
            if watches.isEmpty {
                EmptyRow(text: "No folder watches yet.") { showsNewWatch = true }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(watches) { watch in
                        watchRow(watch)
                    }
                }
                Text("Runs while Bupsy is open. Changes \(bot.name) makes itself don't set it off again.")
                    .font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
            }
        }
    }

    /// One folder watch: opens its edit sheet, with on and off and a visible "..." menu. A folder
    /// that has gone says so, with a way to point the watch at it again.
    private func watchRow(_ watch: FolderWatch) -> some View {
        let missing = !FileManager.default.fileExists(atPath: watch.path)
        return CardRow {
            IconTile(systemName: missing ? "questionmark.folder" : "folder")
        } content: {
            Button { editingWatch = watch } label: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(watch.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    if missing {
                        Text("Folder not found")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.warning)
                            .lineLimit(1)
                    } else {
                        Text(watch.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(missing ? "\(watch.path) isn't there any more. Choose the folder again to keep watching."
                  : "Edit \(watch.name)")
            .accessibilityHint("Opens the folder watch")
        } trailing: {
            HStack(spacing: Theme.Space.tight) {
                if missing {
                    Button("Choose…") { chooseFolder(for: watch) }
                        .buttonStyle(QuietButton(compact: true))
                        .help("Choose the folder to watch")
                } else {
                    Toggle("Watch \(watch.name)", isOn: Binding(
                        get: { watch.enabled },
                        set: { model.setFolderWatchEnabled(watch, $0) }))
                        .labelsHidden()
                        .bupsySwitch()
                }
                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: watch.path)])
                    }
                    .disabled(missing)
                    Button("Edit…") { editingWatch = watch }
                    Divider()
                    Button("Delete watch…", role: .destructive) { deletingWatch = watch }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Theme.scaled(13), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Folder watch options")
                .accessibilityLabel("Options for \(watch.name)")
            }
        }
        .opacity(watch.enabled || missing ? 1 : 0.6)
    }

    /// Points a watch whose folder has gone at a folder that is there.
    private func chooseFolder(for watch: FolderWatch) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            model.moveFolderWatch(watch, to: url.path)
        }
    }

    /// What a bot has actually done, including while nobody was watching.
    ///
    /// Every run and its events have been stored since the first commit; nothing read them back,
    /// so unattended work was invisible even after it happened, which is most of the reason to
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
                            IconTile(systemName: run.host == "local" ? "laptopcomputer" : "server.rack")
                        } content: {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
                                .lineLimit(1)
                            }
                        } trailing: { runBadge(run) }
                    }
                }
            }
        }
    }

    /// Done, Failed or Running, in words rather than an icon you have to decode.
    private func runBadge(_ run: RunSummary) -> some View {
        if run.endedAt == nil { return Badge(text: "Running", tone: .info, dot: true) }
        return run.succeeded
            ? Badge(text: "Done", tone: .success)
            : Badge(text: "Failed", tone: .destructive)
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
            // The crumbs give way one at a time rather than all truncating together: "Bupsy"
            // first, then each earlier crumb, so the page you are on keeps its name longest.
            HStack(spacing: Theme.Space.tight) {
                Text("Bupsy")
                    .foregroundStyle(palette.mutedForeground)
                    .layoutPriority(0)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, part in
                    Text("|")
                        .foregroundStyle(palette.border)
                        .fixedSize()
                    Text(part)
                        .foregroundStyle(index == trail.count - 1
                                         ? palette.foreground.opacity(0.8) : palette.mutedForeground)
                        .fontWeight(index == trail.count - 1 ? .medium : .regular)
                        .truncationMode(.tail)
                        .layoutPriority(Double(index + 1))
                }
            }
            .font(.system(size: Theme.scaled(14)))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((["Bupsy"] + trail).joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)

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

/// The quiet secondary action beside a primary one. A thin wrapper over
/// `BupsyButtonStyle(kind: .secondary)`: 44pt, or the 36pt in-card size when compact.
struct QuietButton: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        BupsyButtonStyle(kind: .secondary, size: compact ? .md : .lg).makeBody(configuration: configuration)
    }
}

struct EmptyRow: View {
    @Environment(\.palette) private var palette
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.step) {
                // The compact empty state: the same grey napping bot as `EmptyState`, held still
                // so a panel of empty sections does not snore in chorus.
                BotFace(hue: 0, mood: .sleeping, size: 24, shape: .bup, colour: 0, still: true)
                    .saturation(0)
                    .opacity(0.7)
                    .accessibilityHidden(true)
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
            // In the trust row's own words, so the promise here matches the setting.
            Text(bot.autonomy.emptyConversationLine)
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.section)
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
                EmptyState(title: "No files changed yet",
                           message: "Files \(bot.name) writes or edits show up here.",
                           faceSize: 48)
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

    var body: some View {
        // Asked of the disk once per render, not once per use below.
        let exists = FileManager.default.fileExists(atPath: file.path)
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
                TextField("", text: $text, prompt: Text("PA, Finance, Research…"))
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
                            .padding(.horizontal, Theme.Space.tight)
                            .padding(.vertical, Theme.Space.hairline)
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
    /// A trust level in one set of words, the same in the details row, its menu and the first-run
    /// picker, so a setting never reads one way where you see it and another where you change it.
    var trustLabel: String {
        switch self {
        case .ask: "Asks before everything"
        case .allowlist: "Asks unless allowed"
        case .trusted: "Asks before edits and commands"
        case .auto: "Never asks"
        }
    }

    /// How a trust level reads in every menu that offers it.
    var menuLabel: String { trustLabel }

    /// The empty conversation's promise, starting with the trust row's own words.
    var emptyConversationLine: String {
        switch self {
        case .ask: "Asks before everything. Even reading files waits for you."
        case .allowlist: "Asks unless allowed. It reads freely and remembers what you always allow."
        case .trusted: "Asks before edits and commands. It reads freely; edits, commands, apps and anything online wait for you."
        case .auto: "Never asks. Everything runs without you, so keep it to throwaway folders."
        }
    }
}

extension Routine.Tier {
    /// The same answer in fewer words, for a narrow row.
    var shortLabel: String {
        switch self {
        case .appOpen: "While open"
        case .launchAgent: "Even when closed"
        case .machine: "On a machine"
        }
    }
}

/// The new-routine sheet on its Folder watch tab, or, given a watch, that watch's edit form.
/// The form itself lives in NewRoutineSheet so there is one copy of it.
struct NewFolderWatchSheet: View {
    let bot: Bot
    let editing: FolderWatch?

    init(bot: Bot, editing: FolderWatch? = nil, onSwitchKind: ((RoutineSheetKind) -> Void)? = nil) {
        self.bot = bot
        self.editing = editing
    }

    var body: some View {
        NewRoutineSheet(bot: bot, kind: .folderWatch, editingWatch: editing)
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
            // Its natural width when it fits; otherwise squeezed into the room left, where the
            // value truncates in the middle instead of running past the panel and being clipped.
            ViewThatFits(in: .horizontal) {
                menu.fixedSize()
                menu.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .onHover { hovering = $0 }
        }
    }

    private var menu: some View {
        Menu {
            items
        } label: {
            HStack(spacing: Theme.Space.xs) {
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
        .help(value)
    }
}
