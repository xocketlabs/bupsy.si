import BupsyKit
import SwiftUI

/// The nav rail: brand, grouped destinations, and who you are signed in as.
///
/// Grouped with labels rather than listed flat. A flat list of bots and settings makes a bot and
/// a settings screen look like the same kind of thing; the labels say which are the people you
/// talk to and which is the machinery behind them.
struct NavRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    @Binding var destination: Destination
    @State private var isAddingBot = false

    enum Destination: Hashable {
        case bot(BotID)
        case machines
        case connectors
        case attention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            brand
            attention

            group("Bots") {
                ForEach(model.bots) { bot in
                    NavItem(
                        selected: destination == .bot(bot.id),
                        action: { destination = .bot(bot.id) }
                    ) {
                        BotFace(hue: bot.avatarHue, mood: mood(for: bot), size: 22)
                        Text(bot.name)
                        Spacer(minLength: Theme.Space.snug)
                        trailing(for: bot)
                    }
                    .contextMenu { BotMenu(bot: bot) }
                    .keyboardShortcut(shortcut(for: bot), modifiers: .command)
                }

                NavItem(selected: false, action: { isAddingBot = true }) {
                    Image(systemName: "plus").font(.system(size: 12)).frame(width: 22)
                    Text("New bot")
                    Spacer(minLength: 0)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            group("Setup") {
                NavItem(
                    selected: destination == .machines,
                    action: { destination = .machines }
                ) {
                    Image(systemName: "server.rack").font(.system(size: 12)).frame(width: 22)
                    Text("Machines")
                    Spacer(minLength: 0)
                    count(model.machines.count)
                }
                NavItem(
                    selected: destination == .connectors,
                    action: { destination = .connectors }
                ) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 12)).frame(width: 22)
                    Text("Apps")
                    Spacer(minLength: 0)
                    count(model.connectors.count)
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 22)
        .padding(.bottom, Theme.Space.gutter)
        .frame(width: 276)
        .background(palette.sidebar)
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
    }

    /// Appears only when something is waiting.
    ///
    /// Previously this was a permanent tray with a count that was usually zero — furniture people
    /// stop seeing, which is the opposite of what a thing called "needs you" should be. Absent
    /// until it matters, it gets noticed the one time it does.
    @ViewBuilder
    private var attention: some View {
        let items = model.attentionItems
        if !items.isEmpty {
            Button { destination = .attention } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11))
                    Text(items.count == 1 ? "1 needs you" : "\(items.count) need you")
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }
                .foregroundStyle(palette.primary)
                .padding(.horizontal, Theme.Space.step)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background(palette.primary.opacity(0.13),
                            in: .rect(cornerRadius: Theme.Radius.control))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var brand: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(
                    colors: [palette.primary, palette.info],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 20, height: 20)
            Text("bupsy")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.foreground)
            Spacer(minLength: Theme.Space.snug)
            Text(model.bots.count == 1 ? "1 bot" : "\(model.bots.count) bots")
                .font(Theme.Typography.badge)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, Theme.Space.snug)
                .padding(.vertical, 5)
                .background(palette.background, in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func group<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Typography.badge)
                .foregroundStyle(palette.sidebarMuted)
                .tracking(0.7)
                .padding(.horizontal, Theme.Space.snug)
                .padding(.bottom, Theme.Space.snug)
            content()
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.snug) {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(palette.sidebarAccent)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedForeground)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("You").font(Theme.Typography.label).foregroundStyle(palette.foreground)
                // The engines, because that is the only account this app has any notion of.
                Text(engineSummary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.sidebarMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.snug)
    }

    private var engineSummary: String {
        let ready = EngineID.allCases.filter { model.engineStatus[$0]?.isUsable == true }
        return ready.isEmpty ? "No engine signed in" : ready.map(\.displayName).joined(separator: " · ")
    }

    /// ⌘1 … ⌘9 for the first nine bots, in the order they appear.
    private func shortcut(for bot: Bot) -> KeyEquivalent {
        guard let index = model.bots.firstIndex(where: { $0.id == bot.id }), index < 9 else {
            // No shortcut rather than a wrong one: KeyEquivalent has no "none", so a bot past
            // the ninth gets a key nobody presses.
            return KeyEquivalent("\u{0}")
        }
        return KeyEquivalent(Character("\(index + 1)"))
    }

    private func mood(for bot: Bot) -> BotMood {
        if model.isWaitingForApproval(bot.id) { return .waitingForYou }
        if model.isRunning(bot.id) { return .working }
        return .idle
    }

    @ViewBuilder
    private func trailing(for bot: Bot) -> some View {
        if model.isWaitingForApproval(bot.id) {
            Text("needs you")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.primary)
        } else if model.isRunning(bot.id) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
        }
    }

    private func count(_ value: Int) -> some View {
        Text(value == 0 ? "" : "\(value)")
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.sidebarMuted)
    }
}

struct NavItem<Content: View>: View {
    @Environment(\.palette) private var palette
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                content
            }
            .font(Theme.Typography.body)
            .foregroundStyle(selected ? palette.foreground : palette.sidebarMutedForeground)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return palette.sidebarAccent }
        return hovering ? palette.sidebarAccent.opacity(0.55) : .clear
    }
}
