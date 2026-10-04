import BupsyKit
import SwiftUI

/// Every standing decision in one place: what each bot may do without asking, and which bots may
/// message which.
///
/// An "always allow" you cannot find again is a permission you cannot take back, so each one is
/// listed here with a way to remove it. Removing never denies anything — it only means the next
/// time, you are asked.
struct PermissionsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private var botsWithRules: [Bot] { model.bots.filter { !$0.toolAllowlist.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SectionHeader(
                    icon: "hand.raised",
                    title: "Permissions",
                    badge: nil,
                    subtitle: "What you've said yes to for good. Remove one and you'll be asked again next time."
                ) { EmptyView() }

                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    groupTitle("Allowed without asking")
                    if botsWithRules.isEmpty {
                        note("Nothing yet. Choose “Always allow” on a bot's request and it shows up here.")
                    } else {
                        ForEach(botsWithRules) { bot in
                            SettingsGroup(title: bot.name) {
                                ForEach(Array(bot.toolAllowlist.sorted().enumerated()), id: \.element) { index, tool in
                                    rule(text: describe(tool), detail: tool, showsDivider: index > 0) {
                                        model.disallow(tool, for: bot)
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.step) {
                    groupTitle("Bots messaging bots")
                    let decisions = model.linkDecisions.filter { name(of: $0.fromBotID) != nil && name(of: $0.toBotID) != nil }
                    if decisions.isEmpty {
                        note("No decisions yet. The first time one bot messages another, you're asked.")
                    } else {
                        SettingsGroup(title: "Answered") {
                            ForEach(Array(decisions.enumerated()), id: \.offset) { index, link in
                                rule(text: "\(name(of: link.fromBotID) ?? "?") → \(name(of: link.toBotID) ?? "?")",
                                     detail: link.allowed ? "Allowed" : "Not allowed",
                                     showsDivider: index > 0) {
                                    model.forgetLink(from: link.fromBotID, to: link.toBotID)
                                }
                            }
                        }
                    }
                }

                Text("Shell commands are never on these lists: their risk is in the command itself, so each one is asked.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: Theme.Size.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func name(of id: String) -> String? { model.bots.first { $0.id.rawValue == id }?.name }

    /// "Use Notion" for a whole server, "Edit files" for a tool — the same words the request used.
    private func describe(_ tool: String) -> String {
        if tool.hasSuffix("__"), tool.hasPrefix("mcp__") {
            let server = tool.dropFirst(5).dropLast(2)
            return "Anything in \(server.capitalized)"
        }
        return ToolNames.action(tool).prefix(1).uppercased() + ToolNames.action(tool).dropFirst()
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.badge)
            .foregroundStyle(palette.sidebarMuted)
            .tracking(0.7)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.mutedForeground)
            .padding(Theme.Space.step)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: .rect(cornerRadius: Theme.Radius.card))
    }

    private func rule(text: String, detail: String, showsDivider: Bool, remove: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            if showsDivider { Rectangle().fill(palette.border).frame(height: 1) }
            HStack(spacing: Theme.Space.step) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(Theme.Typography.body).foregroundStyle(palette.foreground)
                    Text(detail)
                        .font(.system(size: Theme.scaled(11), design: .monospaced))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Remove", action: remove)
                    .buttonStyle(QuietButton(compact: true))
            }
            .padding(.horizontal, Theme.Space.step)
            .padding(.vertical, Theme.Space.snug)
        }
    }
}
