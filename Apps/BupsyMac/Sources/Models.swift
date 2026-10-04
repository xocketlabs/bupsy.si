import BupsyKit
import Foundation

/// A bot as the UI knows it.
///
/// `machineID` is nil for a bot with no machine, which is the default and the common case —
/// see PLAN.md §3. A machine-less bot runs on this Mac and cannot run routines while it sleeps,
/// and the UI has to say so rather than pretend otherwise.
struct Bot: Identifiable, Hashable, Sendable {
    let id: BotID
    var name: String
    var engine: EngineID
    var model: String?
    var autonomy: Autonomy = .ask
    var machineID: String?
    var personaPrompt: String?
    /// Tools this bot may use without asking, above whatever its autonomy level already allows.
    var toolAllowlist: Set<String> = []
    /// Whether this bot holds the Mac awake while it works. Per bot because a research bot
    /// grinding for ten minutes is worth protecting from idle sleep and a quick chat bot is not.
    var keepAwake: KeepAwake = .whileWorking
    /// The folder this bot works in.
    ///
    /// Until this existed a bot ran in whatever directory the app happened to launch from, which
    /// meant it could not see any of the user's work — the single largest gap between this being
    /// a chat window and being a tool. nil still means "no folder", which is right for a bot that
    /// only talks.
    var workdir: String?
    var avatarHue: Double
    /// The folder the user filed this bot under. nil is the normal case — ungrouped bots are
    /// shown first rather than swept under an "Uncategorised" heading nobody chose.
    var folder: String?
    /// Kept at the top of the sidebar, above the folders.
    var pinned = false
    /// Out of the sidebar, but not deleted — it keeps everything it had.
    var hidden = false
    /// nil means never opened.
    var lastReadAt: Date?
    /// A face chosen by hand. nil derives it from the hue.
    var avatarShape: BotShape?
    var avatarColour: Int?
    /// A short label beside the name — "PA", "Finance". Not instructions; that is the job.
    var role: String?
    /// Kept to apps added in bupsy, without the ones on the person's Claude account.
    var onlyBupsyApps = false

    /// The shape this bot actually wears, chosen or derived — for anything that compares faces.
    var effectiveShape: BotShape { avatarShape ?? BotFace.derivedShape(forHue: avatarHue) }

    /// Deterministic from the name, so a bot keeps its colour between launches without
    /// anything being stored.
    init(name: String, engine: EngineID, model: String? = nil, machineID: String? = nil,
         personaPrompt: String? = nil) {
        self.id = BotID(UUID().uuidString)
        self.name = name
        self.engine = engine
        self.model = model
        self.machineID = machineID
        self.personaPrompt = personaPrompt
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        self.avatarHue = Double(abs(hash) % 360) / 360
    }

    /// What the bot can honestly promise about unattended work. PLAN.md §4.
    var scheduleTier: ScheduleTier { machineID == nil ? .macAwake : .alwaysOn }

    /// Rebuilt from storage.
    init(record: BotRecord) {
        self.id = BotID(record.id)
        self.name = record.name
        self.engine = EngineID(rawValue: record.engine) ?? .claude
        self.model = record.model
        self.autonomy = Autonomy(rawValue: record.autonomy) ?? .ask
        self.machineID = record.machineID
        self.personaPrompt = record.personaPrompt
        self.workdir = record.workdir
        self.avatarHue = record.avatarHue
        self.folder = record.folder
        self.pinned = record.pinned
        self.hidden = record.hidden
        self.lastReadAt = record.lastReadAt
        // An unknown name — a shape removed in some later version — falls back to the derived
        // face rather than failing to load the bot.
        self.avatarShape = record.avatarShape.flatMap(BotShape.init(rawValue:))
        self.avatarColour = record.avatarColour
        self.role = record.role
        self.onlyBupsyApps = record.onlyBupsyApps
        self.toolAllowlist = Set((try? JSONDecoder().decode([String].self, from: Data(record.toolAllowlist.utf8))) ?? [])
    }

    func record(sortIndex: Int = 0) -> BotRecord {
        BotRecord(
            id: id.rawValue, name: name, engine: engine.rawValue, model: model,
            machineID: machineID, autonomy: autonomy.rawValue,
            personaPrompt: personaPrompt, workdir: workdir,
            avatarHue: avatarHue, sortIndex: sortIndex, folder: folder, pinned: pinned,
            hidden: hidden, lastReadAt: lastReadAt,
            avatarShape: avatarShape?.rawValue, avatarColour: avatarColour, role: role,
            onlyBupsyApps: onlyBupsyApps,
            toolAllowlist: (try? String(data: JSONEncoder().encode(toolAllowlist.sorted()), encoding: .utf8)) ?? "[]")
    }
}

enum ScheduleTier: Sendable {
    case macAwake
    case alwaysOn

    var label: String {
        switch self {
        case .macAwake: "This Mac"
        case .alwaysOn: "Cloud machine"
        }
    }

    var caveat: String? {
        switch self {
        case .macAwake: "Routines only run while your Mac is awake."
        case .alwaysOn: nil
        }
    }
}

/// One entry in a transcript. Deliberately a flat list rather than nested turns: tool calls and
/// their results interleave with prose, and a flat log is what the audit trail needs anyway.
struct TranscriptEntry: Identifiable, Sendable {
    /// Whether this belongs on the bot's side of the thread. Drives bubble alignment and the
    /// avatar gutter, so it lives with the entry rather than being re-derived in a view.
    var isFromBot: Bool {
        switch kind {
        // A message from another bot sits on the input side of the thread: it is something this
        // bot was told, not something it said.
        case .userMessage, .messageFrom: false
        default: true
        }
    }

    enum Kind: Sendable {
        case userMessage(String)
        /// Another bot speaking into this thread.
        ///
        /// Its own case rather than a decorated `userMessage`: the person reading needs to know
        /// at a glance that an instruction came from a machine rather than from them, and that
        /// distinction must survive into the stored transcript and the audit log, not just the
        /// view layer.
        case messageFrom(botID: String, botName: String, text: String)
        case assistantText(String)
        case thinking(String)
        case tool(name: String, arguments: String, result: String?, failed: Bool)
        case approval(PendingApproval)
        case question(BotQuestion)
        /// Something bupsy itself records in the thread — "Named itself Researcher". Never a
        /// bot's words, so it is drawn as a quiet line, not a bubble.
        case note(String)
        case limits(RateLimit)
        case failure(EngineFailure)
        case finished(Outcome)
    }

    let id = UUID()
    var kind: Kind
    var at = Date()
}

/// A tool call waiting on the user, as the UI holds it.
/// A question a bot asked with answers to pick from. The answer goes back as the person's next
/// message, which is what the bot was told to wait for.
///
/// Held in memory, like approvals: an unanswered question is live, and one restored after a
/// restart would be asking on behalf of a run that has long ended. The answer itself is saved,
/// as an ordinary message.
struct BotQuestion: Identifiable, Sendable, Equatable {
    let id: String
    let question: String
    let options: [String]
    /// What the person chose or typed; nil while waiting. Empty means they dismissed it.
    var answer: String?
}

struct PendingApproval: Identifiable, Sendable, Equatable {
    let id: String
    let tool: String
    let summary: String
    let inputJSON: String
    /// Why the policy decided this needed a person — shown on the card so the user is not
    /// guessing why they are being interrupted.
    let reason: String
    var decided: Decision?

    enum Decision: Sendable, Equatable {
        case allowed
        case denied
        /// Nobody answered and the gate denied it to fail closed.
        case expired
    }
}

/// The live state of one bot's conversation.
@MainActor
@Observable
final class Thread {
    let botID: BotID
    var entries: [TranscriptEntry] = []
    var isRunning = false
    /// Resume handle, captured from `.started` so a thread stays resumable even if a run fails.
    var conversationID: ConversationID?
    var latestLimits: RateLimit?
    /// What the last run reported it used. Kept so the run record can be written with it when the
    /// run ends — the usage line arrives before `.done`, and is the only place the figure exists.
    var latestUsage: Usage?
    var connectorStates: [ConnectorState] = []

    init(botID: BotID) { self.botID = botID }

    /// One line for the conversation list — what a chat app shows under a name.
    var preview: String? {
        for entry in entries.reversed() {
            switch entry.kind {
            // A message from another bot is the newest thing in the thread as much as anything
            // else is. Left out of this switch, a bot whose only content came from another bot
            // read as "No messages yet" while holding a message.
            case .messageFrom(_, let name, let text):
                let flat = text.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !flat.isEmpty { return "\(name): \(flat)" }
            case .assistantText(let text), .userMessage(let text):
                let flat = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !flat.isEmpty { return flat }
            case .question(let question) where question.answer == nil:
                return "Asks: \(question.question)"
            case .approval(let approval):
                return "Asked about \(approval.tool)"
            case .failure(let failure):
                return failure.message
            default:
                continue
            }
        }
        return nil
    }

    var lastActivity: Date? { entries.last?.at }

    /// Folds a canonical event into the transcript.
    ///
    /// Consecutive text events are merged into the preceding bubble so streaming reads as one
    /// message rather than a stack of fragments. Tool results attach to their call by id.
    func apply(_ event: AgentEvent) {
        switch event {
        case .started(let id):
            conversationID = id

        case .text(let chunk):
            if case .assistantText(let existing) = entries.last?.kind {
                entries[entries.count - 1].kind = .assistantText(existing + chunk)
            } else {
                entries.append(TranscriptEntry(kind: .assistantText(chunk)))
            }

        case .thinking(let chunk):
            if case .thinking(let existing) = entries.last?.kind {
                entries[entries.count - 1].kind = .thinking(existing + chunk)
            } else {
                entries.append(TranscriptEntry(kind: .thinking(chunk)))
            }

        case .toolCall(let call):
            entries.append(TranscriptEntry(kind: .tool(
                name: call.name, arguments: call.argumentsJSON, result: nil, failed: false)))

        case .toolResult(let result):
            // Attach to the most recent tool entry still awaiting a result.
            if let index = entries.lastIndex(where: {
                if case .tool(_, _, let r, _) = $0.kind { return r == nil }
                return false
            }), case .tool(let name, let arguments, _, _) = entries[index].kind {
                entries[index].kind = .tool(
                    name: name, arguments: arguments,
                    result: result.content, failed: result.isError)
            }

        case .rateLimit(let limit):
            latestLimits = limit

        case .connectors(let states):
            // The engine's own view of what came up, which beats inferring readiness from
            // whether an environment variable happens to be set.
            connectorStates = states

        case .approvalRequired(let request):
            entries.append(TranscriptEntry(kind: .approval(PendingApproval(
                id: request.id, tool: request.tool, summary: request.summary,
                inputJSON: request.argumentsJSON, reason: request.summary))))

        case .usage(let usage):
            // Was `break`. The event was parsed, normalised, conformance-tested — and then
            // dropped on the floor, so `runs.inputTokens` was null for every run ever recorded
            // and the usage panel could not appear for anyone. The one place the number exists.
            latestUsage = usage

        case .done(let outcome):
            if let id = outcome.conversationID { conversationID = id }
            entries.append(TranscriptEntry(kind: .finished(outcome)))

        case .failed(let failure):
            entries.append(TranscriptEntry(kind: .failure(failure)))

        case .unknown:
            // Never surfaced to the user, but never dropped either — it reaches the log.
            break
        }
    }

    /// Marks a waiting approval as decided, in place, so the card settles rather than vanishing.
    /// A decided card stays in the transcript because it is part of the record of what happened.
    func resolveApproval(id: String, as decision: PendingApproval.Decision) {
        guard let index = entries.lastIndex(where: {
            if case .approval(let approval) = $0.kind { return approval.id == id }
            return false
        }), case .approval(var approval) = entries[index].kind else { return }
        approval.decided = decision
        entries[index].kind = .approval(approval)
    }

    func answerQuestion(id: String, with answer: String) {
        guard let index = entries.lastIndex(where: {
            if case .question(let question) = $0.kind { return question.id == id }
            return false
        }), case .question(var question) = entries[index].kind else { return }
        question.answer = answer
        entries[index].kind = .question(question)
    }

    func raiseApproval(_ approval: PendingApproval) {
        entries.append(TranscriptEntry(kind: .approval(approval)))
    }

    /// Replays a stored row. `userMessage` is written as its own type so a reloaded transcript
    /// shows who said what, which `AgentEvent` alone does not carry — it only ever describes the
    /// engine's side of the conversation.
    /// `at` is the time the event was recorded. Without it every replayed entry was stamped with
    /// the moment the thread was *loaded*, so a week-old conversation reopened today showed
    /// "Today" on every message and could not be ordered by when anything actually happened.
    func applyStored(type: String, payload: String, at: Date) {
        let before = entries.count
        defer {
            for index in before..<entries.count { entries[index].at = at }
        }
        // Stored as "<fromBotID>\u{1}<fromName>\u{1}<text>" inside a text payload, so replaying a
        // transcript keeps the attribution. A unit separator rather than JSON because the event
        // log is append-only and already carries its own encoding; nesting a second one inside it
        // is a shape nobody would expect to find there.
        if type == "messageFrom" {
            let decoded = EventCodec.decode(type: "text", payload: payload)
            if case .text(let joined) = decoded {
                let parts = joined.components(separatedBy: "\u{1}")
                if parts.count == 3 {
                    entries.append(TranscriptEntry(kind: .messageFrom(
                        botID: parts[0], botName: parts[1], text: parts[2])))
                }
            }
            return
        }
        if type == "userMessage" {
            let text = EventCodec.decode(type: "text", payload: payload)
            if case .text(let message) = text {
                entries.append(TranscriptEntry(kind: .userMessage(message)))
            }
            return
        }
        apply(EventCodec.decode(type: type, payload: payload))
    }
}

/// A conversation with several bots in it.
struct ChatGroup: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// Who answers a message that mentions nobody.
    var leadBotID: BotID?
    var memberIDs: [BotID]
    var pinned: Bool
    var lastReadAt: Date?

    init(record: GroupRecord, members: [String]) {
        id = record.id
        name = record.name
        leadBotID = record.leadBotID.map { BotID($0) }
        memberIDs = members.map { BotID($0) }
        pinned = record.pinned
        lastReadAt = record.lastReadAt
    }

    func record(sortIndex: Int) -> GroupRecord {
        GroupRecord(id: id, name: name, leadBotID: leadBotID?.rawValue, sortIndex: sortIndex,
                    pinned: pinned, lastReadAt: lastReadAt)
    }
}

/// The live state of a group thread.
@MainActor
@Observable
final class GroupThread {
    let groupID: String
    var messages: [GroupMessageRecord] = []
    /// Which bot is answering right now, for the typing indicator. nil when nobody is.
    var speaking: BotID?

    init(groupID: String) { self.groupID = groupID }

    /// The latest line, for the sidebar: "Scout: tests are green".
    var preview: String? {
        guard let last = messages.last(where: { $0.author != GroupMessageRecord.systemAuthor })
        else { return nil }
        let text = last.text.replacingOccurrences(of: "\n", with: " ")
        return last.isFromUser ? "You: \(text)" : "\(last.authorName): \(text)"
    }
}

extension GroupMessageRecord {
    /// Notes from bupsy itself — "stopped after six replies" — shown centred, never as a bot.
    static let systemAuthor = "system"
    var isSystem: Bool { author == Self.systemAuthor }
}
