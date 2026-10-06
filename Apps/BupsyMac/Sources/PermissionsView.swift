import BupsyKit
import SwiftUI

/// Every standing decision in one place: what each bot may do without asking, and which bots may
/// message which.
///
/// An "always allow" you cannot find again is a permission you cannot take back, so each one is
/// listed here with a way to remove it. Removing never denies anything; it only means the next
/// time, you are asked.
struct PermissionsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    /// One row per rule, each carrying the bot it belongs to, in roster order. A row can hold
    /// more than one tool: editing and writing files are one permission to a person, so they are
    /// one row, and removing it takes back both.
    private struct AllowRule: Identifiable {
        let bot: Bot
        let tools: [String]
        var id: String { "\(bot.id.rawValue)|\(tools.joined(separator: ","))" }
    }

    /// The tools that together mean "edit files in its folder".
    private static let fileEditTools: Set<String> = ["Edit", "MultiEdit", "Write"]

    private var rules: [AllowRule] {
        model.bots.flatMap { bot -> [AllowRule] in
            let all = bot.toolAllowlist.sorted()
            let editing = all.filter { Self.fileEditTools.contains($0) }
            var rows: [AllowRule] = []
            if !editing.isEmpty { rows.append(AllowRule(bot: bot, tools: editing)) }
            for tool in all where !Self.fileEditTools.contains(tool) {
                rows.append(AllowRule(bot: bot, tools: [tool]))
            }
            return rows
        }
    }

    var body: some View {
        let rules = self.rules
        let decisions = model.linkDecisions.filter {
            name(of: $0.fromBotID) != nil && name(of: $0.toBotID) != nil
        }

        SetupPageScroll {
            SetupPageHeader(title: "Permissions",
                            description: "What your bots may do without asking you first")

            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                SetupSectionHeader(
                    icon: "shield.fill",
                    title: "Allowed without asking",
                    badge: rules.isEmpty ? nil : "\(rules.count) \(rules.count == 1 ? "rule" : "rules")",
                    badgeTone: .info,
                    description: "Every rule here came from you choosing Always allow on a request.")

                if rules.isEmpty {
                    SetupEmptyNote(text: "Nothing yet. Choose Always allow on a bot's request and it shows up here.")
                } else {
                    VStack(spacing: Theme.Space.step) {
                        ForEach(rules) { rule in
                            SetupListRow(title: describe(rule.tools), meta: [rule.bot.name, toolMeta(rule.tools)],
                                         monospacedMeta: 1) {
                                BotFace(bot: rule.bot, mood: .idle, size: 44)
                            } trailing: {
                                SetupIconButton(systemName: "trash",
                                                help: "Remove, and ask again next time",
                                                destructive: true) {
                                    for tool in rule.tools { model.disallow(tool, for: rule.bot) }
                                }
                            }
                        }
                    }
                }
            }

            SetupSectionRule()

            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                SetupSectionHeader(
                    icon: "bubble.left.fill",
                    title: "Bots messaging bots",
                    description: "Each answer covers one direction only.")

                if decisions.isEmpty {
                    SetupEmptyNote(text: "No answers yet. The first time one bot messages another, you\u{2019}re asked.")
                } else {
                    VStack(spacing: Theme.Space.step) {
                        // Keyed by direction, not position: removing one answer must not hand its
                        // row's state to the next.
                        ForEach(decisions, id: \.directionKey) { link in
                            SetupListRow(
                                title: "\(name(of: link.fromBotID) ?? "A bot") to \(name(of: link.toBotID) ?? "a bot")",
                                meta: [link.allowed
                                       ? "Allowed \(Self.when(link.decidedAt))"
                                       : "You said no \(Self.when(link.decidedAt))"]
                            ) {
                                IconTile(systemName: "arrow.right")
                            } trailing: {
                                HStack(spacing: Theme.Space.snug) {
                                    SetupBadge(text: link.allowed ? "Allowed" : "Not allowed",
                                               tone: link.allowed ? .success : .neutral)
                                    SetupIconButton(systemName: "trash",
                                                    help: "Forget this answer, and ask again next time",
                                                    destructive: true) {
                                        model.forgetLink(from: link.fromBotID, to: link.toBotID)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            SetupFootnote(text: "Shell commands are never on these lists. A bot always asks before running one.")
        }
    }

    private func name(of id: String) -> String? { model.bots.first { $0.id.rawValue == id }?.name }

    /// "today", "yesterday", "on Monday", "on 3 Oct": when an answer was given, in words.
    private static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: now), date > week {
            return "on " + date.formatted(.dateTime.weekday(.wide))
        }
        return "on " + date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Anything in GitHub" for a whole server, "Edit files in its folder" for editing, and the
    /// request's own words for anything else.
    private func describe(_ tools: [String]) -> String {
        if tools.contains(where: { Self.fileEditTools.contains($0) }) {
            return "Edit files in its folder"
        }
        guard let tool = tools.first else { return "" }
        if tool.hasSuffix("__"), tool.hasPrefix("mcp__") {
            let server = String(tool.dropFirst(5).dropLast(2))
            return "Anything in \(MCPServer.displayName(of: server))"
        }
        let action = ToolNames.action(tool)
        return action.prefix(1).uppercased() + action.dropFirst()
    }

    /// The tool names behind a row, as the engine spells them: "Edit, Write", "mcp__github__*".
    private func toolMeta(_ tools: [String]) -> String {
        tools.map { tool in
            tool.hasPrefix("mcp__") && tool.hasSuffix("__") ? tool + "*" : tool
        }
        .joined(separator: ", ")
    }
}

private extension BotLinkRecord {
    /// "from|to": one answer per direction, so this is unique in the list.
    var directionKey: String { "\(fromBotID)|\(toBotID)" }
}
