import BupsyKit
import SwiftUI

/// First run.
///
/// Three screens, because the two things a new user must understand are not obvious and both are
/// load-bearing: bupsy runs the agent CLIs *they* already pay for, and bots ask before they act.
/// Someone who misses the first will wonder why nothing works; someone who misses the second will
/// be surprised by a permission card and distrust it.
///
/// Drawn in the app's own palette and buttons — it is the first thing anyone sees, and system
/// grey buttons on it said "unfinished" before the app had said anything at all.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: engines
                default: safety
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            Rectangle().fill(palette.border).frame(height: 1)
            HStack(spacing: Theme.Space.snug) {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { page -= 1 } }
                    .buttonStyle(QuietButton())
                    .opacity(page > 0 ? 1 : 0)
                    .disabled(page == 0)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { index in
                        Circle()
                            .fill(index == page ? palette.primary : palette.border)
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                Button(page == pages - 1 ? "Start" : "Next") {
                    if page == pages - 1 {
                        model.completeOnboarding()
                        dismiss()
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { page += 1 }
                    }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Space.section)
            .padding(.vertical, Theme.Space.step)
        }
        .frame(width: 540, height: 440)
        .background(palette.popover)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        page(
            hero: AnyView(BupsyIconMark(size: 96)),
            title: "Bots that use the AI you already pay for",
            body: "Each bot runs Claude Code or Codex on this Mac, signed in as you. There's no bupsy "
                + "account, nothing to buy, and no server of ours in the middle — there isn't one."
        )
    }

    private var engines: some View {
        VStack(spacing: Theme.Space.gutter) {
            Text("What's signed in")
                .font(Theme.Typography.title)
                .foregroundStyle(palette.foreground)
            Text("bupsy never sees these sign-ins. The CLIs keep their own, in files you own.")
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                ForEach(Array(EngineID.supported.enumerated()), id: \.element) { index, engine in
                    if index > 0 { Rectangle().fill(palette.border).frame(height: 1) }
                    engineRow(engine)
                }
            }
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border))
            .frame(maxWidth: 360)

            Text("Not signed in? Run `claude` or `codex` in Terminal once and sign in there — "
                 + "you only need one.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.section)
    }

    /// Every engine is listed from the start. Listing only the ones already checked left this
    /// page empty on first launch, while the check was still running.
    private func engineRow(_ engine: EngineID) -> some View {
        let status = model.engineStatus[engine]
        return HStack(spacing: Theme.Space.snug) {
            Group {
                if let status {
                    Image(systemName: status.isUsable ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(status.isUsable ? Color.green : palette.mutedForeground)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            Text(engine.displayName)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.foreground)
            Spacer()
            Text(status == nil ? "Checking…" : (status!.isUsable ? "Ready" : "Not signed in"))
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.vertical, Theme.Space.snug + 2)
    }

    private var safety: some View {
        page(
            hero: AnyView(BotFace(hue: 0.08, mood: .waitingForYou, size: 76)),
            title: "Bots ask before they act",
            body: "New bots stop and ask before doing anything beyond reading. If nobody answers, "
                + "the answer is no.\n\nLoosen it per bot whenever you like — right-click a bot "
                + "and choose Trust, or open its panel."
        )
    }

    private func page(hero: AnyView, title: String, body text: String) -> some View {
        VStack(spacing: Theme.Space.gutter) {
            hero
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(palette.foreground)
                .multilineTextAlignment(.center)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(Theme.Space.section)
    }
}
