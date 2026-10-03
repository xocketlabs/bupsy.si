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
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

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
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: Theme.Space.snug) {
            Text("To:")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
            TextField("", text: $query, prompt: Text("Start a chat with…"))
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
                .focused($focused)
                .onSubmit(activate)
                .onChange(of: query) { highlighted = 0 }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(height: 46)
        // Arrow keys move the highlight; the field keeps focus throughout, so typing and
        // choosing never need two different hands.
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
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
        .frame(maxHeight: 320)
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
        for bot in model.bots where needle.isEmpty || bot.name.lowercased().contains(needle) {
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
        case .bot(let bot): onPick(bot.id)
        }
    }
}

struct PaletteItem: Identifiable {
    enum Kind {
        case create
        case bot(Bot)
    }
    let kind: Kind

    var id: String {
        switch kind {
        case .create: "create"
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 24, height: 24)
                        .background(palette.secondary, in: .rect(cornerRadius: 6))
                    Text("Create new bot")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)

                case .bot(let bot):
                    BotFace(hue: bot.avatarHue, mood: .idle, size: 24)
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
