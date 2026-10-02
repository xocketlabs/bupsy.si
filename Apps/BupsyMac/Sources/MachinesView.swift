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
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Machines").font(.headline)
                Spacer()
                if model.hasComputeKey {
                    Button("New machine") { isCreating = true }
                }
            }
            .padding(16)

            Divider()

            if !model.hasComputeKey {
                ComputeKeySetup()
            } else if model.machines.isEmpty {
                VStack(spacing: 6) {
                    Text("No machines yet").font(.callout)
                    Text("A machine is a computer in the cloud your bots can use. "
                         + "Give one to a bot and its routines keep running with your Mac closed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    ForEach(model.machines) { machine in
                        MachineRow(machine: machine)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                if let problem = model.machineProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 440)
        .sheet(isPresented: $isCreating) { NewMachineSheet() }
    }
}

/// Where the user pastes their own key. Says plainly whose account it is and where it goes.
struct ComputeKeySetup: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your own boat.dev account").font(.callout).fontWeight(.medium)
            // One string literal, not a concatenation: SwiftUI only parses markdown in a
            // literal, so `"a" + "**b**"` renders the asterisks verbatim.
            Text("bupsy has no cloud of its own. Machines run on **your** boat.dev account, billed to you, under your control. Your key is kept in this Mac's Keychain and never leaves it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("boat.dev API key", text: $key)
                .textFieldStyle(.roundedBorder)

            HStack {
                Link("Get a key", destination: URL(string: "https://boat.dev")!)
                    .font(.caption)
                Spacer()
                Button("Save") {
                    model.setComputeKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    key = ""
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let machine: MachineRecord

    private var assignedBots: [Bot] {
        model.bots.filter { $0.machineID == machine.id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(machine.state == "running" ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if assignedBots.isEmpty {
                    Text("No bots assigned — this machine is costing you nothing useful.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(assignedBots.map(\.name).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button(machine.state == "running" ? "Stop" : "Start") {
                    model.toggleMachine(machine)
                }
                Divider()
                Button("Delete", role: .destructive) { model.deleteMachine(machine) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("New machine").font(.headline)

            TextField("Name", text: $name, prompt: Text("work"))
                .textFieldStyle(.roundedBorder)

            Picker("Size", selection: $size) {
                ForEach(MachineSize.allCases, id: \.self) { size in
                    Text(label(for: size)).tag(size)
                }
            }

            Toggle("Keep it running", isOn: $alwaysOn)
            Text(alwaysOn
                 ? String(format: "Routines run on time even with your Mac closed. "
                          + "Costs about $%.0f a month on your boat.dev account.",
                          size.alwaysOnMonthlyUSD)
                 : "Sleeps when idle, so it costs very little — but routines only run when "
                   + "something wakes it, which means your Mac has to be awake.")
                .font(.caption)
                .foregroundStyle(alwaysOn ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.createMachine(
                        name: name.trimmingCharacters(in: .whitespaces),
                        size: size, alwaysOn: alwaysOn)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func label(for size: MachineSize) -> String {
        switch size {
        case .small: "Small — 2 CPUs, 4 GB"
        case .default: "Medium — 4 CPUs, 8 GB"
        case .large: "Large — 8 CPUs, 16 GB"
        }
    }
}
