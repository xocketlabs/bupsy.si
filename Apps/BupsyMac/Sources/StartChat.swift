import BupsyKit
import SwiftUI

/// One place to find and start anything — the + button and ⌘F both open it, like Spotlight.
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
        .frame(width: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .background(palette.popover.opacity(0.75), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.scaled(18), weight: .medium))
                .foregroundStyle(palette.mutedForeground)
            PaletteField(
                text: $query,
                placeholder: searchFirst ? "Search bots, groups and messages" : "Start a chat, or search…",
                fontSize: Theme.scaled(20),
                onSubmit: activate,
                onMove: move,
                onCancel: onDismiss)
                .frame(height: 30)
                .onChange(of: query) { highlighted = 0 }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.scaled(14)))
                        .foregroundStyle(palette.mutedForeground)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].section != row.section {
                            Text(row.section.uppercased())
                                .font(.system(size: Theme.scaled(10), weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(palette.mutedForeground)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 2 : 10)
                                .padding(.bottom, 3)
                        }
                        PaletteRow(row: row, needle: needle, highlighted: index == highlighted) {
                            choose(row)
                        }
                        .id(row.id)
                        .onHover { if $0 { highlighted = index } }
                    }
                    if rows.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: Theme.scaled(22)))
                                .foregroundStyle(palette.mutedForeground.opacity(0.6))
                            Text("Nothing matches “\(query)”")
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.mutedForeground)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
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
        guard !rows.isEmpty else { return 110 }
        let sections = Set(rows.map(\.section)).count
        let height = rows.reduce(0) { $0 + ($1.isMessage ? 52 : 42) } + CGFloat(sections) * 24 + 16
        return min(height, 420)
    }

    private var hints: some View {
        HStack(spacing: 16) {
            hint("↑↓", "move")
            hint("↩", "open")
            hint("esc", "close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: Theme.scaled(10), weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(palette.foreground.opacity(0.08), in: .rect(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: Theme.scaled(11)))
        .foregroundStyle(palette.mutedForeground)
    }

    private var rows: [PaletteItem] {
        let needle = self.needle
        var items: [PaletteItem] = []
        let create: [PaletteItem] = [
            PaletteItem(kind: .create, section: "Create", title: "New bot", subtitle: "It asks what it's for"),
            PaletteItem(kind: .createGroup, section: "Create", title: "New group chat", subtitle: "Several bots in one conversation"),
            PaletteItem(kind: .createManually, section: "Create", title: "Set up a bot yourself", subtitle: "Name, face and job up front"),
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
            return items
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
        items += messages.sorted {
            if case .message(_, let a) = $0.kind, case .message(_, let b) = $1.kind { return a > b }
            return false
        }.prefix(12)
        return items
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
        case .bot(let bot), .message(let bot, _): onPick(bot.id)
        case .group(let group): onPickGroup(group.id)
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
    }
    let kind: Kind
    var section: String
    var title: String
    var subtitle: String

    var isMessage: Bool { if case .message = kind { return true } else { return false } }

    var id: String {
        switch kind {
        case .create: "create"
        case .createManually: "create-manually"
        case .createGroup: "create-group"
        case .bot(let bot): "bot-" + bot.id.rawValue
        case .group(let group): "group-" + group.id
        case .message(let bot, let at): "msg-\(bot.id.rawValue)-\(at.timeIntervalSince1970)"
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
            HStack(spacing: 12) {
                icon.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(marked(row.title))
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(marked(snippet(row.subtitle)))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(row.isMessage ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
                if highlighted {
                    Image(systemName: "return")
                        .font(.system(size: Theme.scaled(10), weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: row.isMessage ? 50 : 40)
            .background(highlighted ? palette.primary.opacity(0.16) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .bot(let bot), .message(let bot, _):
            BotFace(bot: bot, mood: .idle, size: 28)
        case .group(let group):
            StackedFaces(bots: model.bots.filter { group.memberIDs.contains($0.id) }, size: 28)
        case .create, .createGroup, .createManually:
            let symbol = row.kind == .create ? "plus" : (row.kind == .createGroup ? "person.2.fill" : "slider.horizontal.3")
            Image(systemName: symbol)
                .font(.system(size: Theme.scaled(12), weight: .semibold))
                .foregroundStyle(row.kind == .create ? palette.onPrimary : palette.foreground)
                .frame(width: 28, height: 28)
                .background(row.kind == .create ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground.opacity(0.08)),
                            in: .rect(cornerRadius: 8))
        }
    }

    /// For a long message, the part around the match — the start of a paragraph rarely is.
    private func snippet(_ text: String) -> String {
        guard row.isMessage, !needle.isEmpty, let range = text.lowercased().range(of: needle) else { return text }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        return (start == text.startIndex ? "" : "…") + text[start...]
    }

    /// The matched part in bold.
    private func marked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !needle.isEmpty, let range = result.range(of: needle, options: .caseInsensitive) else { return result }
        result[range].font = .system(size: Theme.scaled(13), weight: .bold)
        result[range].foregroundColor = palette.primary
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
struct JobChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let change: AppModel.PendingJobChange

    var body: some View {
        SheetFrame(
            title: "Save \(change.bot.name)'s job?",
            icon: "text.badge.checkmark",
            subtitle: "It wrote this from your conversation. It becomes the standing instructions "
                + "for everything \(change.bot.name) does.",
            width: 460,
            closable: false
        ) {
            HStack(spacing: Theme.Space.step) {
                BotFace(bot: change.bot, mood: .idle, size: 40)
                Text(change.bot.name).font(Theme.Typography.title).foregroundStyle(palette.foreground)
                Spacer(minLength: 0)
            }
            Field(label: "Its job") {
                Text(change.job)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.step)
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(palette.border))
            }
            if let current = change.bot.personaPrompt {
                Text("Replaces: \(current)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Keep current") { model.decideJobChange(change, allow: false) }
                .buttonStyle(QuietButton())
            Button("Save job") { model.decideJobChange(change, allow: true) }
                .buttonStyle(PrimaryButton())
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
