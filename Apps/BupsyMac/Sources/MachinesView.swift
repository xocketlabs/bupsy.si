import BupsyKit
import SwiftUI

/// The pool of machines a user rents, with their own key.
///
/// Deliberately framed as "your machines, your account, your bill" rather than something Bupsy
/// provides. We never hold a compute key of our own, and the copy should not let anyone think
/// otherwise: a surprise charge from a company they did not knowingly sign up with would be a
/// worse failure than any bug in here.
struct MachinesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var isCreating = false

    private var runningCount: Int { model.machines.filter { $0.state == "running" }.count }

    /// The first bot that lives on a machine, for the note at the bottom of the page.
    private var resident: (bot: Bot, machine: MachineRecord)? {
        for bot in model.bots {
            if let id = bot.machineID, let machine = model.machines.first(where: { $0.id == id }) {
                return (bot: bot, machine: machine)
            }
        }
        return nil
    }

    var body: some View {
        SetupPageScroll {
            // "New machine" lives in the topbar, as on the board. See NewMachineButton.
            // Beta until it has run end to end against boat.dev, so nobody counts on it unawares.
            SetupPageHeader(title: "Machines", badge: "Beta",
                            description: "A machine lets a bot keep working with your Mac closed. New, so tell us what breaks.")

            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                SetupSectionHeader(
                    icon: "key.fill",
                    title: "boat.dev account",
                    badge: model.hasComputeKey ? "Connected" : "Not connected",
                    badgeTone: model.hasComputeKey ? .success : .neutral)
                ComputeKeySetup()
            }

            if model.hasComputeKey {
                SetupSectionRule()

                VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                    SetupSectionHeader(
                        icon: "desktopcomputer",
                        title: "Your machines",
                        badge: model.machines.isEmpty ? nil : "\(runningCount) running",
                        badgeTone: .info)

                    if model.machines.isEmpty {
                        EmptyState(
                            title: "No machines yet",
                            message: "One lets a bot keep working with your Mac closed.",
                            faceSize: 56
                        ) {
                            Button { isCreating = true } label: {
                                Label("New machine", systemImage: "plus")
                            }
                            .buttonStyle(QuietButton(compact: true))
                        }
                        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
                    } else {
                        VStack(spacing: Theme.Space.step) {
                            ForEach(model.machines) { machine in
                                MachineRow(machine: machine)
                            }
                        }
                    }

                    if let problem = model.machineProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let resident {
                    MachineResidentNote(bot: resident.bot, machine: resident.machine)
                }
            } else if let problem = model.machineProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isCreating) { NewMachineSheet() }
    }
}

/// The page's primary action, drawn in the topbar by `Page`. Only there once a key is saved,
/// since a machine cannot be created without one. It owns its sheet so the topbar does not need
/// to reach into the page for state.
struct NewMachineButton: View {
    @Environment(AppModel.self) private var model
    @State private var isCreating = false

    var body: some View {
        if model.hasComputeKey {
            Button { isCreating = true } label: {
                Label("New machine", systemImage: "plus")
            }
            .buttonStyle(PrimaryButton())
            .sheet(isPresented: $isCreating) { NewMachineSheet() }
        }
    }
}

/// A bot napping on its machine: says in one line what having a machine is for.
private struct MachineResidentNote: View {
    @Environment(\.palette) private var palette
    let bot: Bot
    let machine: MachineRecord

    var body: some View {
        HStack(spacing: Theme.Space.gutter) {
            BotFace(bot: bot, mood: machine.state == "running" ? .idle : .sleeping, size: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text("\(bot.name) runs on \(machine.name)")
                    .font(.system(size: Theme.scaled(14), weight: .medium))
                    .foregroundStyle(palette.foreground)
                Text(machine.ttlSeconds == nil
                     ? "Its routines fire on time even while this Mac sleeps."
                     : "This machine sleeps when idle, so its routines need this Mac awake to wake it.")
                    .font(.system(size: Theme.scaled(13)))
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.gutter)
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
    }
}

/// The account card: the key field, and whose bill this is.
///
/// Without a key it is a paste box. With one it shows the key masked, from the last four
/// characters kept beside it (the key itself lives in the Keychain and the page never reads it
/// back), and offers to replace or remove it. A new key is checked with boat.dev before it is
/// saved, so "Connected" never means a typo.
struct ComputeKeySetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var key = ""
    @State private var replacing = false
    @State private var checking = false
    @State private var keyProblem: String?
    @State private var confirmingRemove = false

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "bd_live_••••3f9a", or a plain line for a key saved before the last four were kept.
    private var maskedKey: String {
        guard let suffix = model.computeKeySuffix, !suffix.isEmpty else {
            return "Saved in this Mac\u{2019}s Keychain"
        }
        return "bd_live_\u{2022}\u{2022}\u{2022}\u{2022}" + suffix
    }

    var body: some View {
        SetupPanel(footer: "The key stays in your Keychain. Machines are billed by boat.dev, not Bupsy.") {
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                if model.hasComputeKey && !replacing {
                    Text("API key")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                    HStack(spacing: Theme.Space.snug) {
                        Text(maskedKey)
                            .font(.system(size: Theme.scaled(12), design: .monospaced))
                            .foregroundStyle(palette.foreground)
                            .padding(.horizontal, Theme.Space.gutter)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.control, alignment: .leading)
                            .background(palette.card.opacity(0.5),
                                        in: .rect(cornerRadius: Theme.Radius.base))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.base)
                                    .strokeBorder(palette.border)
                            }
                            .accessibilityLabel(model.computeKeySuffix.map { "API key ending in \($0)" }
                                                ?? "API key saved")
                        Button("Replace key") {
                            keyProblem = nil
                            replacing = true
                        }
                        .buttonStyle(QuietButton())
                        Button("Remove key") { confirmingRemove = true }
                            .buttonStyle(QuietButton())
                    }
                } else {
                    if !model.hasComputeKey {
                        Text("Connect your own boat.dev account")
                            .font(.system(size: Theme.scaled(14), weight: .medium))
                            .foregroundStyle(palette.foreground)
                        // One string literal, not a concatenation: SwiftUI only parses markdown
                        // in a literal, so `"a" + "**b**"` renders the asterisks verbatim.
                        Text("Bupsy has no cloud of its own. Machines run on **your** boat.dev account, billed to you, under your control.")
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("API key")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                    SecureField("API key", text: $key, prompt: Text("bd_live_..."))
                        .labelsHidden()
                        .textFieldStyle(BupsyFieldStyle())
                        .disabled(checking)
                        // Return saves, as it would in a sheet.
                        .onSubmit { save() }
                        .onChange(of: key) { _, _ in keyProblem = nil }

                    if let keyProblem {
                        Label(keyProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Theme.Space.snug) {
                        // Coloured explicitly: `Link` takes the system link colour rather than
                        // the app tint, so it arrived in macOS blue next to a pink accent.
                        Link("Get a key", destination: URL(string: "https://boat.dev")!)
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.primary)
                        Spacer()
                        if checking {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Checking the key with boat.dev")
                        }
                        if replacing {
                            Button("Cancel") {
                                replacing = false
                                key = ""
                                keyProblem = nil
                            }
                            .buttonStyle(QuietButton())
                            .disabled(checking)
                        }
                        Button(checking ? "Checking…" : "Save key") { save() }
                            .buttonStyle(PrimaryButton())
                            .disabled(trimmedKey.isEmpty || checking)
                    }
                }
            }
        }
        .confirmationDialog("Remove your boat.dev key?", isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { model.removeComputeKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bupsy can't start, stop or create machines until you add a key again. Machines already on boat.dev keep running there.")
        }
    }

    /// Checks the key with boat.dev, then saves it. A refused key stays in the field with the
    /// reason under it, so it can be fixed rather than retyped.
    private func save() {
        let candidate = trimmedKey
        guard !candidate.isEmpty, !checking else { return }
        checking = true
        keyProblem = nil
        Task { @MainActor in
            let problem = await model.validateAndSaveComputeKey(candidate)
            checking = false
            if let problem {
                keyProblem = problem
            } else {
                key = ""
                replacing = false
            }
        }
    }
}

struct MachineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let machine: MachineRecord
    @State private var confirmingDelete = false
    /// True while boat.dev is being asked to shut the machine down. The row stays until it has.
    @State private var deleting = false

    init(machine: MachineRecord) { self.machine = machine }

    private var assignedBots: [Bot] {
        model.bots.filter { $0.machineID == machine.id }
    }

    private var isRunning: Bool { machine.state == "running" }
    private var isFailed: Bool { machine.state == "failed" }
    /// A start, stop or create is on its way to boat.dev.
    private var isBusy: Bool {
        model.machinesInFlight.contains(machine.id) || machine.state == "creating"
    }
    /// Only a machine boat.dev knows about can be started or stopped there.
    private var existsOnBoat: Bool { machine.providerID != nil }

    var body: some View {
        SetupListRow(title: machine.name, meta: meta,
                     flaggedMeta: nil) {
            IconTile(systemName: "desktopcomputer")
        } trailing: {
            HStack(spacing: Theme.Space.snug) {
                SetupBadge(text: stateLabel, tone: badgeTone, dot: isRunning)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Theme.Size.controlSm, height: Theme.Size.controlSm)
                        .help(busyText)
                        .accessibilityLabel(busyText)
                } else if isFailed && !existsOnBoat {
                    Button("Retry") { model.retryMachine(machine) }
                        .buttonStyle(QuietButton(compact: true))
                        .help("Try creating \(machine.name) on boat.dev again")
                } else if existsOnBoat {
                    SetupIconButton(systemName: isRunning ? "pause.fill" : "play.fill",
                                    help: isRunning ? "Stop \(machine.name)" : "Start \(machine.name)") {
                        model.toggleMachine(machine)
                    }
                }
                if deleting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Shutting \(machine.name) down on boat.dev")
                        .accessibilityLabel("Deleting \(machine.name)")
                } else {
                    SetupIconButton(systemName: "trash", help: "Delete \(machine.name)", destructive: true) {
                        confirmingDelete = true
                    }
                    .disabled(isBusy)
                }
            }
        }
        .disabled(deleting)
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete machine", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what really happens: boat's API has no delete, so the machine is force-stopped
            // there and forgotten here. See AppModel.destroyMachine.
            Text(assignedBots.isEmpty
                 ? "It's shut down on boat.dev and removed from Bupsy. To remove it from your boat.dev account too, delete it there."
                 : "It's shut down on boat.dev and removed from Bupsy, and its bots move back to this Mac. To remove it from your boat.dev account too, delete it there.")
        }
    }

    /// Shuts it down on boat.dev, then forgets it. If boat could not stop it, it stays in the
    /// list (it may still be billing) and the page shows why, from `machineProblem`.
    private func delete() {
        deleting = true
        model.machineProblem = nil
        Task { @MainActor in
            _ = await model.destroyMachine(machine)
            deleting = false
        }
    }

    private var badgeTone: SetupTone {
        if isRunning { return .success }
        if isFailed { return .destructive }
        return .neutral
    }

    private var busyText: String {
        if machine.state == "creating" { return "Creating \(machine.name) on boat.dev" }
        return isRunning ? "Stopping \(machine.name)" : "Starting \(machine.name)"
    }

    private var stateLabel: String {
        switch machine.state {
        case "running": "Running"
        case "creating": "Creating"
        case "failed": "Failed"
        case "stopped", "archived", "paused": "Stopped"
        case "unknown", "": "Unknown"
        default: machine.state.prefix(1).uppercased() + machine.state.dropFirst()
        }
    }

    /// Size, availability, cost, and who lives on it.
    ///
    /// Cost is shown per machine, up front. An always-on machine is the one part of Bupsy that
    /// charges somebody money, so it should never be a surprise at the end of the month.
    private var meta: [String] {
        let size = MachineSize(rawValue: machine.size) ?? .small
        var parts = [Self.sizeName(size)]
        if machine.ttlSeconds == nil {
            parts.append("always on")
            parts.append(String(format: "~$%.0f/mo", size.alwaysOnMonthlyUSD))
        } else {
            parts.append("stops when idle")
            // An estimate, marked as one: what it costs depends on how often it is woken.
            parts.append(String(format: "~$%.0f/mo", size.idleMonthlyUSD))
        }
        parts.append(assignedBots.isEmpty ? "No bots yet" : assignedBots.map(\.name).joined(separator: ", "))
        return parts
    }

    static func sizeName(_ size: MachineSize) -> String {
        switch size {
        case .small: "Small"
        case .default: "Medium"
        case .large: "Large"
        }
    }
}

struct NewMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = MachineSize.small
    @State private var alwaysOn = false

    var body: some View {
        SheetFrame(title: "New machine", icon: "desktopcomputer",
                   subtitle: "Created on your own boat.dev account, billed to you.",
                   primaryVerb: "create") {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("work"))
                    .textFieldStyle(BupsyFieldStyle())
            }

            Field(label: "Size") {
                Picker("", selection: $size) {
                    ForEach(MachineSize.allCases, id: \.self) { size in
                        Text(label(for: size)).tag(size)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Field(
                label: "Availability",
                // The cost is the whole decision here, so it is stated before the choice is made
                // rather than discovered on a bill.
                hint: alwaysOn
                    ? String(format: "Routines run on time even with your Mac closed. "
                             + "Costs about $%.0f a month on your boat.dev account.",
                             size.alwaysOnMonthlyUSD)
                    : "Sleeps when idle, so it costs very little. Routines only run when "
                      + "something wakes it, which means your Mac has to be awake."
            ) {
                Toggle("Keep it running", isOn: $alwaysOn)
                    .bupsySwitch()
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create machine") {
                model.createMachine(
                    name: name.trimmingCharacters(in: .whitespaces),
                    size: size, alwaysOn: alwaysOn)
                dismiss()
            }
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func label(for size: MachineSize) -> String {
        switch size {
        case .small: "Small, 2 CPUs, 4 GB"
        case .default: "Medium, 4 CPUs, 8 GB"
        case .large: "Large, 8 CPUs, 16 GB"
        }
    }
}
