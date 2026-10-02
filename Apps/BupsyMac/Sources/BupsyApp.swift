import BupsyKit
import SwiftUI

@main
struct BupsyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.refreshEngineStatus() }
        }
        .defaultSize(width: 1000, height: 680)
        .windowToolbarStyle(.unified)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
