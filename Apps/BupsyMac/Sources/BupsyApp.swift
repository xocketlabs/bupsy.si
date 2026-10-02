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

    var body: some View {
        content
            .sheet(isPresented: Binding(
                get: { model.needsOnboarding },
                set: { if !$0 { model.completeOnboarding() } }
            )) {
                OnboardingSheet()
            }
    }

    private var content: some View {
        NavigationSplitView {
            RosterView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let bot = model.selectedBot {
                ThreadView(bot: bot)
            } else {
                ContentUnavailableView("No bot selected", systemImage: "person.2")
            }
        }
    }
}
