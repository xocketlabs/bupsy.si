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
            SetupPageHeader(title: "Machines",
                            description: "A machine lets a bot keep working with your Mac closed") {
                if model.hasComputeKey {
                    Button { isCreating = true } label: {
                        Label("New machine", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButton())
                }
            }

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
                        .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
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

/// A bot napping on its machine: says in one line what having a machine is for.
private struct MachineResidentNote: View {
    @Environment(\.palette) private var palette
    let bot: Bot
    let machine: MachineRecord

    var body: some View {
        HStack(spacing: Theme.Space.gutter) {
            BotFace(bot: bot, mood: machine.state == "running" ? .idle : .sleeping, size: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
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
        .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// The account card: the key field, and whose bill this is.
///
/// Without a key it is a paste box. With one it shows that a key is saved (never the key itself;
/// it lives in the Keychain and the page does not read it back) and offers to replace it.
struct ComputeKeySetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var key = ""
    @State private var replacing = false

    var body: some View {
        SetupPanel(footer: "The key stays in your Keychain. Machines are billed by boat.dev, not Bupsy.") {
            VStack(alignment: .leading, spacing: Theme.Space.step) {
                if model.hasComputeKey && !replacing {
                    Text("API key")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                    HStack(spacing: Theme.Space.snug) {
                        Text("Saved in this Mac\u{2019}s Keychain")
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
                        Button("Replace key") { replacing = true }
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
                    SecureField("", text: $key, prompt: Text("bd_live_..."))
                        .textFieldStyle(BupsyFieldStyle())

                    HStack(spacing: Theme.Space.snug) {
                        // Coloured explicitly: `Link` takes the system link colour rather than
                        // the app tint, so it arrived in macOS blue next to a pink accent.
                        Link("Get a key", destination: URL(string: "https://boat.dev")!)
                            .font(Theme.Typography.label)
                            .foregroundStyle(palette.primary)
                        Spacer()
                        if replacing {
                            Button("Cancel") {
                                replacing = false
                                key = ""
                            }
                            .buttonStyle(QuietButton())
                        }
                        Button("Save key") {
                            model.setComputeKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            replacing = false
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

struct MachineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let machine: MachineRecord
    @State private var confirmingDelete = false

    init(machine: MachineRecord) { self.machine = machine }

    private var assignedBots: [Bot] {
        model.bots.filter { $0.machineID == machine.id }
    }

    private var isRunning: Bool { machine.state == "running" }

    var body: some View {
        SetupListRow(title: machine.name, meta: meta,
                     flaggedMeta: nil) {
            IconTile(systemName: "desktopcomputer")
        } trailing: {
            HStack(spacing: Theme.Space.snug) {
                SetupBadge(text: stateLabel, tone: isRunning ? .success : .neutral, dot: isRunning)
                SetupIconButton(systemName: isRunning ? "pause.fill" : "play.fill",
                                help: isRunning ? "Stop \(machine.name)" : "Start \(machine.name)") {
                    model.toggleMachine(machine)
                }
                SetupIconButton(systemName: "trash", help: "Delete \(machine.name)", destructive: true) {
                    confirmingDelete = true
                }
            }
        }
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmingDelete) {
            Button("Delete machine", role: .destructive) { model.deleteMachine(machine) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(assignedBots.isEmpty
                 ? "It is removed from your boat.dev account."
                 : "It is removed from your boat.dev account. Its bots go back to running on this Mac.")
        }
    }

    private var stateLabel: String {
        switch machine.state {
        case "running": "Running"
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
                    .toggleStyle(.switch)
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
