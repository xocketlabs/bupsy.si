import BupsyKit
import SwiftUI

/// Bupsy's own slash commands: things the app does, typed in the message box. Never sent to the
/// engine, so they mean the same for every bot, whichever engine it runs.
enum BupsyCommand: String, CaseIterable {
    // In menu order. A slash and Return picks the first, so it is one that only opens something.
    case model, details, routine, fresh, stop, help

    var summary: String {
        switch self {
        case .fresh: "Carry on in a fresh chat, from notes the bot writes first"
        case .model: "Switch this bot's model"
        case .stop: "Stop what the bot is doing"
        case .details: "Open this bot's settings, goals and routines"
        case .routine: "Set up a routine for this bot"
        case .help: "Every command you can use here"
        }
    }

    /// What can be done from here for a bot on another Mac: its settings live on its own Mac.
    func isAvailable(for bot: Bot) -> Bool {
        bot.remote == nil || self == .stop || self == .help
    }

    var command: SlashCommand {
        SlashCommand(name: rawValue, description: summary, argumentHint: self == .model ? "name" : nil, source: .bupsy)
    }
}

/// The engine's commands for each folder, read off the main thread and kept, so the menu opens at
/// once with what was there last time and catches up when the files have changed.
@MainActor @Observable
final class SlashCommandLibrary {
    static let shared = SlashCommandLibrary()

    private var lists: [String: [SlashCommand]] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    private static func key(_ engine: EngineID, _ workdir: URL?) -> String {
        engine.rawValue + "\u{1}" + (workdir?.path ?? "")
    }

    /// What is known so far: Claude's built-ins at the very least, until the files are read.
    func commands(engine: EngineID, workdir: URL?) -> [SlashCommand] {
        lists[Self.key(engine, workdir)] ?? (engine == .claude ? ClaudeCommands.builtIns : [])
    }

    /// Reads the commands again. Called each time the menu opens, since a command file can be
    /// added or edited at any time and there is nothing to tell us.
    func refresh(engine: EngineID, workdir: URL?) {
        let key = Self.key(engine, workdir)
        guard reading.insert(key).inserted else { return }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.discover(engine: engine, workdir: workdir)
            }.value
            reading.remove(key)
            if lists[key] != found { lists[key] = found }
        }
    }

    nonisolated private static func discover(engine: EngineID, workdir: URL?) -> [SlashCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch engine {
        case .claude: return ClaudeCommands.builtIns + ClaudeCommands.discover(home: home, workdir: workdir)
        case .codex: return CodexPrompts.discover(in: CodexPrompts.folder(home: home))
        case .grok, .opencode: return []
        }
    }
}

/// One row of the menu.
struct SlashMenuItem: Identifiable, Equatable {
    enum Action: Equatable {
        /// One of Bupsy's own, done when picked.
        case run(BupsyCommand)
        /// Puts the text in the box, for arguments to follow.
        case insert(String)
        /// A model for /model. nil is the CLI's own default.
        case model(String?)
    }

    let id: String
    let title: String
    var hint: String?
    let detail: String
    var tag: String?
    var tone: BadgeTone = .neutral
    var checked = false
    let action: Action

    /// The rows for what is in the box: commands while their name is being typed, the bot's
    /// models after "/model ", and none otherwise, so the menu never gets in the way of a message.
    @MainActor
    static func items(for draft: String, bot: Bot, engineCommands: [SlashCommand], models: [ModelOption]) -> [SlashMenuItem] {
        if let typed = SlashInput.typedName(draft) {
            let own = BupsyCommand.allCases.filter { $0.isAvailable(for: bot) }.map(\.command)
            // A bot on another Mac runs that Mac's commands, which this one cannot see. A command
            // of the person's with one of Bupsy's names would never reach the engine, so it is
            // not offered.
            let engine = bot.remote == nil ? engineCommands.filter { BupsyCommand(rawValue: $0.name) == nil } : []
            return SlashCommandMatch.rank(own + engine, query: typed).map(item(for:))
        }
        let modelPrefix = "/model "
        guard bot.remote == nil, draft.lowercased().hasPrefix(modelPrefix) else { return [] }
        let wanted = draft.dropFirst(modelPrefix.count).trimmingCharacters(in: .whitespaces).lowercased()
        var rows = models.filter { option in
            wanted.isEmpty || option.label.lowercased().contains(wanted) || (option.id?.lowercased().contains(wanted) ?? false)
        }.map { option in
            SlashMenuItem(id: "model:\(option.id ?? "")", title: option.label, hint: option.id,
                          detail: option.detail ?? "", checked: bot.model == option.id, action: .model(option.id))
        }
        // Anything the list doesn't have yet, the way the model menu takes a custom one.
        if !wanted.isEmpty, rows.isEmpty {
            let typed = draft.dropFirst(modelPrefix.count).trimmingCharacters(in: .whitespaces)
            rows.append(SlashMenuItem(id: "model-custom", title: "Use \u{201C}\(typed)\u{201D}",
                                      detail: "Any model \(bot.engine.displayName) accepts, passed exactly as typed",
                                      action: .model(typed)))
        }
        return rows
    }

    private static func item(for command: SlashCommand) -> SlashMenuItem {
        let action: Action
        if command.source == .bupsy, let own = BupsyCommand(rawValue: command.name), own != .model {
            action = .run(own)
        } else {
            action = .insert("/\(command.name) ")
        }
        let (tag, tone): (String, BadgeTone) = switch command.source {
        case .bupsy: ("Bupsy", .primary)
        case .claude: ("Claude", .neutral)
        case .personal: ("Yours", .info)
        case .project: ("Project", .success)
        case .codex: ("Codex", .neutral)
        }
        return SlashMenuItem(id: command.source.rawValue + ":" + command.name, title: "/" + command.name,
                             hint: command.argumentHint, detail: command.description, tag: tag, tone: tone,
                             action: action)
    }
}

/// The list over the message box while a command is typed, like the one in Claude Code's editor
/// extension: the highlighted row follows the arrow keys, and a click picks a row too.
struct SlashMenu: View {
    @Environment(\.palette) private var palette
    let items: [SlashMenuItem]
    @Binding var highlighted: Int
    let onPick: (SlashMenuItem) -> Void

    private static let rowHeight: CGFloat = Theme.scaled(34)
    private static let visibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, isHighlighted: index == highlighted)
                                .id(item.id)
                                .contentShape(.rect)
                                .onTapGesture { onPick(item) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(Theme.Space.xs)
                }
                .scrollIndicators(items.count > Self.visibleRows ? .automatic : .never)
                .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + Theme.Space.xs * 2)
                .onChange(of: highlighted) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
            Rectangle().fill(palette.border).frame(height: 1)
            Text("\u{2191}\u{2193} to choose, Return or Tab to pick, Esc to close")
                .font(Theme.Typography.caption)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, Theme.Space.step)
                .padding(.vertical, Theme.Space.tight)
        }
        .background(palette.popover, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(palette.border)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private func row(_ item: SlashMenuItem, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.Space.snug) {
            if item.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: Theme.scaled(10), weight: .semibold))
                    .foregroundStyle(palette.foreground)
            }
            Text(item.title)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(palette.foreground)
                .layoutPriority(2)
            if let hint = item.hint, !hint.isEmpty {
                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground.opacity(0.8))
                    .layoutPriority(1)
            }
            Text(item.detail)
                .font(Theme.Typography.label)
                .foregroundStyle(palette.mutedForeground)
            Spacer(minLength: Theme.Space.snug)
            if let tag = item.tag { SlashTag(text: tag, tone: item.tone) }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, Theme.Space.snug)
        .frame(height: Self.rowHeight)
        .background(isHighlighted ? palette.card : .clear, in: .rect(cornerRadius: Theme.Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}

/// Where a command comes from, small enough to sit at the end of a row.
private struct SlashTag: View {
    @Environment(\.palette) private var palette
    let text: String
    let tone: BadgeTone

    var body: some View {
        Text(text)
            .font(Theme.Typography.badge)
            .foregroundStyle(tone.text(palette))
            .padding(.horizontal, Theme.Space.tight)
            .padding(.vertical, 2)
            .background(tone.fill(palette), in: .rect(cornerRadius: Theme.Radius.sm))
            .fixedSize()
    }
}

extension AppModel {
    /// /model from the message box. Said in the chat, since nothing else on screen changes.
    func setModelFromChat(_ bot: Bot, _ id: String?) {
        setModel(bot, id)
        let label = id.flatMap { id in models(for: bot).first { $0.id == id }?.label } ?? id
        thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
            label.map { "\(bot.name) now uses \($0)." } ?? "\(bot.name) now uses your CLI's default model.")))
    }

    /// The prompt a Codex `/prompts:name args` stands for, read from the file as it is now. Nil
    /// when there is no such prompt, so the text goes as typed; an error says what is missing.
    func codexPromptExpansion(_ text: String) -> Result<String, CodexPrompts.ExpansionError>? {
        guard let (name, arguments) = SlashInput.parse(text), name.hasPrefix(CodexPrompts.prefix) else { return nil }
        let file = CodexPrompts.folder(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(String(name.dropFirst(CodexPrompts.prefix.count)) + ".md")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        do { return .success(try CodexPrompts.expand(file: content, arguments: arguments)) } catch { return .failure(error) }
    }
}
