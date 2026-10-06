import Foundation

/// Who answers in a group thread, and when the bots must stop.
///
/// Pure rules, kept here rather than in the app because they decide whose quota gets spent and
/// whether two bots can keep each other talking indefinitely — both things that must be testable.
public enum GroupRouting {

    /// A member, as routing sees it.
    public struct Member: Sendable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// The most bot replies one message of yours can ever set off, counting hand-offs between
    /// bots, whatever a group is set to.
    ///
    /// Without a ceiling two bots that each end by @mentioning the other would talk forever, on
    /// the person's own subscription, with nobody watching. Each group picks its own, smaller or
    /// equal, number from `turnLimitChoices`; this is the hard stop behind all of them, so a
    /// damaged or hand-edited row can never mean "never check with me".
    public static let maxBotTurnsPerMessage = 10

    /// What a group can be set to check with the person after, as the New group sheet offers it.
    public static let turnLimitChoices = [3, 5, 10]

    /// The setting for a new group, and for every group made before the setting existed.
    public static let defaultTurnLimit = 5

    /// The turn limit a group actually runs with: what it stored, kept between one turn and the
    /// hard ceiling.
    public static func effectiveTurnLimit(_ stored: Int) -> Int {
        min(max(stored, 1), maxBotTurnsPerMessage)
    }

    /// Whether the group must pause and check with the person before another bot turn, having
    /// taken `taken` turns since they last spoke.
    public static func shouldPause(afterTaking taken: Int, limit stored: Int) -> Bool {
        taken >= effectiveTurnLimit(stored)
    }

    /// Members @mentioned in `text`, in the order they first appear, each once.
    ///
    /// Names can contain spaces ("Email Agent 3"), so longer names are tried first — otherwise
    /// "@Email Agent 3" would match a member called "Email". Matching is case-insensitive and
    /// needs a word boundary after the name, so "@Scouting" does not summon "Scout".
    public static func mentions(in text: String, members: [Member]) -> [Member] {
        let lowered = text.lowercased()
        let byLength = members.sorted { $0.name.count > $1.name.count }
        var found: [(Int, Member)] = []
        var claimed: [Range<String.Index>] = []

        for member in byLength {
            let needle = "@" + member.name.lowercased()
            var searchStart = lowered.startIndex
            while let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
                searchStart = range.upperBound
                let boundary = range.upperBound == lowered.endIndex
                    || !(lowered[range.upperBound].isLetter || lowered[range.upperBound].isNumber)
                let overlaps = claimed.contains { $0.overlaps(range) }
                guard boundary, !overlaps else { continue }
                claimed.append(range)
                found.append((lowered.distance(from: lowered.startIndex, to: range.lowerBound),
                              member))
                break
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Who should answer a message from the person.
    ///
    /// The members it mentions; failing that, the lead; failing that, the first member. Never
    /// everyone by default: in a group of five that would spend five runs of the person's quota on
    /// every "ok", which is exactly the kind of cost that should only happen when asked for.
    public static func addressees(of text: String, members: [Member], lead: String?) -> [Member] {
        let mentioned = mentions(in: text, members: members)
        if !mentioned.isEmpty { return mentioned }
        if let lead, let member = members.first(where: { $0.id == lead }) { return [member] }
        return members.first.map { [$0] } ?? []
    }

    /// Who a bot's reply hands over to: the members it mentions, never itself.
    ///
    /// A bot mentioning itself would answer itself, which is a loop with extra steps.
    public static func handOffs(from author: Member, reply: String, members: [Member]) -> [Member] {
        mentions(in: reply, members: members).filter { $0 != author }
    }

    /// What a bot is shown when it is asked to speak in a group.
    ///
    /// Each bot runs its own engine session, so it only knows what it is told. It gets the group's
    /// name and members, and the messages since it last spoke — enough to follow the thread
    /// without re-sending the whole history, at the person's own cost, on every turn.
    public static func prompt(group: String, members: [Member], me: Member,
                              recent: [(author: String, text: String)]) -> String {
        let others = members.filter { $0 != me }.map { "@\($0.name)" }.joined(separator: ", ")
        let transcript = recent.map { "\($0.author): \($0.text)" }.joined(separator: "\n\n")
        return """
            You are \(me.name), in a group conversation called "\(group)" with the person and \
            \(others.isEmpty ? "no other bots" : "these other bots: \(others)").

            Here is what has been said since you last spoke:

            \(transcript)

            Reply to the group. To hand something to another bot, mention it by name with @ — \
            only do that when it genuinely needs them, since each mention starts them working.
            """
    }
}
