import BupsyKit
import Foundation

/// What a bot's chat page needs from the model on top of sending: retrying a failed run and
/// checking a sign-in again.
///
/// Both go through calls AppModel already makes. A retry is `send(_:to:)`, the same call the
/// composer makes, so a retried message is queued, recorded and gated exactly like a typed one.
/// A sign-in check is `refreshEngineStatus()`, which asks each engine's own status command and
/// keeps only its verdict.
extension AppModel {
    /// The message a failed run can be retried with, or nil when a retry would not be honest.
    ///
    /// Only the latest failure in the bot's own thread, while nothing is running, and only when
    /// the run was started by something the person typed: a retry re-sends their words, so a
    /// run another bot started, or one bupsy started on their behalf, has nothing of theirs to
    /// send. Anything said after the failure means the conversation moved on, so the card stops
    /// offering it. A run that took several queued messages is retried with all of them, joined
    /// the way they were sent the first time.
    func retryPrompt(afterFailure failureID: UUID, for bot: Bot) -> String? {
        let current = thread(for: bot.id)
        guard !current.isRunning, !isRunning(bot.id),
              let failureIndex = current.entries.firstIndex(where: { $0.id == failureID })
        else { return nil }
        if case .failure(let failure) = current.entries[failureIndex].kind,
           FailureNotice.isRosterNote(failure) {
            return nil
        }

        for entry in current.entries[(failureIndex + 1)...] {
            switch entry.kind {
            // A run's own end marker after its failure is not the conversation moving on.
            case .userMessage, .messageFrom, .assistantText, .failure:
                return nil
            default:
                continue
            }
        }

        guard let messages = Self.failedRunMessages(current.entries, failureIndex: failureIndex)
        else { return nil }
        return QueuedMessages.prompt(messages)
    }

    /// What the person sent to start the run that failed at `failureIndex`, or nil when they
    /// did not start it.
    ///
    /// A run's own messages open it: one typed while the bot was free, or several sent together
    /// after a reload. Messages queued while the bot was busy sit inside the previous run in a
    /// live thread, after its opening, because that is when they were typed; a run that opens
    /// with none of its own took exactly those.
    nonisolated static func failedRunMessages(_ entries: [TranscriptEntry], failureIndex: Int) -> [String]? {
        guard failureIndex > 0, failureIndex <= entries.count else { return nil }
        let start = runStart(entries, before: failureIndex)
        switch opening(entries, from: start, to: failureIndex) {
        case .messages(let messages):
            return messages
        case .fromElsewhere:
            return nil
        case .nothing:
            // Started from the queue: the messages are in the run before, after its opening.
            guard start > 0 else { return nil }
            let previousStart = runStart(entries, before: start - 1)
            var queued: [String] = []
            var pastOpening = false
            for entry in entries[previousStart..<(start - 1)] {
                switch entry.kind {
                case .userMessage(let text):
                    if pastOpening { queued.append(text) }
                case .note, .question:
                    continue
                default:
                    pastOpening = true
                }
            }
            return queued.isEmpty ? nil : queued
        }
    }

    private enum RunOpening { case messages([String]), fromElsewhere, nothing }

    /// The first index after the end of the run before `index`: after the latest `.finished`
    /// or `.failure` before it, or 0.
    private nonisolated static func runStart(_ entries: [TranscriptEntry], before index: Int) -> Int {
        var cursor = index - 1
        while cursor >= 0 {
            switch entries[cursor].kind {
            case .finished, .failure: return cursor + 1
            default: cursor -= 1
            }
        }
        return 0
    }

    /// How the run in `start..<end` began: with the person's messages, with someone else's,
    /// or with nothing of either (bupsy's own prompt, or the queue).
    private nonisolated static func opening(_ entries: [TranscriptEntry], from start: Int, to end: Int) -> RunOpening {
        var messages: [String] = []
        for entry in entries[start..<end] {
            switch entry.kind {
            case .userMessage(let text):
                messages.append(text)
            // Not part of a run's work: bupsy's notes, and a question the bot left before it.
            case .note, .question:
                continue
            case .messageFrom:
                return messages.isEmpty ? .fromElsewhere : .messages(messages)
            default:
                return messages.isEmpty ? .nothing : .messages(messages)
            }
        }
        return messages.isEmpty ? .nothing : .messages(messages)
    }

    /// Re-sends the person's last message to the bot, through the composer's own path.
    func retry(afterFailure failureID: UUID, for bot: Bot) {
        guard let prompt = retryPrompt(afterFailure: failureID, for: bot) else { return }
        send(prompt, to: bot)
    }

    /// Asks the bot's engine whether it is signed in now. True when a run would be expected to
    /// work. Uses the engine's own status command, never anything the engine stores.
    func recheckSignIn(for bot: Bot) async -> Bool {
        await refreshEngineStatus()
        return engineStatus[bot.engine]?.isUsable == true
    }
}

/// A run's latest in-progress step, in words: "Running npm test", "Editing login.ts",
/// "Reading 3 files", "Thinking", or "Working" when nothing more specific is known.
///
/// Read from the transcript alone. Tool calls whose result has not arrived yet are the ones in
/// progress; several at the end of the thread at once are calls the engine made in parallel.
enum ChatLiveStatus {
    static func text(for entries: [TranscriptEntry]) -> String {
        guard let last = entries.last else { return "Working" }
        if case .thinking = last.kind { return "Thinking" }

        var inProgress: [(name: String, arguments: String)] = []
        for entry in entries.reversed() {
            guard case .tool(let name, let arguments, let result, let failed) = entry.kind,
                  result == nil, !failed else { break }
            inProgress.append((name: name, arguments: arguments))
        }
        guard let first = inProgress.last else { return "Working" }
        if inProgress.count == 1 { return single(name: first.name, arguments: first.arguments) }

        let kinds = Set(inProgress.map { kind(of: $0.name) })
        let count = inProgress.count
        if kinds.count == 1, let only = kinds.first {
            switch only {
            case .read: return "Reading \(count) files"
            case .edit: return "Editing \(count) files"
            case .shell: return "Running \(count) commands"
            case .search: return "Searching files"
            case .web: return "Searching the web"
            case .other: break
            }
        }
        return "Working on \(count) things"
    }

    private enum Kind: Hashable { case read, edit, shell, search, web, other }

    private static func kind(of name: String) -> Kind {
        switch name {
        case "Read": .read
        case "Write", "Edit", "MultiEdit", "edit", "NotebookEdit": .edit
        case "Bash", "shell": .shell
        case "Grep", "Glob": .search
        case "WebSearch", "WebFetch": .web
        default: .other
        }
    }

    private static func single(name: String, arguments: String) -> String {
        let object = parse(arguments)
        switch name {
        case "Bash", "shell":
            if let command = object["command"] as? String, let short = shortCommand(command) {
                return "Running \(short)"
            }
            return "Running a command"
        case "Read":
            return fileName(object).map { "Reading \($0)" } ?? "Reading a file"
        case "Write", "Edit", "MultiEdit", "edit", "NotebookEdit":
            return fileName(object).map { "Editing \($0)" } ?? "Editing files"
        case "WebSearch":
            return "Searching the web"
        case "WebFetch":
            if let url = object["url"] as? String, let host = URL(string: url)?.host, !host.isEmpty {
                return "Reading \(host)"
            }
            return "Reading a web page"
        case "Grep", "Glob":
            return "Searching files"
        case "Task":
            return "Working on a sub-task"
        case "mcp__bupsy__message_bot":
            if let to = object["to"] as? String, !to.isEmpty { return "Messaging \(to)" }
            return "Messaging a bot"
        case "mcp__bupsy__ask_person":
            return "Asking you"
        case "ToolSearch", "mcp__bupsy__update_me", "mcp__bupsy__create_bot", "mcp__bupsy__list_bots":
            return "Working"
        default:
            if name.hasPrefix("mcp__") {
                let server = name.dropFirst(5).split(separator: "_").first.map(String.init) ?? ""
                return server.isEmpty ? "Using an app" : "Using \(server.capitalized)"
            }
            return "Working"
        }
    }

    private static func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func fileName(_ object: [String: Any]) -> String? {
        for key in ["file_path", "path", "notebook_path"] {
            if let path = object[key] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return nil
    }

    /// The gist of a shell command: the program and its first word or two, stopping at flags,
    /// pipes and redirects. "cd app && npm test -- login" reads "npm test".
    static func shortCommand(_ command: String) -> String? {
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        // The last step of a chain is the one that does the work; earlier ones are usually `cd`.
        let step = firstLine.components(separatedBy: "&&").last ?? firstLine
        var words = step.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        // Codex wraps commands as `bash -lc '...'`: show what is inside.
        if words.count > 2, words[0].hasSuffix("sh"), words[1].hasPrefix("-"), words[1].contains("c") {
            let inner = words.dropFirst(2).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return shortCommand(inner)
        }
        var kept: [String] = []
        let stops: Set<String> = ["|", "||", ">", ">>", "<", ";", "2>&1"]
        while !words.isEmpty && kept.count < 3 {
            let word = words.removeFirst()
            if word.hasPrefix("-") || stops.contains(word) { break }
            kept.append(word)
        }
        let joined = kept.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return joined.count > 32 ? String(joined.prefix(31)) + "…" : joined
    }
}

/// How long something in a thread took, as a short label: "0.1s", "6.8s", "8s", "1m 12s".
enum ChatDuration {
    static func label(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 10 { return String(format: "%.1fs", value) }
        if value < 60 { return "\(Int(value))s" }
        return "\(Int(value) / 60)m \(Int(value) % 60)s"
    }

    /// Whole seconds once past one, for longer stretches like thinking: "8s" rather than "8.0s".
    static func whole(_ seconds: TimeInterval) -> String {
        seconds < 1 ? label(seconds) : ticking(seconds)
    }

    /// Whole seconds, for a step still running: the count ticks once a second.
    static func ticking(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s"
    }
}
