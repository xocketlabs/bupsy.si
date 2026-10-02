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
    var avatarHue: Double

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
        self.avatarHue = record.avatarHue
    }

    func record(sortIndex: Int = 0) -> BotRecord {
        BotRecord(
            id: id.rawValue, name: name, engine: engine.rawValue, model: model,
            machineID: machineID, autonomy: autonomy.rawValue,
            personaPrompt: personaPrompt, avatarHue: avatarHue, sortIndex: sortIndex)
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
    enum Kind: Sendable {
        case userMessage(String)
        case assistantText(String)
        case thinking(String)
        case tool(name: String, arguments: String, result: String?, failed: Bool)
        case approval(PendingApproval)
        case limits(RateLimit)
        case failure(EngineFailure)
        case finished(Outcome)
    }

    let id = UUID()
    var kind: Kind
    var at = Date()
}

/// A tool call waiting on the user, as the UI holds it.
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
    var connectorStates: [ConnectorState] = []

    init(botID: BotID) { self.botID = botID }

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

        case .usage:
            break

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

    func raiseApproval(_ approval: PendingApproval) {
        entries.append(TranscriptEntry(kind: .approval(approval)))
    }

    /// Replays a stored row. `userMessage` is written as its own type so a reloaded transcript
    /// shows who said what, which `AgentEvent` alone does not carry — it only ever describes the
    /// engine's side of the conversation.
    func applyStored(type: String, payload: String) {
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
