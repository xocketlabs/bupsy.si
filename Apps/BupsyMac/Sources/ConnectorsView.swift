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

                ExecutorCard()

                if model.connectors.contains(where: { $0.name != Executor.name }) {
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(model.connectors.filter { $0.name != Executor.name }) { server in
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
        .onAppear { model.refreshExecutor() }
    }

    /// The catalogue minus what is already set up.
    private var unaddedSuggestions: [MCPSuggestions.Suggestion] {
        MCPSuggestions.all.filter { suggestion in
            !model.connectors.contains { $0.name == suggestion.server.name }
        }
    }
}

/// Executor, offered first: one connection that brings every tool the person set up in it.
///
/// Three states, each with one obvious action — install it, connect tools in it, or turn it back
/// on. Once installed it is on for every bot without a click; its tools still ask first.
struct ExecutorCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private var isOn: Bool { model.connectors.contains { $0.name == Executor.name && $0.enabled } }
    private var isAdded: Bool { model.connectors.contains { $0.name == Executor.name } }

    @State private var showsGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
            if showsGuide || model.executorInstalled == false {
                guide
            }
        }
        .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }

    /// Three steps, in the order they happen, each with the button that does it.
    private var guide: some View {
        VStack(alignment: .leading, spacing: Theme.Space.step) {
            Rectangle().fill(palette.border).frame(height: 1)
            step(1, "Install Executor",
                 model.executorInstalled == true ? "Installed on this Mac."
                    : "Free and open source. Needs Node.js — the installer says so if it's missing.",
                 done: model.executorInstalled == true) {
                if model.executorInstalled != true {
                    Button("Install") { model.installExecutor() }
                        .buttonStyle(QuietButton(compact: true))
                        .disabled(model.executorInstalling)
                }
            }
            step(2, "Connect your tools in Executor",
                 "Open it, add Gmail, Notion, Linear, GitHub or any API, and sign in to each there. "
                    + "The keys stay in Executor.",
                 done: false) {
                Button("Open Executor") { NSWorkspace.shared.open(Executor.webURL) }
                    .buttonStyle(QuietButton(compact: true))
                    .disabled(model.executorInstalled != true)
            }
            step(3, "Ask any bot to use them",
                 "Executor is switched on for every bot. Try \"check my latest emails\" — the bot asks "
                    + "you before it uses a tool, and you can say Always allow.",
                 done: false) { EmptyView() }
            if let server = model.connectors.first(where: { $0.name == Executor.name }) {
                HStack {
                    Spacer(minLength: 0)
                    Button("Turn off for my bots") { model.removeConnector(server) }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
        .padding(.horizontal, Theme.Space.step)
        .padding(.bottom, Theme.Space.step)
    }

    private func step<Action: View>(_ number: Int, _ title: String, _ detail: String, done: Bool,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.step) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.2) : palette.primary.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: Theme.scaled(10), weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: Theme.scaled(11), weight: .bold)).foregroundStyle(palette.primary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.body.weight(.medium)).foregroundStyle(palette.foreground)
                Text(detail).font(Theme.Typography.caption).foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
        }
    }

    private var card: some View {
        HStack(spacing: Theme.Space.step) {
            IconTile(systemName: "point.3.connected.trianglepath.dotted")
            cardText
            Spacer(minLength: 0)
            cardTrailing
        }
        .padding(Theme.Space.step)
    }

    private var cardText: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Executor")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.foreground)
                    if isOn {
                        Text("On for every bot")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Color.green)
                    }
                }
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cardTrailing: some View {
        Group {
            HStack(spacing: Theme.Space.tight) {
                action
                if model.executorInstalled == true {
                    Button(showsGuide ? "Hide steps" : "How to connect") { showsGuide.toggle() }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(palette.mutedForeground)
                }
            }
        }
    }

    private var detail: String {
        switch model.executorInstalled {
        case nil:
            return "Checking whether Executor is on this Mac…"
        case false?:
            return model.executorInstalling
                ? "Installing in Terminal. This switches on by itself when it finishes."
                : "Connect Gmail, Notion, Linear or any API once, and every bot can use them. "
                    + "Executor keeps the keys — bupsy never sees them. Free and open source."
        case true?:
            return isAdded
                ? "Add tools in Executor and every bot can use them. Each bot still asks before using one."
                : "Installed, but turned off for your bots."
        }
    }

    @ViewBuilder private var action: some View {
        switch model.executorInstalled {
        case nil:
            ProgressView().controlSize(.small)
        case false?:
            if model.executorInstalling {
                ProgressView().controlSize(.small)
            } else {
                Button("Install") { model.installExecutor() }
                    .buttonStyle(QuietButton(compact: true))
                    .help("Runs Executor's own installer (npm install -g executor) in Terminal")
            }
        case true?:
            if isAdded {
                Button("Open Executor") { NSWorkspace.shared.open(Executor.webURL) }
                    .buttonStyle(QuietButton(compact: true))
            } else {
                Button("Turn on") { model.addExecutor() }
                    .buttonStyle(QuietButton(compact: true))
            }
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
                Image(systemName: "trash").font(.system(size: Theme.scaled(12)))
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
            IconTile(systemName: icon)
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

    /// One glyph per app, so the list can be scanned instead of read — four identical boxes said
    /// nothing about which row was which.
    private var icon: String {
        switch suggestion.id {
        case "github": "chevron.left.forwardslash.chevron.right"
        case "filesystem": "folder"
        case "slack": "number"
        case "notion": "doc.text"
        default: "shippingbox"
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
        SheetFrame(
            title: "Add an MCP server",
            icon: "puzzlepiece.extension",
            subtitle: "Runs on your machine, under your own sign-ins.",
            width: 460
        ) {
            Field(label: "Name") {
                TextField("", text: $name, prompt: Text("linear"))
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(label: "Command") {
                TextField("", text: $command)
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(label: "Arguments") {
                TextField("", text: $args, prompt: Text("-y @acme/linear-mcp-server"))
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(
                label: "Environment variables it needs",
                hint: "Names only — bupsy never stores the values. Set them in your shell and "
                    + "they reach the server without passing through us."
            ) {
                TextField("", text: $envNames, prompt: Text("LINEAR_API_KEY"))
                    .textFieldStyle(BupsyFieldStyle())
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
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
            .buttonStyle(PrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                      || command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
