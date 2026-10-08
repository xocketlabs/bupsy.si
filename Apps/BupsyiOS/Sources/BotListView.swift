import SwiftUI

/// The home screen: every bot on every paired Mac in one list, in their sidebars' order, with who
/// needs the person first to the eye.
struct BotListView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    @State private var adding: AddMac?

    var body: some View {
        @Bindable var session = session
        let sections = session.sections
        NavigationStack(path: $session.path) {
            List {
                header
                    .listRowBackground(palette.sidebar)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 6, trailing: 16))

                ForEach(session.macs.filter(\.unpaired)) { mac in
                    LostMacRow(mac: mac) { adding = AddMac(address: mac.address.absoluteString) }
                        .listRowBackground(palette.sidebar)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                if sections.isEmpty {
                    Text(session.pairedMacs.count > 1 ? "No bots yet. Make one in Bupsy on one of your Macs."
                                                      : "No bots yet. Make one in Bupsy on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(palette.mutedForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .listRowBackground(palette.sidebar)
                        .listRowSeparator(.hidden)
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.bots) { listed in
                            Button { session.path.append(listed.id) } label: { BotRow(listed: listed) }
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
            .refreshable { await session.refreshAll() }
            .overlay(alignment: .top) {
                if !session.offlineMacs.isEmpty { OfflineBanner(text: offlineText) }
            }
            .animation(.default, value: session.offlineMacs.map(\.id))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a Mac", systemImage: "plus") {
                            adding = AddMac(address: "")
                        }
                        Button("Your Macs", systemImage: "desktopcomputer") {
                            session.showingMacs = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .toolbarBackground(palette.sidebar, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BotRef.self) { ref in
                ChatView(ref: ref, session: session)
            }
        }
        .sheet(item: $adding) { add in
            AddMacSheet(address: add.address)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Wordmark(size: 28)
                Text(session.pairedMacs.map(\.displayName).formatted(.list(type: .and)))
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(2)
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

    /// "Can't reach your Mac" with one Mac; with several, which ones.
    private var offlineText: String {
        let offline = session.offlineMacs
        if session.pairedMacs.count == 1 { return "Can't reach your Mac. Retrying…" }
        return "Can't reach \(offline.map(\.displayName).formatted(.list(type: .and))). Retrying…"
    }

    private func openFirstWaiting() {
        if let listed = session.listed.first(where: { $0.bot.needsYou && $0.online }) {
            session.path.append(listed.id)
        }
    }
}

/// A Mac that removed this phone, while others still work: which one, and a way back.
private struct LostMacRow: View {
    @Environment(\.palette) private var palette
    let mac: PairedMac
    let pairAgain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mac.symbol)
                .foregroundStyle(palette.mutedForeground)
                .accessibilityHidden(true)
            Text("\(mac.displayName) isn't paired with this iPhone any more.")
                .font(.footnote)
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Pair again", action: pairAgain)
                .buttonStyle(.bupsySecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// One bot: its colour and initial, name and role, the Mac it's on when there's more than one,
/// what it last said, and whether it needs you. Greyed while its Mac can't be reached.
private struct BotRow: View {
    @Environment(\.palette) private var palette
    let listed: ListedBot

    private var bot: Bot { listed.bot }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(bot: bot, size: Theme.Size.listAvatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(listed.name.isEmpty ? "Bot" : listed.name)
                        .font(.body.weight(bot.unread ? .bold : .medium))
                        .lineLimit(1)
                    // Lives on this Mac: its kind, quiet, beside the name, as the Mac app marks it.
                    if listed.showsMac {
                        Image(systemName: listed.mac.symbol)
                            .font(.caption)
                            .foregroundStyle(palette.mutedForeground)
                    }
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
                    .foregroundStyle(bot.unread && listed.online ? palette.foreground : palette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, 6)
        .foregroundStyle(palette.foreground)
        .opacity(listed.online ? 1 : 0.5)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var status: some View {
        if bot.needsYou {
            Circle().fill(palette.primary).frame(width: 10, height: 10)
        } else if bot.running, listed.online {
            WorkingDots()
        }
    }

    private var preview: String {
        if !listed.online { return "\(listed.mac.displayName) is offline" }
        if let preview = bot.preview, !preview.isEmpty { return preview }
        return bot.running ? "Working…" : "Nothing yet"
    }

    private var label: String {
        var parts = [listed.name]
        if let role = bot.role { parts.append(role) }
        if listed.showsMac, listed.online { parts.append("on \(listed.mac.displayName)") }
        if bot.needsYou { parts.append("waiting on you") } else if bot.running { parts.append("working") }
        if bot.unread { parts.append("unread") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}
