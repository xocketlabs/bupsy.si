import SwiftUI

/// The home screen: every bot on the Mac, in its sidebar's order, with who needs the person first
/// to the eye.
struct BotListView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    @State private var confirmForget = false

    var body: some View {
        @Bindable var session = session
        NavigationStack(path: $session.path) {
            List {
                header
                    .listRowBackground(palette.sidebar)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 6, trailing: 16))

                if session.bots.isEmpty {
                    Text("No bots yet. Make one in Bupsy on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(palette.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .listRowBackground(palette.sidebar)
                        .listRowSeparator(.hidden)
                }

                ForEach(BotSection.group(session.bots)) { section in
                    Section {
                        ForEach(section.bots) { bot in
                            Button { session.path.append(bot.id) } label: { BotRow(bot: bot) }
                                .listRowBackground(palette.sidebar)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .foregroundStyle(palette.mutedForeground)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(palette.sidebar)
            .refreshable { await session.refreshBots() }
            .overlay(alignment: .top) {
                if session.offline { OfflineBanner() }
            }
            .animation(.default, value: session.offline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Forget this Mac", systemImage: "xmark.circle", role: .destructive) {
                            confirmForget = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .toolbarBackground(palette.sidebar, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { botID in
                ChatView(botID: botID, session: session)
            }
        }
        .forgetMacDialog(isPresented: $confirmForget)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Wordmark(size: 28)
                Text(session.mac)
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedForeground)
            }
            Spacer(minLength: 0)
            if session.waiting > 0 {
                Button(action: openFirstWaiting) {
                    HStack(spacing: 6) {
                        Circle().fill(palette.primary).frame(width: 8, height: 8)
                        Text("\(session.waiting) waiting on you")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.you, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityHint("Opens the first bot that needs you")
            }
        }
    }

    private func openFirstWaiting() {
        if let bot = session.bots.first(where: \.needsYou) { session.path.append(bot.id) }
    }
}

/// One bot: its colour and initial, name and role, what it last said, and whether it needs you.
private struct BotRow: View {
    @Environment(\.palette) private var palette
    let bot: Bot

    var body: some View {
        HStack(spacing: 12) {
            Avatar(bot: bot, size: Theme.Size.listAvatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bot.name.isEmpty ? "Bot" : bot.name)
                        .font(.body.weight(bot.unread ? .bold : .medium))
                        .lineLimit(1)
                    if let role = bot.role, !role.isEmpty {
                        Text(role)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(palette.cardHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .lineLimit(1)
                    }
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(bot.unread ? palette.foreground : palette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 6)
        .foregroundStyle(palette.foreground)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var status: some View {
        if bot.needsYou {
            Circle().fill(palette.primary).frame(width: 10, height: 10)
        } else if bot.running {
            WorkingDots()
        }
    }

    private var preview: String {
        if let preview = bot.preview, !preview.isEmpty { return preview }
        return bot.running ? "Working…" : "Nothing yet"
    }

    private var label: String {
        var parts = [bot.name]
        if let role = bot.role { parts.append(role) }
        if bot.needsYou { parts.append("waiting on you") } else if bot.running { parts.append("working") }
        if bot.unread { parts.append("unread") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}
