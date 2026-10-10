#if DEBUG
import BupsyKit
import Foundation

/// The roster a demo starts with: a small launch team, with a little history so nothing looks
/// empty, links between them already allowed, and a morning routine on the lead.
///
/// Written once, into a fresh throwaway home, before the model loads it. A home that already has
/// bots is left exactly as it is, so a take can be replayed from a copy of a home mid-story.
enum DemoWorld {
    static let leadID = "demo-lead"
    static let researcherID = "demo-researcher"
    static let writerID = "demo-writer"
    static let inboxID = "demo-inbox"
    static let routineID = "demo-daily-brief"

    static let routineName = "Daily brief"
    static let routinePrompt = "Put together the morning brief: read what the team did since yesterday, "
        + "then tell me what's moving, what's blocked and what needs me today."

    /// The face the bot made on camera wears, so every take looks the same.
    static let newBotShape = BotShape.blob
    static let newBotColour = 4

    private struct Member {
        let id: String
        let name: String
        let role: String
        let job: String
        let shape: BotShape
        let colour: Int
        let section: String
    }

    private static let team: [Member] = [
        Member(id: leadID, name: "Lead", role: "Lead",
               job: "Keep the launch on track: plan the week, unblock the others, and tell Alex what needs a decision.",
               shape: .bup, colour: 0, section: "Launch"),
        Member(id: researcherID, name: "Researcher", role: "Research",
               job: "Research markets, competitors and pricing, and report back with sources.",
               shape: .cat, colour: 2, section: "Launch"),
        Member(id: writerID, name: "Writer", role: "Writing",
               job: "Write and edit posts, emails and docs in a clear, warm voice.",
               shape: .bunny, colour: 1, section: "Launch"),
        Member(id: inboxID, name: "Inbox", role: "PA",
               job: "Triage email and calendar. Lead with what needs a decision.",
               shape: .bear, colour: 6, section: "Personal"),
    ]

    /// Seeds an empty home. Returns true when it did.
    @discardableResult
    static func seedIfNeeded(_ store: Store, defaults: UserDefaults = AppHome.defaults, now: Date = Date()) -> Bool {
        guard ((try? store.bots()) ?? []).isEmpty else { return false }
        for (index, member) in team.enumerated() {
            try? store.save(BotRecord(
                id: member.id, name: member.name, engine: EngineID.claude.rawValue,
                autonomy: Autonomy.auto.rawValue, personaPrompt: member.job,
                avatarHue: Double(member.colour) / 8, createdAt: now.addingTimeInterval(-14 * 86_400),
                sortIndex: index, folder: member.section, lastReadAt: now,
                avatarShape: member.shape.rawValue, avatarColour: member.colour, role: member.role))
        }
        // Every pair may hand each other work, so a hand-off never stops for a first-contact card.
        for from in team { for to in team where to.id != from.id {
            try? store.save(BotLinkRecord(fromBotID: from.id, toBotID: to.id, allowed: true, decidedAt: now))
        } }

        let calendar = Calendar.current
        let nineToday = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
        let lastSlot = nineToday <= now ? nineToday : nineToday.addingTimeInterval(-86_400)
        // Filled, so the scheduler never fires it by itself in the middle of a take.
        try? store.save(Routine(id: routineID, botID: leadID, name: routineName, prompt: routinePrompt,
                                cron: "0 9 * * *", tier: .launchAgent, lastFiredAt: lastSlot))

        seedHistory(store, lastSlot: lastSlot, now: now)

        defaults.set(true, forKey: "si.bupsy.onboarded")
        defaults.set(DemoMode.appearance.rawValue, forKey: "si.bupsy.appearance")
        if let json = try? JSONEncoder().encode(["Launch", "Personal"]) {
            defaults.set(String(decoding: json, as: UTF8.self), forKey: "bupsy.sections")
        }
        return true
    }

    // MARK: - History

    private static func seedHistory(_ store: Store, lastSlot: Date, now: Date) {
        // Earlier mornings' briefs, for the routine's numbers; only the latest is in the chat.
        for daysBack in [3, 2] {
            let start = lastSlot.addingTimeInterval(Double(-daysBack) * 86_400)
            record(store, bot: leadID, at: start, seconds: 38 + Double(daysBack) * 3, trigger: routineID,
                   tokens: (41_200, 820), events: [])
        }
        let yesterday = lastSlot.addingTimeInterval(-86_400)
        record(store, bot: leadID, at: yesterday, seconds: 41, trigger: routineID, tokens: (43_900, 910), events: [
            user(routinePrompt),
            tool("mcp__bupsy__read_chat", ["bot": "Researcher"], result: "Pricing table for the three competitors…"),
            tool("mcp__bupsy__read_chat", ["bot": "Writer"], result: "Beta announcement, second pass…"),
            say("""
                Morning! Here's where the launch is.

                **Moving**
                - Researcher finished the competitor pricing table.
                - Writer tightened the beta announcement to 52 words.

                **Blocked**
                - Nothing.

                **Needs you**
                - Pick a launch date: Tuesday or Thursday next week.
                """),
        ])
        record(store, bot: leadID, at: lastSlot.addingTimeInterval(-86_400 + 3 * 3_600), seconds: 9,
               tokens: (44_600, 140), events: [
            user("Thursday. Can you make sure everyone knows?"),
            say("Done. Thursday is on the plan, and I've told Researcher and Writer."),
        ])

        record(store, bot: researcherID, at: yesterday.addingTimeInterval(-2 * 3_600), seconds: 64,
               tokens: (28_300, 1_240), events: [
            user("Compare pricing for the three closest competitors."),
            tool("WebSearch", ["query": "team AI assistant pricing per seat"], result: "10 results"),
            tool("Write", ["file_path": "pricing.md", "content": "…"], result: "File created successfully"),
            say("""
                All three charge per seat. The cheapest starts at $8, the priciest at $30, and only \
                one has a free tier. The full table is in pricing.md.
                """),
        ])

        record(store, bot: writerID, at: yesterday.addingTimeInterval(-90 * 60), seconds: 22,
               tokens: (19_800, 610), events: [
            user("Tighten the intro of the beta announcement."),
            tool("Edit", ["file_path": "beta-announcement.md"], result: "Updated"),
            say("Cut it from 84 words to 52 and moved the invite link up to the first line."),
        ])

        record(store, bot: inboxID, at: lastSlot.addingTimeInterval(-40 * 60), seconds: 17,
               tokens: (12_400, 380), events: [
            user("Anything urgent in my inbox?"),
            say("""
                Two things. Sam wants a yes or no on the venue by noon, and the designer sent the \
                final icon for review. Everything else can wait.
                """),
        ])
    }

    private typealias Event = (type: String, payload: String)

    private static func user(_ text: String) -> [Event] {
        [("userMessage", EventCodec.encode(.text(text)).payload)]
    }

    private static func say(_ text: String) -> [Event] { [EventCodec.encode(.text(text))] }

    private static func tool(_ name: String, _ input: [String: String], result: String) -> [Event] {
        let id = UUID().uuidString
        let arguments = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [EventCodec.encode(.toolCall(ToolCall(id: id, name: name, argumentsJSON: arguments))),
                EventCodec.encode(.toolResult(ToolResult(callID: id, content: result)))]
    }

    /// One finished run, with its events spread over its length.
    private static func record(_ store: Store, bot: String, at start: Date, seconds: Double,
                               trigger: String? = nil, tokens: (Int, Int), events: [[Event]]) {
        let conversation = (try? store.conversation(forBot: bot, engine: EngineID.claude.rawValue))?.id
            ?? {
                let created = ConversationRecord(botID: bot, engine: EngineID.claude.rawValue)
                try? store.save(created)
                return created.id
            }()
        let run = RunRecord(botID: bot, conversationID: conversation, triggerID: trigger, host: "local",
                            status: "finished", startedAt: start, endedAt: start.addingTimeInterval(seconds),
                            inputTokens: tokens.0, outputTokens: tokens.1)
        try? store.save(run)
        let flat = events.flatMap { $0 }
        let records = flat.enumerated().map { index, event in
            EventRecord(runID: run.id, seq: index, type: event.type, payload: event.payload,
                        at: start.addingTimeInterval(seconds * Double(index) / Double(max(flat.count, 1))))
        }
        try? store.append(records)
    }
}
#endif
