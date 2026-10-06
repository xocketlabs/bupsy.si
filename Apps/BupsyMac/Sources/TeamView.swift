import BupsyKit
import SwiftUI

/// The whole team at once: one column per section, a card per bot.
///
/// The sidebar is for going somewhere; this page is for arranging. Every bot shows what it is
/// doing and what it runs on, and moves to another section from its menu or by dragging the card
/// onto another column.
struct TeamView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    let onOpen: (BotID) -> Void

    @State private var isAddingBot = false
    @State private var isAddingToSection = false
    @State private var addingToSection: String?
    @State private var botsBeforeAdding: Set<BotID> = []
    @State private var isAddingSection = false
    @State private var renamingBot: Bot?
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
        visibleBots.filter { model.isRunning($0.id) && !model.isWaitingForApproval($0.id) }.count
    }

    private var needsYouCount: Int {
        visibleBots.filter { model.isWaitingForApproval($0.id) }.count
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
                HStack(spacing: Theme.Space.snug) {
                    if !visibleBots.isEmpty {
                        Button { isAddingSection = true } label: {
                            Label("New section", systemImage: "folder.fill")
                        }
                        .buttonStyle(QuietButton(compact: true))
                    }
                    Button { isAddingBot = true } label: {
                        Label("New bot", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButton())
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.page - 8) {
                    header
                    if visibleBots.isEmpty {
                        EmptyState(title: "No bots yet",
                                   message: "Make one and it shows up here, ready to file into a section.") {
                            Button { isAddingBot = true } label: {
                                Label("New bot", systemImage: "plus")
                            }
                            .buttonStyle(PrimaryButton())
                        }
                        .padding(.top, Theme.Space.page)
                    } else {
                        board
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, Theme.Space.section)
                .padding(.bottom, Theme.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $isAddingBot) { BotCreatorSheet() }
        .background {
            Color.clear.sheet(isPresented: $isAddingToSection, onDismiss: { fileNewBots() }) {
                BotCreatorSheet()
            }
        }
        .background {
            Color.clear.sheet(isPresented: $isAddingSection) { TeamNewSectionSheet() }
        }
        .background {
            Color.clear.sheet(item: $renamingBot) { BotCreatorSheet(editing: $0) }
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
                TeamPill(text: "\(workingCount) working", tone: palette.success)
            }
            if needsYouCount > 0 {
                TeamPill(text: "\(needsYouCount) needs you", tone: palette.primary)
            }
            TeamPill(text: summary, tone: nil)
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: section == nil ? "tray.fill" : "folder.fill")
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                Text(title)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Text("\(bots.count)")
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(palette.background, in: .rect(cornerRadius: 6))
                Spacer(minLength: 0)
                Button { startAdding(to: section) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(13)))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help(section.map { "New bot in \($0)" } ?? "New bot")
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 4)

            if bots.isEmpty {
                emptyColumn(title: title, section: section)
            } else {
                ForEach(bots) { bot in
                    TeamBotCard(
                        bot: bot,
                        sections: sections,
                        onOpen: { onOpen(bot.id) },
                        onRename: { renamingBot = bot })
                    .draggable(bot.id.rawValue)
                }
            }
        }
        .padding(Theme.Space.step)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .top)
        .background(targeted ? palette.cardHover : palette.card,
                    in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.primary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            move(items, to: section)
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
            faceSize: 52
        ) {
            Button { startAdding(to: section) } label: {
                Label("Add a bot", systemImage: "plus")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, Theme.Space.step)
                    .frame(height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(SidebarIconButtonStyle())
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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

    /// Opens the new-bot sheet, and files whatever it made into `section` once it closes.
    private func startAdding(to section: String?) {
        guard let section else {
            isAddingBot = true
            return
        }
        botsBeforeAdding = Set(model.bots.map(\.id))
        addingToSection = section
        isAddingToSection = true
    }

    private func fileNewBots() {
        defer {
            addingToSection = nil
            botsBeforeAdding = []
        }
        guard let section = addingToSection else { return }
        for bot in model.bots where !botsBeforeAdding.contains(bot.id) {
            model.setFolder(bot, section)
        }
    }
}

// MARK: - A bot's card

struct TeamBotCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let bot: Bot
    let sections: [String]
    let onOpen: () -> Void
    let onRename: () -> Void
    @State private var hovering = false

    init(bot: Bot, sections: [String], onOpen: @escaping () -> Void,
         onRename: @escaping () -> Void) {
        self.bot = bot
        self.sections = sections
        self.onOpen = onOpen
        self.onRename = onRename
    }

    private var mood: BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: bot, mood: mood, size: 44)
                    .overlay(alignment: .bottomTrailing) { statusDot }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.tight) {
                        Text(bot.name)
                            .font(.system(size: Theme.scaled(14), weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if let role = bot.role, !role.isEmpty {
                            Text(role)
                                .font(.system(size: Theme.scaled(10)))
                                .foregroundStyle(palette.mutedForeground)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(palette.card, in: .rect(cornerRadius: 6))
                                .fixedSize()
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
    }

    private var menu: some View {
        Menu {
            Section("Move to") {
                ForEach(sections, id: \.self) { section in
                    Button {
                        model.setFolder(bot, section)
                    } label: {
                        Label(section, systemImage: bot.folder == section ? "checkmark" : "folder")
                    }
                }
                Button {
                    model.setFolder(bot, nil)
                } label: {
                    Label("Unassigned", systemImage: (bot.folder ?? "").isEmpty ? "checkmark" : "tray")
                }
            }
            Divider()
            Button { model.togglePin(bot) } label: {
                Label(bot.pinned ? "Unpin" : "Pin to top", systemImage: bot.pinned ? "pin.slash" : "pin")
            }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button { model.shuffleFace(bot) } label: { Label("Shuffle face", systemImage: "sparkles") }
            Button(action: onOpen) { Label("Open chat", systemImage: "bubble.left") }
            Divider()
            Button(role: .destructive) { model.deleteBot(bot) } label: {
                Label("Delete bot", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Theme.scaled(13), weight: .semibold))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(bot.name) options")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 2)
            .background(palette.card, in: .rect(cornerRadius: 6))
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
            return preview ?? "Last run failed"
        case .idle, .done, .sleeping:
            if let preview { return preview }
            if let job = bot.personaPrompt?.split(separator: "\n").first, !job.isEmpty {
                return String(job)
            }
            return "No messages yet"
        }
    }

    private var statusColour: Color {
        switch mood {
        case .waitingForYou: palette.primary
        case .working: palette.success
        case .failed: palette.destructive
        case .idle, .done, .sleeping: palette.mutedForeground
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if mood == .working || mood == .waitingForYou {
            Circle()
                .fill(mood == .working ? palette.success : palette.primary)
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

/// A quiet pill with an optional coloured dot, for the page header's counts.
struct TeamPill: View {
    @Environment(\.palette) private var palette
    let text: String
    let tone: Color?

    init(text: String, tone: Color?) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            if let tone {
                Circle().fill(tone).frame(width: 5, height: 5)
            }
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(tone ?? palette.mutedForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.snug)
        .frame(height: 26)
        .background((tone ?? palette.foreground).opacity(tone == nil ? 0.05 : 0.12),
                    in: .rect(cornerRadius: 6))
    }
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
        SheetFrame(title: "New section", icon: "folder.fill",
                   subtitle: "A sidebar group for bots that work on the same thing.",
                   width: 480, primaryVerb: "create") {
            Field(label: "Name", hint: "A section stays in the sidebar while it has bots in it.") {
                TextField("", text: $name, prompt: Text("Clients"))
                    .textFieldStyle(BupsyFieldStyle())
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Fold it in the sidebar by default")
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Text("Bots that need you still show their count when it's folded.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.snug)
            Toggle("", isOn: $foldByDefault)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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
            BotFace(bot: bot, mood: .idle, size: 26)
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
            Toggle("", isOn: Binding(
                get: { chosen.contains(bot.id) },
                set: { on in
                    if on { chosen.insert(bot.id) } else { chosen.remove(bot.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.step)
        .frame(height: 44)
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
