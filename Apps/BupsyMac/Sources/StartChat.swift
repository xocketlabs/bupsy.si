import BupsyKit
import SwiftUI

/// One place to find and start anything. The + button and Cmd F both open it, like Spotlight.
///
/// Empty, it offers what you can make and the bots and groups you talk to most recently. Typing
/// narrows those by name and also searches what was said, so "invoice" finds the message about
/// the invoice, not only a bot called Invoice. Arrow keys, Return and Escape work throughout.
struct StartChatPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    /// Opened from the search button: lead with search, not with "create".
    var searchFirst = false
    let onPick: (BotID) -> Void
    var onPickGroup: (String) -> Void = { _ in }
    let onCreate: () -> Void
    var onCreateManually: () -> Void = {}
    var onCreateGroup: () -> Void = {}
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    /// Worked out once per change of what was typed, not on every read: the list, its height,
    /// the arrow keys and Return all read it, and each read used to walk every thread again.
    @State private var rows: [PaletteItem] = []
    /// True when what was typed matched nothing and the only row is "Make a bot called ...".
    @State private var matchesNothing = false
    /// The full bot creator, opened from "Make a bot called ..." with the name filled in.
    @State private var isCreatingNamed = false
    @State private var namedDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            field
            if !rows.isEmpty || !needle.isEmpty {
                Rectangle().fill(palette.border).frame(height: 1)
                list
                Rectangle().fill(palette.border).frame(height: 1)
                hints
            }
        }
        .frame(maxWidth: .infinity)
        .background(palette.popover, in: .rect(cornerRadius: Theme.Radius.bubble))
        .clipShape(.rect(cornerRadius: Theme.Radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.bubble).strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.18), radius: 32, y: 14)
        .onAppear(perform: refreshRows)
        .onChange(of: query) { refreshRows() }
        .onChange(of: model.bots.count) { refreshRows() }
        .onChange(of: model.groups.count) { refreshRows() }
        // Hung on the palette, which stays up behind it, so the sheet is not torn down with it.
        // Closing the creator, by saving or cancelling, closes the palette too.
        .sheet(isPresented: $isCreatingNamed, onDismiss: onDismiss) {
            BotCreatorSheet(name: namedDraft)
        }
    }

    private func refreshRows() {
        let (items, nothing) = buildRows()
        rows = items
        matchesNothing = nothing
        if !rows.indices.contains(highlighted) { highlighted = 0 }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var field: some View {
        HStack(spacing: Theme.Space.step) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.scaled(14), weight: .medium))
                .foregroundStyle(palette.mutedForeground)
            PaletteField(
                text: $query,
                placeholder: searchFirst ? "Search bots, groups and messages" : "Start a chat, or search...",
                fontSize: Theme.scaled(15),
                onSubmit: activate,
                onMove: move,
                onCancel: onDismiss)
                .frame(height: 26)
                .onChange(of: query) { highlighted = 0 }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.scaled(13)))
                        .foregroundStyle(palette.mutedForeground)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Keycap("esc")
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(height: 56)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if matchesNothing {
                        // A napping grey bot: nothing found is not an error.
                        HStack(spacing: Theme.Space.step) {
                            BotFace(hue: 0, mood: .sleeping, size: 48, shape: .bup, colour: 0)
                                .saturation(0)
                                .opacity(0.7)
                                .accessibilityHidden(true)
                            Text("Nothing matches \"\(query)\"")
                                .font(.system(size: Theme.scaled(13.5)))
                                .foregroundStyle(palette.mutedForeground)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.Space.snug)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].section != row.section {
                            Text(row.section)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? Theme.Space.snug : Theme.Space.step)
                                .padding(.bottom, 4)
                        }
                        PaletteRow(row: row, needle: needle, highlighted: index == highlighted) {
                            choose(row)
                        }
                        .id(row.id)
                        .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(8)
            }
            .frame(height: listHeight)
            .onChange(of: highlighted) { _, index in
                guard rows.indices.contains(index) else { return }
                proxy.scrollTo(rows[index].id)
            }
        }
    }

    /// Sized to its rows, up to a cap, so a short list leaves no empty panel.
    private var listHeight: CGFloat {
        guard !rows.isEmpty else { return 104 }
        let sections = Set(rows.map(\.section)).count
        let height = rows.reduce(0) { $0 + ($1.isMessage ? 62 : 58) } + CGFloat(sections) * 30 + 16
            + (matchesNothing ? 72 : 0)
        return min(height, 420)
    }

    private var hints: some View {
        HStack(spacing: Theme.Space.gutter) {
            HStack(spacing: 4) {
                Keycap("↑")
                Keycap("↓")
                Text("to move")
            }
            HStack(spacing: 4) {
                Keycap("Return")
                Text("to open")
            }
            HStack(spacing: 4) {
                Keycap("Esc")
                Text("to close")
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 10)
    }

    private func buildRows() -> ([PaletteItem], Bool) {
        let needle = self.needle
        var items: [PaletteItem] = []
        let create: [PaletteItem] = [
            PaletteItem(kind: .create, section: "Create", title: "New bot", subtitle: "It asks what it's for"),
            PaletteItem(kind: .createGroup, section: "Create", title: "New group chat", subtitle: "Two or more bots, one lead"),
            PaletteItem(kind: .createManually, section: "Create", title: "Set up a bot yourself", subtitle: "Pick its face, job, engine and trust"),
        ].filter { model.bots.count >= 2 || $0.kind != .createGroup }

        let chats: [PaletteItem] = {
            let groups = model.groups.map { group in
                PaletteItem(kind: .group(group), section: "Chats", title: group.name,
                            subtitle: model.groupThread(for: group).preview ?? "\(group.memberIDs.count) bots")
            }
            let bots = model.bots
                .sorted { model.lastActivity(for: $0) > model.lastActivity(for: $1) }
                .map { bot in
                    PaletteItem(kind: .bot(bot), section: "Chats", title: bot.name,
                                subtitle: bot.hidden ? "Hidden from the sidebar" : (model.thread(for: bot.id).preview ?? bot.personaPrompt ?? ""))
                }
            return bots + groups
        }()

        if needle.isEmpty {
            items += searchFirst ? chats + create : create + chats
            return (items, false)
        }

        items += chats.filter { $0.title.lowercased().contains(needle) }
        items += create.filter { ($0.title + " " + $0.subtitle).lowercased().contains(needle) }
        // What was said, newest first, a handful per bot so one chatty bot cannot fill the list.
        var messages: [PaletteItem] = []
        for bot in model.bots {
            var count = 0
            for entry in model.thread(for: bot.id).entries.reversed() {
                guard count < 3 else { break }
                let text: String?
                switch entry.kind {
                case .assistantText(let t), .userMessage(let t): text = t
                case .messageFrom(_, _, let t): text = t
                default: text = nil
                }
                guard let text, text.lowercased().contains(needle) else { continue }
                count += 1
                messages.append(PaletteItem(kind: .message(bot, entry.at), section: "Messages",
                                            title: bot.name, subtitle: PlainPreview.of(text)))
            }
        }
        // Group chats too: a message said in a group is as findable as one said to a bot.
        for group in model.groups {
            var count = 0
            for message in model.groupThread(for: group).messages.reversed() {
                guard count < 3 else { break }
                guard message.author != GroupMessageRecord.systemAuthor,
                      message.text.lowercased().contains(needle) else { continue }
                count += 1
                let who = message.isFromUser ? "You" : message.authorName
                messages.append(PaletteItem(kind: .groupMessage(group, message.at), section: "Messages",
                                            title: "\(who) in \(group.name)",
                                            subtitle: PlainPreview.of(message.text)))
            }
        }
        items += messages.sorted { ($0.messageDate ?? .distantPast) > ($1.messageDate ?? .distantPast) }
            .prefix(12)
        if items.isEmpty {
            // Nothing by that name: offer to make one, in the full creator, already named.
            let name = query.trimmingCharacters(in: .whitespaces)
            items.append(PaletteItem(kind: .createNamed(name), section: "Create",
                                     title: "Make a bot called \"\(name)\"",
                                     subtitle: "Set up a bot yourself, with this name filled in"))
            return (items, true)
        }
        return (items, false)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
    }

    private func activate() {
        guard rows.indices.contains(highlighted) else { return }
        choose(rows[highlighted])
    }

    private func choose(_ item: PaletteItem) {
        switch item.kind {
        case .create: onCreate()
        case .createManually: onCreateManually()
        case .createGroup: onCreateGroup()
        case .createNamed(let name):
            namedDraft = name
            isCreatingNamed = true
        case .bot(let bot), .message(let bot, _): onPick(bot.id)
        case .group(let group), .groupMessage(let group, _): onPickGroup(group.id)
        }
    }
}

struct PaletteItem: Identifiable {
    enum Kind: Equatable {
        case create
        case createManually
        case createGroup
        case bot(Bot)
        case group(ChatGroup)
        case message(Bot, Date)
        case groupMessage(ChatGroup, Date)
        case createNamed(String)
    }
    let kind: Kind
    var section: String
    var title: String
    var subtitle: String

    var isMessage: Bool { messageDate != nil }

    var isCreateNamed: Bool { if case .createNamed = kind { return true } else { return false } }

    /// When the message was said, for either kind of message row.
    var messageDate: Date? {
        switch kind {
        case .message(_, let at), .groupMessage(_, let at): return at
        default: return nil
        }
    }

    var id: String {
        switch kind {
        case .create: "create"
        case .createManually: "create-manually"
        case .createGroup: "create-group"
        case .bot(let bot): "bot-" + bot.id.rawValue
        case .group(let group): "group-" + group.id
        case .message(let bot, let at): "msg-\(bot.id.rawValue)-\(at.timeIntervalSince1970)"
        case .groupMessage(let group, let at): "gmsg-\(group.id)-\(at.timeIntervalSince1970)"
        case .createNamed: "create-named"
        }
    }
}

private struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let row: PaletteItem
    let needle: String
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.step) {
                icon.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    if let at = row.messageDate {
                        // Who said it and when, then the words, with the match marked.
                        Text("\(row.title), \(Theme.stamp(at))")
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                        Text(marked(snippet(row.subtitle)))
                            .font(.system(size: Theme.scaled(13.5)))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                    } else {
                        Text(marked(row.title))
                            .font(.system(size: Theme.scaled(13.5), weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(Theme.Typography.label)
                                .foregroundStyle(palette.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                if highlighted {
                    Text("Return")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.Space.snug)
            .background(highlighted ? palette.card : .clear, in: .rect(cornerRadius: Theme.Radius.base))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .bot(let bot), .message(let bot, _):
            // A palette of breathing faces is noise: only the highlighted row or a bot with
            // something going on moves.
            let botMood = mood(for: bot)
            BotFace(bot: bot, mood: botMood, size: 36, still: botMood == .idle && !highlighted)
        case .group(let group), .groupMessage(let group, _):
            StackedFaces(bots: model.bots.filter { group.memberIDs.contains($0.id) }, size: 30)
        case .create, .createGroup, .createManually, .createNamed:
            let symbol = row.kind == .createGroup ? "person.2.fill"
                : (row.kind == .createManually ? "gearshape.fill" : "plus")
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(13), weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 36, height: 36)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.base).fill(palette.card)
                        if row.kind == .create || row.isCreateNamed {
                            // The one thing the palette is mostly opened for gets the accent.
                            RoundedRectangle(cornerRadius: Theme.Radius.base).fill(palette.primary.opacity(0.16))
                        }
                    }
                }
        }
    }

    /// The face matches what the bot is up to, so the list doubles as a glance at the team.
    private func mood(for bot: Bot) -> BotMood {
        model.mood(for: bot)
    }

    /// For a long message, the part around the match. The start of a paragraph rarely is.
    private func snippet(_ text: String) -> String {
        guard row.isMessage, !needle.isEmpty, let range = text.lowercased().range(of: needle) else { return text }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        return (start == text.startIndex ? "" : "...") + text[start...]
    }

    /// The matched part, washed in the accent like a highlighter.
    private func marked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !needle.isEmpty, let range = result.range(of: needle, options: .caseInsensitive) else { return result }
        result[range].backgroundColor = palette.primary.opacity(0.3)
        return result
    }
}

/// First contact between two bots, asked once.
///
/// Shown as a sheet rather than folded into the attention inbox because it is a *permission*
/// decision, not a task: answering it sets a standing rule, and that deserves to be read rather
/// than cleared along with everything else in a list.
struct IntroductionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let introduction: AppModel.PendingIntroduction

    var body: some View {
        SheetFrame(
            title: "Let \(introduction.from.name) message \(introduction.to.name)?",
            icon: "bubble.left.and.bubble.right",
            subtitle: "A bot is trying to send another bot an instruction. "
                + "\(introduction.to.name) would act on it without you reading it first.",
            width: 460,
            closable: false
        ) {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: introduction.from, mood: .idle, size: 40)
                Image(systemName: "arrow.right")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(palette.mutedForeground)
                BotFace(bot: introduction.to, mood: .idle, size: 40)
                Spacer(minLength: 0)
            }

            // The actual message, in full. Deciding whether to allow a channel without seeing
            // what is going down it is not a decision, it is a guess.
            Field(label: "What it wants to send") {
                ScrollView {
                    Text(introduction.text)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.step)
                }
                .frame(maxHeight: 160)
                .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(palette.border))
            }

            Text("Your answer is remembered for this direction only, and does not let "
                 + "\(introduction.to.name) message \(introduction.from.name) back.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Don't allow") { model.decideIntroduction(introduction, allow: false) }
                .buttonStyle(QuietButton())
            Button("Allow") { model.decideIntroduction(introduction, allow: true) }
                .buttonStyle(PrimaryButton())
        }
    }
}

/// A bot asking for a new bot. Asked every time: each new bot is a standing thing on the
/// person's own subscription, and they should see every one arrive.
struct CreationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let creation: AppModel.PendingCreation

    var body: some View {
        SheetFrame(
            title: "Let \(creation.from.name) create “\(creation.name)”?",
            icon: "person.badge.plus",
            subtitle: "A bot wants a new bot on your roster. It would run on your "
                + "\(creation.from.engine.displayName) subscription, like the others.",
            width: 460,
            closable: false
        ) {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: creation.from, mood: .idle, size: 40)
                Image(systemName: "plus")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(palette.mutedForeground)
                Text(creation.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(palette.foreground)
                if let role = creation.role { RoleTag(text: role) }
                Spacer(minLength: 0)
            }
            Field(label: "Its job") {
                Text(creation.job)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.step)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(palette.border))
            }
            Text("It starts fully gated, like every new bot, and \(creation.from.name) can "
                 + "message it straight away. You can rename, change or delete it any time.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Don't create") { model.decideCreation(creation, allow: false) }
                .buttonStyle(QuietButton())
            Button("Create bot") { model.decideCreation(creation, allow: true) }
                .buttonStyle(PrimaryButton())
        }
    }
}

/// A bot proposing its own job. Asked because the job is its standing instructions: a bot must
/// not quietly rewrite its own orders, even ones the person just described to it.
///
/// The bot itself peeks over the sheet, so it is plain whose job this is.
struct JobChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let change: AppModel.PendingJobChange

    var body: some View {
        SheetFrame(
            title: "Save \(change.bot.name)'s job?",
            subtitle: "\(change.bot.name) does this on its own from now on. You can change it any "
                + "time in its details.",
            width: 520,
            closable: false,
            bot: change.bot,
            primaryVerb: "save"
        ) {
            Field(label: "Job") {
                Text(change.job)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.step)
                    .background(palette.background, in: .rect(cornerRadius: Theme.Radius.base))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.base).strokeBorder(palette.border))
            }
            if let current = change.bot.personaPrompt, !current.isEmpty {
                Text("Replaces: \(current)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Not now") { model.decideJobChange(change, allow: false) }
                .buttonStyle(ThreadButtonStyle(kind: .ghost))
                .keyboardShortcut(.cancelAction)
            Button("Save job") { model.decideJobChange(change, allow: true) }
                .buttonStyle(ThreadButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The palette's text field, in AppKit.
///
/// A SwiftUI `TextField` inside an overlay never received focus on macOS — neither set in
/// `onAppear` nor deferred — so the palette opened with the *window* as first responder and
/// typing, Enter and the arrow keys all did nothing. This field takes focus itself the moment it
/// lands in a window, and routes ↑ ↓ ↩ Esc through AppKit's own command handling, which is what
/// those keys are actually delivered as.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = Theme.scaled(13)
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Next turn, once the window has finished installing the view.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
