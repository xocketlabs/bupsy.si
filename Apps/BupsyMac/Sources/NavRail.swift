import BupsyKit
import SwiftUI

/// The nav rail: a conversation list first, and the machinery behind it second.
///
/// Rebuilt from a list of names into a list of *conversations*. A name alone makes every bot look
/// identical and gives no reason to click one rather than another; the line underneath — what it
/// last said — is what turns the sidebar into something you read rather than something you
/// navigate. The same reason every messaging app does it.
///
/// Bots are filed into folders the user names. Those come second: ungrouped bots sit at the top,
/// because filing should be optional and a brand-new bot must not land somewhere surprising.
struct NavRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    @Binding var destination: Destination
    /// Owned by the app rather than the rail: the palette opens over the conversation, which the
    /// rail does not contain.
    var onStartChat: () -> Void = {}
    @State private var isAddingBot = false
    @State private var isSearching = false
    @State private var query = ""
    @State private var renamingFolder: FolderName?
    @State private var filingBot: Bot?
    @State private var renamingBot: Bot?
    @State private var renamingGroup: ChatGroup?
    @FocusState private var searchFocused: Bool

    enum Destination: Hashable {
        case bot(BotID)
        case machines
        case connectors
        case attention
        case usage
        case permissions
        case group(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            header
            if isSearching { searchField }
            attention

            conversations

            setup
            footer
        }
        .padding(.horizontal, Theme.Space.step)
        // Clears the title bar. At 22 the wordmark was clipped by it — the app's own name
        // covered by a second, worse copy of the app's own name.
        .padding(.top, 30)
        .padding(.bottom, Theme.Space.step)
        .frame(width: 292)
        .background(palette.sidebar)
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
        .sheet(item: $renamingFolder) { RenameFolderSheet(folder: $0.id) }
        .sheet(item: $filingBot) { NewFolderSheet(bot: $0) }
        .sheet(item: $renamingBot) { RenameBotSheet(bot: $0) }
        // On its own empty view: two sheets on one view and SwiftUI silently drops one.
        .background {
            Color.clear.sheet(item: Binding(get: { model.customModelBot },
                                            set: { model.customModelBot = $0 })) {
                CustomModelSheet(bot: $0)
            }
        }
        .sheet(item: $renamingGroup) { RenameGroupSheet(group: $0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.snug) {
            // The mark, not a gradient square: the same bubble character as the app icon, and it
            // blinks now and then, because the thing that looks after the bots is one of them.
            BupsyMark(size: Theme.scaled(26), alive: true)
            Text("bupsy")
                .font(.system(size: Theme.scaled(17), weight: .semibold))
                .foregroundStyle(palette.foreground)

            Spacer(minLength: Theme.Space.snug)

            circleButton("magnifyingglass", help: "Search bots") {
                isSearching.toggle()
                if isSearching { searchFocused = true } else { query = "" }
            }
            .keyboardShortcut("f", modifiers: .command)

            circleButton("plus", help: "Start a chat") { onStartChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.tight)
    }

    private func circleButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(11), weight: .medium))
                .foregroundStyle(palette.sidebarMutedForeground)
                .frame(width: 26, height: 26)
                .background(palette.sidebarAccent, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
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

    // MARK: - The conversation list

    private var conversations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                if searching {
                    results
                } else {
                    if !model.pinnedBots.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            sectionHeader("Pinned")
                            ForEach(model.pinnedBots) { row(for: $0) }
                        }
                    }

                    // Groups first after pinned: they are where several bots are already busy, so
                    // the likeliest place you want to look.
                    if !model.groups.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            sectionHeader("Groups")
                            ForEach(model.groups) { group in
                                GroupRow(group: group,
                                         selected: destination == .group(group.id),
                                         action: { destination = .group(group.id) })
                                .contextMenu {
                                    Button("Rename group…") { renamingGroup = group }
                                    // The conversation only. Its bots are untouched.
                                    Button("Delete group", role: .destructive) {
                                        if destination == .group(group.id),
                                           let first = model.bots.first {
                                            destination = .bot(first.id)
                                        }
                                        model.deleteGroup(group)
                                    }
                                }
                            }
                        }
                    }


                    ForEach(model.folders, id: \.self) { folder in
                        let members = model.bots(in: folder)
                        if !members.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                sectionHeader(folder)
                                    .contextMenu {
                                        Button("Rename folder…") {
                                            renamingFolder = FolderName(folder)
                                        }
                                        // Named for what it does. "Delete folder" would read as
                                        // deleting the bots inside it, which it never does.
                                        Button("Ungroup these bots") {
                                            model.dissolveFolder(folder)
                                        }
                                    }
                                ForEach(members) { row(for: $0) }
                            }
                        }
                    }

                    let loose = model.ungroupedBots
                    if !loose.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            // Last, and only headed once sections exist. With no sections these are
                            // simply the list; with sections they are the remainder, and putting
                            // the remainder above the person's own organisation inverted it.
                            if !model.folders.isEmpty { sectionHeader("Unassigned") }
                            ForEach(loose) { row(for: $0) }
                        }
                    }

                    if model.bots.isEmpty { empty }
                }
            }
            .padding(.bottom, Theme.Space.snug)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search results are a flat ranked list, not the same folders with gaps in them.
    ///
    /// Searching is a different task from browsing: you already know what you want and you want it
    /// at the top. Keeping the folder structure during a search buries the best match under
    /// headings and makes the first result's position depend on which folder it happens to be in.
    @ViewBuilder
    private var results: some View {
        let hits = ranked
        if hits.isEmpty {
            noMatches
        } else {
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader(hits.count == 1 ? "1 result" : "\(hits.count) results")
                ForEach(hits) { hit in
                    row(for: hit.bot, matchedOn: hit.matchedPreview ? hit.bot.id : nil)
                }
            }
        }
    }

    /// Name matches first, then matches on what the bot said.
    ///
    /// A name match is almost always what you meant; a preview match is a recall aid. Sorting by
    /// where the match landed — and, within that, how early in the string — puts the obvious
    /// answer first instead of leaving it to the order bots happen to be stored in.
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.badge)
            .foregroundStyle(palette.sidebarMuted)
            .tracking(0.7)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.bottom, Theme.Space.tight)
    }

    private func row(for bot: Bot, matchedOn previewOf: BotID? = nil) -> some View {
        BotRow(
            bot: bot,
            preview: model.thread(for: bot.id).preview,
            mood: mood(for: bot),
            selected: destination == .bot(bot.id),
            unread: model.isUnread(bot),
            // Says *why* a bot is in the results when the name does not contain what you typed.
            // Without it a preview match looks like a mistake.
            matchedOnMessage: previewOf == bot.id,
            action: { destination = .bot(bot.id) }
        )
        // The shortcut goes on the row *before* the context menu, never after.
        //
        // Applied after, it propagated into every button inside the menu: right-clicking the
        // third bot listed ⌘3 against every item, Delete bot included, and with the menu open ⌘3
        // could fire any of them. A shortcut meant to *go to* a bot must not be able to delete
        // one.
        .keyboardShortcut(shortcut(for: bot), modifiers: .command)
        .contextMenu {
            BotMenu(bot: bot,
                    onNewFolder: { filingBot = bot },
                    onRename: { renamingBot = bot })
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("No bots yet")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.sidebarMutedForeground)
            Text("⌘N to make your first one.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.sidebarMuted)
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.top, Theme.Space.snug)
    }

    private var noMatches: some View {
        Text("Nothing matches “\(query)”")
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.sidebarMuted)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.top, Theme.Space.snug)
    }

    // MARK: - Below the list

    /// Appears only when something is waiting.
    ///
    /// Previously this was a permanent tray with a count that was usually zero — furniture people
    /// stop seeing, which is the opposite of what a thing called "needs you" should be. Absent
    /// until it matters, it gets noticed the one time it does.
    @ViewBuilder
    private var attention: some View {
        let items = model.attentionItems
        if !items.isEmpty {
            Button { destination = .attention } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "hand.raised.fill").font(.system(size: Theme.scaled(11)))
                    Text(items.count == 1 ? "1 needs you" : "\(items.count) need you")
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: Theme.scaled(9)))
                }
                .foregroundStyle(palette.primary)
                .padding(.horizontal, Theme.Space.step)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background(palette.primary.opacity(0.13),
                            in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    /// Pinned below the scrolling list, so the machinery stays reachable however many bots there
    /// are — and stays visually separate from the people you talk to.
    private var setup: some View {
        HStack(spacing: Theme.Space.tight) {
            setupItem("server.rack", label: "Machines", count: model.machines.count,
                      selected: destination == .machines) { destination = .machines }
            setupItem("puzzlepiece.extension", label: "Apps", count: model.connectors.count,
                      selected: destination == .connectors) { destination = .connectors }
            setupItem("chart.bar", label: "Usage", count: 0,
                      selected: destination == .usage) { destination = .usage }
            Spacer(minLength: 0)
        }
    }

    private func setupItem(
        _ symbol: String, label: String, count: Int, selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: symbol).font(.system(size: Theme.scaled(11)))
                // One line, always. Squeezed into equal thirds, "Machines" and "Usage" wrapped
                // mid-word the moment the type grew and a third item arrived.
                Text(label)
                    .font(Theme.Typography.label)
                    .lineLimit(1)
                    .fixedSize()
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(palette.sidebarMuted)
                }
            }
            .foregroundStyle(selected ? palette.foreground : palette.sidebarMutedForeground)
            .padding(.horizontal, Theme.Space.snug)
            .frame(height: 32)
            .background(selected ? palette.sidebarAccent : .clear,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        Menu {
            Button("Permissions…") { destination = .permissions }
            Button("Usage") { destination = .usage }
        } label: { footerLabel }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footerLabel: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(palette.sidebarAccent)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: Theme.scaled(10)))
                        .foregroundStyle(palette.mutedForeground)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("You").font(Theme.Typography.label).foregroundStyle(palette.foreground)
                // The engines, because that is the only account this app has any notion of.
                Text(engineSummary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.sidebarMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.tight)
    }

    private var engineSummary: String {
        let ready = EngineID.allCases.filter { model.engineStatus[$0]?.isUsable == true }
        return ready.isEmpty ? "No engine signed in" : ready.map(\.displayName).joined(separator: " · ")
    }

    /// ⌘1 … ⌘9 for the first nine bots, in the order they appear.
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

/// One conversation in the list: face, name, and the last thing said.
///
/// Two lines rather than one. The preview is the entire reason this is a list worth looking at —
/// without it every row is just a name, and you have to open a bot to find out whether it did
/// anything. The status is shown on the face itself rather than as a word on the right, so a
/// glance down the list reads as a column of faces, not a column of labels.
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                BotFace(bot: bot, mood: mood, size: Theme.scaled(34))
                    .overlay(alignment: .bottomTrailing) { statusDot }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Theme.Space.tight) {
                        Text(bot.name)
                            .font(Theme.Typography.body)
                            .fontWeight(unread ? .semibold : .medium)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let role = bot.role { RoleTag(text: role) }
                        Spacer(minLength: 0)
                        if bot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Theme.scaled(8)))
                                .foregroundStyle(palette.sidebarMuted)
                        }
                        // "Needs you" is already on the face and in the subtitle, in the accent.
                        // A third signal here drew two pink dots for one state, which reads as two
                        // things wrong rather than one. The trailing dot is for unread only.
                        if unread && mood != .waitingForYou {
                            // Blue rather than the accent: "there is something new" is a
                            // different claim from "this is waiting on a decision from you", and
                            // the two must not look alike.
                            Circle()
                                .fill(palette.info)
                                .frame(width: 6, height: 6)
                        }
                    }
                    HStack(spacing: 4) {
                        if matchedOnMessage {
                            Image(systemName: "text.quote")
                                .font(.system(size: Theme.scaled(8)))
                                .foregroundStyle(palette.sidebarMuted)
                        }
                        Text(subtitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(unread && mood == .idle
                                             ? palette.sidebarMutedForeground : subtitleColour)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: Theme.Radius.base))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preview ?? bot.name)
    }

    /// What the row says when there is nothing to quote yet. Never blank: an empty second line
    /// makes the row look broken rather than new.
    private var subtitle: String {
        switch mood {
        case .waitingForYou: "Needs you"
        case .working: preview ?? "Working…"
        case .failed: preview ?? "Last run failed"
        case .idle: preview ?? "No messages yet"
        }
    }

    /// Only drawn when there is something to say. A permanent grey dot on every row is furniture.
    @ViewBuilder
    private var statusDot: some View {
        if mood != .idle {
            Circle()
                .fill(dotColour)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(palette.sidebar, lineWidth: 2))
                .offset(x: 1, y: 1)
        }
    }

    private var subtitleColour: Color {
        switch mood {
        case .waitingForYou: palette.primary
        case .failed: palette.destructive
        default: palette.sidebarMuted
        }
    }

    private var dotColour: Color {
        switch mood {
        case .waitingForYou: palette.primary
        case .failed: palette.destructive
        default: .green
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
        SheetFrame(title: "Rename folder", icon: "folder", width: 380) {
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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "New folder", icon: "folder.badge.plus", width: 380) {
            Field(label: "Name", hint: "\(bot.name) moves into it.") {
                TextField("", text: $name, prompt: Text("Outreach"))
                    .textFieldStyle(BupsyFieldStyle())
                    .onSubmit(commit)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create", action: commit)
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commit() {
        model.setFolder(bot, name)
        dismiss()
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
    @State private var shape = BotShape.circle
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
                  hint: "Takes effect on the next thing you say — it does not rewrite the thread.") {
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
