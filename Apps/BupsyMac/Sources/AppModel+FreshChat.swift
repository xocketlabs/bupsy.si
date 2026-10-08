import BupsyKit
import Foundation

/// Starting a bot on a fresh chat without losing the thread of its work.
///
/// A long chat resends its whole history every turn, which is where a subscription's usage goes;
/// the engines compact a chat only once it is nearly full, and a compacted chat is still large.
/// A fresh chat costs almost nothing per turn, but a bot that simply forgot would start over. So
/// the bot first writes itself hand-off notes, shown in the chat, and the first turn of the fresh
/// chat carries them. Its earlier messages stay on screen and in the store either way.
extension AppModel {
    /// How full the context window is before a long chat is moved on, when that is switched on:
    /// well before the engine's own compaction, so each turn after it is cheap.
    static let freshChatThreshold = 0.6

    static let handoffHeading = "Notes you wrote yourself at the end of your previous chat, so you can pick up where you left off:"

    static let handoffPrompt = """
        This chat is getting long, so you are about to continue in a fresh one that starts with \
        no memory of it. Write yourself hand-off notes: what you are working on, what is done, \
        decisions made and why, the files and commands that matter, anything the person asked \
        you to remember, and the next steps. Be specific and brief, under 300 words. Reply with \
        only the notes, and don't use any tools.
        """

    static func handoffKey(_ bot: BotID) -> String { "si.bupsy.handoffNotes.\(bot.rawValue)" }

    /// The button: hand-off notes now, or as soon as the bot finishes what it is doing.
    func moveToFreshChat(_ bot: Bot) {
        guard bot.remote == nil else { return }
        let thread = thread(for: bot.id)
        if isRunning(bot.id) {
            guard !writingHandoff.contains(bot.id), freshChatDue.insert(bot.id).inserted else { return }
            thread.entries.append(TranscriptEntry(kind: .note("A fresh chat starts when \(bot.name) finishes.")))
            return
        }
        if !writeHandoff(bot) {
            thread.entries.append(TranscriptEntry(kind: .note("This is already a fresh chat.")))
        }
    }

    /// Whether a chat that just finished a turn has grown long enough to move on, when the person
    /// asked for that. Only where the window's size is known, so never on a guess.
    func needsFreshChat(_ bot: Bot, thread: Thread) -> Bool {
        guard freshensLongChats, bot.remote == nil, !writingHandoff.contains(bot.id),
              let context = thread.latestUsage?.context,
              let capacity = AgentLimitsCard.contextCapacity(for: bot, reported: context.window)
        else { return false }
        return Double(context.total) >= Double(capacity) * Self.freshChatThreshold
    }

    /// Asks the bot for its notes, then moves it to a fresh chat. False when there is no chat to
    /// leave (it is already fresh) or the run could not start.
    @discardableResult
    func writeHandoff(_ bot: Bot) -> Bool {
        let thread = thread(for: bot.id)
        guard thread.conversationID != nil, !isRunning(bot.id) else { return false }
        writingHandoff.insert(bot.id)
        let started = startRun(Self.handoffPrompt, bot: bot, thread: thread, groupID: nil,
                               onFinish: { [weak self] notes in self?.finishHandoff(bot, notes: notes) },
                               hidesPrompt: true)
        if !started { writingHandoff.remove(bot.id) }
        return started
    }

    private func finishHandoff(_ bot: Bot, notes: String) {
        writingHandoff.remove(bot.id)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = bots.first(where: { $0.id == bot.id }) else {
            thread(for: bot.id).entries.append(TranscriptEntry(kind: .note(
                "\(bot.name) couldn't write hand-off notes, so it stays in this chat.")))
            return
        }
        AppHome.defaults.set(trimmed, forKey: Self.handoffKey(bot.id))
        startFreshChat(current, note: "Fresh chat. \(current.name) carries on from the notes above, "
            + "without resending everything before them.")
    }

    // MARK: - The context meter between turns and across restarts

    private static func contextKey(_ bot: BotID) -> String { "si.bupsy.lastContext.\(bot.rawValue)" }

    private struct RememberedContext: Codable {
        var conversation: String
        var context: ContextUse
    }

    /// After a turn: Codex's own figures, which `exec` leaves out, then the meter is remembered
    /// for the next launch. Only for the conversation it was measured in, so a fresh chat or an
    /// engine switch never shows the old chat's size.
    func settleContext(_ bot: Bot, thread: Thread) {
        guard let conversation = thread.conversationID else { return }
        if bot.engine == .codex {
            let id = conversation.rawValue
            Task { [weak self] in
                let reading = await Task.detached(priority: .utility) { CodexSessions.latest(conversation: id) }.value
                guard let self, let reading, thread.conversationID == conversation else { return }
                if let context = reading.context {
                    var usage = thread.latestUsage ?? Usage()
                    usage.context = context
                    thread.latestUsage = usage
                }
                if let limits = reading.limits { thread.latestLimits = limits }
                self.rememberContext(bot.id, thread: thread)
            }
        } else {
            rememberContext(bot.id, thread: thread)
        }
    }

    private func rememberContext(_ bot: BotID, thread: Thread) {
        guard let conversation = thread.conversationID, let context = thread.latestUsage?.context,
              let data = try? JSONEncoder().encode(RememberedContext(conversation: conversation.rawValue, context: context))
        else { return }
        AppHome.defaults.set(data, forKey: Self.contextKey(bot))
    }

    func rememberedContext(_ bot: BotID, conversation: ConversationID?) -> ContextUse? {
        guard let conversation, let data = AppHome.defaults.data(forKey: Self.contextKey(bot)),
              let remembered = try? JSONDecoder().decode(RememberedContext.self, from: data),
              remembered.conversation == conversation.rawValue else { return nil }
        return remembered.context
    }

    /// The notes for a fresh chat's first turn, once: later turns have them in the chat.
    func takeHandoffNotes(_ bot: BotID) -> String? {
        let key = Self.handoffKey(bot)
        defer { AppHome.defaults.removeObject(forKey: key) }
        return AppHome.defaults.string(forKey: key)
    }
}
