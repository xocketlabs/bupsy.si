import AppKit
import BupsyKit
import Foundation
import SwiftUI

/// A request for the window to show a page.
///
/// Carries its own id so that asking for the page already on screen still counts as a change.
/// "Open" on a bot that is already selected used to set a value to what it already was, which
/// nothing observes, so the click did nothing while you were on another page.
struct NavigationRequest: Equatable {
    let destination: NavRail.Destination
    let id: UUID

    init(destination: NavRail.Destination, id: UUID = UUID()) {
        self.destination = destination
        self.id = id
    }
}

/// A request to open the start-chat palette, from somewhere other than the rail's plus button
/// (the Cmd N menu command). Same id trick as `NavigationRequest`.
struct StartChatRequest: Equatable {
    let searchFirst: Bool
    let id: UUID

    init(searchFirst: Bool, id: UUID = UUID()) {
        self.searchFirst = searchFirst
        self.id = id
    }
}

/// The one main window. A single `Window` scene, so opening it again brings the existing one
/// forward instead of making a second copy.
enum MainWindow {
    static let id = "main"
}

extension AppModel {
    /// Goes to a bot's chat. Always honoured by the root view, even when that bot is already the
    /// selected one and you are looking at some other page.
    func open(_ botID: BotID) {
        selectedBotID = botID
        navigationRequest = NavigationRequest(destination: .bot(botID))
    }

    /// Goes to any page in the window.
    func open(_ destination: NavRail.Destination) {
        if case .bot(let id) = destination {
            open(id)
            return
        }
        navigationRequest = NavigationRequest(destination: destination)
    }

    /// Opens the start-chat palette, as the rail's plus button does.
    func startChat(searchFirst: Bool = false) {
        startChatRequest = StartChatRequest(searchFirst: searchFirst)
    }

    /// Brings the main window forward from outside it (a notification), reopening it if it was
    /// closed. Views that can reach `openWindow` call it directly; this is for code that cannot,
    /// and is picked up by the menu bar icon, which is always on screen.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        windowRequest = UUID()
    }
}

/// Opens the main window when the model asks for it. Hung on the menu bar icon, the one view
/// that exists whether or not the window does.
struct MainWindowOpener: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: model.windowRequest) { _, request in
                guard request != nil else { return }
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
                model.windowRequest = nil
            }
    }
}
