import BupsyKit
import SwiftUI

/// "Start a chat with…" — the way into a conversation, replacing a modal form.
///
/// ⌘N used to open the new-bot sheet directly, which assumed that wanting a conversation means
/// wanting a *new* bot. Most of the time it does not: you want one of the bots you already have,
/// and the fastest route to it is typing two letters of its name. Making a new one is the first
/// item in the same list rather than a separate door.
///
/// Opens over the conversation rather than in a sheet, so the thread you were reading stays
/// visible behind it and dismissing costs nothing.
struct StartChatPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    let onPick: (BotID) -> Void
    let onCreate: () -> Void
    var onCreateManually: () -> Void = {}
    var onCreateGroup: () -> Void = {}
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Rectangle().fill(palette.border).frame(height: 1)
            list
        }
        .frame(width: 520)
        .background(palette.popover, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)

    }

    private var field: some View {
        HStack(spacing: Theme.Space.snug) {
            Text("To:")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
            PaletteField(
                text: $query,
                placeholder: "Start a chat with…",
                onSubmit: activate,
                onMove: move,
                onCancel: onDismiss)
                .frame(height: 22)
                .onChange(of: query) { highlighted = 0 }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.scaled(10), weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(height: 46)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    PaletteRow(row: row, highlighted: index == highlighted) {
                        choose(row)
                    }
                    .onHover { if $0 { highlighted = index } }
                }
                if rows.isEmpty {
                    Text("No bot matches “\(query)”")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.step)
                }
            }
            .padding(Theme.Space.tight)
        }
        // Sized to its rows, up to a cap: a fixed 320pt left a block of empty panel under a
        // short list.
        .frame(height: min(CGFloat(max(rows.count, 1)) * 38 + 12, 340))
    }

    /// What is listed: making a bot first, then every bot that matches.
    ///
    /// Hidden bots are included. Hiding is about keeping the sidebar quiet, not about making a
    /// bot unreachable — if it were, hiding would be a trapdoor rather than tidying.
    private var rows: [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var items: [PaletteItem] = []

        if needle.isEmpty || "create new bot".contains(needle) {
            items.append(PaletteItem(kind: .create))
        }
        // Second, as in Grok Bot's own palette. It was left out until group threads existed —
        // a dead menu item is worse than an absent one.
        if (needle.isEmpty || "create group chat".contains(needle)) && model.bots.count >= 2 {
            items.append(PaletteItem(kind: .createGroup))
        }
        // The form is still there for anyone who would rather set everything up front.
        if !needle.isEmpty && "set up a bot yourself".contains(needle) || needle.isEmpty {
            items.append(PaletteItem(kind: .createManually))
        }
        // Most recently active first. "Start a chat with…" is nearly always "pick up where I
        // left off", and creation order put the bot made first at the top forever.
        let ordered = model.bots.sorted { model.lastActivity(for: $0) > model.lastActivity(for: $1) }
        for bot in ordered where needle.isEmpty || bot.name.lowercased().contains(needle) {
            items.append(PaletteItem(kind: .bot(bot)))
        }
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
        case .bot(let bot): onPick(bot.id)
        }
    }
}

struct PaletteItem: Identifiable {
    enum Kind {
        case create
        case createManually
        case createGroup
        case bot(Bot)
    }
    let kind: Kind

    var id: String {
        switch kind {
        case .create: "create"
        case .createManually: "create-manually"
        case .createGroup: "create-group"
        case .bot(let bot): bot.id.rawValue
        }
    }
}

private struct PaletteRow: View {
    @Environment(\.palette) private var palette
    let row: PaletteItem
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                switch row.kind {
                case .create:
                    Image(systemName: "plus")
                        .font(.system(size: Theme.scaled(12), weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 24, height: 24)
                        .background(palette.secondary, in: .rect(cornerRadius: 6))
                    Text("Create new bot")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                    Text("it'll ask what it's for")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)

                case .createManually:
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: Theme.scaled(11), weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 24, height: 24)
                        .background(palette.secondary, in: .rect(cornerRadius: 6))
                    Text("Set up a bot yourself…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)

                case .createGroup:
                    Image(systemName: "person.2")
                        .font(.system(size: Theme.scaled(11), weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 24, height: 24)
                        .background(palette.secondary, in: .rect(cornerRadius: 6))
                    Text("Create group chat")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)

                case .bot(let bot):
                    BotFace(bot: bot, mood: .idle, size: Theme.scaled(24))
                    Text(bot.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                    if bot.hidden {
                        // Says why a bot you cannot see in the sidebar is offered here.
                        Text("hidden")
                            .font(Theme.Typography.badge)
                            .foregroundStyle(palette.mutedForeground)
                    }
                }
                Spacer(minLength: 0)
                // Only on the highlighted row, and only the key that is true there. Grok Bot
                // prints ⌘1–⌘9 beside every row, but here those shortcuts follow sidebar order;
                // printed beside a recency-ordered list they would point at the wrong bots.
                if highlighted {
                    Text("↩")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Space.snug)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? palette.cardHover : .clear,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Theme.scaled(13))
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
