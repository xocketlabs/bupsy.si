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
    @Environment(\.openSettings) private var openSettings

    @Binding var destination: Destination
    /// Owned by the app rather than the rail: the palette opens over the conversation, which the
    /// rail does not contain.
    var onStartChat: () -> Void = {}
    var onSearch: () -> Void = {}
    @State private var isAddingBot = false
    @State private var isAddingGroup = false
    @State private var isSearching = false
    @State private var showsYouMenu = false
    @State private var showsShortcuts = false
    @State private var query = ""
    @State private var renamingFolder: FolderName?
    @State private var filingBot: Bot?
    @State private var renamingBot: Bot?
    @State private var renamingGroup: ChatGroup?
    /// Sections folded shut, kept across launches. A JSON array of section keys, shared with the
    /// New section sheet's "Fold it in the sidebar by default". See `SidebarFolds`.
    @AppStorage(SidebarFolds.key, store: AppHome.defaults) private var foldedJSON = "[]"
    /// The section a bot made from its "+" should land in, and which bots existed before, so the
    /// new one can be told apart when the sheet closes.
    @State private var addingToSection: String?
    @State private var isAddingToSection = false
    @State private var botsBeforeAdding: Set<BotID> = []
    @FocusState private var searchFocused: Bool

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
    }

    /// Keys for the fixed collapsible sections, kept apart from section names people type.
    private static let groupsKey = "\u{1}groups"
    private static let unassignedKey = "\u{1}unassigned"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Theme.Space.gutter)
            if isSearching {
                searchField.padding(.bottom, Theme.Space.snug)
            }
            places
                .padding(.bottom, Theme.Space.snug)

            conversations

            setup
            footer
                .padding(.top, Theme.Space.snug)
        }
        .padding(.horizontal, Theme.Space.snug)
        // Clears the title bar and its window buttons.
        .padding(.top, 30)
        .padding(.bottom, Theme.Space.snug)
        .frame(width: 276)
        .background(palette.sidebar)
        .sheet(isPresented: $isAddingBot) { BotCreatorSheet() }
        .sheet(item: $renamingFolder) { RenameFolderSheet(folder: $0.id) }
        .sheet(item: $filingBot) { NewFolderSheet(bot: $0) }
        .sheet(item: $renamingBot) { BotCreatorSheet(editing: $0) }
        // On its own empty view: two sheets on one view and SwiftUI silently drops one.
        .background {
            Color.clear.sheet(item: Binding(get: { model.customModelBot },
                                            set: { model.customModelBot = $0 })) {
                CustomModelSheet(bot: $0)
            }
        }
        .background {
            Color.clear.sheet(isPresented: $isAddingToSection, onDismiss: { fileNewBots() }) {
                BotCreatorSheet()
            }
        }
        .background {
            Color.clear.sheet(isPresented: $isAddingGroup) {
                NewGroupSheet(onCreated: { group in destination = .group(group.id) })
            }
        }
        .sheet(item: $renamingGroup) { RenameGroupSheet(group: $0) }
        .background {
            Color.clear.sheet(isPresented: $showsShortcuts) { KeyboardShortcutsSheet() }
        }
        // Help > Keyboard shortcuts (Cmd /) lives on the app; the sheet hangs here.
        .onReceive(NotificationCenter.default.publisher(for: .bupsyShowKeyboardShortcuts)) { _ in
            showsYouMenu = false
            showsShortcuts = true
        }
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

            headerButton("magnifyingglass", help: "Search (Cmd F)") { onSearch() }
                .keyboardShortcut("f", modifiers: .command)

            headerButton("plus", help: "Start a chat (Cmd N)") { onStartChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.leading, Theme.Space.snug)
        .padding(.trailing, 2)
    }

    private func headerButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(13), weight: .medium))
                .foregroundStyle(palette.sidebarMutedForeground)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(SidebarIconButtonStyle())
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.scaled(10)))
                .foregroundStyle(palette.sidebarMuted)
            TextField("", text: $query, prompt: Text("Search bots"))
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .focused($searchFocused)
                .onSubmit { selectFirstMatch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.scaled(11)))
                        .foregroundStyle(palette.sidebarMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.snug)
        .frame(height: 30)
        .background(palette.sidebarAccent, in: .rect(cornerRadius: Theme.Radius.control))
        // Escape closes the field rather than only clearing it, so the shortcut that opened it
        // also puts things back exactly as they were.
        .onExitCommand {
            isSearching = false
            query = ""
        }
    }

    /// Enter in the search field opens the one you were looking for, rather than making you
    /// reach for the mouse to finish a keyboard gesture.
    private func selectFirstMatch() {
        if let first = ranked.first {
            destination = .bot(first.bot.id)
            isSearching = false
            query = ""
        }
    }

    // MARK: - Fixed places

    /// "Waiting on you" and "Team": always in the same spot, so they can be found without looking.
    private var places: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                if searching {
                    results
                } else {
                    if !model.pinnedBots.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            sectionHeader("Pinned")
                            ForEach(model.pinnedBots) { row(for: $0) }
                        }
                    }

                    ForEach(model.folders, id: \.self) { folder in
                        let members = model.bots(in: folder)
                        if !members.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                sectionHeader(folder, key: folder, members: members,
                                              addHelp: "New bot in \(folder)",
                                              onAdd: { startAdding(to: folder) })
                                    .contextMenu {
                                        Button("Rename section…") {
                                            renamingFolder = FolderName(folder)
                                        }
                                        // Named for what it does. "Delete folder" would read as
                                        // deleting the bots inside it, which it never does.
                                        Button("Move these bots to Unassigned") {
                                            model.dissolveFolder(folder)
                                        }
                                    }
                                if !collapsed.contains(folder) {
                                    ForEach(members) { row(for: $0) }
                                }
                            }
                        }
                    }

                    groupsSection

                    let loose = model.ungroupedBots
                    if !loose.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            // Only headed once anything above has a heading: with no sections
                            // these are simply the list.
                            if !model.folders.isEmpty || !model.groups.isEmpty
                                || !model.pinnedBots.isEmpty {
                                sectionHeader(model.folders.isEmpty ? "Bots" : "Unassigned",
                                              key: Self.unassignedKey, members: loose,
                                              addHelp: "New bot",
                                              onAdd: { startAdding(to: nil) })
                            }
                            if !collapsed.contains(Self.unassignedKey) {
                                ForEach(loose) { row(for: $0) }
                            }
                        }
                    }

                    if model.bots.isEmpty { empty }
                }
            }
            .padding(.top, Theme.Space.snug)
            .padding(.bottom, Theme.Space.snug)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    /// Group chats: always present once there are bots to put in one, so its "+" is findable.
    @ViewBuilder
    private var groupsSection: some View {
        if !model.groups.isEmpty || model.bots.count >= 2 {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Groups", key: Self.groupsKey, members: [],
                              count: model.groups.count,
                              addHelp: "New group chat",
                              onAdd: { isAddingGroup = true },
                              onTitle: { destination = .groups })
                if !collapsed.contains(Self.groupsKey) {
                    ForEach(model.groups) { group in
                        GroupRow(group: group,
                                 selected: destination == .group(group.id),
                                 action: { destination = .group(group.id) })
                        .contextMenu {
                            Button("Open chat") { destination = .group(group.id) }
                            Button("Rename group…") { renamingGroup = group }
                            Divider()
                            // The conversation only. Its bots are untouched.
                            Button("Delete group", role: .destructive) {
                                if destination == .group(group.id) {
                                    destination = .groups
                                }
                                model.deleteGroup(group)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search results are a flat ranked list, not the same folders with gaps in them.
    @ViewBuilder
    private var results: some View {
        let hits = ranked
        if hits.isEmpty {
            noMatches
        } else {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader(hits.count == 1 ? "1 result" : "\(hits.count) results")
                ForEach(hits) { hit in
                    row(for: hit.bot, matchedOn: hit.matchedPreview ? hit.bot.id : nil)
                }
            }
        }
    }

    /// Name matches first, then matches on what the bot said, each ordered by how early the
    /// match lands in the string.
    private var ranked: [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        return model.bots.compactMap { bot -> SearchHit? in
            let name = bot.name.lowercased()
            if let position = name.range(of: needle)?.lowerBound {
                return SearchHit(bot: bot, rank: 0,
                                 offset: name.distance(from: name.startIndex, to: position),
                                 matchedPreview: false)
            }
            let preview = (model.thread(for: bot.id).preview ?? "").lowercased()
            if let position = preview.range(of: needle)?.lowerBound {
                return SearchHit(bot: bot, rank: 1,
                                 offset: preview.distance(from: preview.startIndex, to: position),
                                 matchedPreview: true)
            }
            return nil
        }
        .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
    }

    /// A small uppercase label. With a key it folds; with `onAdd` it carries a "+" on the right.
    private func sectionHeader(
        _ text: String, key: String? = nil, members: [Bot] = [], count: Int? = nil,
        addHelp: String = "", onAdd: (() -> Void)? = nil, onTitle: (() -> Void)? = nil
    ) -> some View {
        let isCollapsed = key.map { collapsed.contains($0) } ?? false
        let shown = count ?? members.count
        let urgent = members.contains { model.isWaitingForApproval($0.id) }
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
                withAnimation(.easeOut(duration: 0.15)) {
                    var folded = collapsed
                    if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
                    collapsed = folded
                }
            },
            onAdd: onAdd,
            onTitle: onTitle
        )
    }

    private func row(for bot: Bot, matchedOn previewOf: BotID? = nil) -> some View {
        BotRow(
            bot: bot,
            preview: model.thread(for: bot.id).preview,
            mood: mood(for: bot),
            selected: destination == .bot(bot.id),
            unread: model.isUnread(bot),
            // Says *why* a bot is in the results when the name does not contain what you typed.
            matchedOnMessage: previewOf == bot.id,
            action: { destination = .bot(bot.id) }
        )
        // The shortcut goes on the row *before* the context menu, never after: applied after, it
        // propagated into every button inside the menu, Delete bot included.
        .keyboardShortcut(shortcut(for: bot), modifiers: .command)
        .contextMenu {
            Button("Open chat") { destination = .bot(bot.id) }
            Divider()
            BotMenu(bot: bot,
                    onNewFolder: { filingBot = bot },
                    onRename: { renamingBot = bot })
        }
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

    private var empty: some View {
        EmptyState(title: "No bots yet", message: "Press Cmd N to make your first one.", faceSize: 52)
    }

    private var noMatches: some View {
        Text("Nothing matches “\(query)”")
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.sidebarMuted)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.top, Theme.Space.snug)
    }

    // MARK: - Below the list

    /// The machinery, pinned under the list and set apart from the bots by a rule.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
                .padding(.bottom, Theme.Space.step)
            sectionHeader("Setup")
            SidebarNavRow(icon: "display", label: "Machines",
                          selected: destination == .machines) { destination = .machines }
            SidebarNavRow(icon: "square.grid.2x2.fill", label: "Apps",
                          selected: destination == .connectors) { destination = .connectors }
            SidebarNavRow(icon: "chart.bar.fill", label: "Usage",
                          selected: destination == .usage) { destination = .usage }
        }
    }

    // A button with a popover rather than a `Menu`: a macOS menu label keeps only one image and
    // one line of text, which flattened this row to a bare "You" and dropped the engine line.
    private var footer: some View {
        Button { showsYouMenu.toggle() } label: {
            footerLabel
                .contentShape(.rect)
                .padding(.vertical, 6)
                .background(showsYouMenu ? palette.sidebarAccent : .clear,
                            in: .rect(cornerRadius: Theme.Radius.base))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsYouMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                youMenuItem("gearshape", "Settings", shortcut: "Cmd ,") { openSettings() }
                youMenuItem("hand.raised", "Permissions") { destination = .permissions }
                youMenuItem("display", "Machines") { destination = .machines }
                youMenuItem("square.grid.2x2", "Apps") { destination = .connectors }
                youMenuItem("chart.bar", "Usage") { destination = .usage }
                appearanceItem
                youMenuItem("keyboard", "Keyboard shortcuts", shortcut: "Cmd /") {
                    // After the popover has gone: a sheet asked for while it is still closing
                    // is dropped.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        showsShortcuts = true
                    }
                }
                accountItems
            }
            .padding(6)
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
            Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, 4)
            ForEach(engines, id: \.self) { engine in
                if model.isSignedIn(engine) {
                    youMenuItem("rectangle.portrait.and.arrow.right", "Sign out of \(engine.displayName)",
                                help: "Opens Terminal and runs \(engine.displayName)'s own sign-out command") {
                        model.openSignOut(for: engine)
                    }
                } else {
                    youMenuItem("person.crop.circle.badge.plus", "Sign in to \(engine.displayName)…",
                                help: "Opens Terminal and runs \(engine.displayName)'s own sign-in") {
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

    private var footerLabel: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(palette.sidebarAccent)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: Theme.scaled(12)))
                        .foregroundStyle(palette.mutedForeground)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("You")
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.foreground)
                // The engines, because that is the only account this app has any notion of.
                Text(engineSummary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.sidebarMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: Theme.scaled(10), weight: .semibold))
                .foregroundStyle(palette.sidebarMutedForeground)
        }
        .padding(.horizontal, Theme.Space.snug)
    }

    private var engineSummary: String {
        let ready = EngineID.allCases.filter { model.engineStatus[$0]?.isUsable == true }
        if !ready.isEmpty { return ready.map(\.displayName).joined(separator: ", ") }
        // Until every supported engine has answered, "none signed in" is a guess, and the wrong
        // first thing for someone who just opened the app to read.
        let answered = EngineID.supported.allSatisfy { model.engineStatus[$0] != nil }
        return answered ? "No engine signed in" : "Checking sign-in…"
    }

    /// Cmd 1 to Cmd 9 for the first nine bots, in the order they appear.
    private func shortcut(for bot: Bot) -> KeyEquivalent {
        guard let index = model.bots.firstIndex(where: { $0.id == bot.id }), index < 9 else {
            // No shortcut rather than a wrong one: KeyEquivalent has no "none", so a bot past
            // the ninth gets a key nobody presses.
            return KeyEquivalent("\u{0}")
        }
        return KeyEquivalent(Character("\(index + 1)"))
    }

    private func mood(for bot: Bot) -> BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }
}

// MARK: - Sidebar pieces

/// A fixed place in the sidebar: an icon, a label, and a count when there is one.
struct SidebarNavRow: View {
    @Environment(\.palette) private var palette
    let icon: String
    let label: String
    let selected: Bool
    var count: Int = 0
    /// Pink when the count is things waiting on a person; grey otherwise.
    var countIsUrgent = false
    let action: () -> Void
    @State private var hovering = false

    init(icon: String, label: String, selected: Bool, count: Int = 0, countIsUrgent: Bool = false,
         action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.selected = selected
        self.count = count
        self.countIsUrgent = countIsUrgent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.step) {
                Image(systemName: icon)
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(selected ? palette.foreground : palette.sidebarMutedForeground)
                    .frame(width: 20)
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    SidebarCount(value: count, urgent: countIsUrgent)
                }
            }
            .padding(.horizontal, Theme.Space.step)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.sidebarAccent
                                 : (hovering ? palette.sidebarAccent.opacity(0.55) : .clear),
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
            .font(.system(size: Theme.scaled(10), weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(urgent ? palette.onPrimary : palette.sidebarMutedForeground)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(urgent ? palette.primary : palette.foreground.opacity(0.07),
                        in: .rect(cornerRadius: 5))
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

    var body: some View {
        HStack(spacing: 6) {
            if collapsible {
                Button(action: onToggle) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 6))
                        .rotationEffect(.degrees(collapsed ? 90 : 180))
                        .foregroundStyle(palette.sidebarMutedForeground)
                        .frame(width: 12, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show \(title)" : "Fold \(title)")
            }

            Button(action: { (onTitle ?? onToggle)() }) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(Theme.Typography.badge)
                        .tracking(0.7)
                        .foregroundStyle(palette.sidebarMuted)
                        .lineLimit(1)
                    if let count {
                        SidebarCount(value: count, urgent: countIsUrgent)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!collapsible && onTitle == nil)

            Spacer(minLength: 0)

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(11), weight: .medium))
                        .foregroundStyle(palette.sidebarMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help(addHelp)
            }
        }
        .padding(.leading, collapsible ? 4 : Theme.Space.snug)
        .padding(.trailing, 4)
        .frame(height: 26)
    }
}

/// A borderless icon button that shows a soft square under the pointer.
struct SidebarIconButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? palette.sidebarAccent : .clear,
                        in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

/// One bot in the list: face, name, role tag.
///
/// One line, as the dashboard sidebar draws it. What it last said is still there, as the row's
/// tooltip and in search, but the list itself reads as a column of faces: the state lives on the
/// face (a dot for working or needs you), not in a second line of text.
struct BotRow: View {
    @Environment(\.palette) private var palette

    let bot: Bot
    let preview: String?
    let mood: BotMood
    let selected: Bool
    var unread = false
    var matchedOnMessage = false
    let action: () -> Void

    @State private var hovering = false

    init(bot: Bot, preview: String?, mood: BotMood, selected: Bool, unread: Bool = false,
         matchedOnMessage: Bool = false, action: @escaping () -> Void) {
        self.bot = bot
        self.preview = preview
        self.mood = mood
        self.selected = selected
        self.unread = unread
        self.matchedOnMessage = matchedOnMessage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: bot, mood: mood, size: Theme.scaled(22))
                    .overlay(alignment: .bottomTrailing) { statusDot }
                    .frame(width: 20)

                Text(bot.name)
                    .font(Theme.Typography.body)
                    .fontWeight(unread || selected ? .semibold : .regular)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)

                if matchedOnMessage {
                    Image(systemName: "text.quote")
                        .font(.system(size: Theme.scaled(9)))
                        .foregroundStyle(palette.sidebarMuted)
                        .help("Matched on what \(bot.name) said")
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
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var helpText: String {
        switch mood {
        case .waitingForYou: "\(bot.name) needs you"
        case .working: preview.map { "Working. \($0)" } ?? "\(bot.name) is working"
        case .failed: preview ?? "Last run failed"
        case .idle, .done, .sleeping: preview ?? bot.name
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

    private var background: Color {
        if selected { return palette.sidebarAccent }
        return hovering ? palette.sidebarAccent.opacity(0.55) : .clear
    }
}


/// Renames a folder across every bot filed under it.
///
/// The folder *is* the string on each bot, so renaming is a bulk edit rather than a record
/// update. Done here rather than inline in the context menu because a text field inside a menu
/// cannot take focus on macOS.
struct RenameFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "Rename section", icon: "rectangle.stack", width: 380, primaryVerb: "rename", hints: false) {
            Field(label: "Name",
                  hint: "\(model.bots(in: folder).count) bots move with it.") {
                TextField("", text: $name, prompt: Text(folder))
                    .textFieldStyle(BupsyFieldStyle())
                    .onSubmit(commit)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Rename", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { name = folder }
    }

    private func commit() {
        model.renameFolder(folder, to: name)
        SidebarFolds.rename(folder, to: name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

/// `sheet(item:)` needs an Identifiable. A wrapper rather than a retroactive conformance on
/// String: that conformance would apply everywhere in the app and can quietly change which
/// SwiftUI overload gets picked somewhere unrelated.
/// One search result, with enough about *how* it matched to rank it and to explain itself.
struct SearchHit: Identifiable {
    let bot: Bot
    /// 0 for a name match, 1 for a match on what the bot said.
    let rank: Int
    /// Where in the string the match started. Earlier reads as more relevant.
    let offset: Int
    let matchedPreview: Bool

    var id: BotID { bot.id }
}

struct FolderName: Identifiable, Hashable {
    let id: String
    init(_ name: String) { id = name }
}

/// Files one bot into a folder that does not exist yet.
///
/// Creating the folder and putting something in it are the same action on purpose: a folder here
/// exists exactly as long as a bot is in it, so there is no way to make an empty one and then
/// wonder where it went.
struct NewFolderSheet: View {
    let bot: Bot

    init(bot: Bot) { self.bot = bot }

    /// The same sheet the Team page uses, with this bot already picked.
    var body: some View {
        TeamNewSectionSheet(preselected: bot.id)
    }
}

/// Renames a bot, and edits what it is for.
///
/// Both in one place because they are the same thought — "this bot is actually for something
/// else" — and splitting them across two menu items means doing half the edit and forgetting the
/// rest.
struct RenameBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var name = ""
    @State private var job = ""
    @State private var role = ""
    @State private var shape = BotShape.bup
    @State private var colour = 0
    /// Only a face someone actually changed is saved as a choice. Saving every bot's derived face
    /// as "chosen" on an unrelated rename would quietly pin faces nobody picked.
    @State private var faceChanged = false

    var body: some View {
        SheetFrame(title: "Edit bot", icon: "pencil", subtitle: "Its name, its job, and the face you'll know it by.",
                   width: 460) {
            HStack(spacing: Theme.Space.step) {
                // The face shown live as you pick, so the sheet is a preview rather than a form.
                BotFace(hue: bot.avatarHue, mood: .idle, size: 56, shape: shape, colour: colour)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $name, prompt: Text(bot.name))
                        .textFieldStyle(BupsyFieldStyle())
                        .onSubmit(commit)
                    if model.isNameTaken(name, except: bot.id) {
                        Text("Another bot is already called that.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            AvatarPicker(
                shape: $shape, colour: $colour,
                taken: Set(model.bots.filter { $0.id != bot.id }.map(\.effectiveShape)),
                onChange: { faceChanged = true })

            Field(label: "Role tag", hint: "A word or two shown beside its name, like PA or Finance.") {
                TextField("", text: $role, prompt: Text("Optional"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            Field(label: "What's its job?",
                  hint: "Takes effect on the next thing you say. It does not rewrite the thread.") {
                TextField("", text: $job,
                          prompt: Text("Research things and report back plainly."),
                          axis: .vertical)
                    .textFieldStyle(BupsyFieldStyle())
                    .lineLimit(3...5)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Save", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.isNameTaken(name, except: bot.id))
        }
        .onAppear {
            let current = model.bots.first { $0.id == bot.id } ?? bot
            name = current.name
            job = current.personaPrompt ?? ""
            role = current.role ?? ""
            shape = current.effectiveShape
            colour = current.avatarColour ?? BotFace.derivedColour(forHue: current.avatarHue)
        }
    }

    private func commit() {
        model.rename(bot, to: name)
        model.setJob(bot, job)
        model.setRole(bot, role)
        if faceChanged { model.setAvatar(bot, shape: shape, colour: colour) }
        dismiss()
    }
}

/// A bot's role, as a small quiet chip beside its name.
struct RoleTag: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Theme.scaled(10), weight: .medium))
            .foregroundStyle(palette.sidebarMuted)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(palette.foreground.opacity(0.07), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

/// A row in a small popover menu: highlights under the pointer, like a real menu item.
struct MenuRowStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? palette.foreground.opacity(0.08) : .clear,
                        in: .rect(cornerRadius: 6))
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
