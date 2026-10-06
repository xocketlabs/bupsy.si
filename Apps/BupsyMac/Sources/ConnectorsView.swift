import BupsyKit
import SwiftUI

/// Apps your bots can use, as MCP servers you run.
///
/// Framed as "your servers", because that is what they are. Bupsy did not write a Gmail
/// integration and does not hold a Gmail token. The server authenticates itself, wherever it
/// keeps its own credentials, and we only ever learn whether it is configured.
struct ConnectorsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var isAdding = false

    private var servers: [MCPServer] { model.connectors.filter { $0.name != Executor.name } }

    var body: some View {
        SetupPageScroll {
            SetupPageHeader(
                title: "Apps",
                description: "Connect a tool once and every bot can use it. Bots still ask before they do."
            ) {
                Button { isAdding = true } label: {
                    Label("Add a server", systemImage: "plus")
                }
                .buttonStyle(QuietButton())
            }

            ExecutorCard()

            SetupSectionRule()

            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                SetupSectionHeader(
                    icon: "apple.terminal",
                    title: "Your servers",
                    badge: servers.isEmpty ? nil : "\(servers.count)",
                    badgeTone: .info,
                    description: "MCP servers you added yourself. Bupsy stores names of the keys they "
                        + "need, never the values.")

                if servers.isEmpty {
                    EmptyState(
                        title: "No servers yet",
                        message: "Add any MCP server by its command, or pick a common one below.",
                        faceSize: 56
                    ) {
                        Button("Add a server") { isAdding = true }
                            .buttonStyle(QuietButton(compact: true))
                    }
                    .background(palette.card, in: .rect(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: Theme.Space.step) {
                        ForEach(servers) { server in
                            ConnectorRow(server: server)
                        }
                    }
                }
            }

            if !unaddedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                    SetupSectionHeader(icon: "plus", title: "Common ones")
                    // Filtered rather than disabled in place. A server you have added is
                    // already listed above, and leaving a greyed-out "Added" copy below it
                    // showed every connector twice, which reads as a bug because it is one.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.step),
                                        GridItem(.flexible(), spacing: Theme.Space.step)],
                              alignment: .leading, spacing: Theme.Space.step) {
                        ForEach(unaddedSuggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion)
                        }
                    }
                }
            }
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
/// Four states, each with one obvious action: install it, wait for the installer, open it, or
/// turn it back on. Once installed it is on for every bot without a click; its tools still ask
/// first. A mascot sits in the panel and wears the state: waiting, busy, pleased, asleep.
struct ExecutorCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private enum Phase { case checking, missing, installing, on, off }

    private var phase: Phase {
        switch model.executorInstalled {
        case nil: return .checking
        case false?: return model.executorInstalling ? .installing : .missing
        case true?: return isAdded ? .on : .off
        }
    }

    private var isAdded: Bool { model.connectors.contains { $0.name == Executor.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SetupSectionHeader(
                icon: "square.grid.2x2.fill",
                title: "Executor",
                badge: badge.text,
                badgeTone: badge.tone,
                description: "Gmail, Notion, Linear or any API. The keys stay in Executor, never in Bupsy.")

            SetupPanel(footer: footer) {
                HStack(alignment: .center, spacing: 20) {
                    BotFace(hue: 0, mood: mood, size: 88, shape: .bup, colour: 0)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(title)
                            .font(.system(size: Theme.scaled(17), weight: .medium))
                            .tracking(-0.3)
                            .foregroundStyle(palette.foreground)
                        Text(detail)
                            .font(.system(size: Theme.scaled(13)))
                            .foregroundStyle(palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
        }
    }

    private var badge: (text: String, tone: SetupTone) {
        switch phase {
        case .checking: return ("Checking", .neutral)
        case .missing: return ("Not installed", .warning)
        case .installing: return ("Installing", .info)
        case .on: return ("On for every bot", .success)
        case .off: return ("Off", .neutral)
        }
    }

    private var mood: BotMood {
        switch phase {
        case .checking, .missing: return .idle
        case .installing: return .working
        case .on: return .done
        case .off: return .sleeping
        }
    }

    private var title: String {
        switch phase {
        case .checking: return "Looking for Executor"
        case .missing: return "Executor isn\u{2019}t on this Mac yet"
        case .installing: return "Installing in Terminal..."
        case .on: return "Executor is on"
        case .off: return "Installed, but off for your bots"
        }
    }

    private var detail: String {
        switch phase {
        case .checking:
            return "Checking whether Executor is installed on this Mac."
        case .missing:
            return "Install it once. It opens Terminal and runs Executor\u{2019}s own installer. "
                + "Free and open source, and it needs Node.js."
        case .installing:
            return "This switches on by itself when it finishes. Bupsy checks for up to 10 minutes."
        case .on:
            return "Open it to sign in to Gmail, Notion, Linear and more. Then ask any bot, like "
                + "\u{201C}check my latest emails\u{201D}."
        case .off:
            return "Turn it back on whenever you want bots to use your apps."
        }
    }

    private var footer: String {
        switch phase {
        case .checking: return "Takes a moment"
        case .missing: return "Takes about a minute"
        case .installing: return "Leave Terminal open"
        case .on: return "Each bot still asks before it uses a tool, and you can say Always allow."
        case .off: return "Your connections in Executor are kept"
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .missing:
            Button { model.installExecutor() } label: {
                Label("Install", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(PrimaryButton())
            .help("Runs Executor's own installer (npm install -g executor) in Terminal")
        case .installing:
            HStack(spacing: Theme.Space.snug) {
                ProgressView().controlSize(.small)
                Button("Done installing") { model.refreshExecutor() }
                    .buttonStyle(QuietButton())
            }
        case .on:
            HStack(spacing: Theme.Space.snug) {
                Button { NSWorkspace.shared.open(Executor.webURL) } label: {
                    Label("Open Executor", systemImage: "arrow.right")
                }
                .buttonStyle(PrimaryButton())
                if let server = model.connectors.first(where: { $0.name == Executor.name }) {
                    Button("Turn off for my bots") { model.removeConnector(server) }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, Theme.Space.snug)
                }
            }
        case .off:
            Button("Turn on") { model.addExecutor() }
                .buttonStyle(PrimaryButton())
        }
    }
}

struct ConnectorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let server: MCPServer
    /// Set to ask before removing. Removing also takes back every always-allow rule for it.
    @State private var removing: MCPServer?

    init(server: MCPServer) {
        self.server = server
    }

    private var missing: [String] { server.missingEnv() }
    private var live: ConnectorState? { model.liveStatus(of: server) }

    var body: some View {
        SetupListRow(title: server.name, meta: meta, monospacedMeta: nil) {
            IconTile(systemName: "chevron.left.forwardslash.chevron.right")
        } trailing: {
            HStack(spacing: Theme.Space.snug) {
                SetupBadge(text: status.text, tone: status.tone, dot: status.dot)
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { model.setConnectorEnabled(server, $0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(server.enabled ? "Turn off \(server.name)" : "Turn on \(server.name)")
                SetupIconButton(systemName: "trash", help: "Remove \(server.name)", destructive: true) {
                    removing = server
                }
            }
        }
        .opacity(server.enabled ? 1 : 0.6)
        .confirmsDeletion(
            of: $removing,
            title: { "Remove \($0.name)?" },
            button: "Remove server",
            message: { _ in "Bots lose its tools and any always-allow rules for it." },
            perform: { model.removeConnector($0) })
    }

    private var command: String {
        ([server.command] + server.args).joined(separator: " ")
    }

    /// The command, then the one thing to do about it if anything.
    private var meta: [String] {
        var parts = [command]
        if let live, live.status == .failed {
            parts.append("Check the command and arguments")
        } else if live == nil || live?.status != .connected, !missing.isEmpty {
            // Named plainly, because the alternative is a bot failing mid-run with a message
            // from someone else's server that nobody can act on.
            parts.append("Set \(missing.joined(separator: " and ")) in your shell, then restart Bupsy")
        }
        return parts
    }

    /// The engine's own verdict wins over our guess: a server can be configured perfectly and
    /// still fail to start, and a tick next to something about to break a run is worse than no
    /// tick at all.
    private var status: (text: String, tone: SetupTone, dot: Bool) {
        if !server.enabled { return ("Off", .neutral, false) }
        if let live {
            switch live.status {
            case .connected: return ("Connected", .success, true)
            case .failed: return ("Failed to start", .destructive, false)
            case .needsAuth: return ("Needs you to sign in", .warning, false)
            case .pending: return ("Starting", .info, false)
            case .unknown: break
            }
        }
        if !missing.isEmpty { return ("Needs \(missing.joined(separator: ", "))", .warning, false) }
        return ("Not used yet", .neutral, false)
    }
}

struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: MCPSuggestions.Suggestion

    var body: some View {
        SetupListRow(title: suggestion.title, meta: [suggestion.detail]) {
            IconTile(systemName: icon)
        } trailing: {
            Button { model.addConnector(suggestion.server) } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(QuietButton(compact: true))
        }
    }

    /// One glyph per app, so the list can be scanned instead of read. Four identical boxes said
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
                hint: "Names only. Bupsy never stores the values. Set them in your shell and "
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
