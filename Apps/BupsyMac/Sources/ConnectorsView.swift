import BupsyKit
import SwiftUI

/// Apps your bots can use, as MCP servers you run.
///
/// Framed as "your servers", because that is what they are. bupsy did not write a Gmail
/// integration and does not hold a Gmail token — the server authenticates itself, wherever it
/// keeps its own credentials, and we only ever learn whether it is configured.
struct ConnectorsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Button("Add a server") { isAdding = true }
            }
            .padding(16)

            Divider()

            List {
                if !model.connectors.isEmpty {
                    Section("Yours") {
                        ForEach(model.connectors) { server in
                            ConnectorRow(server: server)
                        }
                    }
                }
                Section(model.connectors.isEmpty ? "Common ones" : "Add another") {
                    ForEach(MCPSuggestions.all) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("These are other people's software, run on your machine. bupsy never sees "
                     + "their sign-ins.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 460)
        .sheet(isPresented: $isAdding) { AddServerSheet() }
    }
}

struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer

    private var missing: [String] { server.missingEnv() }
    private var live: ConnectorState? { model.liveStatus(of: server) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { model.setConnectorEnabled(server, $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).fontWeight(.medium)
                Text("\(server.command) \(server.args.joined(separator: " "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // The engine's own verdict wins over our guess: a server can be configured
                // perfectly and still fail to start, and a tick next to something about to
                // break a run is worse than no tick at all.
                if let live, live.status != .connected {
                    Text(describe(live.status))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let live, live.status == .connected {
                    Text("Connected")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if !missing.isEmpty {
                    // Named plainly, because the alternative is a bot failing mid-run with a
                    // message from someone else's server that nobody can act on.
                    Text("Set \(missing.joined(separator: " and ")) in your shell, then restart bupsy.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                model.removeConnector(server)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .opacity(server.enabled ? 1 : 0.5)
    }

    private func describe(_ status: ConnectorState.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .failed: "Failed to start — check the command and arguments"
        case .needsAuth: "Needs you to sign in"
        case .pending: "Starting…"
        case .unknown: "Status unknown"
        }
    }
}

struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: MCPSuggestions.Suggestion

    private var alreadyAdded: Bool {
        model.connectors.contains { $0.name == suggestion.server.name }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                Text(suggestion.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(alreadyAdded ? "Added" : "Add") {
                model.addConnector(suggestion.server)
            }
            .disabled(alreadyAdded)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// The generic path, and the one that matters. A built-in catalogue would rot; being able to add
/// any MCP server never does.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = "npx"
    @State private var args = ""
    @State private var envNames = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an MCP server").font(.headline)

            TextField("Name", text: $name, prompt: Text("linear"))
                .textFieldStyle(.roundedBorder)
            TextField("Command", text: $command)
                .textFieldStyle(.roundedBorder)
            TextField("Arguments", text: $args, prompt: Text("-y @acme/linear-mcp-server"))
                .textFieldStyle(.roundedBorder)
            TextField("Environment variables it needs", text: $envNames,
                      prompt: Text("LINEAR_API_KEY"))
                .textFieldStyle(.roundedBorder)

            Text("Names only — bupsy never stores the values. Set them in your shell and they "
                 + "reach the server without passing through us.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    model.addConnector(MCPServer(
                        name: name.trimmingCharacters(in: .whitespaces),
                        command: command.trimmingCharacters(in: .whitespaces),
                        args: args.split(separator: " ").map(String.init),
                        requiredEnvNames: envNames
                            .split(whereSeparator: { $0 == " " || $0 == "," })
                            .map(String.init)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
