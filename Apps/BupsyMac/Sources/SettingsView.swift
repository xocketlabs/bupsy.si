import AppKit
import BupsyKit
import Combine
import SwiftUI

/// Bupsy > Settings (Cmd comma).
///
/// Only what the app really has today: how it looks, which engines are signed in, using it from
/// other devices, keeping the Mac awake with the lid closed, and what build this is. Each engine's own sign-in and sign-out run its CLI in Terminal (see
/// `AppModel+Account.swift`); this window shows the verdict and never anything more.
struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsContent()
            .withPalette(colorScheme)
    }
}

private struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var checking = false
    /// The engine "Sign out" was clicked for, until the person confirms.
    @State private var signingOut: EngineID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                appearance
                engines
                RemoteSettingsSection()
                LidSleepSection()
                about
            }
            .padding(Theme.Space.section)
        }
        .frame(width: 520)
        .frame(minHeight: 460, idealHeight: 560)
        .background(palette.background)
        .tint(palette.primary)
        .confirmsSignOut($signingOut)
        // Back from Terminal: ask the engines again, once, if a sign-in or sign-out was opened.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshEngineStatusIfAuthChanged() }
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
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

    // MARK: - Engines

    private var engines: some View {
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

    // MARK: - About

    private var about: some View {
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
                    Text("Source-available under BSL 1.1. No telemetry.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
                Spacer(minLength: Theme.Space.snug)
                // No update feed yet (GitHub Releases only), so this says what it does rather than
                // pretending to check. Matches the app menu's "Releases on GitHub…".
                Button("Check releases on GitHub") { NSWorkspace.shared.open(Updater.releasesURL) }
                    .buttonStyle(QuietButton(compact: true))
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
