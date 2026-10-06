import BupsyKit
import SwiftUI

// MARK: - Faces

/// Two faces overlapping, and "+N" for the rest: how a group reads at a glance in a small spot.
struct StackedFaces: View {
    @Environment(\.palette) private var palette
    let bots: [Bot]
    var size: CGFloat = Theme.scaled(34)

    var body: some View {
        let small = size * 0.66
        ZStack(alignment: .topLeading) {
            ForEach(Array(bots.prefix(2).enumerated()), id: \.offset) { index, bot in
                BotFace(bot: bot, mood: .idle, size: small)
                    .offset(x: CGFloat(index) * size * 0.34, y: CGFloat(index) * size * 0.3)
            }
            if bots.count > 2 {
                Text("+\(bots.count - 2)")
                    .font(.system(size: Theme.scaled(9), weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 3)
                    .background(palette.sidebarAccent, in: .capsule)
                    .offset(x: 0, y: size * 0.62)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// Faces in a row, each tucked a little behind the next, as the group cards and the group
/// topbar draw them.
struct GroupFaceRow: View {
    @Environment(\.palette) private var palette
    let bots: [Bot]
    var size: CGFloat = 36
    var limit = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(bots.prefix(limit).enumerated()), id: \.offset) { index, bot in
                BotFace(bot: bot, mood: .idle, size: size)
                    .zIndex(Double(limit - index))
            }
            if bots.count > limit {
                Text("+\(bots.count - limit)")
                    .font(.system(size: Theme.scaled(10), weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .background(palette.card, in: .circle)
                    .padding(.leading, size * 0.4)
            }
        }
    }
}

// MARK: - Sidebar row

/// One group chat in the sidebar: an icon and its name, on one line like a bot row.
struct GroupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let group: ChatGroup
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    init(group: ChatGroup, selected: Bool, action: @escaping () -> Void) {
        self.group = group
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let unread = model.isGroupUnread(group)
        let active = model.groupThread(for: group).speaking != nil
        let waiting = model.groupThread(for: group).isWaitingOnYou
        Button(action: action) {
            HStack(spacing: Theme.Space.step) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(selected ? palette.foreground : palette.sidebarMutedForeground)
                    .frame(width: 20)
                Text(group.name)
                    .font(Theme.Typography.body)
                    .fontWeight(unread || selected ? .semibold : .regular)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if active {
                    Circle().fill(palette.success).frame(width: 6, height: 6)
                } else if waiting {
                    // Paused at its turn limit: the one accent for "needs you".
                    Circle().fill(palette.primary).frame(width: 6, height: 6)
                        .help("Waiting on you")
                } else if unread {
                    Circle().fill(palette.info).frame(width: 6, height: 6)
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
        .help(model.groupThread(for: group).preview ?? group.name)
    }
}

// MARK: - All group chats

/// Every group chat as a card: who is in it, the latest line, and who leads.
struct GroupsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let onOpen: (String) -> Void
    @State private var isCreating = false
    @State private var renaming: ChatGroup?

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                HStack(alignment: .bottom, spacing: Theme.Space.gutter) {
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text("Group chats")
                            .font(Theme.Typography.title)
                            .foregroundStyle(palette.foreground)
                        Text("A few bots in one thread. Mention one with @ to ask it, or the lead answers.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.gutter)
                    Button { isCreating = true } label: {
                        Label("New group", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.bots.count < 2)
                }

                VStack(spacing: Theme.Space.step) {
                    ForEach(model.groups) { group in
                        GroupCard(group: group,
                                  onOpen: { onOpen(group.id) },
                                  onRename: { renaming = group })
                    }
                    invite
                }
            }
            .padding(.horizontal, Theme.Space.section + Theme.Space.tight)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.page)
            .frame(maxWidth: 896)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $isCreating) {
            NewGroupSheet(onCreated: { onOpen($0.id) })
        }
        .background {
            Color.clear.sheet(item: $renaming) { RenameGroupSheet(group: $0) }
        }
    }

    /// The napping bot and one way forward. Under the list rather than instead of it, so the
    /// reason to make another group is always in reach.
    private var invite: some View {
        EmptyState(
            title: model.groups.isEmpty ? "No group chats yet" : "Got a job that needs more than one bot?",
            message: model.bots.count < 2
                ? "Make a second bot first. A group needs at least two."
                : "Put them in a group. They answer in one thread, and anything risky still waits for you."
        ) {
            if model.bots.count >= 2 {
                Button { isCreating = true } label: {
                    Label("Start a group chat", systemImage: "person.2.fill")
                }
                .buttonStyle(QuietButton(compact: true))
            }
        }
        .padding(.vertical, Theme.Space.snug)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}

/// One group in the list.
struct GroupCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let group: ChatGroup
    let onOpen: () -> Void
    let onRename: () -> Void
    @State private var hovering = false

    init(group: ChatGroup, onOpen: @escaping () -> Void, onRename: @escaping () -> Void) {
        self.group = group
        self.onOpen = onOpen
        self.onRename = onRename
    }

    var body: some View {
        let members = model.members(of: group)
        let thread = model.groupThread(for: group)
        let lead = members.first { $0.id == group.leadBotID } ?? members.first
        HStack(alignment: .top, spacing: Theme.Space.gutter) {
            GroupFaceRow(bots: members, size: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.snug) {
                    Text(group.name)
                        .font(Theme.Typography.heading)
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    if thread.speaking != nil {
                        TeamPill(text: "Active now", tone: palette.success)
                    } else if thread.isWaitingOnYou {
                        TeamPill(text: "Waiting on you", tone: palette.primary)
                    }
                }
                Text(thread.preview ?? "No messages yet. Say hi to get them going.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(thread.preview == nil ? palette.mutedForeground : palette.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Theme.Space.tight) {
                    fact("person.2.fill", members.count == 1 ? "1 bot" : "\(members.count) bots")
                    if let lead { fact("star.fill", "\(lead.name) leads") }
                    fact("hand.raised.fill", "Checks with you after \(group.turnLimit) turns")
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            if let last = thread.messages.last {
                Text(Theme.stamp(last.at))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.top, 4)
            }

            Menu {
                Button(action: onOpen) { Label("Open chat", systemImage: "bubble.left") }
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                GroupTurnLimitPicker(group: group)
                Divider()
                // The conversation only. Its bots are untouched.
                Button(role: .destructive) { model.deleteGroup(group) } label: {
                    Label("Delete group", systemImage: "trash")
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
        }
        .padding(Theme.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? palette.cardHover : palette.card,
                    in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: Theme.scaled(9)))
            Text(text).font(Theme.Typography.caption)
        }
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, 3)
        .background(palette.background, in: .rect(cornerRadius: 6))
    }
}

// MARK: - The page

struct GroupPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let group: ChatGroup
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(group: ChatGroup) {
        self.group = group
    }

    private var thread: GroupThread { model.groupThread(for: group) }
    private var members: [Bot] { model.members(of: group) }

    var body: some View {
        PanelSurface {
            VStack(spacing: 0) {
                Topbar(trail: [group.name]) {
                    HStack(spacing: Theme.Space.snug) {
                        GroupFaceRow(bots: members, size: 26)
                        Text(memberLine)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Space.snug)
                            .padding(.vertical, 5)
                            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                        Menu {
                            GroupTurnLimitPicker(group: group)
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
                        .help("Group settings")
                    }
                }
                transcript
                composer
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .onAppear {
            model.selectedGroupID = group.id
            model.markGroupRead(group)
        }
        // Opening a conversation puts the cursor in it, as every chat app does. Deferred a moment
        // so the field is in the window when asked.
        .task(id: group.id) {
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
        .onDisappear {
            if model.selectedGroupID == group.id { model.selectedGroupID = nil }
        }
    }

    private var memberLine: String {
        let count = members.count == 1 ? "1 bot" : "\(members.count) bots"
        guard let lead else { return count }
        return "\(count), \(lead.name) leads"
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                        if thread.messages.isEmpty {
                            // Centred in the pane, like an empty one-to-one thread, rather than
                            // sitting on the composer at the bottom.
                            empty
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: geometry.size.height * 0.7, alignment: .center)
                        }
                        ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(
                                message.at, inSameDayAs: thread.messages[index - 1].at) {
                                DaySeparator(date: message.at)
                            }
                            GroupBubble(message: message,
                                        bot: members.first { $0.id.rawValue == message.author },
                                        showsName: showsName(at: index))
                                .id(message.id)
                        }
                        // Approvals a member raised inside this group. They stop that bot until
                        // you answer, so they belong in the thread, not only in the inbox.
                        ForEach(model.pendingApprovals(in: group), id: \.1.id) { bot, approval in
                            ApprovalCard(approval: approval, owner: bot)
                                .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .leading)
                                .padding(.leading, Theme.Size.bubbleAvatar + 4 + Theme.Space.step)
                        }
                        if let speaking = thread.speaking,
                           let bot = members.first(where: { $0.id == speaking }),
                           !model.isWaitingForApproval(bot.id) {
                            HStack(spacing: Theme.Space.snug) {
                                BotFace(bot: bot, mood: .working, size: Theme.scaled(24))
                                Text("\(bot.name) is replying")
                                    .font(Theme.Typography.label)
                                    .foregroundStyle(palette.mutedForeground)
                            }
                            .padding(.leading, Theme.Size.bubbleAvatar + 4 + Theme.Space.step)
                            .id("speaking")
                        }
                    }
                    .padding(.top, Theme.Space.section)
                    .padding(.bottom, Theme.Space.gutter)
                    .padding(.horizontal, Theme.Space.section + Theme.Space.tight)
                    .frame(maxWidth: 896)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                // Opens at the latest message, as one-to-one threads do.
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.messages.count) {
                    guard let last = thread.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// A bot's name is shown above its first message in a run of its own messages. With several
    /// bots in one thread, a face alone is not enough to know who is speaking.
    private func showsName(at index: Int) -> Bool {
        let message = thread.messages[index]
        guard !message.isFromUser, !message.isSystem else { return false }
        guard index > 0 else { return true }
        return thread.messages[index - 1].author != message.author
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.snug) {
            GroupFaceRow(bots: members, size: 48)
                .padding(.bottom, Theme.Space.tight)
            Text("Say something to \(group.name)")
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            Text("Mention a bot with @ to ask it directly. Otherwise "
                 + "\(lead?.name ?? "the first bot") answers.")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.page)
    }

    private var lead: Bot? {
        members.first { $0.id == group.leadBotID } ?? members.first
    }

    // MARK: Composer

    /// Who will answer, worked out live from what you have typed, so a message never goes to
    /// someone you did not mean, and you can see it before you press return.
    private var addressees: [Bot] {
        let routing = members.map { GroupRouting.Member(id: $0.id.rawValue, name: $0.name) }
        return GroupRouting.addressees(of: draft, members: routing, lead: group.leadBotID?.rawValue)
            .compactMap { member in members.first { $0.id.rawValue == member.id } }
    }

    private var composer: some View {
        let typed = !draft.trimmingCharacters(in: .whitespaces).isEmpty
        let addressed: Set<BotID> = typed ? Set(addressees.map(\.id)) : []
        return VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.tight) {
                ForEach(members) { bot in
                    // Tap to mention. Typing @ works too; these are for not having to remember
                    // the exact name of "LinkedIn YC connection maker for founders".
                    let isAddressed = addressed.contains(bot.id)
                    Button { mention(bot) } label: {
                        HStack(spacing: 5) {
                            BotFace(bot: bot, mood: .idle, size: 18)
                            Text("@\(bot.name)")
                                .font(Theme.Typography.label)
                                .lineLimit(1)
                        }
                        .foregroundStyle(isAddressed ? palette.foreground : palette.mutedForeground)
                        .padding(.horizontal, Theme.Space.snug)
                        .frame(height: 30)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(isAddressed ? palette.foreground.opacity(0.5) : .clear)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if typed {
                    Text("To \(addressees.map(\.name).joined(separator: ", "))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .bottom, spacing: Theme.Space.snug) {
                // The same + as a one-to-one thread: files go in as paths, for whichever bot
                // answers to open itself.
                Button(action: pickFiles) {
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(14), weight: .regular))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .help("Attach files")

                TextField("Message \(group.name)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .lineLimit(1...8)
                    .padding(.vertical, 7)
                    .focused($composerFocused)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Theme.scaled(13), weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(palette.primary.opacity(typed ? 1 : 0.45),
                                    in: .rect(cornerRadius: Theme.Radius.control))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!typed)
            }
            .padding(.leading, Theme.Space.snug)
            .padding(.trailing, Theme.Space.snug)
            .padding(.vertical, Theme.Space.snug)
            .background(palette.background, in: .rect(cornerRadius: Theme.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble).strokeBorder(palette.border)
            }
        }
        .padding(.horizontal, Theme.Space.section + Theme.Space.tight)
        .padding(.bottom, Theme.Space.section)
        .padding(.top, Theme.Space.snug)
        .frame(maxWidth: 896)
        .frame(maxWidth: .infinity)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.count == 1 ? panel.urls[0].path
            : panel.urls.map { "- \($0.path)" }.joined(separator: "\n")
        draft = draft.isEmpty ? paths : draft + "\n" + paths
    }

    private func mention(_ bot: Bot) {
        let tag = "@\(bot.name) "
        if draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft += tag
        } else {
            draft += " " + tag
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text, toGroup: group)
    }
}

/// One message in a group thread.
///
/// Yours sit on the right in a grey bubble. A bot's has no bubble: its face, its name and the
/// time, then the words, as one-to-one threads draw them.
struct GroupBubble: View {
    @Environment(\.palette) private var palette
    let message: GroupMessageRecord
    let bot: Bot?
    let showsName: Bool

    init(message: GroupMessageRecord, bot: Bot?, showsName: Bool) {
        self.message = message
        self.bot = bot
        self.showsName = showsName
    }

    private var avatarSize: CGFloat { Theme.Size.bubbleAvatar + 4 }

    var body: some View {
        if message.isSystem {
            // Notes from bupsy itself: a bot handing work to another, a stop after too many
            // replies. Quiet and indented, so they read as stage directions.
            HStack(spacing: Theme.Space.tight) {
                // A pause at the turn limit is the group waiting on you, so it gets the accent.
                Image(systemName: message.isPauseNote ? "hand.raised.fill" : "bubble.left.fill")
                    .font(.system(size: Theme.scaled(10)))
                    .foregroundStyle(message.isPauseNote ? palette.primary : palette.mutedForeground)
                Text(message.text)
                    .font(Theme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.mutedForeground)
            .padding(.leading, avatarSize + Theme.Space.step)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.isFromUser {
            HStack {
                Spacer(minLength: 96)
                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, 10)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                    .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Space.step) {
                Group {
                    if let bot {
                        BotFace(bot: bot, mood: .idle, size: avatarSize)
                    } else {
                        // The bot has since been deleted; its words stay, as a transcript's do.
                        Circle().fill(palette.secondary)
                            .frame(width: avatarSize, height: avatarSize)
                    }
                }
                .opacity(showsName ? 1 : 0)
                .frame(height: showsName ? avatarSize : 1, alignment: .top)

                VStack(alignment: .leading, spacing: 3) {
                    if showsName {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                            Text(message.authorName)
                                .font(Theme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(palette.foreground)
                            Text(message.at.formatted(date: .omitted, time: .shortened))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                        }
                    }
                    FormattedReply(markdown: message.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Turn limit

/// How many bot turns the group takes before it checks with you, as a menu section. Used in the
/// group card's menu and the group page's header menu, so both edit the same stored value.
struct GroupTurnLimitPicker: View {
    @Environment(AppModel.self) private var model
    let group: ChatGroup

    init(group: ChatGroup) {
        self.group = group
    }

    var body: some View {
        Picker(selection: Binding(
            get: { model.groups.first(where: { $0.id == group.id })?.turnLimit ?? group.turnLimit },
            set: { model.setTurnLimit($0, for: group) }
        )) {
            ForEach(GroupRouting.turnLimitChoices, id: \.self) { turns in
                Text("\(turns) turns").tag(turns)
            }
        } label: {
            Label("Checks with you after", systemImage: "hand.raised")
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Making a group

struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    var onCreated: (ChatGroup) -> Void
    @State private var name = ""
    @State private var chosen: [BotID] = []
    @State private var lead: BotID?
    @State private var turnLimit = GroupRouting.defaultTurnLimit

    init(onCreated: @escaping (ChatGroup) -> Void = { _ in }) {
        self.onCreated = onCreated
    }

    private var chosenBots: [Bot] {
        chosen.compactMap { id in model.bots.first { $0.id == id } }
    }

    private var effectiveLead: BotID? {
        if let lead, chosen.contains(lead) { return lead }
        return chosen.first
    }

    var body: some View {
        SheetFrame(title: "New group chat", icon: "person.2.fill",
                   subtitle: "Put a few bots in one thread to work on one goal together.",
                   width: 520, tone: .info, primaryVerb: "create") {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("Docs refresh"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack {
                    Text("Members")
                    Spacer(minLength: 0)
                    Text(chosen.isEmpty ? "None picked" : "\(chosen.count) picked")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.bots.enumerated()), id: \.element.id) { index, bot in
                            if index > 0 {
                                Rectangle().fill(palette.border).frame(height: 1)
                            }
                            memberRow(bot)
                        }
                    }
                }
                .frame(maxHeight: 270)
                .background(palette.background, in: .rect(cornerRadius: Theme.Radius.base))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border)
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.gutter) {
                Field(label: "Lead", hint: "Answers anything that doesn't mention a bot by name.") {
                    Picker("", selection: Binding(
                        get: { effectiveLead },
                        set: { lead = $0 }
                    )) {
                        if chosenBots.isEmpty {
                            Text("Pick members first").tag(BotID?.none)
                        }
                        ForEach(chosenBots) { bot in
                            Text(bot.name).tag(BotID?.some(bot.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(chosenBots.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Field(label: "Turns before it checks with you",
                      hint: "When the bots pass work back and forth, they pause here until you reply.") {
                    Picker("", selection: $turnLimit) {
                        ForEach(GroupRouting.turnLimitChoices, id: \.self) { turns in
                            Text("\(turns) turns").tag(turns)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if chosen.count == 1, let only = chosenBots.first {
                Label("Pick one more bot. With only \(only.name) it would just be a normal chat.",
                      systemImage: "info.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create group") {
                let leader = effectiveLead.flatMap { id in chosenBots.first { $0.id == id } }
                if let group = model.createGroup(name: name, members: chosenBots, lead: leader,
                                                 turnLimit: turnLimit) {
                    onCreated(group)
                }
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.count < 2)
        }
    }

    private func memberRow(_ bot: Bot) -> some View {
        HStack(spacing: Theme.Space.snug) {
            BotFace(bot: bot, mood: .idle, size: 26)
            Text(bot.name)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            if let role = bot.role, !role.isEmpty { RoleTag(text: role) }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { chosen.contains(bot.id) },
                set: { on in
                    if on {
                        if !chosen.contains(bot.id) { chosen.append(bot.id) }
                    } else {
                        chosen.removeAll { $0 == bot.id }
                        if lead == bot.id { lead = nil }
                    }
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
}

struct RenameGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ChatGroup
    @State private var name = ""

    init(group: ChatGroup) {
        self.group = group
    }

    var body: some View {
        SheetFrame(title: "Rename group", icon: "person.2.fill", width: 400, tone: .info,
                   primaryVerb: "rename") {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text(group.name))
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
        .onAppear { name = group.name }
    }

    private func commit() {
        model.renameGroup(group, to: name)
        dismiss()
    }
}
