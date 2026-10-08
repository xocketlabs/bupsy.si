import BupsyKit
import SwiftUI

/// File › Continue a Claude Code Chat: the person's recent conversations in Claude Code (VS Code
/// or the terminal), to carry one on as a bot.
struct ClaudeChatsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ClaudeSession]?
    @State private var chosen: ClaudeSession.ID?
    @State private var moves = false

    var onContinued: (BotID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Continue a Claude Code chat")
                    .font(Theme.Typography.heading)
                    .foregroundStyle(palette.foreground)
                Text("Pick a conversation from VS Code or the terminal. It becomes a bot that works in the same folder and remembers everything said so far.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            list
                .frame(minHeight: 260, maxHeight: 380)

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Picker("", selection: $moves) {
                    Text("Copy and continue").tag(false)
                    Text("Move here").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Text(moves
                     ? "The same conversation carries on here. Don't keep using it in VS Code at the same time, or the two will tangle."
                     : "A copy carries on here, and the original stays exactly as it is, so you can keep using both.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("The bot is kept to this Mac. Change it in its Details.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .md))
                    .keyboardShortcut(.cancelAction)
                Button(moves ? "Move here" : "Continue") { carryOn() }
                    .buttonStyle(BupsyButtonStyle(kind: .primary, size: .md))
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(Theme.Space.section)
        .frame(width: 600)
        .background(palette.background)
        // Read off the main thread: there can be dozens of files, some very large.
        .task {
            // Not the conversations Bupsy's own bots have had: those are bots already.
            let known = (try? model.store?.knownProviderConversationIDs()) ?? []
            let botFolders = AppModel.workspacesDirectory.path
            let found = await Task.detached(priority: .userInitiated) {
                ClaudeSessions.recent(excluding: known, excludingFolder: botFolders)
            }.value
            sessions = found
            chosen = found.first?.id
        }
    }

    @ViewBuilder
    private var list: some View {
        if let sessions, !sessions.isEmpty {
            ScrollView {
                LazyVStack(spacing: Theme.Space.xs) {
                    ForEach(sessions) { session in row(session) }
                }
            }
        } else if sessions == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No Claude Code conversations on this Mac yet. Start one in VS Code or the terminal, then come back.")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ session: ClaudeSession) -> some View {
        let selected = chosen == session.id
        return Button {
            chosen = session.id
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Image(systemName: session.source == .vscode ? "chevron.left.forwardslash.chevron.right" : "terminal")
                    .font(.system(size: Theme.scaled(12)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text("\(PathShortener.shorten(session.folder, workingDirectory: nil)) · \(session.source.rawValue) · \(session.lastActive.formatted(.relative(presentation: .named)))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
            .background(selected ? palette.cardHover : palette.card, in: .rect(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(selected ? palette.primary.opacity(0.6) : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func carryOn() {
        guard let session = sessions?.first(where: { $0.id == chosen }),
              let bot = model.continueClaudeSession(session, as: moves ? .move : .copy) else { return }
        dismiss()
        onContinued(bot.id)
    }
}
