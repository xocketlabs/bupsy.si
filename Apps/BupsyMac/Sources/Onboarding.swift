import AppKit
import BupsyKit
import SwiftUI

/// First run.
///
/// Three steps, because the two things a new user must understand are not obvious and both are
/// load-bearing: bupsy runs the agent CLIs *they* already pay for, and bots ask before they act.
/// Someone who misses the first will wonder why nothing works; someone who misses the second will
/// be surprised by a permission card and distrust it.
///
/// A split window: on the left a tinted, dotted stage where Bupsy acts out each step, on the
/// right a progress bar, the step itself and a footer with Back and one primary action.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    /// The trust level being tried out on the last step. It only moves the scene: nothing is
    /// saved, and every new bot still starts at `.ask`.
    @State private var previewTrust = Autonomy.ask
    @State private var checking = false
    @State private var copiedCommand: String?

    private let pages = 3
    private let stepNames = ["Hello", "Sign-in", "Trust"]

    /// The row of sleeping bots under Bupsy on the first step.
    private static let lineup: [(shape: BotShape, colour: Int)] = [
        (.bup, 1), (.cat, 2), (.bunny, 4), (.ghost, 3), (.bear, 6), (.pill, 5), (.horns, 7),
    ]

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(width: 400)
                .frame(maxHeight: .infinity)
            column
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 620)
        .background(palette.popover)
        .interactiveDismissDisabled()
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            MascotStageBackground(tint: palette.primary)
            MascotStageGlow(tint: palette.primary, diameter: 380)
            Group {
                switch page {
                case 0: helloScene
                case 1: enginesScene
                default: trustScene
                }
            }
            .id(page)
            .transition(.opacity)
        }
        .clipped()
    }

    /// Bupsy itself: the pink Bup.
    private func bupsy(_ mood: BotMood, size: CGFloat) -> some View {
        BotFace(hue: 0, mood: mood, size: size, shape: .bup, colour: 0)
    }

    private var helloScene: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            MascotStageBubble(text: "Hi! I'm Bupsy.")
                .padding(.bottom, 16)
            bupsy(.waitingForYou, size: 180)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.snug) {
                HStack(spacing: 4) {
                    ForEach(Array(Self.lineup.enumerated()), id: \.offset) { _, member in
                        BotFace(hue: 0, mood: .sleeping, size: 44, shape: member.shape, colour: member.colour)
                    }
                }
                Text("Your future team, asleep until you make them")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private var enginesScene: some View {
        let left = EngineID.supported.first ?? .claude
        let right = EngineID.supported.last ?? .codex
        return VStack(spacing: 18) {
            MascotStageBubble(text: engineLine)
                .frame(maxWidth: 270)
            HStack(spacing: 0) {
                stageEngineCard(left)
                stageConnector(left)
                bupsy(engineMood, size: 140)
                stageConnector(right)
                stageEngineCard(right)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func stageEngineCard(_ engine: EngineID) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(12), weight: .semibold))
            Text(engine.displayName)
                .font(Theme.Typography.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(palette.foreground)
        .frame(width: 86, height: 70)
        .background(palette.popover, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(engineTone(engine))
                .frame(width: 7, height: 7)
                .padding(8)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
    }

    private func stageConnector(_ engine: EngineID) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 22, y: 1))
        }
        .stroke(engineTone(engine), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        .frame(width: 22, height: 2)
    }

    private var trustScene: some View {
        VStack(spacing: 18) {
            MascotStageBubble(text: trustLine(previewTrust))
            bupsy(trustMood(previewTrust), size: 170)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Autonomy.allCases, id: \.self) { level in
                        Capsule()
                            .fill(level <= previewTrust ? meterFill : palette.foreground.opacity(0.12))
                            .frame(width: 40, height: 6)
                    }
                }
                HStack {
                    Text("Careful")
                    Spacer(minLength: 0)
                    Text("Bold")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            }
            .frame(width: 178)
            .animation(.easeOut(duration: 0.18), value: previewTrust)
        }
    }

    private var meterFill: Color { previewTrust == .auto ? palette.destructive : palette.primary }

    // MARK: - Column

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
            Spacer(minLength: Theme.Space.gutter)
            Group {
                switch page {
                case 0: hello
                case 1: engines
                default: safety
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(page)
            .transition(.opacity)
            Spacer(minLength: Theme.Space.gutter)
            footer
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .background(palette.popover)
    }

    /// One segment per step: done in ink, the current one in pink, the rest still empty.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { index in
                    Capsule()
                        .fill(index < page ? palette.foreground
                              : (index == page ? palette.primary : palette.cardHover))
                        .frame(height: 4)
                }
            }
            HStack(spacing: Theme.Space.snug) {
                Text(stepNames[min(page, stepNames.count - 1)])
                    .fontWeight(.medium)
                    .foregroundStyle(palette.foreground)
                Text("\(page + 1) of \(pages)")
                    .foregroundStyle(palette.mutedForeground)
            }
            .font(Theme.Typography.caption)
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Text(title)
                .font(.system(size: Theme.scaled(28), weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(.system(size: Theme.scaled(14)))
                .foregroundStyle(palette.mutedForeground)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hello: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            heading("Bots that use the AI you already pay for.",
                    "Bupsy turns your Claude Code or Codex subscription into a team of bots. Each one "
                        + "gets a face and a job, and works while you do something else.")
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                check("No account to make, nothing to buy")
                check("No server of ours in the middle")
                check("Your sign-ins stay with the CLIs, in files you own")
            }
        }
    }

    private func check(_ text: String) -> some View {
        HStack(spacing: Theme.Space.step) {
            Image(systemName: "checkmark")
                .font(.system(size: Theme.scaled(12), weight: .bold))
                .foregroundStyle(palette.success)
                .frame(width: 18)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
        }
    }

    private var engines: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("What's signed in",
                    "Bots run under your own sign-in. One engine is enough to start.")
            VStack(spacing: Theme.Space.snug) {
                ForEach(EngineID.supported, id: \.self) { engine in
                    engineRow(engine)
                }
            }
            if let missing = firstMissingEngine {
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    Text("To add \(missing.displayName), run this once in Terminal and sign in")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    commandBox(signInCommand(for: missing))
                }
            }
            if !isChecking && !readyEngines.isEmpty && readyEngines.count < EngineID.supported.count {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text("Or skip it. You can add \(missingEngines.map(\.displayName).joined(separator: ", ")) any time.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            } else if !isChecking && readyEngines.isEmpty {
                HStack(spacing: Theme.Space.step) {
                    checkAgainButton
                    Text("Sign in to one, then check again.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
    }

    /// Every engine is listed from the start. Listing only the ones already checked left this
    /// page empty on first launch, while the check was still running.
    private func engineRow(_ engine: EngineID) -> some View {
        let status = model.engineStatus[engine]
        return HStack(spacing: Theme.Space.step) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: Theme.scaled(12), weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 40, height: 40)
                .background(palette.popover, in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.border))
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(palette.foreground)
                Text(engineDetail(status))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(2)
                    .help(engineDetail(status))
            }
            Spacer(minLength: Theme.Space.snug)
            statusPill(status)
        }
        .padding(Theme.Space.step)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private func statusPill(_ status: AuthStatus?) -> some View {
        if let status {
            let tone = status.isUsable ? palette.success : palette.warning
            HStack(spacing: 5) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text(statusLabel(status))
            }
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(tone)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 5)
            .background(tone.opacity(0.13), in: .rect(cornerRadius: Theme.Radius.control))
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Text(command)
                .font(.system(size: Theme.scaled(12), design: .monospaced))
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command
            } label: {
                Image(systemName: copiedCommand == command ? "checkmark" : "doc.on.doc")
                    .font(.system(size: Theme.scaled(12)))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.leading, Theme.Space.gutter)
        .padding(.trailing, Theme.Space.snug)
        .frame(height: 44)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
    }

    private var checkAgainButton: some View {
        Button(action: checkAgain) {
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "magnifyingglass")
                }
                Text("Check again")
            }
        }
        .buttonStyle(QuietButton(compact: true))
        .disabled(checking)
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            heading("Bots ask before they act.",
                    "New bots start at the top of this list. If nobody answers, the answer is no.")
            VStack(spacing: Theme.Space.snug) {
                ForEach(Autonomy.allCases, id: \.self) { level in
                    trustRow(level)
                }
            }
            Text("Pick one to see how a bot takes it. Change it per bot whenever you like: right-click "
                 + "a bot and choose Trust, or open its panel.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trustRow(_ level: Autonomy) -> some View {
        let selected = level == previewTrust
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { previewTrust = level }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.menuLabel)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(level == .auto ? palette.destructiveText : palette.foreground)
                    Text(trustDetail(level))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
                Spacer(minLength: Theme.Space.snug)
                if level == .ask {
                    Text("Where new bots start")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.popover : palette.card,
                        in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(selected ? palette.foreground : Color.clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.step) {
            if page > 0 {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { page -= 1 } }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, Theme.Space.gutter)
                    .frame(height: Theme.Size.control)
                    .contentShape(.rect)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("press")
                Keycap("Return")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            Button(action: next) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "arrow.right")
                    Text(nextLabel)
                }
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
        }
    }

    private var nextLabel: String {
        switch page {
        case 0:
            return "Set me up"
        case pages - 1:
            return "Start"
        default:
            if page == 1, readyEngines.count == 1, !isChecking, let only = readyEngines.first {
                return "Continue with \(only.displayName)"
            }
            return "Continue"
        }
    }

    private func next() {
        if page == pages - 1 {
            model.completeOnboarding()
            dismiss()
        } else {
            withAnimation(.easeOut(duration: 0.15)) { page += 1 }
        }
    }

    private func checkAgain() {
        checking = true
        Task { @MainActor in
            await model.refreshEngineStatus()
            checking = false
        }
    }

    // MARK: - Engine status, in words

    private var isChecking: Bool { EngineID.supported.contains { model.engineStatus[$0] == nil } }

    private var readyEngines: [EngineID] {
        EngineID.supported.filter { model.engineStatus[$0]?.isUsable == true }
    }

    private var missingEngines: [EngineID] {
        EngineID.supported.filter { engine in
            guard let status = model.engineStatus[engine] else { return false }
            return !status.isUsable
        }
    }

    private var firstMissingEngine: EngineID? { missingEngines.first }

    private var engineLine: String {
        if isChecking { return "Checking what's signed in..." }
        let ready = readyEngines.map(\.displayName).joined(separator: " and ")
        let missing = missingEngines.map(\.displayName).joined(separator: " and ")
        if missingEngines.isEmpty { return "Everything's signed in!" }
        if readyEngines.isEmpty { return "Nothing's signed in yet." }
        return "\(ready) is ready.\n\(missing) isn't yet."
    }

    private var engineMood: BotMood {
        if isChecking { return .working }
        if missingEngines.isEmpty { return .done }
        if readyEngines.isEmpty { return .waitingForYou }
        return .idle
    }

    private func engineTone(_ engine: EngineID) -> Color {
        guard let status = model.engineStatus[engine] else { return palette.mutedForeground }
        return status.isUsable ? palette.success : palette.warning
    }

    private func engineDetail(_ status: AuthStatus?) -> String {
        guard let status else { return "Looking for it on this Mac" }
        switch status {
        case .signedIn(let method):
            switch method {
            case .subscription: return "Signed in with your subscription"
            case .apiKey: return "Signed in with an API key"
            }
        case .signedInWithoutModelAccess(let detail):
            return detail.isEmpty ? "Signed in, but this plan can't run it" : detail
        case .signedOut:
            return "Not signed in yet"
        case .unknown(let message):
            return message.isEmpty ? "Couldn't check" : message
        }
    }

    private func statusLabel(_ status: AuthStatus) -> String {
        switch status {
        case .signedIn: "Ready"
        case .signedInWithoutModelAccess: "Can't run models"
        case .signedOut: "Not signed in"
        case .unknown: "Not ready"
        }
    }

    private func signInCommand(for engine: EngineID) -> String {
        switch engine {
        case .codex: "codex login"
        default: "claude"
        }
    }

    // MARK: - Trust, in words

    private func trustDetail(_ level: Autonomy) -> String {
        switch level {
        case .ask: "Asks before every action you haven't always allowed"
        case .allowlist: "Reads freely, asks for anything not on its list"
        case .trusted: "Works freely on this Mac, asks before anything leaves it"
        case .auto: "Runs anything on its own. Only for throwaway folders"
        }
    }

    private func trustLine(_ level: Autonomy) -> String {
        switch level {
        case .ask: "I'll ask before every step."
        case .allowlist: "I'll ask once, then remember."
        case .trusted: "I'll stay on this Mac unless you say so."
        case .auto: "Wait. Never ask? Are you sure?"
        }
    }

    private func trustMood(_ level: Autonomy) -> BotMood {
        switch level {
        case .ask: .waitingForYou
        case .allowlist, .trusted: .idle
        case .auto: .failed
        }
    }
}
