import Observation
import SwiftUI

/// One open chat: its entries, kept fresh while it's on screen, and what the person does in it.
///
/// Every call goes to the bot's own Mac, through `AppSession.client(for:)`, so with several Macs
/// paired nothing here can reach the wrong one.
@MainActor
@Observable
final class ChatModel {
    let ref: BotRef
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

    init(ref: BotRef, session: AppSession) {
        self.ref = ref
        self.session = session
    }

    var bot: Bot {
        fromThread ?? session.bot(ref) ?? .placeholder(ref)
    }

    /// The bot's name as the list shows it: "Scout · Mac mini" when another Mac has a Scout too.
    var shownName: String {
        session.listed(ref)?.name ?? bot.name
    }

    /// Every 1.5 seconds while the chat is on screen and the app is in the foreground.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    func refresh() async {
        guard let client = session.client(for: ref) else { return }
        do {
            let thread = try await client.thread(ref.botID)
            if thread.bot != fromThread { fromThread = thread.bot }
            // Only on change: a poll that brings nothing new must not move the scroll or redraw.
            if thread.entries != entries { entries = thread.entries }
            loaded = true
        } catch let error as RemoteError {
            switch error {
            case .unpaired: session.lostPairing(ref.macID)
            case _ where error.isGone:
                session.path.removeAll { $0 == ref }
            default:
                break // The list's poll marks the Mac offline; one place says it.
            }
        } catch {
            // Cancelled as the chat closed.
        }
    }

    /// Sends a message. False if it didn't go, so the text can go back in the box.
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = session.client(for: ref) else { return false }
        do {
            try await client.send(trimmed, to: ref.botID)
            await refresh()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func decide(_ approval: Approval, allow: Bool) async {
        if allow {
            switch await OwnerCheck.confirm("Allow \(bot.name.isEmpty ? "your bot" : shownName) to \(approval.action)") {
            case .confirmed: break
            case .cancelled: return
            case .unavailable(let message): report(message); return
            }
        }
        let botID = ref.botID
        await answer(approval.id) { client in
            try await client.decide(approval.id, allow: allow, for: botID)
        }
    }

    func answer(_ question: Question, with option: String) async {
        let botID = ref.botID
        await answer(question.id) { client in
            try await client.answer(question.id, with: option, for: botID)
        }
    }

    func stop() async {
        guard let client = session.client(for: ref) else { return }
        do {
            try await client.stop(ref.botID)
            await session.refresh(ref.macID)
        } catch {
            report(error)
        }
    }

    private func answer(_ id: String, _ call: (RemoteClient) async throws -> Void) async {
        guard let client = session.client(for: ref), !answering.contains(id) else { return }
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
        await session.refresh(ref.macID)
    }

    private func report(_ error: Error) {
        if case RemoteError.unpaired = error {
            session.lostPairing(ref.macID)
            return
        }
        // With several Macs, "your Mac" could be any of them: say which.
        if case RemoteError.unreachable = error, session.pairedMacs.count > 1, let mac = session.mac(ref.macID) {
            report("Couldn't reach \(mac.displayName). Check it's awake with Bupsy open, and that Tailscale is on here and there.")
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
