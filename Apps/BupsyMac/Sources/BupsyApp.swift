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
                    await model.refreshEngineStatus()
                }
        }
        .defaultSize(width: 1000, height: 680)
        .windowToolbarStyle(.unified)
        .commands { UpdaterCommands(updater: updater) }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var destination: NavRail.Destination?

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
                    if case .bot(let id) = newValue { model.selectedBotID = id }
                }
            ))

            // The working surface floats inside the rail's colour with a small inset, which is
            // where this layout gets its depth — the panel reads as an object on a ground
            // rather than a second column butted against the first.
            stage
                .padding(.leading, 0)
                .padding([.top, .bottom, .trailing], 8)
        }
        .background(PaletteBackground())
    }

    @ViewBuilder
    private var stage: some View {
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
