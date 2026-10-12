import BupsyKit
import Combine
import SwiftUI

/// The nav rail, laid out like the agndex dashboard sidebar.
///
/// Top to bottom: the brand with search and new, the two fixed places ("Waiting on you" and
/// "Team"), then the scrolling list (pinned bots, the person's own sections, group chats, and the
/// bots not filed anywhere), then the setup rows and the account row pinned to the bottom so they
/// stay reachable however many bots there are.
///
/// Rows are one line: a face, a name, a role tag. The face carries the state (working, needs
/// you), so a glance down the list reads as a column of faces rather than a column of labels.
struct NavRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var destination: Destination
    /// Owned by the app rather than the rail: the palette opens over the conversation, which the
    /// rail does not contain.
    var onStartChat: () -> Void = {}
    var onSearch: () -> Void = {}
    /// The one sheet the rail has up, if any. One `.sheet(item:)` for all of them: several
    /// chained `.sheet`s on one view and SwiftUI silently drops all but one.
    @State private var sheet: RailSheet?
    @State private var showsYouMenu = false
    @State private var hoveringAccount = false
    /// Set to ask before deleting. Owned here, not by the context menu, which is gone on click.
    @State private var deletingBot: Bot?
    @State private var deletingGroup: ChatGroup?
    /// The section the person picked "Delete section…" for, until they confirm.
    @State private var deletingSection: String?
    /// The engine the person picked "Sign out" for, until they confirm.
    @State private var signingOut: EngineID?
    /// True after a sign-in or sign-out was started from the You menu, so a failure is shown here
    /// as an alert, and not also when it was started from Settings › Engines, which says it inline.
    @State private var awaitingAccount = false
    /// Sections folded shut, kept across launches. A JSON array of section keys, shared with the
    /// New section sheet's "Fold it in the sidebar by default". See `SidebarFolds`.
    @AppStorage(SidebarFolds.key, store: AppHome.defaults) private var foldedJSON = "[]"

    enum Destination: Hashable {
        case bot(BotID)
        case machines
        case connectors
        case attention
        case usage
        case permissions
        case group(String)
        case team
        case groups
        /// Settings, on the pane in `AppModel.settingsPane`. See `AppModel.openSettings(_:)`.
        case settings
    }

    /// Every sheet the rail presents.
    enum RailSheet: Identifiable {
        case addBot
        /// A new bot with its Section field already set to this section.
        case addBotToSection(String)
        case renameFolder(String)
        case fileBot(Bot)
        case editBot(Bot)
        case customModel(Bot)
        case addGroup
        case renameGroup(ChatGroup)
        case shortcuts

        var id: String {
            switch self {
            case .addBot: "add-bot"
            case .addBotToSection(let section): "add-bot-to-section-" + section
            case .renameFolder(let name): "rename-folder-" + name
            case .fileBot(let bot): "file-bot-" + bot.id.rawValue
            case .editBot(let bot): "edit-bot-" + bot.id.rawValue
            case .customModel(let bot): "custom-model-" + bot.id.rawValue
            case .addGroup: "add-group"
            case .renameGroup(let group): "rename-group-" + group.id
            case .shortcuts: "shortcuts"
            }
        }
    }

    /// Keys for the fixed collapsible sections, kept apart from section names people type.
    private static let groupsKey = "\u{1}groups"
    private static let unassignedKey = "\u{1}unassigned"
    /// The Hidden section is folded unless this key is in the folded set: folded by default.
    private static let hiddenOpenKey = "\u{1}hidden-open"

    // In small parts, each its own property: as one expression, the column, its sheet and seven
    // dialogs were more than Swift 6.2's type checker would solve in time.
    var body: some View {
        column
            // Cmd 1 to 9, registered once here rather than on the rows, so they follow the order
            // the list shows and keep working while a section is folded.
            .background { numberShortcuts }
            .sheet(item: sheetBinding) { item in sheetContent(item) }
            .background { dialogHosts }
            // Help > Keyboard shortcuts (Cmd /) lives on the app; the sheet hangs here.
            .onReceive(NotificationCenter.default.publisher(for: .bupsyShowKeyboardShortcuts)) { _ in
                showsYouMenu = false
                sheet = .shortcuts
            }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Theme.Space.gutter)
            pausedBanner
            places
                .padding(.bottom, Theme.Space.snug)

            conversations

            setup
            footer
                .padding(.top, Theme.Space.snug)
        }
        .padding(.horizontal, Theme.Space.snug)
        // The window keeps its standard title bar, so the rail already starts below the window
        // buttons. A second title bar's worth of padding here pushed the brand down twice.
        .padding(.top, Theme.Space.gutter)
        .padding(.bottom, Theme.Space.snug)
        .frame(width: 276)
        .background(palette.sidebar)
    }

    @ViewBuilder
    private func sheetContent(_ item: RailSheet) -> some View {
        switch item {
        case .addBot: BotCreatorSheet()
        case .addBotToSection(let section): BotCreatorSheet(section: section)
        case .renameFolder(let name): RenameFolderSheet(folder: name)
        case .fileBot(let bot): NewFolderSheet(bot: bot)
        case .editBot(let bot): BotCreatorSheet(editing: bot)
        case .customModel(let bot): CustomModelSheet(bot: bot)
        case .addGroup: NewGroupSheet(onCreated: { group in destination = .group(group.id) })
        case .renameGroup(let group): RenameGroupSheet(group: group)
        case .shortcuts: KeyboardShortcutsSheet()
        }
    }

    /// Each dialog on its own empty view: two dialogs on one view and SwiftUI silently drops one.
    private var dialogHosts: some View {
        ZStack {
            botDeletionHost
            groupDeletionHost
            sectionDeletionHost
            signOutHost
            moveConfirmationHost
            moveOutcomeHost
            accountProblemHost
        }
    }

    private var botDeletionHost: some View {
        Color.clear.confirmsBotDeletion($deletingBot) { bot in
            model.deleteBot(bot)
        }
    }

    private var groupDeletionHost: some View {
        Color.clear.confirmsGroupDeletion($deletingGroup) { group in
            if destination == .group(group.id) {
                destination = .groups
            }
            model.deleteGroup(group)
        }
    }

    private var sectionDeletionHost: some View {
        Color.clear.confirmsSectionDeletion($deletingSection) { section in
            model.deleteSection(section)
            SidebarFolds.unfold(section)
        }
    }

    private var signOutHost: some View {
        Color.clear.confirmsSignOut($signingOut, onConfirm: { awaitingAccount = true })
    }

    // Moving a bot or a section to another Mac: asked from the bot's menus, its details and a
    // section's menu, so the request lives on the model and is answered here, once.
    private var moveConfirmationHost: some View {
        let shown = Binding<Bool>(
            get: { model.moveRequest != nil },
            set: { if !$0 { model.moveRequest = nil } })
        return Color.clear.confirmationDialog(
            model.moveRequest.map(model.moveTitle) ?? "",
            isPresented: shown,
            titleVisibility: .visible,
            presenting: model.moveRequest
        ) { (request: AppModel.MoveRequest) in
            Button("Move to \(request.mac.name)") { model.confirmMove(request) }
            Button("Cancel", role: .cancel) {}
        } message: { (request: AppModel.MoveRequest) in
            Text(model.moveMessage(request))
        }
    }

    private var moveOutcomeHost: some View {
        let shown = Binding<Bool>(
            get: { model.moveOutcome != nil },
            set: { if !$0 { model.moveOutcome = nil } })
        return Color.clear.alert(
            model.moveOutcome?.title ?? "",
            isPresented: shown,
            presenting: model.moveOutcome
        ) { outcome in
            // When the fix is a setting, the way there, rather than only its name.
            if let pane = outcome.settingsPane {
                Button("Open \(pane.label)") { model.openSettings(pane) }
            }
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
    }

    private var accountProblemHost: some View {
        let shown = Binding<Bool>(
            get: { awaitingAccount && model.accountProblem != nil },
            set: { stillShown in
                if !stillShown {
                    awaitingAccount = false
                    model.accountProblem = nil
                }
            })
        return Color.clear.alert("That didn't work", isPresented: shown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.accountProblem ?? "")
        }
    }

    private var sheetBinding: Binding<RailSheet?> {
        Binding(
            get: { sheet ?? model.customModelBot.map { RailSheet.customModel($0) } },
            set: { newValue in
                if let newValue {
                    sheet = newValue
                } else if sheet != nil {
                    sheet = nil
                } else {
                    model.customModelBot = nil
                }
            })
    }

    /// The bots in the order the list shows them: pinned, then each section in order, then the
    /// unassigned ones. Hidden bots are left out. Folding a section does not change it.
    private var visibleOrder: [Bot] {
        model.pinnedBots + model.folders.flatMap { model.bots(in: $0) } + model.ungroupedBots
    }

    /// Invisible buttons carrying Cmd 1 to Cmd 9 for the first nine bots in `visibleOrder`.
    private var numberShortcuts: some View {
        let order = Array(visibleOrder.prefix(9))
        return ZStack {
            ForEach(Array(order.enumerated()), id: \.element.id) { index, bot in
                Button("Open \(bot.name)") { destination = .bot(bot.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The folded set, read from and written back to the saved JSON.
    private var collapsed: Set<String> {
        get { SidebarFolds.decode(foldedJSON) }
        nonmutating set { foldedJSON = SidebarFolds.encode(newValue) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.snug) {
            // The mark, not a gradient square: the same bubble character as the app icon, and it
            // blinks now and then, because the thing that looks after the bots is one of them.
            BupsyIconMark(size: Theme.scaled(24))
            Text("Bupsy")
                .font(.system(size: Theme.scaled(16), weight: .semibold))
                .foregroundStyle(palette.foreground)

            Spacer(minLength: Theme.Space.snug)

            headerButton("magnifyingglass", label: "Search", help: "Search (Cmd F)") { onSearch() }
                .keyboardShortcut("f", modifiers: .command)

            headerButton("plus", label: "Start a chat", help: "Start a chat (Cmd N)") { onStartChat() }
        }
        .padding(.leading, Theme.Space.snug)
        .padding(.trailing, Theme.Space.hairline)
    }

    /// The brand row's icon buttons: 32pt squares, as the board draws them.
    private func headerButton(
        _ symbol: String, label: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(14), weight: .medium))
                .frame(width: Theme.Size.controlSm + Theme.Space.xs,
                       height: Theme.Size.controlSm + Theme.Space.xs)
                .contentShape(.rect)
        }
        .buttonStyle(SidebarIconButtonStyle(radius: Theme.Radius.lg))
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: - Fixed places

    /// "Waiting on you" and "Team": always in the same spot, so they can be found without looking.
    private var places: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            let waiting = model.attentionItems.count
            SidebarNavRow(icon: "hand.raised.fill", label: "Waiting on you",
                          selected: destination == .attention,
                          count: waiting, countIsUrgent: true) { destination = .attention }
            SidebarNavRow(icon: "person.2.fill", label: "Team",
                          selected: destination == .team) { destination = .team }
        }
    }

    // MARK: - The conversation list

    private var conversations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                if !model.pinnedBots.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        sectionHeader("Pinned")
                        ForEach(model.pinnedBots) { row(for: $0) }
                    }
                }

                // Every section, empty ones too: a section stays until it is deleted.
                ForEach(model.folders, id: \.self) { folder in
                    let members = model.bots(in: folder)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        sectionHeader(folder, key: folder, members: members,
                                      addHelp: "Set up a bot yourself in \(folder)",
                                      onAdd: { startAdding(to: folder) })
                            .contextMenu {
                                Button("Rename section…") {
                                    sheet = .renameFolder(folder)
                                }
                                // Named for what it does: the bots leave, the section stays.
                                Button("Move these bots to Unassigned") {
                                    model.dissolveFolder(folder)
                                }
                                .disabled(!model.bots.contains { $0.folder == folder })
                                // The whole section to another of the person's Macs, bots and all.
                                if model.bots.contains(where: { $0.folder == folder }) {
                                    ForEach(model.moveTargets) { mac in
                                        Button("Move section to \(mac.name)…") {
                                            model.askToMove(section: folder, to: mac)
                                        }
                                        .disabled(!model.moving.isEmpty)
                                    }
                                }
                                Divider()
                                // Asks first. Its bots move to Unassigned; nothing is deleted
                                // but the section.
                                Button("Delete section…", role: .destructive) {
                                    deletingSection = folder
                                }
                            }
                        if !collapsed.contains(folder) {
                            if members.isEmpty {
                                emptySectionRow(folder)
                            } else {
                                ForEach(members) { row(for: $0) }
                            }
                        }
                    }
                }

                groupsSection

                let loose = model.ungroupedBots
                if !loose.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        // Only headed once anything else in the list has a heading: with no
                        // sections these are simply the list. The Groups header counts even
                        // with no groups in it, or these bots would read as its groups.
                        if !model.folders.isEmpty || showsGroupsSection
                            || !model.pinnedBots.isEmpty || !hiddenBots.isEmpty {
                            sectionHeader(model.folders.isEmpty ? "Bots" : "Unassigned",
                                          key: Self.unassignedKey, members: loose,
                                          addHelp: "Set up a bot yourself",
                                          onAdd: { startAdding(to: nil) })
                        }
                        if !collapsed.contains(Self.unassignedKey) {
                            ForEach(loose) { row(for: $0) }
                        }
                    }
                }

                hiddenSection

                if model.bots.isEmpty { empty }
            }
            .padding(.top, Theme.Space.snug)
            .padding(.bottom, Theme.Space.snug)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    private var showsGroupsSection: Bool {
        !model.groups.isEmpty || model.bots.count >= 2
    }

    private var hiddenBots: [Bot] { model.bots.filter(\.hidden) }

    /// Bots taken out of the sidebar, folded at the bottom so they can be put back. Only there
    /// when something is hidden.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = hiddenBots
        if !hidden.isEmpty {
            let isOpen = collapsed.contains(Self.hiddenOpenKey)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                SidebarSectionHeader(
                    title: "Hidden",
                    collapsible: true,
                    collapsed: !isOpen,
                    count: isOpen ? nil : hidden.count,
                    countIsUrgent: false,
                    addHelp: "",
                    onToggle: {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                            var folded = collapsed
                            if folded.contains(Self.hiddenOpenKey) {
                                folded.remove(Self.hiddenOpenKey)
                            } else {
                                folded.insert(Self.hiddenOpenKey)
                            }
                            collapsed = folded
                        }
                    },
                    onAdd: nil,
                    onTitle: nil)
                if isOpen {
                    ForEach(hidden) { bot in
                        HStack(spacing: Theme.Space.hairline) {
                            BotRow(
                                bot: bot,
                                preview: model.thread(for: bot.id).preview,
                                mood: mood(for: bot),
                                selected: destination == .bot(bot.id),
                                unread: model.isUnread(bot),
                                action: { destination = .bot(bot.id) })
                            Button { model.toggleHidden(bot) } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: Theme.scaled(11), weight: .medium))
                                    .foregroundStyle(palette.sidebarMuted)
                                    .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(SidebarIconButtonStyle())
                            .help("Show in sidebar")
                            .accessibilityLabel("Show \(bot.name) in sidebar")
                        }
                        .contextMenu {
                            Button("Show in sidebar") { model.toggleHidden(bot) }
                            Button("Open chat") { destination = .bot(bot.id) }
                            Divider()
                            Button("Delete bot…", role: .destructive) { deletingBot = bot }
                        }
                    }
                }
            }
        }
    }

    /// Group chats: always present once there are bots to put in one, so its "+" is findable.
    @ViewBuilder
    private var groupsSection: some View {
        if showsGroupsSection {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                sectionHeader("Groups", key: Self.groupsKey, members: [],
                              count: model.groups.count,
                              urgent: groupsNeedYou,
                              addHelp: "New group chat",
                              onAdd: { sheet = .addGroup },
                              onTitle: { destination = .groups })
                if !collapsed.contains(Self.groupsKey) {
                    ForEach(model.groups) { group in
                        GroupRow(group: group,
                                 selected: destination == .group(group.id),
                                 action: { destination = .group(group.id) })
                        .contextMenu {
                            GroupMenu(group: group,
                                      onOpen: { destination = .group(group.id) },
                                      onRename: { sheet = .renameGroup(group) },
                                      onDelete: { deletingGroup = group })
                        }
                    }
                }
            }
        }
    }

    /// A group paused at its turn limit, or holding an approval a member raised in it, is
    /// waiting on you: the folded Groups count turns pink for it, as a bot folder's does.
    private var groupsNeedYou: Bool {
        model.groups.contains { group in
            model.groupThread(for: group).isWaitingOnYou || !model.pendingApprovals(in: group).isEmpty
        }
    }

    /// A small uppercase label. With a key it folds; with `onAdd` it carries a "+" on the right.
    private func sectionHeader(
        _ text: String, key: String? = nil, members: [Bot] = [], count: Int? = nil,
        urgent urgentOverride: Bool? = nil,
        addHelp: String = "", onAdd: (() -> Void)? = nil, onTitle: (() -> Void)? = nil
    ) -> some View {
        let isCollapsed = key.map { collapsed.contains($0) } ?? false
        let shown = count ?? members.count
        let urgent = urgentOverride ?? members.contains { model.needsYou($0) }
        return SidebarSectionHeader(
            title: text,
            collapsible: key != nil,
            collapsed: isCollapsed,
            // Folded, a section still says how many it holds, in pink when one of them needs you.
            count: isCollapsed && shown > 0 ? shown : nil,
            countIsUrgent: urgent,
            addHelp: addHelp,
            onToggle: {
                guard let key else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    var folded = collapsed
                    if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
                    collapsed = folded
                }
            },
            onAdd: onAdd,
            onTitle: onTitle
        )
    }

    private func row(for bot: Bot) -> some View {
        BotRow(
            bot: shownWithMac(bot),
            preview: bot.remote.map { $0.preview } ?? model.thread(for: bot.id).preview,
            mood: mood(for: bot),
            selected: destination == .bot(bot.id),
            unread: model.isUnread(bot),
            action: { destination = .bot(bot.id) }
        )
        // Cmd 1 to 9 are not on the rows: see `numberShortcuts`.
        .contextMenu {
            // A bot on another Mac is renamed, filed and deleted there; here it only opens.
            if let remote = bot.remote {
                Button("Open") { destination = .bot(bot.id) }
                Text("Runs on \(remote.macName)")
            } else {
                BotMenu(bot: bot,
                        onOpen: { destination = .bot(bot.id) },
                        onNewFolder: { sheet = .fileBot(bot) },
                        onRename: { sheet = .editBot(bot) },
                        onDelete: { deletingBot = bot })
            }
        }
    }

    /// A bot from another Mac whose name another bot here also has, named with its Mac too
    /// ("Scout · Mac mini"), so two Scouts can be told apart without hovering over the icon.
    private func shownWithMac(_ bot: Bot) -> Bot {
        guard let remote = bot.remote else { return bot }
        let others = model.bots.map(\.name) + model.linked.remoteBots.filter { $0.id != bot.id }.map(\.name)
        guard others.contains(where: { $0.caseInsensitiveCompare(bot.name) == .orderedSame }) else { return bot }
        var shown = bot
        shown.name = "\(bot.name) · \(remote.macName)"
        return shown
    }

    /// Opens the creator with its Section field already set to `section`, so what you see in the
    /// form is where the bot lands.
    private func startAdding(to section: String?) {
        if let section {
            sheet = .addBotToSection(section)
        } else {
            sheet = .addBot
        }
    }

    /// A section with nothing listed under it: a quiet line and a way to add a bot. Its bots may
    /// all be pinned or hidden, which is listed elsewhere, so the line says which.
    private func emptySectionRow(_ folder: String) -> some View {
        let filedElsewhere = model.bots.contains { $0.folder == folder }
        return HStack(spacing: Theme.Space.snug) {
            Text(filedElsewhere ? "Its bots are pinned or hidden" : "No bots yet")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.sidebarMutedForeground)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { startAdding(to: folder) } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .sm))
            .help("Set up a bot yourself in \(folder)")
            .accessibilityLabel("Set up a bot yourself in \(folder)")
        }
        .padding(.leading, Theme.Space.step)
        .padding(.trailing, Theme.Space.xs)
        .frame(minHeight: Theme.Size.controlSm)
    }

    /// While bots are paused: one quiet line saying what that means, and the way back. Paused
    /// is a choice, not a fault, so it wears the rail's own fill rather than a warning colour.
    @ViewBuilder
    private var pausedBanner: some View {
        if model.isPaused {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.sidebarMutedForeground)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("Bots are paused. Routines and goals won't start on their own.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.resumeAll() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(BupsyButtonStyle(kind: .secondary, size: .sm))
                    .help("Let routines, goals and folder watches start on their own again")
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.compact)
            .background(palette.sidebarAccent, in: .rect(cornerRadius: Theme.Radius.lg))
            .padding(.bottom, Theme.Space.step)
            .accessibilityElement(children: .contain)
        }
    }

    /// No second mascot here: the page beside it already has one. A heading and a line of how,
    /// as the board shows.
    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            sectionHeader("Bots")
            Text("No bots yet. Cmd N makes one.")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, Theme.Space.snug)
                .padding(.vertical, Theme.Space.xs)
        }
    }

    // MARK: - Below the list

    /// The machinery, pinned under the list and set apart from the bots by a rule.
    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
                .padding(.bottom, Theme.Space.step)
            sectionHeader("Setup")
            // Beta until cloud machines have run end to end against boat.dev.
            SidebarNavRow(icon: "display", label: "Machines", tag: "Beta",
                          selected: destination == .machines) { destination = .machines }
            SidebarNavRow(icon: "square.grid.2x2.fill", label: "Apps",
                          selected: destination == .connectors) { destination = .connectors }
            SidebarNavRow(icon: "chart.bar.fill", label: "Usage",
                          selected: destination == .usage) { destination = .usage }
            // A page here like the rest, not a window of its own over the chats.
            SidebarNavRow(icon: "gearshape.fill", label: "Settings",
                          selected: destination == .settings) { destination = .settings }
        }
    }

    // A button with a popover rather than a `Menu`: a macOS menu label keeps only one image and
    // one line of text, which flattened this row to a bare "You" and dropped the engine line.
    private var footer: some View {
        Button { showsYouMenu.toggle() } label: {
            footerLabel
                .contentShape(.rect)
                .padding(.vertical, Theme.Space.snug)
                .background(showsYouMenu || hoveringAccount ? palette.sidebarAccent : .clear,
                            in: .rect(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hoveringAccount = $0 }
        .help("Settings, appearance and sign-in")
        .accessibilityLabel("\(accountName), \(engineSummary)")
        .accessibilityHint("Opens settings, appearance and sign-in")
        // The board's order. Apps is one click away under Setup, so it is not repeated here;
        // Permissions is, because this menu is the only way to it. Settings stays here as well as
        // under Setup: it is where the board puts it, and where people look for it.
        .popover(isPresented: $showsYouMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                youMenuItem("gearshape", "Settings", shortcut: "Cmd ,") { destination = .settings }
                youMenuItem("display", "Machines") { destination = .machines }
                youMenuItem("chart.bar", "Usage") { destination = .usage }
                youMenuItem("hand.raised", "Permissions") { destination = .permissions }
                appearanceItem
                youMenuItem("keyboard", "Keyboard shortcuts", shortcut: "Cmd /") {
                    // After the popover has gone: a sheet asked for while it is still closing
                    // is dropped.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        sheet = .shortcuts
                    }
                }
                accountItems
            }
            .padding(Theme.Space.tight)
            .frame(width: 260)
        }
    }

    /// Appearance as a row with its current value, opening the three choices. The same
    /// preference as Settings > Appearance; both write `model.appearance`.
    private var appearanceItem: some View {
        Menu {
            ForEach(AppModel.Appearance.allCases, id: \.self) { option in
                Button {
                    model.appearance = option
                } label: {
                    if option == model.appearance {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 16)
                Text("Appearance")
                    .foregroundStyle(palette.foreground)
                Spacer(minLength: 0)
                Text(model.appearance.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.scaled(9), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
            }
            .font(Theme.Typography.body)
            .padding(.horizontal, Theme.Space.snug)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(MenuRowStyle())
        .menuIndicator(.hidden)
    }

    /// Sign out of each engine that is signed in, or sign in to one that is not. Both open the
    /// engine's own command in Terminal; Bupsy never handles the sign-in itself.
    @ViewBuilder
    private var accountItems: some View {
        let engines = EngineID.supported.filter { model.engineStatus[$0] != nil }
        if !engines.isEmpty {
            Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, Theme.Space.xs)
            ForEach(engines, id: \.self) { engine in
                if model.isSignedIn(engine) {
                    youMenuItem("rectangle.portrait.and.arrow.right", "Sign out of \(engine.displayName)…",
                                help: "Opens Terminal and runs \(engine.displayName)'s own sign-out command") {
                        // After the popover has gone: a dialog asked for while it is still
                        // closing is dropped, the same as the shortcuts sheet.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            signingOut = engine
                        }
                    }
                } else {
                    youMenuItem("person.crop.circle.badge.plus", "Sign in to \(engine.displayName)…",
                                help: "Opens Terminal and runs \(engine.displayName)'s own sign-in") {
                        awaitingAccount = true
                        model.openSignIn(for: engine)
                    }
                }
            }
        }
    }

    private func youMenuItem(
        _ symbol: String, _ title: String, shortcut: String? = nil, help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showsYouMenu = false
            action()
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: symbol)
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .font(Theme.Typography.body)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, Theme.Space.snug)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(MenuRowStyle())
        .help(help ?? "")
    }

    /// Your name and initials, as the board's account row shows them. Taken from the Mac's own
    /// account, the only name the app has; "You" when that is blank.
    private var footerLabel: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(palette.sidebarAccent)
                .frame(width: Theme.Size.controlSm + Theme.Space.xs,
                       height: Theme.Size.controlSm + Theme.Space.xs)
                .overlay {
                    Text(accountInitials)
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(palette.foreground)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(accountName)
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                // The engines, because that is the only account this app has any notion of.
                Text(engineSummary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.sidebarMutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: Theme.scaled(10), weight: .semibold))
                .foregroundStyle(palette.sidebarMuted)
        }
        .padding(.horizontal, Theme.Space.snug)
    }

    private var accountName: String {
        #if DEBUG
        // A recorded demo never shows whose Mac it was made on.
        if DemoMode.isOn { return DemoMode.personName }
        #endif
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "You" : name
    }

    /// Up to two initials, from the first and last words of the name.
    private var accountInitials: String {
        let words = accountName.split(whereSeparator: { $0 == " " })
        let picked = words.count > 1 ? [words[0], words[words.count - 1]] : Array(words.prefix(1))
        let letters = picked.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private var engineSummary: String {
        let ready = EngineID.allCases.filter { model.engineStatus[$0]?.isUsable == true }
        if !ready.isEmpty { return ready.map(\.displayName).joined(separator: ", ") }
        // Until every supported engine has answered, "none signed in" is a guess, and the wrong
        // first thing for someone who just opened the app to read.
        let answered = EngineID.supported.allSatisfy { model.engineStatus[$0] != nil }
        return answered ? "No engine signed in" : "Checking sign-in…"
    }

    /// One truth for the face and the dot: the model's mood, so the sidebar, Team, the menu bar
    /// and Waiting on you never disagree about who needs you.
    private func mood(for bot: Bot) -> BotMood {
        model.mood(for: bot)
    }
}

// MARK: - Sidebar pieces

/// The ink and fill every sidebar row shares, from the board's `.bp-nav`: muted text at 80% that
/// comes up to full on hover, ink for the current row and for a row that needs you, and an accent
/// fill under the current row (at 60% under the pointer). Pure, so bot, group and place rows
/// cannot drift apart again.
enum SidebarRowInk {
    static func text(selected: Bool, hovering: Bool, needs: Bool, palette: Palette.Scheme) -> Color {
        if selected || needs { return palette.foreground }
        return palette.sidebarMutedForeground.opacity(hovering ? 1 : 0.8)
    }

    static func fill(selected: Bool, hovering: Bool, palette: Palette.Scheme) -> Color {
        if selected { return palette.sidebarAccent }
        return hovering ? palette.sidebarAccent.opacity(0.6) : Color.clear
    }
}

/// A fixed place in the sidebar: an icon, a label, and a count when there is one.
struct SidebarNavRow: View {
    @Environment(\.palette) private var palette
    let icon: String
    let label: String
    /// A word beside the label, such as "Beta", for a part of the app still being proven.
    var tag: String?
    let selected: Bool
    var count: Int = 0
    /// Pink when the count is things waiting on a person; grey otherwise.
    var countIsUrgent = false
    let action: () -> Void
    @State private var hovering = false

    init(icon: String, label: String, tag: String? = nil, selected: Bool, count: Int = 0,
         countIsUrgent: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.tag = tag
        self.selected = selected
        self.count = count
        self.countIsUrgent = countIsUrgent
        self.action = action
    }

    var body: some View {
        let needs = countIsUrgent && count > 0
        Button(action: action) {
            HStack(spacing: Theme.Space.compact) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(13)))
                    .frame(width: 20)
                Text(label)
                    .font(Theme.Typography.body)
                    .fontWeight(selected ? .medium : .regular)
                    .lineLimit(1)
                if let tag { SetupBadge(text: tag, tone: .info) }
                Spacer(minLength: 0)
                if count > 0 {
                    SidebarCount(value: count, urgent: countIsUrgent)
                }
            }
            .foregroundStyle(SidebarRowInk.text(selected: selected, hovering: hovering, needs: needs,
                                                palette: palette))
            .padding(.horizontal, Theme.Space.step)
            .frame(height: Theme.Size.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarRowInk.fill(selected: selected, hovering: hovering, palette: palette),
                        in: .rect(cornerRadius: Theme.Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(count > 0 ? (countIsUrgent ? "\(count) waiting" : "\(count)") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small count. Pink and filled when it is things that need you, so it is the one spot of
/// colour in the sidebar; a quiet grey chip otherwise.
struct SidebarCount: View {
    @Environment(\.palette) private var palette
    let value: Int
    var urgent = false

    var body: some View {
        Text("\(value)")
            .font(Theme.Typography.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(urgent ? palette.onPrimary : palette.foreground)
            .padding(.horizontal, Theme.Space.tight)
            .frame(minWidth: 20, minHeight: 20)
            .background(urgent ? palette.primary : palette.sidebarBadge,
                        in: .rect(cornerRadius: Theme.Radius.sm))
            .accessibilityLabel(urgent ? "\(value) need you" : "\(value)")
    }
}

/// An uppercase section label with an optional fold caret, count and "+".
struct SidebarSectionHeader: View {
    @Environment(\.palette) private var palette
    let title: String
    let collapsible: Bool
    let collapsed: Bool
    let count: Int?
    let countIsUrgent: Bool
    let addHelp: String
    let onToggle: () -> Void
    let onAdd: (() -> Void)?
    /// When set, the title goes somewhere and only the caret folds.
    let onTitle: (() -> Void)?

    /// The smallest target the caret and "+" may have.
    private let hitTarget: CGFloat = 24

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if collapsible {
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.scaled(9), weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(palette.sidebarMutedForeground)
                        .frame(width: hitTarget, height: hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // A 24pt target that keeps the caret where the 12pt one sat.
                .padding(.horizontal, -Theme.Space.tight)
                .help(collapsed ? "Show \(title)" : "Fold \(title)")
                .accessibilityLabel(collapsed ? "Show \(title)" : "Fold \(title)")
                .accessibilityValue(collapsed ? "Folded" : "Open")
            }

            Button(action: { (onTitle ?? onToggle)() }) {
                HStack(spacing: Theme.Space.tight) {
                    Text(title.uppercased())
                        .font(Theme.Typography.caption.weight(.medium))
                        .tracking(0.6)
                        .foregroundStyle(palette.sidebarMutedForeground)
                        .lineLimit(1)
                    if let count {
                        SidebarCount(value: count, urgent: countIsUrgent)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!collapsible && onTitle == nil)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(11), weight: .medium))
                        .frame(width: hitTarget, height: hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help(addHelp)
                .accessibilityLabel(addHelp.isEmpty ? "Add" : addHelp)
            }
        }
        .padding(.leading, collapsible ? Theme.Space.xs : Theme.Space.snug)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: Theme.Size.controlSm)
    }
}

/// A borderless icon button that shows a soft square under the pointer, and brings its icon up
/// from muted to ink while it does.
///
/// The drawing lives in `SidebarIconButtonBody`, a view, so it can read the palette and hold its
/// hover state; a style's own `@State` and environment are not reliably kept.
struct SidebarIconButtonStyle: ButtonStyle {
    var radius: CGFloat

    init(radius: CGFloat = Theme.Radius.md) {
        self.radius = radius
    }

    func makeBody(configuration: Configuration) -> some View {
        SidebarIconButtonBody(configuration: configuration, radius: radius)
    }
}

struct SidebarIconButtonBody: View {
    @Environment(\.palette) private var palette
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @State private var hovering = false

    init(configuration: ButtonStyleConfiguration, radius: CGFloat) {
        self.configuration = configuration
        self.radius = radius
    }

    var body: some View {
        let lit = hovering || configuration.isPressed
        configuration.label
            .foregroundStyle(lit ? palette.foreground : palette.sidebarMutedForeground)
            .background(lit ? palette.sidebarAccent : Color.clear, in: .rect(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

/// One bot in the list: face, name, role tag.
///
/// One line, as the dashboard sidebar draws it. What it last said is still there, as the row's
/// tooltip, but the list itself reads as a column of faces: the state lives on the
/// face (a dot for working or needs you), not in a second line of text. VoiceOver gets the same
/// state in words, since the dot is colour only.
struct BotRow: View {
    @Environment(\.palette) private var palette

    let bot: Bot
    let preview: String?
    let mood: BotMood
    let selected: Bool
    var unread = false
    let action: () -> Void

    @State private var hovering = false

    init(bot: Bot, preview: String?, mood: BotMood, selected: Bool, unread: Bool = false,
         action: @escaping () -> Void) {
        self.bot = bot
        self.preview = preview
        self.mood = mood
        self.selected = selected
        self.unread = unread
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.compact) {
                // Still when idle or asleep and not selected: a sidebar of faces all breathing at 30fps is
                // noise and battery. The face is 22pt, so the frame is too (no overhang).
                BotFace(bot: bot, mood: mood, size: Theme.scaled(22),
                        still: (mood == .idle || mood == .sleeping) && !selected)
                    .overlay(alignment: .bottomTrailing) { statusDot }
                    .frame(width: Theme.scaled(22), height: Theme.scaled(22))

                Text(bot.name)
                    .font(Theme.Typography.body)
                    .fontWeight(unread || selected ? .medium : .regular)
                    .foregroundStyle(SidebarRowInk.text(selected: selected, hovering: hovering,
                                                        needs: mood == .waitingForYou || unread,
                                                        palette: palette))
                    .lineLimit(1)
                    .layoutPriority(1)

                // Lives on another Mac: that Mac's kind, quiet, beside the name.
                if let remote = bot.remote {
                    Image(systemName: remote.symbol)
                        .font(.system(size: Theme.scaled(10)))
                        .foregroundStyle(palette.sidebarMutedForeground)
                        .opacity(remote.online ? 1 : 0.5)
                        .accessibilityLabel("On \(remote.macName)")
                }

                Spacer(minLength: 0)

                // Blue rather than the accent: "there is something new" is a different claim
                // from "this is waiting on a decision from you", and the two must not look alike.
                if unread && mood != .waitingForYou {
                    Circle()
                        .fill(palette.info)
                        .frame(width: 6, height: 6)
                }
                if let role = bot.role, !role.isEmpty { RoleTag(text: role) }
            }
            .padding(.horizontal, Theme.Space.step)
            .frame(height: Theme.Size.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarRowInk.fill(selected: selected, hovering: hovering, palette: palette),
                        in: .rect(cornerRadius: Theme.Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        // Name, then role, then state: not the face's mood first, as the combined children read.
        .accessibilityLabel(accessibleName)
        .accessibilityValue(accessibleState)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibleName: String {
        guard let role = bot.role, !role.isEmpty else { return bot.name }
        return "\(bot.name), \(role)"
    }

    /// What the dot and the weight say, in words. Empty for an idle bot with nothing new.
    private var accessibleState: String {
        var parts: [String] = []
        switch mood {
        case .waitingForYou: parts.append("Needs you")
        case .working: parts.append("Working")
        case .failed: parts.append("Last run failed")
        case .done: parts.append("Done")
        case .sleeping: parts.append("Asleep")
        case .idle: break
        }
        if unread { parts.append("Unread") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        if let remote = bot.remote {
            return remote.online ? "Runs on \(remote.macName)" : "\(remote.macName) is offline"
        }
        return localHelpText
    }

    private var localHelpText: String {
        switch mood {
        case .waitingForYou: "\(bot.name) needs you"
        case .working: preview.map { "Working. \($0)" } ?? "\(bot.name) is working"
        case .failed: preview.map { "Last run failed. \($0)" } ?? "Last run failed"
        case .done: preview.map { "Done. \($0)" } ?? "\(bot.name) is done"
        case .sleeping: "\(bot.name) is asleep"
        case .idle: preview ?? bot.name
        }
    }

    /// Only drawn when there is something to say. A permanent grey dot on every row is furniture.
    @ViewBuilder
    private var statusDot: some View {
        if mood == .working || mood == .waitingForYou || mood == .failed {
            Circle()
                .fill(dotColour)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(palette.sidebar, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
    }

    private var dotColour: Color {
        switch mood {
        case .waitingForYou: palette.primary
        case .failed: palette.destructive
        default: palette.success
        }
    }
}

/// Renames a folder across every bot filed under it.
///
/// The folder *is* the string on each bot, so renaming is a bulk edit rather than a record
/// update. Done here rather than inline in the context menu because a text field inside a menu
/// cannot take focus on macOS.
///
/// The count is every bot filed here, pinned and hidden ones too, since the rename moves them
/// all. A name another section already has merges the two, so the sheet says so and the button
/// says Merge rather than letting it happen silently.
struct RenameFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var name = ""

    init(folder: String) {
        self.folder = folder
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var memberCount: Int { model.bots.filter { $0.folder == folder }.count }

    /// The other section the new name already belongs to, if any.
    private var mergeTarget: String? {
        guard !trimmed.isEmpty, trimmed != folder else { return nil }
        return model.sectionExists(trimmed) ? trimmed : nil
    }

    private var hint: String {
        let moving = memberCount == 1 ? "1 bot moves" : "\(memberCount) bots move"
        if let target = mergeTarget {
            if memberCount == 0 {
                return "There's already a section called \(target). The two become one."
            }
            return "There's already a section called \(target). \(moving) into it and the two become one."
        }
        return memberCount == 0 ? "No bots in it yet." : "\(moving) with it."
    }

    var body: some View {
        SheetFrame(title: "Rename section", icon: "rectangle.stack", width: 380,
                   tone: mergeTarget == nil ? .primary : .warning,
                   primaryVerb: mergeTarget == nil ? "rename" : "merge", hints: false) {
            Field(label: "Name", hint: hint) {
                TextField("", text: $name, prompt: Text(folder))
                    .bupsyField()
                    .onSubmit(commit)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(mergeTarget == nil ? "Rename" : "Merge sections", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        }
        .onAppear { name = folder }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        model.renameFolder(folder, to: trimmed)
        SidebarFolds.rename(folder, to: trimmed)
        dismiss()
    }
}

/// Files one bot into a section that does not exist yet.
struct NewFolderSheet: View {
    let bot: Bot

    init(bot: Bot) { self.bot = bot }

    /// The same sheet the Team page uses, with this bot already picked.
    var body: some View {
        TeamNewSectionSheet(preselected: bot.id)
    }
}

/// A bot's role, as a small quiet tag beside its name: the board's `.bp-nav-tag`. A role, not a
/// status, so it stays its own small tag rather than a `Badge`.
struct RoleTag: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.sidebarMutedForeground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.tight)
            .padding(.vertical, Theme.Space.hairline)
            .background(palette.sidebarBadge, in: .rect(cornerRadius: Theme.Radius.sm))
            .fixedSize()
    }
}

/// A row in a small popover menu: highlights under the pointer, like a real menu item. Drawn by
/// `MenuRowBody`, a view, so the palette and the hover state are read reliably.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }
}

struct MenuRowBody: View {
    @Environment(\.palette) private var palette
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    init(configuration: ButtonStyleConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? palette.foreground.opacity(0.08) : Color.clear,
                        in: .rect(cornerRadius: Theme.Radius.sm))
            .onHover { hovering = $0 }
    }
}

/// Which sidebar sections are folded, saved across launches.
///
/// One JSON-encoded array of section keys under `bupsy.foldedSections`, in the app's own
/// defaults (`AppHome.defaults`, so a throwaway `BUPSY_HOME` run keeps its own). The sidebar
/// reads and writes it with `@AppStorage`; the New section sheet adds to it when "Fold it in the
/// sidebar by default" is on. Pure helpers, no state of their own.
enum SidebarFolds {
    static let key = "bupsy.foldedSections"

    static func decode(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    static func encode(_ keys: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(keys.sorted()),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Folds one section, from outside the sidebar.
    static func fold(_ section: String) {
        let defaults = AppHome.defaults
        var keys = decode(defaults.string(forKey: key) ?? "[]")
        keys.insert(section)
        defaults.set(encode(keys), forKey: key)
    }

    /// Unfolds one section, from outside the sidebar.
    static func unfold(_ section: String) {
        let defaults = AppHome.defaults
        var keys = decode(defaults.string(forKey: key) ?? "[]")
        guard keys.remove(section) != nil else { return }
        defaults.set(encode(keys), forKey: key)
    }

    /// Carries a fold over when a section is renamed, so renaming does not unfold it.
    static func rename(_ old: String, to new: String) {
        guard !new.isEmpty, new != old else { return }
        let defaults = AppHome.defaults
        var keys = decode(defaults.string(forKey: key) ?? "[]")
        guard keys.remove(old) != nil else { return }
        keys.insert(new)
        defaults.set(encode(keys), forKey: key)
    }
}

// MARK: - Asking before signing out

extension View {
    /// Asks before signing an engine out. Shared by the You menu and Settings, so both say the
    /// same thing: the CLI's sign-out is not Bupsy's, it reaches every other use of that command
    /// on this Mac too.
    func confirmsSignOut(_ engine: Binding<EngineID?>, onConfirm: @escaping () -> Void = {}) -> some View {
        modifier(SignOutConfirmation(engine: engine, onConfirm: onConfirm))
    }
}

private struct SignOutConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var engine: EngineID?
    let onConfirm: () -> Void

    init(engine: Binding<EngineID?>, onConfirm: @escaping () -> Void) {
        self._engine = engine
        self.onConfirm = onConfirm
    }

    func body(content: Content) -> some View {
        content.confirmsDeletion(
            of: $engine,
            title: { "Sign out of \($0.displayName)?" },
            button: "Sign out",
            message: {
                "This signs the \($0.rawValue) command out everywhere on this Mac, not just in Bupsy."
            },
            perform: { engine in
                onConfirm()
                // Fire and forget: a failure to open Terminal lands in `accountProblem`.
                model.openSignOut(for: engine)
            })
    }
}
