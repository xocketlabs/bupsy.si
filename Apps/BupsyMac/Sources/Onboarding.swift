import BupsyKit
import SwiftUI

/// First run.
///
/// Three screens, because the two things a new user must understand are not obvious and both are
/// load-bearing: bupsy runs the agent CLIs *they* already pay for, and bots ask before they act.
/// Someone who misses the first will wonder why nothing works; someone who misses the second will
/// be surprised by a permission card and distrust it.
///
/// It also puts the cloud machine *after* the free tiers deliberately — nobody should reach a
/// paid option before they have seen the app work for nothing.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                engines.tag(1)
                safety.tag(2)
            }
            .tabViewStyle(.automatic)

            Divider()
            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Spacer()
                Text("\(page + 1) of 3").font(Theme.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button(page == 2 ? "Start" : "Next") {
                    if page == 2 {
                        model.completeOnboarding()
                        dismiss()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 420)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        page(
            face: BotFace(hue: 0.17, mood: .idle, size: 72),
            title: "Bots that use the AI you already pay for",
            body: """
                Each bot runs Claude Code or Codex on this Mac, signed in as you. \
                There is no bupsy account, no subscription to buy, and nothing sent to a server \
                of ours — because there isn't one.
                """
        )
    }

    private var engines: some View {
        VStack(spacing: 14) {
            Text("What's signed in").font(Theme.Typography.title).fontWeight(.semibold)
            Text("bupsy never sees these sign-ins. The CLIs keep their own, in files you own.")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(EngineID.allCases.filter { model.engineStatus[$0] != nil }, id: \.self) { engine in
                    if let status = model.engineStatus[engine] {
                        HStack {
                            Image(systemName: status.isUsable
                                  ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(status.isUsable ? Color.green : Color.orange)
                            Text(engine.displayName)
                            Spacer()
                            Text(status.isUsable ? "ready" : "not ready")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: 320)

            Text("Not signed in? Run `claude` or `codex` in Terminal once, and sign in there.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    private var safety: some View {
        page(
            face: BotFace(hue: 0.08, mood: .waitingForYou, size: 72),
            title: "Bots ask before they act",
            body: """
                New bots are fully gated: anything beyond reading stops and asks you first. \
                If nobody answers, the answer is no.

                You can loosen that per bot later — right-click any bot and pick Trust.
                """
        )
    }

    private func page(face: some View, title: String, body text: String) -> some View {
        VStack(spacing: 16) {
            face
            Text(title).font(Theme.Typography.title).fontWeight(.semibold)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
