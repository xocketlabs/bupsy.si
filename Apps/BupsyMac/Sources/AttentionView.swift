import BupsyKit
import SwiftUI

/// Something that cannot move without a person.
struct AttentionItem: Identifiable, Hashable {
    enum Kind: Hashable { case approval, objective }

    let id: String
    let botID: BotID
    let botName: String
    let hue: Double
    let kind: Kind
    let title: String
    let detail: String
    /// Shown in a fixed-width font. In a proportional one `ls` reads as "Is".
    var detailIsCommand = false
}

/// One place for everything waiting on you.
///
/// The thing that makes standing goals usable rather than alarming. A bot that works unattended
/// will inevitably reach something only a person can settle, and without a single list those
/// land scattered across threads nobody is reading. A count on the sidebar is the difference
/// between autonomy and things quietly stalling.
/// One page for everything waiting on a person.
///
/// Decisions are made *here* rather than only linked from here. Sending someone to another screen
/// to answer a question they are already looking at is the kind of friction that turns "two things
/// need you" into a number nobody clears.
struct AttentionInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SectionHeader(
                    icon: "hand.raised",
                    title: "Waiting on you",
                    badge: model.attentionItems.isEmpty ? nil : "\(model.attentionItems.count)",
                    subtitle: "Approvals and goals that cannot move without a decision"
                ) { EmptyView() }

                if model.attentionItems.isEmpty {
                    CardRow {
                        IconTile(systemName: "checkmark.circle")
                    } content: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nothing needs you")
                                .font(Theme.Typography.body)
                                .foregroundStyle(palette.foreground)
                            Text("Approvals and stuck goals turn up here.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(palette.mutedForeground)
                        }
                    } trailing: { EmptyView() }
                } else {
                    VStack(spacing: Theme.Space.snug) {
                        ForEach(model.attentionItems) { item in
                            AttentionRow(item: item)
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
    }
}

struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let item: AttentionItem

    // By id, not name: names can change, and before they were unique two bots sharing one sent
    // a decision to whichever came first.
    private var bot: Bot? { model.bots.first { $0.id == item.botID } }

    var body: some View {
        CardRow {
            BotFace(hue: item.hue, mood: .waitingForYou, size: Theme.Size.tile)
        } content: {
            // Who is asking leads. It was last and faintest, under the tool name — but the first
            // thing anyone deciding needs is which of their bots this is.
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    if item.detailIsCommand {
                        Text(item.detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(2)
                            .padding(.horizontal, Theme.Space.tight)
                            .padding(.vertical, 3)
                            .background(palette.sidebar, in: .rect(cornerRadius: 5))
                    } else {
                        Text(item.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(2)
                    }
                }
            }
        } trailing: {
            // An approval can be settled from here; a stuck goal needs its thread, so that one
            // links out instead of pretending to offer a decision.
            if item.kind == .approval, let bot, let approval = pendingApproval(for: bot) {
                HStack(spacing: Theme.Space.tight) {
                    Button("Allow") { model.decide(approval, allow: true, for: bot) }
                        .buttonStyle(QuietButton(compact: true))
                    Button("Deny") { model.decide(approval, allow: false, for: bot) }
                        .buttonStyle(QuietButton(compact: true))
                }
            } else {
                Button("Open") { model.selectedBotID = bot?.id }
                    .buttonStyle(QuietButton(compact: true))
            }
        }
    }

    private func pendingApproval(for bot: Bot) -> PendingApproval? {
        model.thread(for: bot.id).entries.compactMap {
            if case .approval(let approval) = $0.kind, approval.id == item.id { return approval }
            return nil
        }.first
    }
}
