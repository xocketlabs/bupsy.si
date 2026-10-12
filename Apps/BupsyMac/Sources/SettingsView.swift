import AppKit
import BupsyKit
import Combine
import SwiftUI

/// The panes of Settings, in the order its left column lists them.
///
/// One pane per group the old Settings window stacked, under the same names, so "Settings › Use
/// from other devices" in the README, the web app's pairing hint and the move-a-bot errors still
/// names a place you can find.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case appearance, engines, otherDevices, otherMacs, lidClosed, voice, about

    var id: String { rawValue }

    /// The pane's name in the left column and the breadcrumb.
    var label: String {
        switch self {
        case .appearance: "Appearance"
        case .engines: "Engines"
        case .otherDevices: "Use from other devices"
        case .otherMacs: "Other Macs"
        case .lidClosed: "Lid closed"
        case .voice: "Voice"
        case .about: "About"
        }
    }

    /// The heading over the pane. Only the lid's is longer than its label, which would not fit
    /// the left column.
    var title: String {
        self == .lidClosed ? "Keep working with the lid closed" : label
    }

    /// The sentence under the heading: what the pane is for, before any of its controls.
    var summary: String {
        switch self {
        case .appearance: "How Bupsy looks on this Mac"
        case .engines: "The AI your bots run on, and whether each one is signed in"
        case .otherDevices: "Chat with your bots from your phone or another Mac, away from this one"
        case .otherMacs: "See and talk to the bots on your other Macs, here"
        case .lidClosed: "Let bots carry on when you close this Mac's lid"
        case .voice: "Hear replies read aloud, and talk to bots instead of typing"
        case .about: "This copy of Bupsy"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .engines: "chevron.left.forwardslash.chevron.right"
        case .otherDevices: "iphone"
        case .otherMacs: "laptopcomputer"
        case .lidClosed: "moon.zzz"
        case .voice: "waveform"
        case .about: "info.circle"
        }
    }
}

/// Settings: a page in the main window like Machines and Usage, reached from Setup in the
/// sidebar, the You menu and Bupsy › Settings (Cmd comma).
///
/// It used to be a window of its own, which sat over the chats and could not be moved between
/// like every other page. Now it is the panes on the left and the chosen one on the right, so
/// something that sends you to one setting ("Link it again in Settings › Other Macs") lands on it.
///
/// Only what the app really has today: how it looks, which engines are signed in, using it from
/// other devices, other Macs, keeping the Mac awake with the lid closed, voice, and what build
/// this is. Each engine's own sign-in and sign-out run its CLI in Terminal (see
/// `AppModel+Account.swift`); this page shows the verdict and never anything more.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var model = model
        Page(trail: ["Settings", model.settingsPane.label]) {
            GeometryReader { proxy in
                // In a narrow window the names would leave the pane a sliver, so the column keeps
                // only its icons; the breadcrumb and each icon's tooltip still name the pane.
                let compact = proxy.size.width < Self.compactBelow
                HStack(spacing: 0) {
                    SettingsIndex(selection: $model.settingsPane, compact: compact)
                    Rectangle().fill(palette.border).frame(width: 1)
                    SettingsPaneView(pane: model.settingsPane)
                        // Each pane starts at its top, not wherever the last one was scrolled to.
                        .id(model.settingsPane)
                }
            }
        }
    }

    /// The panel width under which the left column drops its names: below this, a full column
    /// leaves the pane narrower than the old Settings window was.
    private static let compactBelow: CGFloat = 820
}

/// The left column: every pane, drawn as the sidebar's own rows so it reads as the same kind of
/// place.
private struct SettingsIndex: View {
    @Binding var selection: SettingsPane
    var compact = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                ForEach(SettingsPane.allCases) { pane in
                    if compact {
                        SettingsIconRow(pane: pane, selected: selection == pane) { selection = pane }
                    } else {
                        SidebarNavRow(icon: pane.icon, label: pane.label, selected: selection == pane) {
                            selection = pane
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? Theme.Space.snug : Theme.Space.step)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.section)
        }
        .frame(width: compact ? 60 : 256)
    }
}

/// A pane as its icon alone, for the narrow column. Same ink and fill as a sidebar row.
private struct SettingsIconRow: View {
    @Environment(\.palette) private var palette
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pane.icon)
                .font(.system(size: Theme.scaled(13)))
                .foregroundStyle(SidebarRowInk.text(selected: selected, hovering: hovering, needs: false,
                                                    palette: palette))
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.row)
                .background(SidebarRowInk.fill(selected: selected, hovering: hovering, palette: palette),
                            in: .rect(cornerRadius: Theme.Radius.lg))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pane.label)
        .accessibilityLabel(pane.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One pane: its heading, then its settings, scrolling on their own.
private struct SettingsPaneView: View {
    let pane: SettingsPane
    /// The engine "Sign out" was clicked for, until the person confirms.
    @State private var signingOut: EngineID?

    /// A settings column, not the whole width: a switch at the far end of a 1000pt row is too far
    /// from the words it belongs to.
    private static let columnWidth: CGFloat = 640

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SetupPageHeader(title: pane.title, description: pane.summary)
                content
                    // The heading above names the pane, so a card's own small title would only
                    // say it again.
                    .environment(\.settingsGroupShowsTitle, false)
            }
            .padding(.horizontal, Theme.Space.pageSide)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.page)
            .frame(maxWidth: Self.columnWidth + Theme.Space.pageSide * 2, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmsSignOut($signingOut)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .appearance: AppearanceSettingsSection()
        case .engines: EnginesSettingsSection(signingOut: $signingOut)
        case .otherDevices: RemoteSettingsSection()
        case .otherMacs: LinkedMacsSection()
        case .lidClosed: LidSleepSection()
        case .voice: VoiceSettingsSection()
        case .about: AboutSettingsSection()
        }
    }
}

// MARK: - Appearance

/// Settings › Appearance: light, dark, or as the Mac is set.
private struct AppearanceSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Appearance") {
            // "Appearance", the word the You menu uses for the same setting.
            SettingRow(label: "Appearance", value: model.appearance.label,
                       icon: "circle.lefthalf.filled", showsDivider: false) {
                ForEach(AppModel.Appearance.allCases, id: \.self) { option in
                    Button {
                        model.appearance = option
                    } label: {
                        if option == model.appearance {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Engines

/// Settings › Engines: each engine's sign-in, and the way to change it.
private struct EnginesSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var checking = false
    /// Owned by the pane, which hangs the confirmation, so it outlives a redraw of this list.
    @Binding var signingOut: EngineID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SettingsGroup(title: "Engines") {
                ForEach(Array(EngineID.supported.enumerated()), id: \.element) { index, engine in
                    engineRow(engine, showsDivider: index > 0)
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.step) {
                Text("Sign-in and sign-out open the engine's own command in Terminal. "
                     + "Your sign-in stays with the CLI. Bupsy only learns whether it worked.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.snug)
                Button(checking ? "Checking…" : "Check again") {
                    checking = true
                    Task {
                        await model.refreshEngineStatus()
                        checking = false
                    }
                }
                .buttonStyle(QuietButton(compact: true))
                .disabled(checking)
            }
            .padding(.horizontal, Theme.Space.hairline)
            // A sign-in or sign-out that could not even open Terminal says so, rather than
            // leaving the button looking like it did nothing.
            if let problem = model.accountProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.hairline)
            }
            // Never hidden: each engine can also run on an API key, and saying so is part of not
            // restricting any of its sign-in methods.
            Text("Prefer an API key? Claude Code offers Anthropic Console during its own sign-in, "
                 + "and Codex lists its API key option under codex login --help.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.hairline)
        }
        // Coming back from Terminal is handled once, by the window: it asks the engines again if
        // a sign-in or sign-out was opened. See BupsyApp.
    }

    private func engineRow(_ engine: EngineID, showsDivider: Bool) -> some View {
        let status = model.engineStatus[engine]
        let signedIn = model.isSignedIn(engine)
        return VStack(spacing: 0) {
            if showsDivider {
                Rectangle().fill(palette.border).frame(height: 1)
                    .padding(.leading, Theme.Space.step)
            }
            HStack(spacing: Theme.Space.step) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: Theme.scaled(11), weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: Theme.Size.controlSm + Theme.Space.xs,
                           height: Theme.Size.controlSm + Theme.Space.xs)
                    .background(palette.sidebar, in: .rect(cornerRadius: Theme.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(palette.border)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    HStack(spacing: Theme.Space.tight) {
                        Text(engine.displayName)
                            .font(Theme.Typography.body.weight(.medium))
                            .foregroundStyle(palette.foreground)
                        Circle()
                            .fill(dotColour(status))
                            .frame(width: 6, height: 6)
                            // Colour alone says ready or not; say it in words too.
                            .accessibilityLabel(dotLabel(status))
                    }
                    Text(AppModel.accountStatusLine(status))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(2)
                        .help(AppModel.accountStatusLine(status))
                }
                Spacer(minLength: Theme.Space.snug)
                if status != nil {
                    if signedIn {
                        Button("Sign out…") { signingOut = engine }
                            .buttonStyle(QuietButton(compact: true))
                            .help("Opens Terminal and runs \(engine.displayName)'s own sign-out command")
                    } else {
                        Button("Sign in") { model.openSignIn(for: engine) }
                            .buttonStyle(QuietButton(compact: true))
                            .help("Opens Terminal and runs \(engine.displayName)'s own sign-in")
                    }
                }
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
            .frame(minHeight: 52)
        }
    }

    private func dotLabel(_ status: AuthStatus?) -> String {
        guard let status else { return "Checking" }
        return status.isUsable ? "Ready" : "Needs attention"
    }

    private func dotColour(_ status: AuthStatus?) -> Color {
        guard let status else { return palette.mutedForeground }
        return status.isUsable ? palette.success : palette.warning
    }
}

// MARK: - About

/// Settings › About: which build this is, and where new ones come from.
private struct AboutSettingsSection: View {
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup(title: "About") {
            HStack(spacing: Theme.Space.gutter) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text("Bupsy")
                        .font(Theme.Typography.heading)
                        .foregroundStyle(palette.foreground)
                    Text(Self.versionLine)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    Text("Source-available under PolyForm Shield 1.0.0. No telemetry.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    // The bundled libraries' licences require their notices to travel with the
                    // app; this is where a person can read them.
                    if let notices = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        Button("Third-party licences") { NSWorkspace.shared.open(notices) }
                            .buttonStyle(.link)
                            .font(Theme.Typography.caption)
                    }
                }
                Spacer(minLength: Theme.Space.snug)
                // No update feed yet (GitHub Releases only), so this says what it does rather than
                // pretending to check. Matches the app menu's "Releases on GitHub…".
                Button("Check releases on GitHub") { NSWorkspace.shared.open(Updater.releasesURL) }
                    .buttonStyle(QuietButton(compact: true))
                    // In a narrow window the lines beside it wrap rather than the button's name
                    // being cut short.
                    .fixedSize()
                    .help("Opens the releases page, where new versions are published")
            }
            .padding(Theme.Space.step)
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty, build != version {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }
}

// MARK: - Group titles

private struct SettingsGroupShowsTitleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False inside a Settings pane, whose heading already names the one card under it. A bot's
    /// details keep their cards' titles ("Runs on", "Tokens"), where several sit together.
    var settingsGroupShowsTitle: Bool {
        get { self[SettingsGroupShowsTitleKey.self] }
        set { self[SettingsGroupShowsTitleKey.self] = newValue }
    }
}
