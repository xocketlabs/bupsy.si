import BupsyKit
import SwiftUI

/// Something that cannot move without a person.
struct AttentionItem: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A tool request in the bot's own chat.
        case approval
        case objective
        /// A question the bot asked you in its chat and is waiting on.
        case question
        /// A tool request from the bot's turn inside a group. Carries the group id.
        case groupApproval(String)
        /// A group that reached its turn limit and is waiting for you to speak. Carries the group id.
        case pausedGroup(String)

        /// Settled right here with Allow and Deny, wherever it was raised.
        var isApproval: Bool {
            switch self {
            case .approval, .groupApproval: true
            default: false
            }
        }

        /// Belongs to a group rather than to the bot whose face it borrows.
        var isPausedGroup: Bool {
            if case .pausedGroup = self { return true }
            return false
        }
    }

    let id: String
    let botID: BotID
    let botName: String
    let hue: Double
    let kind: Kind
    let title: String
    let detail: String
    /// Shown in a fixed-width font. In a proportional one `ls` reads as "Is".
    var detailIsCommand = false
    /// The group it came from, for group approvals and paused groups.
    var groupName: String? = nil
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
    /// Every approval this page has shown since it opened, in the order they arrived. An answered
    /// one stays, showing what you decided, rather than vanishing from under the pointer the
    /// moment you click; it goes when you leave the page.
    @State private var shownApprovals: [AttentionItem] = []

    private var approvals: [AttentionItem] { model.attentionItems.filter { $0.kind.isApproval } }
    private var goals: [AttentionItem] { model.attentionItems.filter { $0.kind == .objective } }
    /// Questions bots asked and groups that paused: things to go and answer, not decide here.
    private var others: [AttentionItem] {
        model.attentionItems.filter { !$0.kind.isApproval && $0.kind != .objective }
    }

    /// Answered approvals from this visit that can still be drawn in their decided state.
    private var answered: [AttentionItem] {
        let open = Set(approvals.map(\.id))
        return shownApprovals.filter { item in
            !open.contains(item.id) && model.pendingApproval(id: item.id, for: item.botID) != nil
        }
    }

    /// The approvals to draw: open ones in arrival order, answered ones where they were.
    private var approvalRows: [AttentionItem] {
        let open = Set(approvals.map(\.id))
        let kept = Set(answered.map(\.id))
        let seen = shownApprovals.filter { open.contains($0.id) || kept.contains($0.id) }
        let fresh = approvals.filter { item in !seen.contains { $0.id == item.id } }
        return seen + fresh
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.page) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("Waiting on you")
                        .font(Theme.Typography.title)
                        .foregroundStyle(palette.foreground)
                    Text("Approvals and goals that can't move without a decision")
                        .font(Theme.Typography.lead)
                        .foregroundStyle(palette.mutedForeground)
                }

                if model.attentionItems.isEmpty {
                    // Empty is good news here, so the bot cheers rather than naps, at the size
                    // the board draws it.
                    EmptyState(title: "Nothing needs you",
                               message: "Approvals and stuck goals turn up here.",
                               mood: .done, colour: 0, faceSize: 160)
                        .padding(.vertical, Theme.Space.section)
                }

                if !model.attentionItems.isEmpty || !answered.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        if !approvalRows.isEmpty {
                            AttentionSectionHeader(
                                icon: "hand.raised", title: "Approvals",
                                badge: approvals.isEmpty ? nil : "\(approvals.count) waiting")
                            ForEach(approvalRows) { item in
                                // Only the first open one answers to Shift Cmd A.
                                AttentionRow(item: item, showsShortcuts: item.id == approvals.first?.id)
                            }
                        }
                        if !approvalRows.isEmpty && !others.isEmpty {
                            Rectangle().fill(palette.border).frame(height: 1)
                        }
                        if !others.isEmpty {
                            AttentionSectionHeader(icon: "bubble.left", title: "Waiting for a reply", badge: nil)
                            VStack(spacing: Theme.Space.snug) {
                                ForEach(others) { item in
                                    AttentionRow(item: item)
                                }
                            }
                        }
                        if (!approvalRows.isEmpty || !others.isEmpty) && !goals.isEmpty {
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
            .padding(.horizontal, Theme.Space.pageSide)
            .padding(.top, Theme.Space.section)
            .padding(.bottom, Theme.Space.page)
            .frame(maxWidth: ThreadLayout.columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: rememberApprovals)
        .onChange(of: model.attentionItems) { rememberApprovals() }
    }

    private func rememberApprovals() {
        for item in approvals where !shownApprovals.contains(where: { $0.id == item.id }) {
            shownApprovals.append(item)
        }
    }
}

/// A section's icon, title and, for approvals, a pink count: the shared `SectionHeader` look,
/// with the count in the "needs you" tone.
private struct AttentionSectionHeader: View {
    @Environment(\.palette) private var palette
    let icon: String
    let title: String
    let badge: String?

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: icon)
                .font(.system(size: Theme.scaled(13)))
                .foregroundStyle(palette.mutedForeground)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.heading)
                .foregroundStyle(palette.foreground)
                .accessibilityAddTraits(.isHeader)
            if let badge {
                Badge(text: badge, tone: .primary)
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
        if item.kind.isApproval, let bot, let approval = model.pendingApproval(id: item.id, for: bot.id) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                if let groupName = item.groupName {
                    Text("In \(groupName)")
                        .font(Theme.Typography.label)
                        .foregroundStyle(palette.mutedForeground)
                }
                ApprovalCard(approval: approval, owner: bot, showsShortcuts: showsShortcuts)
            }
        } else {
            CardRow {
                Group {
                    if let bot {
                        BotFace(bot: bot, mood: faceMood, size: 36)
                    } else {
                        BotFace(hue: item.hue, mood: faceMood, size: 36)
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.snug) {
                        Text(item.title)
                            .font(Theme.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(2)
                        if item.kind == .objective {
                            Badge(text: "Stuck", tone: .warning)
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
                HStack(spacing: Theme.Space.tight) {
                    if item.kind == .objective, let objective {
                        Button("Mark as handled") { model.markObjectiveHandled(objective) }
                            .buttonStyle(BupsyButtonStyle(kind: .ghost, size: .md))
                            .help("Clear this goal from Waiting on you. Its next check runs as usual.")
                    }
                    Button(openTitle) { open() }
                        .buttonStyle(QuietButton(compact: true))
                }
            }
        }
    }

    /// A stuck goal is something that went wrong; a question or a paused group is the bot
    /// waiting on you.
    private var faceMood: BotMood {
        item.kind == .objective ? .failed : .waitingForYou
    }

    private var objective: Objective? {
        model.objectives.first { $0.id == item.id }
    }

    /// Says where the button goes: the bot by name, or the group.
    private var openTitle: String {
        if case .pausedGroup = item.kind { return "Open group" }
        return "Open \(bot?.name ?? item.botName)"
    }

    private func open() {
        switch item.kind {
        case .pausedGroup(let groupID), .groupApproval(let groupID):
            model.open(.group(groupID))
        default:
            if let id = bot?.id { model.open(id) }
        }
    }
}
