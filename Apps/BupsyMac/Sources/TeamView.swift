import BupsyKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole team at once: one column per section, a card per bot.
///
/// The sidebar is for going somewhere; this page is for arranging. Every bot shows what it is
/// doing and what it runs on, and moves to another section from its menu or by dragging the card
/// onto another column.
struct TeamView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    let onOpen: (BotID) -> Void

    /// The full creator, with the section it was opened from. See `TeamCreatorRequest`.
    @State private var settingUp: TeamCreatorRequest?
    @State private var isAddingSection = false
    /// A new section with this bot already picked, from the card's "New section…".
    @State private var sectionFor: Bot?
    @State private var renamingBot: Bot?
    /// Set to ask before deleting. Owned here, not by the card's menu, which is gone on click.
    @State private var deletingBot: Bot?
    /// The column a dragged card is over, so it can light up. "" is Unassigned.
    @State private var dropTarget: String?

    init(onOpen: @escaping (BotID) -> Void = { _ in }) {
        self.onOpen = onOpen
    }

    // MARK: Data

    /// Every bot the person has not hidden, pinned ones included: pinning changes where a bot
    /// sits in the sidebar, not which section it belongs to.
    private var visibleBots: [Bot] { model.bots.filter { !$0.hidden } }

    private var sections: [String] {
        var seen: [String] = []
        for bot in visibleBots {
            if let folder = bot.folder, !folder.isEmpty, !seen.contains(folder) {
                seen.append(folder)
            }
        }
        return seen
    }

    private func members(of section: String?) -> [Bot] {
        let key = section ?? ""
        return visibleBots.filter { ($0.folder ?? "") == key }
    }

    private var workingCount: Int {
        visibleBots.filter { model.mood(for: $0) == .working }.count
    }

    private var needsYouCount: Int {
        visibleBots.filter { model.needsYou($0) }.count
    }

    private var summary: String {
        let bots = visibleBots.count
        let botsText = bots == 1 ? "1 bot" : "\(bots) bots"
        let count = sections.count
        if count == 0 { return botsText }
        return botsText + (count == 1 ? ", 1 section" : ", \(count) sections")
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: ["Team"]) {
                // One height for the whole row: the topbar's actions are page actions, 44pt, so
                // the pink one does not stand taller than the grey ones beside it.
                HStack(spacing: Theme.Space.snug) {
                    if !visibleBots.isEmpty {
                        Button { isAddingSection = true } label: {
                            Label("New section", systemImage: "rectangle.stack")
                        }
                        .buttonStyle(QuietButton())
                    }
                    Button { settingUp = TeamCreatorRequest(section: nil) } label: {
                        Label("Set up a bot yourself", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(QuietButton())
                    Button(action: quickCreate) {
                        Label("New bot", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButton())
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.pageSide) {
                    header
                    if visibleBots.isEmpty && !model.bots.isEmpty {
                        // Every bot is hidden from the sidebar, not gone: say so, and offer them back.
                        EmptyState(title: "All your bots are hidden",
                                   message: "They're still here, with their chats and routines. Show them to put them back in the sidebar and on this page.") {
                            Button {
                                for bot in model.bots where bot.hidden { model.toggleHidden(bot) }
                            } label: {
                                Label("Show them", systemImage: "eye")
                            }
                            .buttonStyle(PrimaryButton())
                        }
                        .padding(.top, Theme.Space.page)
                    } else if visibleBots.isEmpty {
                        EmptyState(title: "No bots yet",
                                   message: "Make one and it shows up here, ready to file into a section.") {
                            HStack(spacing: Theme.Space.snug) {
                                Button(action: quickCreate) {
                                    Label("New bot", systemImage: "plus")
                                }
                                .buttonStyle(PrimaryButton())
                                Button { settingUp = TeamCreatorRequest(section: nil) } label: {
                                    Label("Set up a bot yourself", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(QuietButton())
                            }
                        }
                        .padding(.top, Theme.Space.page)
                    } else {
                        board
                    }
                }
                .padding(.horizontal, Theme.Space.pageSide)
                .padding(.top, Theme.Space.section)
                .padding(.bottom, Theme.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $settingUp) { request in
            BotCreatorSheet(section: request.section)
        }
        .background {
            Color.clear.sheet(isPresented: $isAddingSection) { TeamNewSectionSheet() }
        }
        .background {
            Color.clear.sheet(item: $sectionFor) { TeamNewSectionSheet(preselected: $0.id) }
        }
        .background {
            Color.clear.sheet(item: $renamingBot) { BotCreatorSheet(editing: $0) }
        }
        .background {
            Color.clear.confirmsBotDeletion($deletingBot) { model.deleteBot($0) }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Space.gutter) {
                titleBlock
                Spacer(minLength: Theme.Space.gutter)
                pills
            }
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                titleBlock
                pills
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Team")
                .font(Theme.Typography.title)
                .foregroundStyle(palette.foreground)
            Text("Your bots, by section. Move a bot with its menu, or drag it to another column.")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pills: some View {
        HStack(spacing: Theme.Space.snug) {
            if workingCount > 0 {
                Badge(text: "\(workingCount) working", tone: .success, dot: true)
            }
            if needsYouCount > 0 {
                Badge(text: "\(needsYouCount) needs you", tone: .primary, dot: true)
            }
            Badge(text: summary, tone: .neutral)
        }
        .fixedSize()
    }

    private var board: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Space.gutter,
                                     alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.gutter) {
            ForEach(sections, id: \.self) { section in
                column(section: section)
            }
            // Always present, so there is somewhere to drag a bot out of its section.
            column(section: nil)
            newSectionTile
        }
    }

    // MARK: Columns

    private func column(section: String?) -> some View {
        let bots = members(of: section)
        let title = section ?? "Unassigned"
        let key = section ?? ""
        let targeted = dropTarget == key
        return VStack(alignment: .leading, spacing: Theme.Space.compact) {
            HStack(spacing: Theme.Space.snug) {
                // Sections wear the section icon everywhere; a folder means a working folder.
                Image(systemName: section == nil ? "tray" : "rectangle.stack")
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(bots.count)")
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, Theme.Space.tight)
                    .padding(.vertical, Theme.Space.hairline)
                    .background(palette.background, in: .rect(cornerRadius: Theme.Radius.sm))
                    .accessibilityLabel(bots.count == 1 ? "1 bot" : "\(bots.count) bots")
                Spacer(minLength: 0)
                Button { startAdding(to: section) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(13)))
                        .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help(section.map { "Set up a bot yourself in \($0)" } ?? "Set up a bot yourself")
                .accessibilityLabel(section.map { "Set up a bot yourself in \($0)" } ?? "Set up a bot yourself")
            }
            .padding(.horizontal, Theme.Space.xs)
            .padding(.top, Theme.Space.hairline)
            .padding(.bottom, Theme.Space.xs)

            if bots.isEmpty {
                emptyColumn(title: title, section: section)
            } else {
                ForEach(bots) { bot in
                    TeamBotCard(
                        bot: bot,
                        sections: sections,
                        onOpen: { onOpen(bot.id) },
                        onRename: { renamingBot = bot },
                        onDelete: { deletingBot = bot },
                        onNewSection: { sectionFor = bot })
                    // A typed reference, not the id as plain text: dropped on a text field, a
                    // string payload pasted the raw id into it.
                    .draggable(TeamBotDrag(id: bot.id.rawValue))
                }
            }
        }
        .padding(Theme.Space.step)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .top)
        .background(targeted ? palette.cardHover : palette.card,
                    in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(palette.primary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .dropDestination(for: TeamBotDrag.self) { items, _ in
            move(items.map(\.id), to: section)
        } isTargeted: { inside in
            if inside {
                dropTarget = key
            } else if dropTarget == key {
                dropTarget = nil
            }
        }
    }

    private func emptyColumn(title: String, section: String?) -> some View {
        EmptyState(
            title: section == nil ? "Every bot is in a section" : "No bots in \(title) yet",
            message: section == nil
                ? "Drag a bot here to take it out of its section."
                : "Drag a bot here, or make one that starts in this section.",
            mood: .sleeping,
            faceSize: 52
        ) {
            Button { startAdding(to: section) } label: {
                Label("Set up a bot yourself", systemImage: "plus")
            }
            .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .md))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    private var newSectionTile: some View {
        Button { isAddingSection = true } label: {
            VStack(spacing: Theme.Space.snug) {
                Image(systemName: "plus")
                    .font(.system(size: Theme.scaled(15)))
                Text("New section")
                    .font(Theme.Typography.body)
            }
            .foregroundStyle(palette.mutedForeground)
            .frame(maxWidth: .infinity, minHeight: 260)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Make a section by moving bots into it")
    }

    // MARK: Actions

    private func move(_ ids: [String], to section: String?) -> Bool {
        var moved = false
        for raw in ids {
            guard let bot = model.bots.first(where: { $0.id.rawValue == raw }) else { continue }
            if (bot.folder ?? "") != (section ?? "") {
                model.setFolder(bot, section)
            }
            moved = true
        }
        dropTarget = nil
        return moved
    }

    /// Opens the full creator with its Section field already set to `section`, so the form shows
    /// where the bot lands.
    private func startAdding(to section: String?) {
        settingUp = TeamCreatorRequest(section: section)
    }

    /// "New bot": made at once, and it asks what it is for.
    private func quickCreate() {
        if let id = model.quickCreateBot(engine: model.defaultNewBotEngine) { onOpen(id) }
    }
}

// MARK: - A bot's card

/// A bot being dragged between Team columns.
///
/// Its own type rather than the id as a `String`: a string drag is plain text to every other
/// drop target, so a card dropped on a text field pasted the raw id into it.
struct TeamBotDrag: Codable, Sendable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bupsyBotReference)
    }
}

extension UTType {
    /// A Bupsy bot, by id. Only ever dragged within the app. Computed, so no global state.
    static var bupsyBotReference: UTType { UTType(exportedAs: "si.bupsy.mac.bot-reference") }
}

/// One bot on the board. The whole card opens the chat: by click, by Return or Space once it
/// has keyboard focus, or by VoiceOver's default action. Its menu is the same `BotMenu` the
/// sidebar row uses.
struct TeamBotCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    let sections: [String]
    let onOpen: () -> Void
    let onRename: () -> Void
    /// Asks the board to confirm. The menu cannot host the dialog: it closes on click.
    let onDelete: () -> Void
    /// Opens the new-section sheet with this bot picked.
    let onNewSection: () -> Void
    @State private var hovering = false

    init(bot: Bot, sections: [String], onOpen: @escaping () -> Void,
         onRename: @escaping () -> Void, onDelete: @escaping () -> Void,
         onNewSection: @escaping () -> Void = {}) {
        self.bot = bot
        self.sections = sections
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
        self.onNewSection = onNewSection
    }

    private var mood: BotMood { model.mood(for: bot) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            HStack(spacing: Theme.Space.step) {
                // A board of idle faces holds still; only a bot with something going on moves.
                BotFace(bot: bot, mood: mood, size: Theme.Size.tile, still: mood == .idle)
                    .overlay(alignment: .bottomTrailing) { statusDot }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    HStack(spacing: Theme.Space.tight) {
                        Text(bot.name)
                            .font(.system(size: Theme.scaled(14), weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if let role = bot.role, !role.isEmpty {
                            RoleTag(text: role)
                        }
                    }
                    Text(status)
                        .font(Theme.Typography.label)
                        .foregroundStyle(statusColour)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
                menu
            }

            HStack(spacing: Theme.Space.tight) {
                chip(engineLine)
                if let second = secondFact { chip(second) }
            }
        }
        .padding(Theme.Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? palette.cardHover : palette.background,
                    in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(palette.border)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("Open \(bot.name)")
        // Reachable without a mouse: Tab lands on the card, Return or Space opens it.
        .focusable()
        .onKeyPress(.return) { onOpen(); return .handled }
        .onKeyPress(.space) { onOpen(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibleName)
        .accessibilityValue(status)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private var accessibleName: String {
        guard let role = bot.role, !role.isEmpty else { return bot.name }
        return "\(bot.name), \(role)"
    }

    private var menu: some View {
        Menu {
            BotMenu(bot: bot,
                    onOpen: onOpen,
                    onNewFolder: onNewSection,
                    onRename: onRename,
                    onDelete: onDelete)
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
        .help("\(bot.name) options")
        .accessibilityLabel("\(bot.name) options")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, Theme.Space.hairline)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.sm))
    }

    /// What it is doing, in one line. Never blank: an empty line makes a card look broken.
    private var status: String {
        let preview = model.thread(for: bot.id).preview
        switch mood {
        case .waitingForYou:
            return "Needs you"
        case .working:
            return preview.map { "Working: \($0)" } ?? "Working"
        case .failed:
            return "Last run failed"
        case .done:
            return preview.map { "Done: \($0)" } ?? "Done"
        case .sleeping:
            return "Asleep"
        case .idle:
            if let preview { return preview }
            if let job = bot.personaPrompt?.split(separator: "\n").first, !job.isEmpty {
                return String(job)
            }
            return "No messages yet"
        }
    }

    /// The line of text. Red text uses the readable red, not the fill red.
    private var statusColour: Color {
        switch mood {
        case .waitingForYou: palette.foreground
        case .working: palette.success
        case .failed: palette.destructiveText
        case .idle, .done, .sleeping: palette.mutedForeground
        }
    }

    private var dotColour: Color {
        switch mood {
        case .waitingForYou: palette.primary
        case .working: palette.success
        case .failed: palette.destructive
        case .idle, .done, .sleeping: palette.mutedForeground
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if mood == .working || mood == .waitingForYou || mood == .failed {
            Circle()
                .fill(dotColour)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(palette.background, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }

    /// "Claude Code, Opus": the engine, and the model when one was picked.
    private var engineLine: String {
        guard let id = bot.model, !id.isEmpty else { return bot.engine.displayName }
        let label = model.models(for: bot).first { $0.id == id }?.label ?? id
        return "\(bot.engine.displayName), \(label)"
    }

    /// Its schedule if it has one, otherwise where it runs when that is not this Mac.
    private var secondFact: String? {
        if let routine = model.routines.first(where: { $0.botID == bot.id.rawValue && $0.enabled }) {
            return Schedule.describe(routine.cron)
        }
        if let machineID = bot.machineID,
           let machine = model.machines.first(where: { $0.id == machineID }) {
            return "On \(machine.name)"
        }
        return nil
    }
}

/// A quiet pill with an optional coloured dot. Kept for older call sites; it draws a `Badge`,
/// the app's one status pill.
struct TeamPill: View {
    let text: String
    let tone: Color?

    init(text: String, tone: Color?) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Badge(text: text, tone: tone, dot: tone != nil)
    }
}

/// Which section the full creator was opened from, nil for none. Its own type so one
/// `.sheet(item:)` covers both the toolbar button and each column's "+".
struct TeamCreatorRequest: Identifiable {
    let id = UUID()
    let section: String?
}

// MARK: - New section

/// Makes a section by moving bots into it.
///
/// A section exists exactly as long as a bot is in it, so making one and filling it are the same
/// action: pick a name and at least one bot.
struct TeamNewSectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let preselected: BotID?
    @State private var name = ""
    @State private var chosen: Set<BotID> = []
    /// Saved into the sidebar's folded sections (`SidebarFolds`) when the section is created.
    @State private var foldByDefault = false

    init(preselected: BotID? = nil) {
        self.preselected = preselected
    }

    private var bots: [Bot] { model.bots.filter { !$0.hidden } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetFrame(title: "New section", icon: "rectangle.stack",
                   subtitle: "A sidebar group for bots that work on the same thing.",
                   width: 480, primaryVerb: "create") {
            Field(label: "Name", hint: "A section stays in the sidebar while it has bots in it.") {
                TextField("", text: $name, prompt: Text("Clients"))
                    .bupsyField()
                    .onSubmit(commit)
            }

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack {
                    Text("Add bots")
                    Spacer(minLength: 0)
                    Text(countLine)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                            if index > 0 {
                                Rectangle().fill(palette.border).frame(height: 1)
                            }
                            row(bot)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(palette.background, in: .rect(cornerRadius: Theme.Radius.base))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border)
                }
            }

            foldRow
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create section", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || chosen.isEmpty)
        }
        .onAppear {
            if let preselected { chosen.insert(preselected) }
        }
    }

    /// Folded, the section header still shows how many bots it holds, in pink when one of them
    /// needs you, so folding it hides nothing urgent.
    private var foldRow: some View {
        HStack(spacing: Theme.Space.snug) {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text("Fold it in the sidebar by default")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Text("Bots that need you still show their count when it's folded.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.snug)
            Toggle("Fold it in the sidebar by default", isOn: $foldByDefault)
                .labelsHidden()
                .bupsySwitch()
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.step)
        .background(palette.background, in: .rect(cornerRadius: Theme.Radius.base))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border)
        }
    }

    private var countLine: String {
        switch chosen.count {
        case 0: "Pick at least one"
        case 1: "1 bot moves here"
        default: "\(chosen.count) bots move here"
        }
    }

    private func row(_ bot: Bot) -> some View {
        let isIn = chosen.contains(bot.id)
        let current = (bot.folder ?? "").isEmpty ? nil : bot.folder
        let whereNow: String = {
            guard let current else { return isIn ? "" : "Unassigned" }
            return isIn ? "Moves from \(current)" : "In \(current)"
        }()
        return HStack(spacing: Theme.Space.snug) {
            BotFace(bot: bot, mood: .idle, size: 26, still: true)
            Text(bot.name)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            if !whereNow.isEmpty {
                Text(whereNow)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("Move \(bot.name) here", isOn: Binding(
                get: { chosen.contains(bot.id) },
                set: { on in
                    if on { chosen.insert(bot.id) } else { chosen.remove(bot.id) }
                }
            ))
            .labelsHidden()
            .bupsySwitch()
        }
        .padding(.horizontal, Theme.Space.step)
        .frame(height: Theme.Size.controlLg)
        .contentShape(.rect)
    }

    private func commit() {
        guard !trimmed.isEmpty, !chosen.isEmpty else { return }
        let isNew = !model.folders.contains(trimmed)
        for bot in model.bots where chosen.contains(bot.id) {
            model.setFolder(bot, trimmed)
        }
        // The same store the sidebar's fold caret writes. Off leaves an existing section's fold
        // alone and only makes sure a brand new one starts open.
        if foldByDefault {
            SidebarFolds.fold(trimmed)
        } else if isNew {
            SidebarFolds.unfold(trimmed)
        }
        dismiss()
    }
}
