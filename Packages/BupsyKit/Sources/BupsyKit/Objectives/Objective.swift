import Foundation

/// A standing outcome a bot owns, rather than a job it does once.
///
/// The difference from a routine is the whole point. A routine runs a prompt on a schedule and
/// always does the same thing. An objective has a *goal* and a *done-when*, and each check the bot
/// decides whether anything needs doing at all — most checks on a healthy objective should do
/// nothing and cost almost nothing.
///
/// This is the half of the product neither open-source alternative has, and the half that is
/// genuinely hard, because "is this goal met?" is a judgement rather than a fact.
public struct Objective: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var botID: String
    /// What should be true. "My inbox has nothing older than four hours."
    public var goal: String
    /// How the bot can tell. Kept separate from the goal because a vague goal with a sharp
    /// done-when still works, and a sharp goal with no done-when does not.
    public var doneWhen: String
    /// When to look. Five-field cron, same vocabulary as routines.
    public var checkCron: String
    public var enabled: Bool
    public var tier: Routine.Tier
    /// What the bot has learned about this objective, carried into every check.
    ///
    /// Plain text rather than structure on purpose: the bot writes it and the bot reads it, and a
    /// schema would only constrain what it can notice. The user can read and edit it, which is
    /// the real safeguard against it drifting somewhere unhelpful.
    public var notes: String
    public var lastCheckedAt: Date?
    public var lastOutcome: ObjectiveOutcome?

    public init(id: String = UUID().uuidString, botID: String, goal: String, doneWhen: String,
                checkCron: String = "0 9-18 * * 1-5", enabled: Bool = true,
                tier: Routine.Tier = .launchAgent, notes: String = "",
                lastCheckedAt: Date? = nil, lastOutcome: ObjectiveOutcome? = nil) {
        self.id = id; self.botID = botID; self.goal = goal; self.doneWhen = doneWhen
        self.checkCron = checkCron; self.enabled = enabled; self.tier = tier
        self.notes = notes; self.lastCheckedAt = lastCheckedAt; self.lastOutcome = lastOutcome
    }
}

/// What a check concluded.
public enum ObjectiveOutcome: Sendable, Equatable, Codable {
    /// Nothing to do. The cheap, common case on a healthy objective.
    case met
    /// The bot did something to move toward the goal.
    case acted(summary: String)
    /// A person has to decide. Appears in the attention inbox.
    case needsYou(question: String)
    /// The run finished but said nothing we could read.
    ///
    /// Deliberately **not** folded into `met`. Treating an unreadable answer as success would
    /// quietly report a goal as handled when nobody knows whether it was, which is the single
    /// most damaging thing this feature could do.
    case unclear(reply: String)
    case failed(reason: String)

    public var needsAttention: Bool {
        switch self {
        case .needsYou, .failed, .unclear: true
        case .met, .acted: false
        }
    }

    public var label: String {
        switch self {
        case .met: "On track"
        case .acted: "Acted"
        case .needsYou: "Needs you"
        case .unclear: "Unclear"
        case .failed: "Failed"
        }
    }
}

/// Turns an objective into a prompt, and a reply back into an outcome.
public enum ObjectiveCheck {

    /// Markers the bot is asked to use.
    ///
    /// Distinctive enough not to appear by accident in ordinary prose, and checked at the start of
    /// a line so a bot *discussing* the markers does not trigger one.
    static let met = "OBJECTIVE_MET"
    static let acted = "OBJECTIVE_ACTED:"
    static let needsYou = "NEEDS_YOU:"

    public static func prompt(for objective: Objective, now: Date = Date()) -> String {
        var sections = [
            """
            You have a standing objective. This is not a one-off task — you are checking whether \
            it currently holds, and acting only if it does not.

            OBJECTIVE: \(objective.goal)

            IT IS MET WHEN: \(objective.doneWhen)
            """
        ]

        if !objective.notes.isEmpty {
            sections.append("""
                WHAT YOU HAVE LEARNED SO FAR:
                \(objective.notes)
                """)
        }

        sections.append("""
            Check whether the objective is met right now.

            Your reply MUST BEGIN with exactly one of these lines, before any explanation:

              \(met)
              \(acted) <one line on what you did>
              \(needsYou) <the question, in one line>

            Write that line first, then explain underneath if you want to.

            If it is met, do not take any action — most checks should end that way, and that is \
            the point. If you are unsure whether it is met, use \(needsYou) rather than guessing.

            If you learned something worth remembering for next time — a pattern, an exception, \
            something the person always wants done a particular way — add a line starting with \
            `NOTE:` and it will be carried into future checks.
            """)

        return sections.joined(separator: "\n\n")
    }

    /// Reads a reply into an outcome.
    ///
    /// Matching is **deliberately asymmetric**, and this is the most important decision in the
    /// file. Observed against the real binary: a model told to lead with a marker sometimes
    /// writes `I'll check the drafts folder.NEEDS_YOU: ...` — correct marker, wrong position.
    /// Requiring every marker to start a line would have silently dropped that escalation.
    ///
    /// So:
    /// - `NEEDS_YOU:` and `OBJECTIVE_ACTED:` are found **anywhere**. They carry a colon and a
    ///   payload, so a false positive is unlikely, and missing one means burying a question only
    ///   a person can answer.
    /// - `OBJECTIVE_MET` must **start a line**. It is the "all is well" answer, so a false
    ///   positive is the expensive direction — a bot discussing the marker in prose must never
    ///   be read as reporting success.
    ///
    /// Lenient about escalation, strict about reassurance. Anything unreadable becomes
    /// `.unclear`, never `.met`: an objective that silently reports itself handled when nobody
    /// knows is far worse than one admitting it does not know.
    public static func outcome(from reply: String) -> ObjectiveOutcome {
        // Most urgent first: a reply that both acted and hit a decision must surface the decision.
        if let question = payload(after: needsYou, in: reply) {
            return .needsYou(question: question.isEmpty ? "A decision is needed." : question)
        }
        if let summary = payload(after: acted, in: reply) {
            return .acted(summary: summary.isEmpty ? "Took action." : summary)
        }

        let lines = reply
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0 == met || $0.hasPrefix(met) }) {
            return .met
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unclear(reply: trimmed.isEmpty ? "The bot replied with nothing." : trimmed)
    }

    /// Text following a marker, up to the end of its line, wherever the marker appears.
    private static func payload(after marker: String, in reply: String) -> String? {
        guard let range = reply.range(of: marker) else { return nil }
        let rest = reply[range.upperBound...]
        let line = rest.prefix { $0 != "\n" }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Pulls out anything the bot asked to remember, to append to the objective's notes.
    public static func learnings(from reply: String) -> [String] {
        reply
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("NOTE:") }
            .map { String($0.dropFirst("NOTE:".count)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Appends new learnings, keeping the notes bounded.
    ///
    /// Capped because notes ride along in every check: unbounded growth would quietly make each
    /// check slower and more expensive until someone noticed their quota draining. Oldest lines
    /// go first.
    public static func updatedNotes(
        _ existing: String, adding learnings: [String], limit: Int = 25
    ) -> String {
        guard !learnings.isEmpty else { return existing }
        var lines = existing.split(separator: "\n").map(String.init)
        for learning in learnings where !lines.contains("- \(learning)") {
            lines.append("- \(learning)")
        }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
