import Observation
import SwiftUI

/// One open chat: its entries, kept fresh while it's on screen, and what the person does in it.
@MainActor
@Observable
final class ChatModel {
    let botID: String
    private(set) var entries: [Entry] = []
    /// Whether the first answer has come back, so an empty chat can say so rather than flash.
    private(set) var loaded = false
    /// The approval or question being answered, so its buttons can't be pressed twice.
    private(set) var answering: Set<String> = []
    /// What went wrong with the last thing the person did, shown for a few seconds.
    private(set) var problem: String?

    /// The bot as this chat's own poll last saw it, which is fresher than the list's.
    private var fromThread: Bot?
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var clearProblem: Task<Void, Never>?

    init(botID: String, session: AppSession) {
        self.botID = botID
        self.session = session
    }

    var bot: Bot {
        fromThread ?? session.bot(botID) ?? .placeholder(botID)
    }

    /// Every 1.5 seconds while the chat is on screen and the app is in the foreground.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    func refresh() async {
        guard let client = session.client else { return }
        do {
            let thread = try await client.thread(botID)
            if thread.bot != fromThread { fromThread = thread.bot }
            // Only on change: a poll that brings nothing new must not move the scroll or redraw.
            if thread.entries != entries { entries = thread.entries }
            loaded = true
        } catch let error as RemoteError {
            switch error {
            case .unpaired: session.lostPairing()
            case _ where error.isGone:
                session.path.removeAll { $0 == botID }
            default:
                break // The list's poll shows the offline banner; one place says it.
            }
        } catch {
            // Cancelled as the chat closed.
        }
    }

    /// Sends a message. False if it didn't go, so the text can go back in the box.
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = session.client else { return false }
        do {
            try await client.send(trimmed, to: botID)
            await refresh()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func decide(_ approval: Approval, allow: Bool) async {
        if allow {
            switch await OwnerCheck.confirm("Allow \(bot.name.isEmpty ? "your bot" : bot.name) to \(approval.action)") {
            case .confirmed: break
            case .cancelled: return
            case .unavailable(let message): report(message); return
            }
        }
        await answer(approval.id) { client in
            try await client.decide(approval.id, allow: allow, for: self.botID)
        }
    }

    func answer(_ question: Question, with option: String) async {
        await answer(question.id) { client in
            try await client.answer(question.id, with: option, for: self.botID)
        }
    }

    func stop() async {
        guard let client = session.client else { return }
        do {
            try await client.stop(botID)
            await session.refreshBots()
        } catch {
            report(error)
        }
    }

    private func answer(_ id: String, _ call: (RemoteClient) async throws -> Void) async {
        guard let client = session.client, !answering.contains(id) else { return }
        answering.insert(id)
        defer { answering.remove(id) }
        do {
            try await call(client)
        } catch let error as RemoteError where error.isAlreadyAnswered {
            // Answered on the Mac first. The refresh below shows what was decided.
        } catch {
            report(error)
        }
        await refresh()
        await session.refreshBots()
    }

    private func report(_ error: Error) {
        if case RemoteError.unpaired = error {
            session.lostPairing()
            return
        }
        report(error.localizedDescription)
    }

    private func report(_ message: String) {
        withAnimation { problem = message }
        clearProblem?.cancel()
        clearProblem = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { problem = nil }
        }
    }
}
