import SwiftUI

/// Pairing, reaching the Macs, or the app itself, and the loop that keeps it current.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    /// What decides whether the loop runs: in the foreground, and which Macs to talk to. A Mac
    /// added, forgotten or lost restarts it with the new list.
    private struct Liveness: Equatable {
        let active: Bool
        let macs: [String]
    }

    var body: some View {
        @Bindable var session = session
        Group {
            switch session.phase {
            case .unpaired(let message):
                PairView(message: message,
                         address: session.macs.first(where: \.unpaired)?.address.absoluteString ?? "")
            case .connecting(let message):
                ConnectingView(problem: message)
            case .ready:
                BotListView()
            }
        }
        .sheet(isPresented: $session.showingMacs) {
            MacsView()
                .withPalette(colorScheme)
                .tint(Palette.scheme(for: colorScheme).primary)
        }
        .withPalette(colorScheme)
        .tint(Palette.scheme(for: colorScheme).primary)
        // Polling stops the moment the app leaves the foreground, and starts again on return.
        .task(id: Liveness(active: scenePhase == .active, macs: session.pairedMacs.map(\.id))) {
            guard scenePhase == .active, session.isPaired else { return }
            await session.keepFresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, session.isPaired { BackgroundRefresh.schedule() }
        }
    }
}

/// Paired, but no Mac has answered yet: usually they're asleep, or Tailscale is off.
struct ConnectingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    let problem: String?
    @State private var forgetting: PairedMac?

    var body: some View {
        let several = session.pairedMacs.count > 1
        VStack(spacing: 16) {
            Wordmark(size: 36)
            if let problem {
                Text(problem)
                    .font(.body)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await session.refreshAll() }
                }
                .buttonStyle(.bupsySecondary)
            } else {
                ProgressView()
                Text(several ? "Connecting to your Macs…" : "Connecting to your Mac…")
                    .foregroundStyle(palette.mutedForeground)
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Group {
                if several {
                    Button("Your Macs") { session.showingMacs = true }
                        .foregroundStyle(palette.mutedForeground)
                } else {
                    Button("Forget this Mac", role: .destructive) { forgetting = session.pairedMacs.first }
                        .foregroundStyle(palette.destructiveText)
                }
            }
            .font(.subheadline)
            .padding(.bottom, 12)
        }
        .background(palette.sidebar)
        .forgetMacDialog($forgetting)
    }
}

extension View {
    /// The one way to forget a Mac, asked first: pairing again needs the Mac in front of you.
    func forgetMacDialog(_ mac: Binding<PairedMac?>) -> some View {
        modifier(ForgetMacDialog(mac: mac))
    }
}

private struct ForgetMacDialog: ViewModifier {
    @Environment(AppSession.self) private var session
    @Binding var mac: PairedMac?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Forget \(mac?.displayName ?? "this Mac")?",
            isPresented: Binding(get: { mac != nil }, set: { if !$0 { mac = nil } }),
            titleVisibility: .visible,
            presenting: mac
        ) { mac in
            Button("Forget \(mac.displayName)", role: .destructive) { session.forget(mac) }
        } message: { mac in
            Text("This iPhone stops talking to \(mac.displayName). To use it again, pair with a new code from that Mac. To stop the Mac trusting this iPhone, remove it in Bupsy's settings there.")
        }
    }
}
