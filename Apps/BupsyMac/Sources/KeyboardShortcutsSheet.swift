import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by Help > Keyboard shortcuts (Cmd /). The sidebar presents the sheet, because the
    /// menu command lives on the app and has no window of its own to put a sheet on.
    static let bupsyShowKeyboardShortcuts = Notification.Name("bupsy.showKeyboardShortcuts")
}

/// Every keyboard shortcut the app really has, in one small sheet.
///
/// Written from the `.keyboardShortcut` calls in the sources, not from a wish list: a shortcut
/// listed here that does nothing is worse than one nobody knows about. Keep it in step when one
/// is added or removed.
struct KeyboardShortcutsSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    struct Shortcut: Identifiable {
        let keys: [String]
        let action: String
        var id: String { action }
    }

    struct ShortcutGroup: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Anywhere", shortcuts: [
            Shortcut(keys: ["Cmd", "N"], action: "Start a chat"),
            Shortcut(keys: ["Cmd", "F"], action: "Search bots"),
            Shortcut(keys: ["Cmd", "1 to 9"], action: "Open the first nine bots in the sidebar, top to bottom"),
            Shortcut(keys: ["Cmd", ","], action: "Settings"),
            Shortcut(keys: ["Cmd", "/"], action: "Keyboard shortcuts"),
        ]),
        ShortcutGroup(title: "In a chat", shortcuts: [
            Shortcut(keys: ["Cmd", "Return"], action: "Send"),
            Shortcut(keys: ["Shift", "Cmd", "A"], action: "Allow what a bot is asking to do"),
            Shortcut(keys: ["Shift", "Cmd", "D"], action: "Deny it"),
        ]),
        ShortcutGroup(title: "In a dialog", shortcuts: [
            Shortcut(keys: ["Return"], action: "Do what the pink button says"),
            Shortcut(keys: ["Esc"], action: "Cancel and close"),
        ]),
        ShortcutGroup(title: "In the menu bar panel", shortcuts: [
            Shortcut(keys: ["Cmd", "Q"], action: "Quit Bupsy"),
        ]),
    ]

    var body: some View {
        SheetFrame(title: "Keyboard shortcuts", icon: "keyboard",
                   subtitle: "Everything you can do without reaching for the mouse.",
                   width: 460, primaryVerb: "close", hints: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                    ForEach(Self.groups) { group in
                        section(group)
                    }
                }
            }
            .frame(maxHeight: 420)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func section(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(group.title)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    if index > 0 {
                        Rectangle().fill(palette.border).frame(height: 1)
                            .padding(.leading, Theme.Space.step)
                    }
                    HStack(spacing: Theme.Space.snug) {
                        Text(shortcut.action)
                            .font(Theme.Typography.body)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.snug)
                        HStack(spacing: 4) {
                            ForEach(shortcut.keys, id: \.self) { Keycap($0) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.step)
                    .frame(minHeight: 40)
                }
            }
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(palette.border, lineWidth: 1)
            }
        }
    }
}
