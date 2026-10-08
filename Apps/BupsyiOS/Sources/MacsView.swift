import SwiftUI

/// "Your Macs": every Mac this iPhone is paired with, how each is doing, and ways to add one,
/// pair one again or forget one.
struct MacsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: PairedMac?
    @State private var adding: AddMac?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.macs) { mac in
                        MacRow(mac: mac, status: session.status(of: mac),
                               onPairAgain: { adding = AddMac(address: mac.address.absoluteString) },
                               onForget: { forgetting = mac })
                            .listRowBackground(palette.card)
                            .swipeActions {
                                Button("Forget", role: .destructive) { forgetting = mac }
                            }
                    }
                } footer: {
                    Text("Forgetting a Mac stops this iPhone talking to it. To stop a Mac trusting this iPhone, remove it in Bupsy's settings there.")
                        .foregroundStyle(palette.mutedForeground)
                }

                Section {
                    Button {
                        adding = AddMac(address: "")
                    } label: {
                        Label("Add a Mac", systemImage: "plus")
                            .foregroundStyle(palette.primary)
                    }
                    .listRowBackground(palette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.sidebar)
            .navigationTitle("Your Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $adding) { add in
                AddMacSheet(address: add.address)
            }
            .forgetMacDialog($forgetting)
        }
    }
}

/// One Mac: its icon and name, how it's doing, and what can be done about it.
private struct MacRow: View {
    @Environment(\.palette) private var palette
    let mac: PairedMac
    let status: MacStatus
    let onPairAgain: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mac.symbol)
                .font(.system(size: 20))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(colour).frame(width: 7, height: 7)
                    Text(status.label)
                }
                .font(.footnote)
                .foregroundStyle(palette.mutedForeground)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if status == .notPaired {
                Button("Pair again", action: onPairAgain)
                    .buttonStyle(.bupsySecondary)
            }
            Menu {
                if status == .notPaired {
                    Button("Pair again", systemImage: "qrcode.viewfinder", action: onPairAgain)
                }
                Button("Forget \(mac.displayName)", systemImage: "xmark.circle", role: .destructive, action: onForget)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More for \(mac.displayName)")
        }
        .padding(.vertical, 4)
    }

    /// Its Tailscale name, with the port only when it isn't Bupsy's usual one.
    private var address: String {
        guard let host = mac.address.host else { return mac.address.absoluteString }
        guard let port = mac.address.port, port != PairingLink.port else { return host }
        return "\(host):\(port)"
    }

    private var colour: Color {
        switch status {
        case .connected: palette.success
        case .offline: palette.warning
        case .notPaired: palette.destructiveText
        case .connecting: palette.mutedForeground
        }
    }
}

/// A request to pair a Mac from inside the app: a new one, or one at a known address again.
struct AddMac: Identifiable {
    let id = UUID()
    let address: String
}

/// The pairing screen as a sheet over the app, which closes itself once the Mac is paired.
struct AddMacSheet: View {
    @Environment(\.dismiss) private var dismiss
    let address: String

    var body: some View {
        NavigationStack {
            PairView(message: nil, address: address, onPaired: { dismiss() })
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}
