import SwiftUI
import VisionKit

/// Pairing this iPhone with Bupsy on the person's Mac: scan the code it shows, or type it.
struct PairView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.palette) private var palette
    /// Why we're here, when it isn't the first time: the Mac removed this phone.
    let message: String?

    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    @State private var pairing = false
    @State private var scanning = false
    @FocusState private var focus: Field?

    private enum Field { case address, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Wordmark(size: 36)
                    .padding(.top, 48)
                Text("Pair this iPhone with Bupsy on your Mac")
                    .font(.title3)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)

                Button {
                    error = nil
                    scanning = true
                } label: {
                    Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(BupsyButtonStyle(kind: .primary, wide: true))
                .disabled(pairing)

                Text("or type it")
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.vertical, 4)

                TextField("your-mac.your-tailnet.ts.net", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .address)
                    .onSubmit { focus = .code }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityLabel("Your Mac's address")

                TextField("ABC123", text: $code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .code)
                    .onSubmit(pairTyped)
                    .onChange(of: code) { _, typed in
                        let clean = PairingLink.normalise(typed)
                        if clean != typed { code = clean }
                    }
                    .padding(.vertical, 12)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityLabel("Pairing code")

                Button(action: pairTyped) {
                    if pairing { ProgressView().tint(palette.onPrimary) } else { Text("Pair") }
                }
                .buttonStyle(BupsyButtonStyle(kind: .primary, wide: true))
                .disabled(pairing || code.count != 6 || address.trimmingCharacters(in: .whitespaces).isEmpty)

                if let shown = error ?? message {
                    Text(shown)
                        .font(.subheadline)
                        .foregroundStyle(palette.destructiveText)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isStaticText)
                }

                Text("On your Mac: Bupsy → Settings → Use from other devices → Pair a device. Both need Tailscale, signed in to the same account.")
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.sidebar)
        .onAppear { if address.isEmpty { address = session.lastAddress } }
        .sheet(isPresented: $scanning) {
            ScanSheet { scanned in
                scanning = false
                pairScanned(scanned)
            }
        }
    }

    private func pairTyped() {
        guard let link = PairingLink(address: address, code: code) else {
            error = PairingLink.address(from: address) == nil
                ? "That address doesn't look right. It's your Mac's Tailscale name, like studio.tail1234.ts.net."
                : "Enter the 6-character code from your Mac."
            return
        }
        pair(link)
    }

    private func pairScanned(_ text: String) {
        guard let link = PairingLink(scanned: text) else {
            error = "That QR code isn't a Bupsy pairing code."
            return
        }
        address = link.address.absoluteString
        guard link.code != nil else {
            error = "That QR code has no pairing code in it. Make a new one on your Mac."
            return
        }
        pair(link)
    }

    private func pair(_ link: PairingLink) {
        focus = nil
        error = nil
        pairing = true
        Task {
            do {
                try await session.pair(link)
            } catch {
                self.error = error.localizedDescription
                code = ""
            }
            pairing = false
        }
    }
}

/// The camera, looking for the Mac's QR code, or an honest note when it can't.
private struct ScanSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let found: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    unavailable("This iPhone can't scan codes. Type the address and code instead.")
                } else if !DataScannerViewController.isAvailable {
                    VStack(spacing: 12) {
                        unavailable("Bupsy needs the camera to scan. Allow it in Settings, or type the code instead.")
                        Button("Open Settings") {
                            if let settings = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settings)
                            }
                        }
                        .buttonStyle(.bupsySecondary)
                    }
                } else {
                    QRScanner(found: found)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("Scan the code on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(palette.mutedForeground)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}

/// VisionKit's live scanner, set to QR codes only, reporting the first one it reads.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        /// One code is enough; the scanner keeps reporting it for as long as it's in view.
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !done, case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
                done = true
                found(text)
            }
        }
    }
}
