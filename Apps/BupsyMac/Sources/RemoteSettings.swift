import AppKit
import BupsyKit
import SwiftUI

/// Settings › Use from other devices: the switch, where to go, pairing, and the paired devices.
struct RemoteSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var copied = false

    private var remote: RemoteAccess { model.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SettingsGroup(title: "Use from other devices") {
                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    Toggle(isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text("Use Bupsy from your phone or another Mac")
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.foreground)
                            Text("Chats, messages and approvals, over Tailscale. Only your own devices can reach it.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The words take the row, so the switch sits at the card's edge.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .bupsySwitch()

                    status
                    if remote.address != nil { pairingArea }
                    if !remote.devices.isEmpty { deviceList }
                }
                .padding(Theme.Space.step)
            }
            Text("Install Tailscale on this Mac and on each device, signed in to the same account. "
                 + "Bupsy is shared on your private Tailscale network only, never the internet, and every "
                 + "device must be paired here first. Bots on this Mac need it awake to work.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.hairline)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch remote.status {
        case .off:
            EmptyView()
        case .starting:
            HStack(spacing: Theme.Space.tight) {
                ProgressView().controlSize(.small)
                Text("Starting…").font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
            }
        case .on(let url):
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
                Text(url.absoluteString)
                    .font(ThreadLayout.monoFont)
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.tight)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(QuietButton(compact: true))
            }
        case .problem(let message):
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Space.snug) {
                    Button("Try again") { Task { await remote.start() } }
                        .buttonStyle(QuietButton(compact: true))
                    if remote.tailscale?.state == .notInstalled {
                        Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download")!) }
                            .buttonStyle(QuietButton(compact: true))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pairingArea: some View {
        if let pairing = remote.pairing {
            HStack(alignment: .top, spacing: Theme.Space.gutter) {
                if let image = remote.qrImage(for: pairing.link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .padding(Theme.Space.tight)
                        .background(.white, in: .rect(cornerRadius: Theme.Radius.control))
                        .accessibilityLabel("QR code to pair a device")
                }
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    Text("Scan with your phone's camera")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(palette.foreground)
                    Text("Or open the address above on the device and type this code:")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pairing.code)
                        .font(.system(size: Theme.scaled(22), weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                    Text("Works once, for 10 minutes.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                    Button("Cancel") { remote.cancelPairing() }
                        .buttonStyle(QuietButton(compact: true))
                }
            }
        } else {
            Button("Pair a device…") { remote.startPairing() }
                .buttonStyle(BupsyButtonStyle(kind: .secondary, size: .sm))
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Paired devices")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            ForEach(remote.devices) { device in
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: device.name.localizedCaseInsensitiveContains("mac") ? "laptopcomputer" : "iphone")
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(Theme.Typography.body).foregroundStyle(palette.foreground)
                        Text(seenLine(device)).font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
                    }
                    Spacer(minLength: Theme.Space.tight)
                    Button("Remove") { remote.remove(device) }
                        .buttonStyle(QuietButton(compact: true))
                        .help("This device will need pairing again")
                }
            }
        }
    }

    private func seenLine(_ device: PairedDevice) -> String {
        let seen = device.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "never"
        return "Last used \(seen)"
    }
}

/// Settings › Keep working with the lid closed, through Sleepless's switch.
struct LidSleepSection: View {
    @Environment(\.palette) private var palette
    @State private var state: LidSleep.State = .sleeps
    @State private var availability: LidSleep.Availability = .ready
    @State private var checked = false

    private var sleeplessURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: LidSleep.sleeplessBundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SettingsGroup(title: "Keep working with the lid closed") {
                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    Toggle(isOn: Binding(get: { state == .survives }, set: { state = LidSleep.set(survives: $0) })) {
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text("Survive sleep")
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.foreground)
                            Text(state == .survives
                                 ? "On. This Mac keeps running with the lid closed, so your bots keep working."
                                 : "Off. Closing the lid sleeps this Mac and pauses bots running on it.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .bupsySwitch()
                    .disabled(availability != .ready)

                    switch availability {
                    case .ready:
                        EmptyView()
                    case .needsSleeplessPermission:
                        hint("Open Sleepless once and turn it on, so it can ask macOS for permission. Then check again.") {
                            if let url = sleeplessURL { NSWorkspace.shared.open(url) }
                        } label: { "Open Sleepless" }
                    case .needsSleepless:
                        hint("This uses Sleepless, a free open-source app, to flip the one macOS setting that keeps a Mac awake with the lid closed.") {
                            NSWorkspace.shared.open(LidSleep.sleeplessURL)
                        } label: { "Get Sleepless" }
                    }
                }
                .padding(Theme.Space.step)
            }
            Text("Keep it plugged in: a closed Mac on battery keeps draining. Sleepless switches this off at low battery while it's running.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.hairline)
        }
        .task { refresh() }
        // Back from Sleepless: it may have just been given its permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        state = LidSleep.state()
        availability = LidSleep.availability(sleeplessInstalled: sleeplessURL != nil)
        checked = true
    }

    private func hint(_ text: String, action: @escaping () -> Void, label: () -> String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.snug) {
                Button(label(), action: action).buttonStyle(QuietButton(compact: true))
                Button("Check again") { refresh() }.buttonStyle(QuietButton(compact: true))
            }
        }
    }
}

/// Settings › Other Macs: the person's other Bupsy Macs whose bots show here, and linking one.
struct LinkedMacsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var adding = false
    @State private var peers: [Tailscale.Peer] = []
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

    private var linked: LinkedMacs { model.linked }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SettingsGroup(title: "Other Macs") {
                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    if linked.links.isEmpty && !adding {
                        Text("Link another Mac running Bupsy to see its bots here, in the same sections, marked with that Mac's icon.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(linked.links) { link in linkRow(link) }
                    if adding { addForm } else {
                        Button("Add a Mac…") { startAdding() }
                            .buttonStyle(BupsyButtonStyle(kind: .secondary, size: .sm))
                    }
                }
                .padding(Theme.Space.step)
            }
            Text("On the other Mac: Settings › Use from other devices, turn it on, then Pair a device to get a code. "
                 + "Its bots keep running there; this Mac shows them and sends your messages and decisions back.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.hairline)
        }
    }

    private func linkRow(_ link: LinkedMacs.Link) -> some View {
        let online = linked.online[link.id]
        return HStack(spacing: Theme.Space.snug) {
            Image(systemName: link.kind == "laptop" ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.name).font(Theme.Typography.body).foregroundStyle(palette.foreground)
                Text(online == true ? "Connected · \(linked.remoteBots.filter { $0.remote?.macID == link.id }.count) shared bots"
                     : (linked.problems[link.id] ?? "Connecting…"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(online == false ? palette.warning : palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.tight)
            Button("Remove") { linked.remove(link) }
                .buttonStyle(QuietButton(compact: true))
                .help("Stop showing \(link.name)'s bots here")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if !peers.isEmpty {
                Text("Your Macs on Tailscale").font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
                ForEach(peers) { peer in
                    Button {
                        address = peer.dnsName
                    } label: {
                        HStack(spacing: Theme.Space.tight) {
                            Image(systemName: address == peer.dnsName ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(address == peer.dnsName ? palette.primary : palette.mutedForeground)
                            Text(peer.name).foregroundStyle(palette.foreground)
                            if !peer.online { Text("offline").foregroundStyle(palette.mutedForeground) }
                        }
                        .font(Theme.Typography.body)
                    }
                    .buttonStyle(.plain)
                    .disabled(!peer.online)
                }
            }
            TextField("Address, e.g. my-mac-mini.tailnet.ts.net", text: $address)
                .textFieldStyle(.roundedBorder)
            TextField("Code shown on that Mac", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.snug) {
                Button(working ? "Linking…" : "Link") { link() }
                    .buttonStyle(BupsyButtonStyle(kind: .primary, size: .sm))
                    .disabled(working || address.isEmpty || code.count < 6)
                Button("Cancel") { adding = false; problem = nil }
                    .buttonStyle(QuietButton(compact: true))
            }
        }
    }

    private func startAdding() {
        adding = true
        problem = nil
        code = ""
        Task {
            // This Mac itself is never offered: Tailscale lists peers, not the Mac asking.
            peers = await Tailscale.macs()
            if address.isEmpty, let first = peers.first(where: \.online) { address = first.dnsName }
        }
    }

    private func link() {
        working = true
        problem = nil
        Task {
            do {
                try await linked.add(address: address, code: code)
                adding = false
                address = ""
                code = ""
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// Settings › Voice: replies read aloud, and where the voice itself is chosen.
struct VoiceSettingsSection: View {
    @Environment(\.palette) private var palette
    @State private var readsReplies = VoiceOutput.readsReplies

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            SettingsGroup(title: "Voice") {
                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    Toggle(isOn: Binding(get: { readsReplies }, set: {
                        readsReplies = $0
                        VoiceOutput.readsReplies = $0
                        if !$0 { VoiceOutput.shared.stop() }
                    })) {
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text("Read new replies aloud")
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.foreground)
                            Text("When a bot finishes in the chat you have open. Any reply can be read with its speaker button.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .bupsySwitch()
                    HStack(spacing: Theme.Space.snug) {
                        Button("Try the voice") { VoiceOutput.shared.speak("Hi! This is how your bots will sound.") }
                            .buttonStyle(QuietButton(compact: true))
                        Button("Choose a voice…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                        }
                        .buttonStyle(QuietButton(compact: true))
                        .help("System Settings › Accessibility › Spoken Content › System voice. The higher-quality voices there are free to download.")
                    }
                }
                .padding(Theme.Space.step)
            }
            Text("Talk to a bot with the microphone button in any chat (Option Cmd D). Voice uses your Mac's own speech "
                 + "recognition and voices: free, no account, and on this Mac whenever your language allows.")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.hairline)
        }
    }
}
