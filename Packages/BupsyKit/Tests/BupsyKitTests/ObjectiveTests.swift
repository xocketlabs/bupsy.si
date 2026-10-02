import Foundation
import Testing
@testable import BupsyKit

@Suite("Objectives")
struct ObjectiveTests {
    private let objective = Objective(
        botID: "b", goal: "My inbox has nothing older than four hours",
        doneWhen: "No unread mail older than four hours remains",
        notes: "- Newsletters from Stripe are never worth surfacing")

    // MARK: - Reading a reply

    @Test("reads the three outcomes a check is asked to produce")
    func readsOutcomes() {
        #expect(ObjectiveCheck.outcome(from: "OBJECTIVE_MET") == .met)
        #expect(ObjectiveCheck.outcome(from: "Checked everything.\nOBJECTIVE_MET") == .met)
        #expect(ObjectiveCheck.outcome(from: "OBJECTIVE_ACTED: archived 12 newsletters")
            == .acted(summary: "archived 12 newsletters"))
        #expect(ObjectiveCheck.outcome(from: "NEEDS_YOU: reply to the invoice from Acme?")
            == .needsYou(question: "reply to the invoice from Acme?"))
    }

    /// The single most important behaviour in this file. A model can forget to emit a marker, and
    /// treating that as success would quietly report a goal as handled when nobody knows whether
    /// it was.
    @Test("an unreadable reply is never treated as met")
    func unreadableIsNeverMet() {
        for reply in ["I had a look at things.", "", "   ", "Everything seems fine to me"] {
            let outcome = ObjectiveCheck.outcome(from: reply)
            #expect(outcome != .met, "an ambiguous reply must not read as success")
            if case .unclear = outcome {} else {
                Issue.record("expected .unclear for \(reply.debugDescription), got \(outcome)")
            }
        }
    }

    /// A reply that both acted and hit a decision should surface the decision — the part only a
    /// person can resolve is the part that must not be buried.
    @Test("a question wins over an action")
    func questionWinsOverAction() {
        let reply = """
            OBJECTIVE_ACTED: archived 12 newsletters
            NEEDS_YOU: should I reply to the invoice from Acme?
            """
        #expect(ObjectiveCheck.outcome(from: reply)
            == .needsYou(question: "should I reply to the invoice from Acme?"))
    }

    /// Matching is asymmetric on purpose. `OBJECTIVE_MET` must start a line, because a false
    /// "all is well" is the expensive direction — a bot discussing the marker must never be read
    /// as reporting success.
    @Test("OBJECTIVE_MET mentioned mid-sentence does not count as success")
    func metMustStartALine() {
        let reply = "I would normally say OBJECTIVE_MET here but I could not check."
        if case .unclear = ObjectiveCheck.outcome(from: reply) {} else {
            Issue.record("a marker inside prose should not be read as success")
        }
    }

    /// Captured verbatim from the real binary. Told to lead with a marker, it wrote the preamble
    /// and the marker on the same line. Requiring a line start would have silently dropped a
    /// question only a person can answer — so escalation markers are found anywhere.
    @Test("an escalation is found even when the model buries it mid-line")
    func escalationFoundAnywhere() {
        let reply = "I'll check the drafts folder.NEEDS_YOU: Four drafts are 2–3 months old — "
            + "delete them or send them?\n\nAll four predate the seven-day line."
        #expect(ObjectiveCheck.outcome(from: reply)
            == .needsYou(question: "Four drafts are 2–3 months old — delete them or send them?"))
    }

    @Test("an action is also found mid-line")
    func actionFoundAnywhere() {
        #expect(ObjectiveCheck.outcome(from: "Done. OBJECTIVE_ACTED: archived 12 newsletters")
            == .acted(summary: "archived 12 newsletters"))
    }

    /// Captured verbatim: the clean case does produce a bare marker, with explanation below.
    @Test("a marker followed by explanation still reads as met")
    func metWithExplanation() {
        let reply = "OBJECTIVE_MET\n\n`ls` returned \"No such file\" — nothing to do."
        #expect(ObjectiveCheck.outcome(from: reply) == .met)
    }

    @Test("only outcomes that need a person are flagged for attention")
    func attentionFlags() {
        #expect(!ObjectiveOutcome.met.needsAttention)
        #expect(!ObjectiveOutcome.acted(summary: "x").needsAttention)
        #expect(ObjectiveOutcome.needsYou(question: "x").needsAttention)
        #expect(ObjectiveOutcome.failed(reason: "x").needsAttention)
        // Unclear needs a person too: somebody has to decide whether it actually got done.
        #expect(ObjectiveOutcome.unclear(reply: "x").needsAttention)
    }

    // MARK: - The prompt

    @Test("the prompt asks for no action when the goal already holds")
    func promptFavoursDoingNothing() {
        let prompt = ObjectiveCheck.prompt(for: objective)
        #expect(prompt.contains("do not take any action"))
        #expect(prompt.contains("most checks should end that way"))
        // Marker-first, because a model asked to end with one often buries it in prose instead.
        #expect(prompt.contains("MUST BEGIN"))
        #expect(prompt.contains(objective.goal))
        #expect(prompt.contains(objective.doneWhen))
    }

    @Test("what the bot has learned rides along into the next check")
    func promptCarriesNotes() {
        #expect(ObjectiveCheck.prompt(for: objective).contains("Stripe"))
        // And an objective with nothing learned yet gets no empty section.
        let fresh = Objective(botID: "b", goal: "g", doneWhen: "d")
        #expect(!ObjectiveCheck.prompt(for: fresh).contains("WHAT YOU HAVE LEARNED"))
    }

    @Test("asks rather than guesses")
    func promptPrefersAsking() {
        #expect(ObjectiveCheck.prompt(for: objective).contains("rather than guessing"))
    }

    // MARK: - Memory

    @Test("collects what the bot asked to remember")
    func collectsLearnings() {
        let reply = """
            OBJECTIVE_ACTED: archived 12 newsletters
            NOTE: Vansh never wants Stripe receipts surfaced
            NOTE: invoices from Acme always need a reply
            """
        #expect(ObjectiveCheck.learnings(from: reply) == [
            "Vansh never wants Stripe receipts surfaced",
            "invoices from Acme always need a reply",
        ])
    }

    @Test("does not record the same lesson twice")
    func doesNotDuplicate() {
        let notes = ObjectiveCheck.updatedNotes("- already known", adding: ["already known"])
        #expect(notes == "- already known")
    }

    /// Notes ride along in every check, so unbounded growth would quietly make each one slower
    /// and more expensive until somebody noticed their quota draining.
    @Test("notes stay bounded, dropping the oldest")
    func notesAreBounded() {
        let existing = (1...30).map { "- lesson \($0)" }.joined(separator: "\n")
        let notes = ObjectiveCheck.updatedNotes(existing, adding: ["newest"], limit: 10)
        let lines = notes.split(separator: "\n")

        #expect(lines.count == 10)
        #expect(lines.last == "- newest")
        #expect(!notes.contains("lesson 1\n"), "the oldest lessons are dropped first")
    }

    @Test("nothing learned leaves the notes untouched")
    func noLearningsNoChange() {
        #expect(ObjectiveCheck.updatedNotes("- a", adding: []) == "- a")
    }
}

@Suite("Objective storage")
struct ObjectiveStorageTests {
    @Test("an objective survives being written and read back, learnings included")
    func roundTrips() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Inbox", engine: "claude")
        try store.save(bot)

        let objective = Objective(
            botID: bot.id, goal: "Inbox clear", doneWhen: "nothing older than 4h",
            checkCron: "0 9-18 * * 1-5", tier: .machine,
            notes: "- Stripe receipts never matter",
            lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOutcome: .needsYou(question: "reply to Acme?"))
        try store.save(objective)

        let loaded = try #require(try store.objectives().first)
        #expect(loaded.goal == "Inbox clear")
        #expect(loaded.tier == .machine)
        #expect(loaded.notes.contains("Stripe"))
        #expect(loaded.lastOutcome == .needsYou(question: "reply to Acme?"))
        #expect(loaded.lastCheckedAt == objective.lastCheckedAt)
    }

    /// Objectives and routines share a table, so each must only ever see its own.
    @Test("objectives and routines do not leak into each other")
    func kindsStaySeparate() throws {
        let store = try Store.inMemory()
        let bot = BotRecord(name: "Inbox", engine: "claude")
        try store.save(bot)

        try store.save(Routine(botID: bot.id, name: "Brief", prompt: "p", cron: "0 7 * * *"))
        try store.save(Objective(botID: bot.id, goal: "g", doneWhen: "d"))

        #expect(try store.routines().count == 1)
        #expect(try store.objectives().count == 1)
        #expect(try store.routines().first?.name == "Brief")
        #expect(try store.objectives().first?.goal == "g")
    }
}
