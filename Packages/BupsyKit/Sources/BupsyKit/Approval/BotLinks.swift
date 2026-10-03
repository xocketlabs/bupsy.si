import Foundation

/// Who may message whom, and in which direction.
///
/// Lives here rather than in the app because this is a permission decision, and permission
/// decisions are the part of this product that must be testable. One bot messaging another routes
/// around the approval gate — the receiving bot acts on instructions no human read — so the rules
/// below are the whole safety argument for the feature.
public struct BotLinks: Sendable, Equatable {
    public private(set) var decisions: [BotLinkRecord]

    public init(_ decisions: [BotLinkRecord] = []) {
        self.decisions = decisions
    }

    /// What has been decided about this direction, or nil if nobody has been asked yet.
    ///
    /// **Directional on purpose.** "Scout may message Builder" says nothing about whether Builder
    /// may message Scout. Treating a link as symmetric would grant a direction nobody was asked
    /// about, and in a roster where one bot orchestrates others that is precisely the direction
    /// that matters — the orchestrator being allowed to instruct a worker must not quietly let
    /// the worker instruct the orchestrator back.
    public func decision(from sender: String, to recipient: String) -> Bool? {
        decisions.first { $0.fromBotID == sender && $0.toBotID == recipient }?.allowed
    }

    /// Whether this message can go without asking.
    public func isAllowed(from sender: String, to recipient: String) -> Bool {
        decision(from: sender, to: recipient) == true
    }

    /// Whether a person has to be asked before this message moves.
    ///
    /// A refusal is a decision, not an absence of one: a denied pair must not re-prompt on every
    /// attempt, because a dialog that keeps returning is one people learn to dismiss unread.
    public func needsApproval(from sender: String, to recipient: String) -> Bool {
        decision(from: sender, to: recipient) == nil
    }

    /// Records an answer, replacing any earlier one for the same direction.
    public mutating func decide(from sender: String, to recipient: String, allowed: Bool,
                                at moment: Date = Date()) {
        decisions.removeAll { $0.fromBotID == sender && $0.toBotID == recipient }
        decisions.append(BotLinkRecord(
            fromBotID: sender, toBotID: recipient, allowed: allowed, decidedAt: moment))
    }

    /// Drops a decision so the next attempt asks again.
    public mutating func forget(from sender: String, to recipient: String) {
        decisions.removeAll { $0.fromBotID == sender && $0.toBotID == recipient }
    }

    /// A bot may not message itself.
    ///
    /// Not a permission question but a loop: a bot writing into its own thread would feed its own
    /// output back as input, and no human answer makes that safe. Refused outright rather than
    /// offered as something to approve.
    public static func isSelfMessage(from sender: String, to recipient: String) -> Bool {
        sender == recipient
    }
}
