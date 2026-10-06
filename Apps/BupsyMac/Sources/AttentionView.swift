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
/// land scattered across threads nobody is reading.
///
/// Decisions are made *here* rather than only linked from here: each approval is the same card
/// as in the thread, with the same buttons. Sending someone to another screen to answer a question
/// they are already looking at is the kind of friction that turns "two things need you" into a
/// number nobody clears.
struct AttentionInbox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    private var approvals: [AttentionItem] { model.attentionItems.filter { $0.kind == .approval } }
    private var goals: [AttentionItem] { model.attentionItems.filter { $0.kind == .objective } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("Waiting on you")
                        .font(.system(size: Theme.scaled(21), weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(palette.foreground)
                    Text("Approvals and goals that can't move without a decision")
                        .font(Theme.Typography.body)
                        .foregroundStyle(palette.mutedForeground)
                }

                if model.attentionItems.isEmpty {
                    // Empty is good news here, so the bot cheers rather than naps.
                    EmptyState(title: "Nothing waiting on you",
                               message: "Approvals and stuck goals turn up here.",
                               mood: .done, colour: 0, faceSize: 120)
                        .padding(.vertical, Theme.Space.section)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        if !approvals.isEmpty {
                            AttentionSectionHeader(icon: "hand.raised", title: "Approvals",
                                                   badge: "\(approvals.count) waiting")
                            ForEach(Array(approvals.enumerated()), id: \.element.id) { index, item in
                                AttentionRow(item: item, showsShortcuts: index == 0)
                            }
                        }
                        if !approvals.isEmpty && !goals.isEmpty {
                            Rectangle().fill(palette.border).frame(height: 1)
                        }
                        if !goals.isEmpty {
                            AttentionSectionHeader(icon: "info.circle", title: "Stuck goals", badge: nil)
                            VStack(spacing: Theme.Space.snug) {
                                ForEach(goals) { item in
                                    AttentionRow(item: item)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, 40)
            .frame(maxWidth: ThreadLayout.columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// A section's icon, title and, for approvals, a pink count.
private struct AttentionSectionHeader: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    let badge: String?

    var body: some View {
        HStack(spacing: Theme.Space.step) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(13), weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 18)
            Text(title)
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
            if let badge {
                Text(badge)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, Theme.Space.snug)
                    .frame(height: 26)
                    .background(palette.primary.opacity(0.16), in: .rect(cornerRadius: Theme.Radius.control))
            }
        }
    }
}

struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let item: AttentionItem
    /// Only the first approval on the page answers to Shift Cmd A, so a shortcut cannot land on
    /// a card further down that you have not read.
    var showsShortcuts = false

    init(item: AttentionItem, showsShortcuts: Bool = false) {
        self.item = item
        self.showsShortcuts = showsShortcuts
    }

    // By id, not name: names can change, and before they were unique two bots sharing one sent
    // a decision to whichever came first.
    private var bot: Bot? { model.bots.first { $0.id == item.botID } }

    var body: some View {
        // An approval is settled right here, on the same card the thread shows. A stuck goal needs
        // its thread, so that one links out instead of pretending to offer a decision.
        if item.kind == .approval, let bot, let approval = pendingApproval(for: bot) {
            ApprovalCard(approval: approval, owner: bot, showsShortcuts: showsShortcuts)
        } else {
            CardRow {
                Group {
                    if let bot {
                        BotFace(bot: bot, mood: .waitingForYou, size: 36)
                    } else {
                        BotFace(hue: item.hue, mood: .waitingForYou, size: 36)
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.snug) {
                        Text(item.title)
                            .font(Theme.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(2)
                        if item.kind == .objective {
                            ThreadStatusBadge(text: "Stuck", tone: palette.warning)
                        }
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(item.detailIsCommand ? ThreadLayout.monoFont : Theme.Typography.label)
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(2)
                    }
                }
            } trailing: {
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
