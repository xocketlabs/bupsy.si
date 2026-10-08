import SwiftUI

/// Pairing, reaching the Mac, or the app itself, and the loop that keeps it current.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    /// What decides whether the loop runs: in the foreground, with a Mac to talk to.
    private struct Liveness: Equatable {
        let active: Bool
        let paired: Bool
    }

    var body: some View {
        Group {
            switch session.phase {
            case .unpaired(let message):
                PairView(message: message)
            case .connecting(let message):
                ConnectingView(problem: message)
            case .ready:
                BotListView()
            }
        }
        .withPalette(colorScheme)
        .tint(Palette.scheme(for: colorScheme).primary)
        // Polling stops the moment the app leaves the foreground, and starts again on return.
        .task(id: Liveness(active: scenePhase == .active, paired: session.isPaired)) {
            guard scenePhase == .active, session.isPaired else { return }
            await session.keepFresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, session.isPaired { BackgroundRefresh.schedule() }
        }
    }
}

/// Paired, but the Mac hasn't answered yet: usually it's asleep, or Tailscale is off.
struct ConnectingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    let problem: String?
    @State private var confirmForget = false

    var body: some View {
        VStack(spacing: 16) {
            Wordmark(size: 36)
            if let problem {
                Text(problem)
                    .font(.body)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await session.connect() }
                }
                .buttonStyle(.bupsySecondary)
            } else {
                ProgressView()
                Text("Connecting to your Mac…")
                    .foregroundStyle(palette.mutedForeground)
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Button("Forget this Mac", role: .destructive) { confirmForget = true }
                .font(.subheadline)
                .foregroundStyle(palette.destructiveText)
                .padding(.bottom, 12)
        }
        .background(palette.sidebar)
        .forgetMacDialog(isPresented: $confirmForget)
    }
}

extension View {
    /// The one way to forget the Mac, asked first: pairing again needs the Mac in front of you.
    func forgetMacDialog(isPresented: Binding<Bool>) -> some View {
        modifier(ForgetMacDialog(isPresented: isPresented))
    }
}

private struct ForgetMacDialog: ViewModifier {
    @Environment(AppSession.self) private var session
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Forget this Mac?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { session.forget() }
        } message: {
            Text("This iPhone stops talking to it. To use it again, pair with a new code from your Mac. To stop the Mac trusting this iPhone, remove it in Bupsy's settings there.")
        }
    }
}
