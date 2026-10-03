import BupsyKit
import SwiftUI

/// The pool of machines a user rents, with their own key.
///
/// Deliberately framed as "your machines, your account, your bill" rather than something bupsy
/// provides. We never hold a compute key of our own, and the copy should not let anyone think
/// otherwise — a surprise charge from a company they did not knowingly sign up with would be a
/// worse failure than any bug in here.
struct MachinesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            SectionHeader(
                icon: "server.rack",
                title: "Machines",
                badge: model.machines.isEmpty ? nil : "\(model.machines.count)",
                subtitle: "Rented on your own boat.dev account, billed to you"
            ) {
                if model.hasComputeKey {
                    Button("New machine") { isCreating = true }
                        .buttonStyle(QuietButton())
                }
            }

            if !model.hasComputeKey {
                ComputeKeySetup()
            } else if model.machines.isEmpty {
                EmptyRow(text: "No machines yet. One lets a bot keep working with your Mac closed.") {
                    isCreating = true
                }
            } else {
                VStack(spacing: Theme.Space.snug) {
                    ForEach(model.machines) { machine in
                        MachineRow(machine: machine)
                    }
                }
            }

            if let problem = model.machineProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.label)
                    .foregroundStyle(palette.primary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .frame(maxWidth: Theme.Size.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .sheet(isPresented: $isCreating) { NewMachineSheet() }
    }
}

/// Where the user pastes their own key. Says plainly whose account it is and where it goes.
struct ComputeKeySetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your own boat.dev account").font(Theme.Typography.body).fontWeight(.medium)
            // One string literal, not a concatenation: SwiftUI only parses markdown in a
            // literal, so `"a" + "**b**"` renders the asterisks verbatim.
            Text("bupsy has no cloud of its own. Machines run on **your** boat.dev account, billed to you, under your control. Your key is kept in this Mac's Keychain and never leaves it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("boat.dev API key", text: $key)
                .textFieldStyle(BupsyFieldStyle())

            HStack {
                // Coloured explicitly: `Link` takes the system link colour rather than the app
                // tint, so it arrived in macOS blue next to a pink accent.
                Link("Get a key", destination: URL(string: "https://boat.dev")!)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.primary)
                Spacer()
                Button("Save") {
                    model.setComputeKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    key = ""
                }
                .buttonStyle(PrimaryButton())
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.gutter)
        .frame(maxWidth: 460, alignment: .leading)
        // No `maxHeight: .infinity`. It made this fill the pane and centre itself, so the setup
        // card floated in the middle of the window with a few hundred points of nothing between
        // it and the heading it belongs to.
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(palette.border))
    }
}

struct MachineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let machine: MachineRecord

    private var assignedBots: [Bot] {
        model.bots.filter { $0.machineID == machine.id }
    }

    var body: some View {
        CardRow {
            IconTile(systemName: "server.rack")
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Theme.Space.tight) {
                    Circle()
                        .fill(machine.state == "running" ? Color.green : palette.mutedForeground)
                        .frame(width: 6, height: 6)
                    Text(machine.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                }
                HStack(spacing: Theme.Space.snug) {
                    Text(subtitle)
                    MetaDot()
                    Text(assignedBots.isEmpty
                         ? "No bots assigned"
                         : assignedBots.map(\.name).joined(separator: ", "))
                        .foregroundStyle(assignedBots.isEmpty
                                         ? palette.primary : palette.mutedForeground)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
            }
        } trailing: {
            Menu {
                Button(machine.state == "running" ? "Stop" : "Start") {
                    model.toggleMachine(machine)
                }
                Divider()
                Button("Delete", role: .destructive) { model.deleteMachine(machine) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(palette.mutedForeground)
        }
    }

    /// Cost is shown per machine, up front. An always-on machine is the one part of bupsy that
    /// charges somebody money, so it should never be a surprise at the end of the month.
    private var subtitle: String {
        let size = MachineSize(rawValue: machine.size) ?? .small
        var parts = [machine.size, machine.state]
        if machine.ttlSeconds == nil {
            parts.append(String(format: "always on · ~$%.0f/mo", size.alwaysOnMonthlyUSD))
        } else {
            parts.append("sleeps when idle")
        }
        return parts.joined(separator: " · ")
    }
}

struct NewMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = MachineSize.small
    @State private var alwaysOn = false

    var body: some View {
        SheetFrame(title: "New machine", icon: "server.rack",
                   subtitle: "Created on your own boat.dev account, billed to you.") {
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
                    : "Sleeps when idle, so it costs very little — but routines only run when "
                      + "something wakes it, which means your Mac has to be awake."
            ) {
                Toggle("Keep it running", isOn: $alwaysOn)
                    .toggleStyle(.switch)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button("Create") {
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
        case .small: "Small — 2 CPUs, 4 GB"
        case .default: "Medium — 4 CPUs, 8 GB"
        case .large: "Large — 8 CPUs, 16 GB"
        }
    }
}
