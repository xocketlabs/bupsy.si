import AppKit
import BupsyKit
import Combine
import SwiftUI

@main
struct BupsyApp: App {
    @NSApplicationDelegateAdaptor(BupsyAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @StateObject private var updater = Updater()
    /// Allow and Deny on approval banners. Made with the app so it is the notification delegate
    /// before launch finishes; attached to the model once the window's task runs.
    @State private var notificationActions = ApprovalNotificationActions()

    var body: some Scene {
        // One window, not a group. Opening it again (menu bar, notification) brings the existing
        // window forward or reopens a closed one, and there is no File > New Window to make a
        // second copy of the same roster.
        Window("Bupsy", id: MainWindow.id) {
            RootView()
                .environment(model)
                // Every link the window shows, bots' replies included, goes through this first.
                .environment(\.openURL, LinkGuard.action)
                .preferredColorScheme(model.appearance.scheme)
                // Below this the chat column gets too narrow to read and pages overflow.
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // launchd starts us with this flag when a routine is due. Run it before
                    // anything slow, so a 7am briefing is not waiting on an auth probe.
                    if CommandLine.arguments.contains("--run-due-routines") {
                        model.runDueRoutines()
                    }
                    notificationActions.attach(to: model)
                    model.startRoutineTimer()
                    #if DEBUG
                    if TourMode.isOn { Task { await TourMode.run(model: model) } }
                    #endif
                    model.startOutbox()
                    model.startFolderWatches()
                    model.refreshExecutor()
                    await model.refreshEngineStatus()
                }
                // Back from a sign-in or sign-out window in Terminal: ask the engines again, once.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshEngineStatusIfAuthChanged() }
                }
        }
        .defaultSize(width: 1280, height: 820)
        // Left as the standard window on purpose. `.hiddenTitleBar` is the look this design was
        // drawn for and what Grok Bot uses, but it has to be done with the close, minimise and
        // zoom buttons verifiably still reachable. Shipping a window someone cannot close is
        // not a trade worth making for a strip of chrome. Worth a deliberate pass, not a guess.
        .windowToolbarStyle(.unified)
        // The window cannot be dragged smaller than the root view's minimum frame.
        .windowResizability(.contentMinSize)
        .commands {
            UpdaterCommands(updater: updater)
            // Cmd N starts a chat, as the rail's plus does, instead of File > New Window.
            CommandGroup(replacing: .newItem) {
                NewChatCommand().environment(model)
            }
            // Bupsy > Pause all bots, beside Settings. No shortcut: it is not something to hit by
            // accident, and every obvious one is taken.
            CommandGroup(after: .appSettings) {
                PauseCommand().environment(model)
            }
            CommandGroup(after: .help) {
                Button("Keyboard shortcuts") {
                    NotificationCenter.default.post(name: .bupsyShowKeyboardShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        // Bupsy > Settings, Cmd comma. The scene provides both the menu item and the shortcut.
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
        }

        // Present whether or not the window is. A bot that works for ten minutes and then asks a
        // question should be able to reach you without the window coming forward.
        MenuBarExtra {
            // A drawn panel rather than a native menu, so bots show their live faces and a bot
            // that needs you can be answered right here. MenuBarView is the plain-menu fallback.
            MenuBarPanel()
                .environment(model)
                .environment(\.openURL, LinkGuard.action)
        } label: {
            // The label is always on screen, so it is also what reopens a closed window when
            // something without a view (a notification click) asks for it.
            MenuBarLabel()
                .modifier(MainWindowOpener())
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opens links with a look first at anything that is not a web page or an email.
///
/// A bot's reply is Markdown, and a link in it can point anywhere: `file:///…/Payload.app`,
/// `x-apple.systempreferences:`, another app's own scheme that acts on open. Without this a single
/// click in a reply, written by whatever the bot read, would launch it. Web and mail links open as
/// before; anything else shows the full address and opens only when the person says so.
@MainActor
enum LinkGuard {
    /// Schemes that open in a browser or mail app, never run anything themselves.
    static let safeSchemes: Set<String> = ["http", "https", "mailto"]

    static var action: OpenURLAction {
        // SwiftUI calls this on the main thread, from a click.
        OpenURLAction { url in
            MainActor.assumeIsolated {
                if let scheme = url.scheme?.lowercased(), safeSchemes.contains(scheme) {
                    return .systemAction
                }
                return confirm(url) ? open(url) : .discarded
            }
        }
    }

    private static func open(_ url: URL) -> OpenURLAction.Result {
        NSWorkspace.shared.open(url) ? .handled : .discarded
    }

    /// Asks before opening. Cancel is the default button, so Return does not open it.
    private static func confirm(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this link?"
        alert.informativeText = """
            It isn't a web link, so it may open a file or another app on your Mac.

            \(url.absoluteString)
            """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Keeps the app running when the window closes. Bots keep working and the menu bar item stays,
/// which a single `Window` scene would otherwise end by quitting the app.
@MainActor
final class BupsyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// File > New chat, Cmd N. Reopens the window if it was closed, then opens the palette.
private struct NewChatCommand: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New chat") {
            openWindow(id: MainWindow.id)
            NSApp.activate(ignoringOtherApps: true)
            model.startChat()
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// Bupsy > Pause all bots, or Resume bots while paused. The same toggle as the menu bar's.
private struct PauseCommand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isPaused ? "Resume bots" : "Pause all bots") {
            model.togglePause()
        }
    }
}

/// The sheets the root window presents, one at a time through a single `.sheet(item:)`.
/// Chained `.sheet` modifiers on one view do not all work: SwiftUI honours one and silently
/// drops the rest.
private enum RootSheet: Identifiable {
    case onboarding
    case newBot
    case newGroup
    case introduction(AppModel.PendingIntroduction)
    case creation(AppModel.PendingCreation)
    case jobChange(AppModel.PendingJobChange)

    var id: String {
        switch self {
        case .onboarding: "onboarding"
        case .newBot: "newBot"
        case .newGroup: "newGroup"
        case .introduction(let item): "introduction-\(item.id.uuidString)"
        case .creation(let item): "creation-\(item.id.uuidString)"
        case .jobChange(let item): "jobChange-\(item.id.uuidString)"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Worked out here from the scheme rather than read from the environment: this view is the
    /// one that publishes the palette (`withPalette` below), so the environment it reads still
    /// holds the dark default, which made the app tint dark pink in light mode.
    private var palette: Palette.Scheme { Palette.scheme(for: colorScheme) }
    @State private var destination: NavRail.Destination?
    /// What the panel shows: `destination`, one frame behind. A click answers in the sidebar at
    /// once, and the page, which takes longer to build, follows on the next frame. Built in the
    /// same frame, nothing on screen moved, not even the highlight, until the whole new chat was
    /// laid out, and a click that shows nothing for a tenth of a second feels ignored.
    @State private var panelDestination: NavRail.Destination?
    @State private var isStartingChat = false
    @State private var paletteSearchFirst = false
    @State private var isAddingBot = false
    @State private var isAddingGroup = false

    /// What the rail highlights when there is nothing to show: a bot id no bot has, so no row
    /// lights up. Falling back to Machines lit Machines while the panel showed the empty roster.
    private static let noHighlight = NavRail.Destination.bot(BotID(rawValue: ""))

    var body: some View {
        content
            .withPalette(colorScheme)
            .onChange(of: model.tourDestination) { _, new in if let new { go(to: new) } }
            .onChange(of: destination) { _, new in
                DispatchQueue.main.async { panelDestination = new }
            }
            .onChange(of: model.pendingDestination) { _, new in
                if let new { go(to: new); model.pendingDestination = nil }
            }
            // `open(_:)` from anywhere: Waiting on you, Usage, the menu bar, a notification.
            .onChange(of: model.navigationRequest) { _, new in
                if let new { go(to: new.destination); model.navigationRequest = nil }
            }
            // File > New chat (Cmd N), from AppModel.startChat.
            .onChange(of: model.startChatRequest) { _, new in
                if let new { startChat(searchFirst: new.searchFirst); model.startChatRequest = nil }
            }
            // A request made while the window was closed is waiting when it reopens, and
            // onChange does not fire for a value that was already there.
            .onAppear(perform: takeWaitingRequests)
            .onChange(of: model.tourPalette) { _, new in
                if let new { paletteSearchFirst = new; isStartingChat = true } else { isStartingChat = false }
            }
            .onChange(of: model.tourSheet) { _, new in
                isAddingBot = new == "newBot"; isAddingGroup = new == "newGroup"
                if new == "onboarding" { model.needsOnboarding = true } else if model.needsOnboarding && new == nil { model.needsOnboarding = false }
            }
            // Every root sheet through one presentation. See RootSheet.
            .sheet(item: sheetBinding) { sheet in
                // Its own palette: this sheet hangs off the root, outside withPalette above, so it
                // fell back to the dark default and showed a dark welcome in light mode.
                sheetContent(sheet)
                    .withPalette(colorScheme)
            }
    }

    /// Which sheet is up, in order: the welcome, then a sheet you opened yourself (so a bot's
    /// request arriving does not tear down a half-filled form), then the permission questions
    /// bots raise, one at a time and oldest first. A queue of permission dialogs stacked on each
    /// other is how people approve the one underneath without seeing it.
    private var currentSheet: RootSheet? {
        if model.needsOnboarding { return .onboarding }
        if isAddingBot { return .newBot }
        if isAddingGroup { return .newGroup }
        if let introduction = model.pendingIntroductions.first { return .introduction(introduction) }
        if let creation = model.pendingCreations.first { return .creation(creation) }
        if let change = model.pendingJobChanges.first { return .jobChange(change) }
        return nil
    }

    private var sheetBinding: Binding<RootSheet?> {
        Binding(
            get: { currentSheet },
            set: { new in
                // Only the sheets you opened close by being dismissed. Only the Start button
                // finishes onboarding: treating any dismissal as done marked it complete when
                // SwiftUI tore the sheet down on its own, so a new user could lose the welcome
                // without ever seeing it. The permission questions have no neutral way out;
                // answering them is what removes them from the queue.
                guard new == nil else { return }
                if isAddingBot { isAddingBot = false } else if isAddingGroup { isAddingGroup = false }
            }
        )
    }

    @ViewBuilder
    private func sheetContent(_ sheet: RootSheet) -> some View {
        switch sheet {
        case .onboarding:
            OnboardingSheet()
        case .newBot:
            BotCreatorSheet()
        case .newGroup:
            NewGroupSheet(onCreated: { group in go(to: .group(group.id)) })
        case .introduction(let introduction):
            // Dismissing without answering would drop the message silently, which is the
            // behaviour this whole feature exists to prevent.
            IntroductionSheet(introduction: introduction).interactiveDismissDisabled()
        case .creation(let creation):
            CreationSheet(creation: creation).interactiveDismissDisabled()
        case .jobChange(let change):
            JobChangeSheet(change: change).interactiveDismissDisabled()
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            NavRail(destination: Binding(
                get: { destination ?? model.bots.first.map { .bot($0.id) } ?? Self.noHighlight },
                set: { newValue in go(to: newValue) }
            ), onStartChat: { startChat(searchFirst: false) },
               onSearch: { startChat(searchFirst: true) })

            // The working surface floats inside the rail's colour with a small inset, which is
            // where this layout gets its depth: the panel reads as an object on a ground
            // rather than a second column butted against the first.
            // The inset is applied per page now rather than here, because a bot page owns its own
            // card: its details panel sits *outside* the card, on the window, like the rail.
            panel
        }
        // Over the whole window rather than in a sheet, so the thread you were reading stays
        // visible behind it and dismissing costs nothing.
        .overlay(alignment: .top) { paletteOverlay }
        .overlay(alignment: .top) { storageBanner }
        // Selecting a bot from inside the model (deleting or hiding the selected one) moves the
        // chat on screen along with it, but never pulls you off another page. Explicit "go there"
        // requests come through `open(_:)` instead.
        .onChange(of: model.selectedBotID) { _, id in followSelection(id) }
        .background(PaletteBackground())
        // One tint for the whole app, so system controls (segmented pickers, focus rings,
        // toggles) stop arriving in macOS blue next to a pink accent. Set once here rather than
        // remembered at each call site, which is how the blue got in.
        .tint(palette.primary)
    }

    /// The start-chat palette over a scrim. Clicking the scrim closes it, like any popover.
    @ViewBuilder
    private var paletteOverlay: some View {
        if isStartingChat {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { isStartingChat = false }
                    .accessibilityLabel("Close")
                    .accessibilityAddTraits(.isButton)

                StartChatPalette(
                    searchFirst: paletteSearchFirst,
                    onPick: { id in
                        isStartingChat = false
                        go(to: .bot(id))
                    },
                    onPickGroup: { id in
                        isStartingChat = false
                        go(to: .group(id))
                    },
                    onCreate: {
                        isStartingChat = false
                        if let id = model.quickCreateBot() { go(to: .bot(id)) }
                    },
                    onCreateManually: {
                        isStartingChat = false
                        isAddingBot = true
                    },
                    onCreateGroup: {
                        isStartingChat = false
                        isAddingGroup = true
                    },
                    onDismiss: { isStartingChat = false }
                )
                .frame(maxWidth: 640)
                // Never taller than the window has room for; the palette's list takes the cut.
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 90)
                .padding(.bottom, Theme.Space.gutter)
                .padding(.horizontal, Theme.Space.gutter)
            }
            .transition(.opacity)
        }
    }

    private func startChat(searchFirst: Bool) {
        paletteSearchFirst = searchFirst
        isStartingChat = true
    }

    /// The one way the window changes page. Opening a thread is what "reading" means, so a bot
    /// is marked read here, once, rather than in the page body on every redraw.
    private func go(to target: NavRail.Destination) {
        destination = target
        if case .bot(let id) = target {
            if model.selectedBotID != id { model.selectedBotID = id }
            if let bot = model.bots.first(where: { $0.id == id }) { model.markRead(bot) }
        }
    }

    /// Keeps a chat page in step with the selection without moving any other page.
    private func followSelection(_ id: BotID?) {
        switch destination {
        case .none, .some(.bot):
            break
        default:
            // On Team, Usage, a group and so on: the selection changing (a bot deleted or
            // hidden from Team) is not a reason to leave.
            return
        }
        if let id {
            guard destination != .bot(id) else { return }
            go(to: .bot(id))
        } else if case .bot(let shown) = destination, !model.bots.contains(where: { $0.id == shown }) {
            // The bot on screen is gone and nothing else is selected: the empty roster when no
            // bots are left, "No bot selected" otherwise.
            destination = nil
        }
    }

    /// Requests made before this view existed, as when a notification reopened the window.
    private func takeWaitingRequests() {
        if let request = model.navigationRequest {
            go(to: request.destination)
            model.navigationRequest = nil
        } else if let pending = model.pendingDestination {
            go(to: pending)
            model.pendingDestination = nil
        }
        if let request = model.startChatRequest {
            startChat(searchFirst: request.searchFirst)
            model.startChatRequest = nil
        }
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
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    // Two very different failures wear this banner, and saying the wrong one is
                    // its own problem: "nothing will be saved" is alarming and false when a
                    // single write failed on an otherwise healthy database.
                    Text(model.hasStore
                         ? "Something couldn't be saved."
                         : "Bupsy can't open its database, so nothing in this session will be saved.")
                        .font(Theme.Typography.body)
                        .fontWeight(.medium)
                    // The reassurance matters as much as the warning: the instinct on seeing an
                    // empty roster is to start recreating bots, which is the one action that
                    // could actually lose something.
                    Text(model.hasStore
                         ? problem
                         : "Your existing bots are still on disk, so don't recreate them. \(problem)")
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
    private var panel: some View {
        switch (panelDestination ?? destination) ?? model.bots.first.map({ .bot($0.id) }) {
        case .bot(let id):
            if let bot = model.bots.first(where: { $0.id == id }) {
                // No card here: BotPage draws its own, so its details panel can sit beside the
                // card on the window rather than inside it. See BotPage.body.
                // Keyed by the bot, so switching bots starts a fresh page: a draft, a reply-to or a
                // scroll position belongs to one conversation and must never follow you into the
                // next, where it could be sent to the wrong bot.
                BotPage(bot: bot)
                    .id(bot.id)
                    // A quick fade in, not a hard cut: the new chat arrives rather than snaps.
                    // In only, so the old page never lingers over the new one.
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.14)),
                        removal: .identity))
            } else if model.bots.isEmpty {
                // The last bot was just deleted: the empty roster, not "No bot selected".
                floating { RosterEmpty() }
            } else {
                floating { NothingSelected() }
            }
        case .machines:
            floating {
                Page(trail: ["Machines"]) { MachinesSheet() } actions: { NewMachineButton() }
            }
        case .connectors:
            floating {
                Page(trail: ["Apps"]) { ConnectorsSheet() } actions: { AddServerButton() }
            }
        case .permissions:
            floating { Page(trail: ["Permissions"]) { PermissionsPage() } }
        case .attention:
            floating { Page(trail: ["Waiting on you"]) { AttentionInbox() } }
        case .usage:
            // Draws its own topbar, so the breadcrumb can carry the period it is showing.
            floating { UsageSheet() }
        case .team:
            floating { TeamView(onOpen: { openBot($0) }) }
        case .groups:
            floating {
                Page(trail: ["Group chats"]) {
                    GroupsListView(onOpen: { go(to: .group($0)) })
                }
            }
        case .group(let id):
            if let group = model.groups.first(where: { $0.id == id }) {
                // Like a bot page, it draws its own card.
                // Keyed for the same reason as BotPage: a draft belongs to one group.
                GroupPage(group: group)
                    .id(group.id)
            } else {
                floating { NothingSelected() }
            }
        case .none:
            if model.bots.isEmpty {
                floating { RosterEmpty() }
            } else {
                floating { NothingSelected() }
            }
        }
    }

    /// Goes to a bot's thread from a page inside the panel, marking it read as the rail does.
    private func openBot(_ id: BotID) {
        go(to: .bot(id))
    }

    /// The floating card every page sits on: inset from the window on three sides and flush to
    /// the rail on the fourth, which is where the layout's depth comes from.
    private func floating<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        PanelSurface { content() }
            .padding([.top, .bottom, .trailing], Theme.Space.snug)
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
///
/// `actions` sit at the right of the topbar, where the boards put a page's primary action
/// ("Add a server", "New machine"). Pages without one leave it out.
struct Page<Content: View, Actions: View>: View {
    let trail: [String]
    let content: Content
    let actions: Actions

    init(trail: [String], @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.trail = trail
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Topbar(trail: trail) { actions }
            content
        }
    }
}

extension Page where Actions == EmptyView {
    init(trail: [String], @ViewBuilder content: () -> Content) {
        self.init(trail: trail, content: content) { EmptyView() }
    }
}

struct NothingSelected: View {
    var body: some View {
        EmptyState(title: "No bot selected", message: "Pick one on the left, or make a new one.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
