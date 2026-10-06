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
            // "Add a server" lives in the topbar, as on the board. See AddServerButton.
            SetupPageHeader(
                title: "Apps",
                description: "Connect a tool once and every bot can use it. Bots still ask before they do."
            )

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
                    .background(palette.card, in: .rect(cornerRadius: Theme.Radius.xl, style: .continuous))
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

/// The page's primary action, drawn in the topbar by `Page`. It owns its sheet so the topbar
/// does not need to reach into the page for state.
struct AddServerButton: View {
    @State private var isAdding = false

    var body: some View {
        Button { isAdding = true } label: {
            Label("Add a server", systemImage: "plus")
        }
        .buttonStyle(QuietButton())
        .sheet(isPresented: $isAdding) { AddServerSheet() }
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
        case .installing: return "Installing in Terminal…"
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
        case .off: return "Your connections are kept"
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
                        .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .lg))
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
    /// Set to open the edit sheet, prefilled with this server.
    @State private var editing: MCPServer?

    init(server: MCPServer) {
        self.server = server
    }

    private var missing: [String] { model.missingConnectorEnv[server.name] ?? [] }
    private var live: ConnectorState? { model.liveStatus(of: server) }

    var body: some View {
        SetupListRow(title: MCPServer.displayName(of: server.name), meta: meta, monospacedMeta: nil) {
            IconTile(systemName: "chevron.left.forwardslash.chevron.right")
        } trailing: {
            HStack(spacing: Theme.Space.snug) {
                SetupBadge(text: status.text, tone: status.tone, dot: status.dot)
                // Edit, not a switch: the board has no toggle on the row. Turning a server off
                // is in the edit sheet, next to everything else about it.
                SetupIconButton(systemName: "pencil", help: "Edit \(server.name)") {
                    editing = server
                }
                SetupIconButton(systemName: "trash", help: "Remove \(server.name)", destructive: true) {
                    removing = server
                }
            }
        }
        .opacity(server.enabled ? 1 : 0.6)
        .sheet(item: $editing) { server in AddServerSheet(editing: server) }
        .confirmsDeletion(
            of: $removing,
            title: { "Remove \($0.name)?" },
            button: "Remove server",
            message: { _ in "Bots lose its tools and any always-allow rules for it." },
            perform: { model.removeConnector($0) })
    }

    private var command: String {
        ([server.command] + [MCPServer.joinArguments(server.args)])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
///
/// Also the edit sheet: given a server, it opens prefilled and saving replaces that server.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    /// The server being edited, or nil when adding a new one.
    private let editing: MCPServer?
    @State private var name: String
    @State private var command: String
    @State private var args: String
    @State private var envNames: String
    @State private var enabled: Bool

    init(editing: MCPServer? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _command = State(initialValue: editing?.command ?? "npx")
        _args = State(initialValue: editing.map { MCPServer.joinArguments($0.args) } ?? "")
        _envNames = State(initialValue: editing?.requiredEnvNames.joined(separator: " ") ?? "")
        _enabled = State(initialValue: editing?.enabled ?? true)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedCommand: String { command.trimmingCharacters(in: .whitespaces) }

    /// Names key the engine's config, so a second server with a name already in use would
    /// silently replace the first. Said before Add, not after.
    private var duplicate: Bool {
        !trimmedName.isEmpty && model.connectorNameTaken(trimmedName, except: editing?.id)
    }

    /// Why this name cannot be used, or nil when it can.
    ///
    /// The engine names a server's tools `mcp__<name>__<tool>`, and the approval policy recognises
    /// bupsy's own tools by those names. "bupsy" is the built-in server's, and a name containing
    /// "__" would make the boundary between server and tool ambiguous — a server called
    /// `bupsy__x` produces tools that read as bupsy's own. Refused here, before it is saved.
    private var reservedNameProblem: String? {
        if trimmedName.lowercased() == "bupsy" {
            return "\"bupsy\" is the name of Bupsy's own server. Choose another name."
        }
        if trimmedName.contains("__") {
            return "A name can't contain two underscores in a row (\"__\")."
        }
        return nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedCommand.isEmpty && !duplicate && reservedNameProblem == nil
    }

    var body: some View {
        SheetFrame(
            title: editing == nil ? "Add an MCP server" : "Edit \(editing?.name ?? "server")",
            icon: "puzzlepiece.extension",
            subtitle: "Runs on your machine, under your own sign-ins.",
            width: 460,
            primaryVerb: editing == nil ? "add" : "save"
        ) {
            Field(label: "Name") {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    TextField("Name", text: $name, prompt: Text("linear"))
                        .labelsHidden()
                        .textFieldStyle(BupsyFieldStyle())
                    if let reservedNameProblem {
                        Text(reservedNameProblem)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if duplicate {
                        Text("You already have a server called \(trimmedName)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Field(label: "Command") {
                TextField("Command", text: $command, prompt: Text("npx"))
                    .labelsHidden()
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(
                label: "Arguments",
                hint: "Quote an argument with spaces, like \"/Users/me/My Folder\"."
            ) {
                TextField("Arguments", text: $args, prompt: Text("-y @acme/linear-mcp-server"))
                    .labelsHidden()
                    .textFieldStyle(BupsyFieldStyle())
            }
            Field(
                label: "Environment variables it needs",
                hint: "Names only. Bupsy never stores the values. Set them in your shell and "
                    + "they reach the server without passing through us."
            ) {
                TextField("Environment variables it needs", text: $envNames,
                          prompt: Text("LINEAR_API_KEY, LINEAR_TEAM"))
                    .labelsHidden()
                    .textFieldStyle(BupsyFieldStyle())
            }
            if editing != nil {
                Toggle("On for your bots", isOn: $enabled)
                    .bupsySwitch()
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(QuietButton())
            Button(editing == nil ? "Add" : "Save") { save() }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private func save() {
        guard canSave else { return }
        let server = MCPServer(
            id: editing?.id ?? UUID().uuidString,
            name: trimmedName,
            command: trimmedCommand,
            args: MCPServer.splitArguments(args),
            requiredEnvNames: envNames
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .map(String.init),
            enabled: enabled)
        if editing == nil {
            model.addConnector(server)
        } else {
            model.updateConnector(server)
        }
        dismiss()
    }
}
