import BupsyKit
import Foundation

/// Carrying on a conversation from Claude Code itself (VS Code or the terminal) as a bot.
///
/// Bupsy runs the same Claude Code, and Claude Code resumes any of its conversations by id. So a
/// conversation becomes a bot that works in that conversation's folder, shows its recent history,
/// and continues it with everything Claude already knew. Copied by default: the first message
/// forks it (`--fork-session`), so the original carries on untouched in VS Code. Moved, it is the
/// same conversation, which must then not be used in both places at once.
extension AppModel {
    enum CarryOver {
        /// A copy to continue here; the original is left as it was.
        case copy
        /// The conversation itself continues here.
        case move
    }

    /// Forked on the bot's next run, then cleared once Claude has started the copy.
    static func forkKey(_ bot: BotID) -> String { "claude.forkNextRun.\(bot.rawValue)" }

    func shouldFork(_ bot: BotID) -> Bool { AppHome.defaults.bool(forKey: Self.forkKey(bot)) }

    func forked(_ bot: BotID) { AppHome.defaults.removeObject(forKey: Self.forkKey(bot)) }

    /// Makes the bot, opens it, and returns it.
    @discardableResult
    func continueClaudeSession(_ session: ClaudeSession, as mode: CarryOver) -> Bot? {
        var name = Self.botName(from: session)
        var counter = 2
        let base = name
        while isNameTaken(name) { name = "\(base) \(counter)"; counter += 1 }
        addBot(name: name, engine: .claude)
        guard let index = bots.firstIndex(where: { $0.name == name }) else { return nil }

        // Its folder is the conversation's, which is where Claude Code keeps it and where it
        // resumes. Kept to this Mac by default: it was private work in someone's editor.
        bots[index].workdir = session.folder
        bots[index].sharedWithDevices = false
        try? store?.save(bots[index].record(sortIndex: index))
        let bot = bots[index]

        let conversation = ConversationRecord(botID: bot.id.rawValue, engine: EngineID.claude.rawValue,
                                              providerConversationID: session.id, title: session.title,
                                              lastEventAt: session.lastActive)
        try? store?.save(conversation)
        let thread = thread(for: bot.id)
        thread.conversationID = ConversationID(session.id)
        importHistory(ClaudeSessions.transcript(of: session), into: thread, bot: bot, conversation: conversation.id)

        if mode == .copy { AppHome.defaults.set(true, forKey: Self.forkKey(bot.id)) }
        let from = session.source.rawValue
        thread.entries.append(TranscriptEntry(kind: .note(mode == .copy
            ? "Copied from \(from). Your next message continues a copy here; the original in \(from) stays as it was."
            : "Moved from \(from). It continues here now, so don't keep using it there at the same time.")))
        open(bot.id)
        return bot
    }

    /// The recent history, shown and kept as the bot's own, with the times it was said.
    private func importHistory(_ messages: [ImportedMessage], into thread: Thread, bot: Bot, conversation: String) {
        guard let first = messages.first else { return }
        func date(_ message: ImportedMessage) -> Date {
            switch message {
            case .you(_, let at), .bot(_, let at), .tool(_, _, let at): at
            }
        }
        let run = RunRecord(botID: bot.id.rawValue, conversationID: conversation, host: "local",
                            status: "imported", startedAt: date(first), endedAt: messages.last.map(date))
        try? store?.save(run)

        var records: [EventRecord] = []
        var seq = 0
        func record(_ event: AgentEvent, as type: String? = nil, at: Date) {
            let (kind, payload) = EventCodec.encode(event)
            records.append(EventRecord(runID: run.id, seq: seq, type: type ?? kind, payload: payload, at: at))
            seq += 1
        }
        for message in messages {
            switch message {
            case .you(let text, let at):
                thread.entries.append(TranscriptEntry(kind: .userMessage(text), at: at))
                record(.text(text), as: "userMessage", at: at)
            case .bot(let text, let at):
                thread.entries.append(TranscriptEntry(kind: .assistantText(text), at: at))
                record(.text(text), at: at)
            case .tool(let name, let arguments, let at):
                // Settled: these ran in Claude Code, before this bot existed.
                let id = UUID().uuidString
                thread.entries.append(TranscriptEntry(kind: .tool(name: name, arguments: arguments, result: "", failed: false), at: at))
                record(.toolCall(ToolCall(id: id, name: name, argumentsJSON: arguments)), at: at)
                record(.toolResult(ToolResult(callID: id, content: "", isError: false)), at: at)
            }
        }
        try? store?.append(records)
    }

    /// A short name from the conversation's title: its first few words.
    static func botName(from session: ClaudeSession) -> String {
        let words = session.title.split(separator: " ").prefix(4).joined(separator: " ")
        let trimmed = String(words.prefix(28)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return trimmed.isEmpty ? "Claude chat" : trimmed
    }
}
