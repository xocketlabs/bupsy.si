import BupsyKit
import SwiftUI

@main
struct BupsyApp: App {
    @State private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // launchd starts us with this flag when a routine is due. Run it before
                    // anything slow, so a 7am briefing is not waiting on an auth probe.
                    if CommandLine.arguments.contains("--run-due-routines") {
                        model.runDueRoutines()
                    }
                    model.startRoutineTimer()
                    model.startOutbox()
                    await model.refreshEngineStatus()
                }
        }
        .defaultSize(width: 1000, height: 680)
        // Left as the standard window on purpose. `.hiddenTitleBar` is the look this design was
        // drawn for and what Grok Bot uses, but it has to be done with the close, minimise and
        // zoom buttons verifiably still reachable — shipping a window someone cannot close is
        // not a trade worth making for a strip of chrome. Worth a deliberate pass, not a guess.
        .windowToolbarStyle(.unified)
        .commands { UpdaterCommands(updater: updater) }

        // Present whether or not the window is. A bot that works for ten minutes and then asks a
        // question should be able to reach you without the window coming forward.
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.palette) private var palette
    @State private var destination: NavRail.Destination?
    @State private var isStartingChat = false
    @State private var isAddingBot = false

    var body: some View {
        content
            .withPalette(colorScheme)
            .sheet(isPresented: Binding(
                get: { model.needsOnboarding },
                set: { if !$0 { model.completeOnboarding() } }
            )) {
                OnboardingSheet()
            }
    }

    private var content: some View {
        HStack(spacing: 0) {
            NavRail(destination: Binding(
                get: { destination ?? model.bots.first.map { .bot($0.id) } ?? .machines },
                set: { newValue in
                    destination = newValue
                    if case .bot(let id) = newValue {
                        model.selectedBotID = id
                        // Opening a thread is what "reading" means. Done here rather than in the
                        // page body so it fires once on selection instead of on every redraw.
                        if let bot = model.bots.first(where: { $0.id == id }) {
                            model.markRead(bot)
                        }
                    }
                }
            ), onStartChat: { isStartingChat = true })

            // The working surface floats inside the rail's colour with a small inset, which is
            // where this layout gets its depth — the panel reads as an object on a ground
            // rather than a second column butted against the first.
            stage
                .padding(.leading, 0)
                .padding([.top, .bottom, .trailing], 8)
                // Over the conversation rather than in a sheet, so the thread you were reading
                // stays visible behind it and dismissing costs nothing.
                .overlay(alignment: .top) {
                    if isStartingChat {
                        StartChatPalette(
                            onPick: { id in
                                destination = .bot(id)
                                model.selectedBotID = id
                                if let bot = model.bots.first(where: { $0.id == id }) {
                                    model.markRead(bot)
                                }
                                isStartingChat = false
                            },
                            onCreate: {
                                isStartingChat = false
                                isAddingBot = true
                            },
                            onDismiss: { isStartingChat = false }
                        )
                        .padding(.top, 60)
                        .transition(.opacity)
                    }
                }
        }
        .overlay(alignment: .top) { storageBanner }
        // Anything that sets the selected bot — the attention inbox's "Open", the menu bar, a
        // notification — now actually goes there. The page was driven by local state alone, so
        // setting `selectedBotID` from anywhere else changed a value nothing was watching, and
        // "Open" did nothing at all.
        .onChange(of: model.selectedBotID) { _, id in
            guard let id, destination != .bot(id) else { return }
            destination = .bot(id)
            if let bot = model.bots.first(where: { $0.id == id }) { model.markRead(bot) }
        }
        .background(PaletteBackground())
        // One tint for the whole app, so system controls — segmented pickers, focus rings,
        // toggles — stop arriving in macOS blue next to a pink accent. Set once here rather than
        // remembered at each call site, which is how the blue got in.
        .tint(palette.primary)
        .sheet(isPresented: $isAddingBot) { NewBotSheet() }
    }

    /// Says so when the database could not be opened.
    ///
    /// `storageProblem` has been set on failure since the beginning and displayed nowhere, with a
    /// comment claiming the opposite. The effect was the worst possible version of this failure:
    /// a database that would not open produced a roster of fresh starter bots and no explanation,
    /// so it looked exactly like every bot had been deleted. The data was intact on disk the whole
    /// time. Stating it plainly is the difference between a bug and a catastrophe.
    @ViewBuilder
    private var storageBanner: some View {
        if let problem = model.storageProblem {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Theme.scaled(11)))
                VStack(alignment: .leading, spacing: 2) {
                    // Two very different failures wear this banner, and saying the wrong one is
                    // its own problem: "nothing will be saved" is alarming and false when a
                    // single write failed on an otherwise healthy database.
                    Text(model.hasStore
                         ? "Something couldn't be saved."
                         : "bupsy can't open its database, so nothing in this session will be saved.")
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                    // The reassurance matters as much as the warning: the instinct on seeing an
                    // empty roster is to start recreating bots, which is the one action that
                    // could actually lose something.
                    Text(model.hasStore
                         ? problem
                         : "Your existing bots are still on disk — don't recreate them. \(problem)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.foreground.opacity(0.8))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.snug)
            .background(palette.destructive.opacity(0.9))
            .clipShape(.rect(cornerRadius: Theme.Radius.control))
            .padding(Theme.Space.snug)
        }
    }

    @ViewBuilder
    private var stage: some View {
        panel
            // One at a time, oldest first: a queue of permission dialogs stacked on each other is
            // how people approve the one underneath without seeing it.
            //
            // Attached here rather than beside the new-bot sheet because two `.sheet` modifiers
            // on the same view do not both work — SwiftUI honours one and silently drops the
            // other, which is exactly what happened: the message was consumed and nothing asked.
            .sheet(item: Binding(
                get: { model.pendingIntroductions.first },
                set: { _ in }
            )) { introduction in
                IntroductionSheet(introduction: introduction)
                    // There is no neutral way out of a permission question. Dismissing without
                    // answering would drop the message silently, which is the behaviour this
                    // whole feature exists to prevent.
                    .interactiveDismissDisabled()
            }
    }

    @ViewBuilder
    private var panel: some View {
        PanelSurface {
            switch destination ?? model.bots.first.map({ .bot($0.id) }) {
            case .bot(let id):
                if let bot = model.bots.first(where: { $0.id == id }) {
                    BotPage(bot: bot)
                } else {
                    NothingSelected()
                }
            case .machines:
                Page(trail: ["Machines"]) { MachinesSheet() }
            case .connectors:
                Page(trail: ["Apps"]) { ConnectorsSheet() }
            case .attention:
                Page(trail: ["Waiting on you"]) { AttentionInbox() }
            case .none:
                NothingSelected()
            }
        }
    }
}

/// The rounded panel the whole app works inside.
struct PanelSurface<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
            .clipShape(.rect(cornerRadius: Theme.Radius.card))
    }
}

private struct PaletteBackground: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.sidebar.ignoresSafeArea() }
}

/// A page under the topbar. Everything in the panel wears the same chrome, so moving between a
/// bot and the machines list does not feel like crossing into a different application.
struct Page<Content: View>: View {
    let trail: [String]
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: trail) { EmptyView() }
            content
        }
    }
}

struct NothingSelected: View {
    @Environment(\.palette) private var palette
    var body: some View {
        VStack(spacing: Theme.Space.step) {
            Text("No bot selected")
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            Text("Pick one on the left, or make a new one.")
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
