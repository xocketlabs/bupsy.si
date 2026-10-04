import BupsyKit
import SwiftUI

// MARK: - Faces

/// Two faces overlapping, and "+N" for the rest — how a group reads at a glance in a list.
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

// MARK: - Sidebar row

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let group: ChatGroup
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let unread = model.isGroupUnread(group)
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                StackedFaces(bots: model.members(of: group))
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(group.name)
                            .font(Theme.Typography.body)
                            .fontWeight(unread ? .semibold : .medium)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if unread {
                            Circle().fill(palette.info).frame(width: 6, height: 6)
                        }
                    }
                    Text(model.groupThread(for: group).preview
                         ?? "\(group.memberIDs.count) bots · say hi")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(unread ? palette.sidebarMutedForeground : palette.sidebarMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.sidebarAccent
                                 : (hovering ? palette.sidebarAccent.opacity(0.55) : .clear),
                        in: .rect(cornerRadius: Theme.Radius.base))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - The page

struct GroupPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let group: ChatGroup
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var thread: GroupThread { model.groupThread(for: group) }
    private var members: [Bot] { model.members(of: group) }

    var body: some View {
        PanelSurface {
            VStack(spacing: 0) {
                transcript
                composer
            }
            .overlay(alignment: .top) { titlePill }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .onAppear {
            model.selectedGroupID = group.id
            model.markGroupRead(group)
        }
        // Opening a conversation puts the cursor in it, as every chat app does — you came here
        // to say something. Deferred a moment so the field is in the window when asked.
        .task(id: group.id) {
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
        .onDisappear {
            if model.selectedGroupID == group.id { model.selectedGroupID = nil }
        }
    }

    private var titlePill: some View {
        HStack(spacing: Theme.Space.snug) {
            StackedFaces(bots: members, size: Theme.scaled(24))
            Text(group.name)
                .font(Theme.Typography.body)
                .fontWeight(.medium)
                .foregroundStyle(palette.foreground)
            Text("\(members.count) bots")
                .font(Theme.Typography.badge)
                .foregroundStyle(palette.mutedForeground)
        }
        .padding(.leading, Theme.Space.snug)
        .padding(.trailing, Theme.Space.step)
        .padding(.vertical, 6)
        .background(palette.card, in: .capsule)
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
        .padding(.top, Theme.Space.step)
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.step) {
                        if thread.messages.isEmpty {
                            empty
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
                        }
                        if let speaking = thread.speaking,
                           let bot = members.first(where: { $0.id == speaking }),
                           !model.isWaitingForApproval(bot.id) {
                            HStack(spacing: Theme.Space.tight) {
                                BotFace(bot: bot, mood: .working, size: Theme.Size.bubbleAvatar)
                                Text("\(bot.name) is replying…")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(palette.mutedForeground)
                            }
                            .id("speaking")
                        }
                    }
                    .padding(.top, 56)
                    .padding(.bottom, Theme.Space.gutter)
                    .padding(.horizontal, Theme.Space.section)
                    .frame(maxWidth: Theme.Size.contentMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                .onChange(of: thread.messages.count) {
                    guard let last = thread.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// A bot's name is shown above its first message in a run of its own messages — with several
    /// bots in one thread, a face alone is not enough to know who is speaking.
    private func showsName(at index: Int) -> Bool {
        let message = thread.messages[index]
        guard !message.isFromUser, !message.isSystem else { return false }
        guard index > 0 else { return true }
        return thread.messages[index - 1].author != message.author
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.snug) {
            StackedFaces(bots: members, size: 56)
            Text("Say something to \(group.name)")
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            Text("Mention a bot with @ to ask it directly. Otherwise "
                 + "\(lead?.name ?? "the first bot") answers.")
                .font(Theme.Typography.caption)
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

    /// Who will answer, worked out live from what you have typed — so a message never goes to
    /// someone you did not mean, and you can see it before you press return.
    private var addressees: [Bot] {
        let routing = members.map { GroupRouting.Member(id: $0.id.rawValue, name: $0.name) }
        return GroupRouting.addressees(of: draft, members: routing, lead: group.leadBotID?.rawValue)
            .compactMap { member in members.first { $0.id.rawValue == member.id } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.tight) {
                ForEach(members) { bot in
                    // Tap to mention. Typing @ works too; these are for not having to remember
                    // the exact name of "LinkedIn YC connection maker for founders".
                    Button { mention(bot) } label: {
                        HStack(spacing: 4) {
                            BotFace(bot: bot, mood: .idle, size: 16)
                            Text("@\(bot.name)")
                                .font(Theme.Typography.caption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, Theme.Space.snug)
                        .padding(.vertical, 4)
                        .background(palette.card, in: .capsule)
                        .overlay(Capsule().stroke(palette.border))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("To \(addressees.map(\.name).joined(separator: ", "))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.primary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .bottom, spacing: Theme.Space.snug) {
                TextField("Message \(group.name)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .lineLimit(1...8)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.step)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.base))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.base)
                        .strokeBorder(palette.border))
                    .focused($composerFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Theme.scaled(13), weight: .semibold))
                        .foregroundStyle(draft.isEmpty ? palette.mutedForeground : palette.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(draft.isEmpty ? palette.secondary : palette.primary, in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.step)
        .frame(maxWidth: Theme.Size.contentMaxWidth)
        .frame(maxWidth: .infinity)
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
struct GroupBubble: View {
    @Environment(\.palette) private var palette
    let message: GroupMessageRecord
    let bot: Bot?
    let showsName: Bool

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.tight)
        } else if message.isFromUser {
            HStack {
                Spacer(minLength: 72)
                Text(message.text)
                    .font(Theme.Typography.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.step)
                    .padding(.vertical, Theme.Space.snug)
                    .background(palette.primary, in: .rect(cornerRadius: Theme.Radius.bubble))
                    .foregroundStyle(palette.onPrimary)
                    .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Space.tight) {
                Group {
                    if let bot {
                        BotFace(bot: bot, mood: .idle, size: Theme.Size.bubbleAvatar)
                    } else {
                        // The bot has since been deleted; its words stay, as a transcript's do.
                        Circle().fill(palette.secondary)
                            .frame(width: Theme.Size.bubbleAvatar, height: Theme.Size.bubbleAvatar)
                    }
                }
                .opacity(showsName ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    if showsName {
                        // In the bot's own colour, as its mentions are — a name you can match to
                        // a face at a glance in a busy room.
                        Text(message.authorName)
                            .font(Theme.Typography.badge)
                            .foregroundStyle(bot.map(BotFace.colour(of:)) ?? palette.mutedForeground)
                    }
                    FormattedReply(markdown: message.text)
                        .padding(.horizontal, Theme.Space.step)
                        .padding(.vertical, Theme.Space.snug)
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.bubble))
                }
                .frame(maxWidth: Theme.Size.bubbleMaxWidth, alignment: .leading)
                Spacer(minLength: 48)
            }
        }
    }
}

// MARK: - Making a group

struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    var onCreated: (ChatGroup) -> Void = { _ in }
    @State private var name = ""
    @State private var chosen: [BotID] = []
    @State private var lead: BotID?

    var body: some View {
        SheetFrame(title: "New group chat", icon: "person.2",
                   subtitle: "Several bots in one conversation. Mention one with @ to ask it; "
                       + "otherwise the lead answers.",
                   width: 460) {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("Launch team"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            Field(label: "Who's in it",
                  hint: chosen.count < 2 ? "Pick at least two." : nil) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.bots) { bot in
                            memberRow(bot)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .padding(Theme.Space.tight)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(palette.border))
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create") {
                let members = chosen.compactMap { id in model.bots.first { $0.id == id } }
                let leader = lead.flatMap { id in members.first { $0.id == id } }
                if let group = model.createGroup(name: name, members: members, lead: leader) {
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
        let isIn = chosen.contains(bot.id)
        let isLead = (lead ?? chosen.first) == bot.id && isIn
        return HStack(spacing: Theme.Space.snug) {
            Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isIn ? palette.primary : palette.mutedForeground)
            BotFace(bot: bot, mood: .idle, size: 24)
            Text(bot.name)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isIn {
                // The lead answers anything not addressed to someone. Shown on every member so it
                // is obvious which one it is and how to change it.
                Button(isLead ? "Lead" : "Make lead") { lead = bot.id }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.badge)
                    .foregroundStyle(isLead ? palette.primary : palette.mutedForeground)
                    .disabled(isLead)
            }
        }
        .padding(.horizontal, Theme.Space.snug)
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture {
            if isIn {
                chosen.removeAll { $0 == bot.id }
                if lead == bot.id { lead = nil }
            } else {
                chosen.append(bot.id)
            }
        }
    }
}

struct RenameGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ChatGroup
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "Rename group", icon: "person.2", width: 380) {
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
