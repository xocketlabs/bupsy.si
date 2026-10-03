import BupsyKit
import SwiftUI

/// Apps your bots can use, as MCP servers you run.
///
/// Framed as "your servers", because that is what they are. bupsy did not write a Gmail
/// integration and does not hold a Gmail token — the server authenticates itself, wherever it
/// keeps its own credentials, and we only ever learn whether it is configured.
struct ConnectorsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var isAdding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SectionHeader(
                    icon: "puzzlepiece.extension",
                    title: "Apps",
                    badge: model.connectors.isEmpty ? nil : "\(model.connectors.count)",
                    subtitle: "Your MCP servers, run on your machine. bupsy never sees their sign-ins."
                ) {
                    Button("Add a server") { isAdding = true }
                        .buttonStyle(QuietButton())
                }

                if !model.connectors.isEmpty {
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(model.connectors) { server in
                            ConnectorRow(server: server)
                        }
                    }
                }

                if !unaddedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    Text((model.connectors.isEmpty ? "Common ones" : "Add another").uppercased())
                        .font(Theme.Typography.badge)
                        .foregroundStyle(palette.sidebarMuted)
                        .tracking(0.7)
                    VStack(spacing: Theme.Space.snug) {
                        // Filtered rather than disabled in place. A server you have added is
                        // already listed above, and leaving a greyed-out "Added" copy below it
                        // showed every connector twice — which reads as a bug, because it is one.
                        ForEach(unaddedSuggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion)
                        }
                    }
                }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: Theme.Size.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(isPresented: $isAdding) { AddServerSheet() }
    }

    /// The catalogue minus what is already set up.
    private var unaddedSuggestions: [MCPSuggestions.Suggestion] {
        MCPSuggestions.all.filter { suggestion in
            !model.connectors.contains { $0.name == suggestion.server.name }
        }
    }
}

struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let server: MCPServer

    private var missing: [String] { server.missingEnv() }
    private var live: ConnectorState? { model.liveStatus(of: server) }

    var body: some View {
        CardRow {
            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { model.setConnectorEnabled(server, $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Text("\(server.command) \(server.args.joined(separator: " "))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)

                // The engine's own verdict wins over our guess: a server can be configured
                // perfectly and still fail to start, and a tick next to something about to
                // break a run is worse than no tick at all.
                if let live, live.status != .connected {
                    Text(describe(live.status))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.primary)
                } else if let live, live.status == .connected {
                    Text("Connected")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.green)
                } else if !missing.isEmpty {
                    // Named plainly, because the alternative is a bot failing mid-run with a
                    // message from someone else's server that nobody can act on.
                    Text("Set \(missing.joined(separator: " and ")) in your shell, then restart bupsy.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.primary)
                }
            }
        } trailing: {
            Button(role: .destructive) {
                model.removeConnector(server)
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.mutedForeground)
        }
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
    @Environment(\.palette) private var palette
    let suggestion: MCPSuggestions.Suggestion

    var body: some View {
        CardRow {
            IconTile(systemName: "shippingbox")
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                Text(suggestion.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
        } trailing: {
            Button("Add") { model.addConnector(suggestion.server) }
                .buttonStyle(QuietButton(compact: true))
        }
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
