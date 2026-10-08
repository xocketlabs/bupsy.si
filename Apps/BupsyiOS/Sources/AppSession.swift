import Observation
import UIKit

/// The app's one source of truth: which Macs, whether each can be reached, and their bots.
///
/// It polls rather than holding connections open, like the web app. A phone sleeps, changes
/// networks and drops off Tailscale far more often than a desktop does, and a poll simply carries
/// on afterwards where a socket would need reconnecting. Polling runs only while the app is in
/// the foreground (see `RootView`), so an idle phone costs the Macs nothing.
///
/// Each Mac is looked at on its own, at the same time as the others, so one that's asleep and
/// slow to time out never holds up the rest. One Mac failing, or removing this phone, changes
/// only that Mac's bots.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        /// No Mac yet, or every Mac removed this phone. The message says why, when there is a why.
        case unpaired(String?)
        /// Paired, and no Mac has answered yet. The message is why the last tries failed.
        case connecting(String?)
        case ready
    }

    /// Every Mac this phone knows, in the order they were paired, including any that removed it.
    private(set) var macs: [PairedMac]
    /// What each Mac said at its last look, by Mac id.
    private(set) var states: [String: MacState] = [:]
    /// The chats open on top of the list, newest last: the list's navigation path.
    var path: [BotRef] = []
    /// Unsent text per bot, so leaving a chat never loses a half-typed message.
    var drafts: [BotRef: String] = [:]
    /// The "Your Macs" screen is up.
    var showingMacs = false

    @ObservationIgnored private var clients: [String: RemoteClient] = [:]
    @ObservationIgnored private let store: MacStore
    @ObservationIgnored private let network: URLSession
    @ObservationIgnored let alerts = NeedsYouAlerts()

    init(store: MacStore = MacStore(), network: URLSession = .remote) {
        self.store = store
        self.network = network
        var macs = store.load()
        for index in macs.indices where !macs[index].unpaired {
            let mac = macs[index]
            guard let key = store.keys.key(for: mac.id) else {
                // No key, no way in. Not saved: if the Keychain was only unreadable for a moment,
                // the next launch finds it again.
                macs[index].unpaired = true
                continue
            }
            clients[mac.id] = RemoteClient(pairing: Pairing(address: mac.address, key: key), macID: mac.id, session: network)
        }
        self.macs = macs
    }

    // MARK: - Reading

    var phase: Phase {
        let paired = pairedMacs
        if paired.isEmpty {
            guard let lost = macs.first(where: \.unpaired) else { return .unpaired(nil) }
            return .unpaired("This iPhone isn't paired with \(lost.displayName) any more. Make a new code on your Mac to pair it again.")
        }
        if paired.contains(where: { states[$0.id]?.reached == true }) { return .ready }
        let problems = paired.compactMap { states[$0.id]?.problem }
        return .connecting(problems.count == paired.count ? problems.first : nil)
    }

    /// The Macs this phone can still talk to.
    var pairedMacs: [PairedMac] { macs.filter { !$0.unpaired } }

    var isPaired: Bool { !pairedMacs.isEmpty }

    /// Every bot on every Mac, merged into one set of sections.
    var sections: [BotSection] { BotDirectory.sections(macs: macs, states: states) }

    var listed: [ListedBot] { BotDirectory.list(macs: macs, states: states) }

    /// How many bots need the person, across the Macs that answered.
    var waiting: Int { BotDirectory.waiting(macs: macs, states: states) }

    /// The Macs whose last look failed, for the banner over the list.
    var offlineMacs: [PairedMac] { pairedMacs.filter { states[$0.id]?.problem != nil } }

    var openBotID: BotRef? { path.last }

    func mac(_ id: String) -> PairedMac? {
        macs.first { $0.id == id }
    }

    func status(of mac: PairedMac) -> MacStatus {
        BotDirectory.status(of: mac, states[mac.id])
    }

    func bot(_ ref: BotRef) -> Bot? {
        states[ref.macID]?.bots.first { $0.ref == ref }
    }

    func listed(_ ref: BotRef) -> ListedBot? {
        listed.first { $0.id == ref }
    }

    /// One Mac's bots, for telling which of them is speaking in a chat on that Mac.
    func bots(on macID: String) -> [Bot] {
        states[macID]?.bots ?? []
    }

    /// The client for a bot's own Mac. Every call about a bot goes through this, so nothing meant
    /// for one Mac can reach another.
    func client(for ref: BotRef) -> RemoteClient? {
        clients[ref.macID]
    }

    /// Why the person can't write to this bot right now, or nil when they can.
    func cannotSend(to ref: BotRef) -> String? {
        guard let mac = mac(ref.macID) else { return "This bot's Mac isn't paired with this iPhone." }
        switch status(of: mac) {
        case .offline:
            return "\(mac.displayName) is offline. You can send again when it's awake and on Tailscale."
        case .notPaired:
            return "\(mac.displayName) isn't paired with this iPhone any more."
        case .connecting, .connected:
            return nil
        }
    }

    /// Opens a chat on its own, as a tap on its notification does.
    func open(_ ref: BotRef) {
        path = [ref]
    }

    /// The bot a notification is about. One posted by the one-Mac version carries a bare bot id,
    /// which can only have meant the one Mac there was.
    func ref(fromNotification text: String) -> BotRef? {
        if let ref = BotRef(text), mac(ref.macID) != nil { return ref }
        if macs.count == 1, let only = macs.first { return BotRef(macID: only.id, botID: text) }
        return nil
    }

    // MARK: - Pairing

    /// Pairs with a Mac and adds it to the list. A Mac already on the list at the same address is
    /// paired again in place, keeping its id, so its drafts and chats carry on.
    func pair(_ link: PairingLink) async throws {
        let pairing = try await RemoteClient.pair(link, name: UIDevice.current.model, session: network)
        var mac = macs.first { $0.address == link.address } ?? PairedMac(name: "", address: link.address)
        try store.keys.setKey(pairing.key, for: mac.id)
        mac.unpaired = false
        if let index = macs.firstIndex(where: { $0.id == mac.id }) { macs[index] = mac } else { macs.append(mac) }
        store.save(macs)
        clients[mac.id] = RemoteClient(pairing: pairing, macID: mac.id, session: network)
        states[mac.id] = MacState()
        await refresh(mac.id)
    }

    /// Forgets a Mac on this phone, key and all. The Mac still lists this phone until it's
    /// removed there.
    func forget(_ mac: PairedMac) {
        store.keys.removeKey(for: mac.id)
        macs.removeAll { $0.id == mac.id }
        store.save(macs)
        clients[mac.id] = nil
        states[mac.id] = nil
        path.removeAll { $0.macID == mac.id }
        drafts = drafts.filter { $0.key.macID != mac.id }
        if macs.isEmpty { alerts.reset() } else { alerts.forget(mac.id) }
    }

    /// A Mac turned this phone's key away: it was removed in Bupsy's settings there. Only that
    /// Mac stops. It stays on the list, marked, so the person can see which one it was and pair
    /// it again; its drafts are kept for when they do.
    func lostPairing(_ macID: String) {
        guard let index = macs.firstIndex(where: { $0.id == macID }), !macs[index].unpaired else { return }
        macs[index].unpaired = true
        store.save(macs)
        // The Mac won't take it again, so it's no use to keep.
        store.keys.removeKey(for: macID)
        clients[macID] = nil
        states[macID] = nil
        path.removeAll { $0.macID == macID }
        if pairedMacs.isEmpty { alerts.reset() } else { alerts.forget(macID) }
    }

    // MARK: - Staying current

    /// Runs for as long as the app is in the foreground: keeps every Mac's bots fresh, each on
    /// its own loop. `RootView` restarts it when the list of Macs changes.
    func keepFresh() async {
        let ids = pairedMacs.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.follow(id) }
            }
        }
    }

    private func follow(_ macID: String) async {
        while !Task.isCancelled, clients[macID] != nil {
            await refresh(macID)
            // The list every 3 seconds. A Mac that can't be reached is tried less often: it is
            // usually asleep, and will wake on its own.
            try? await Task.sleep(for: states[macID]?.online == true ? .seconds(3) : .seconds(5))
        }
    }

    /// One look at every Mac at once, for pull to refresh and after the person does something.
    func refreshAll() async {
        let ids = pairedMacs.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// One look at one Mac. The first look since launch also asks the Mac its name and kind, so
    /// a renamed Mac, or one moved over from the one-Mac version, is named right.
    func refresh(_ macID: String) async {
        guard let client = clients[macID] else { return }
        do {
            if states[macID]?.reached != true {
                learn(try await client.mac(), about: macID)
            }
            let list = try await client.bots()
            // Forgotten or re-paired while the request was out: this answer is about nothing now.
            guard clients[macID]?.pairing == client.pairing, let mac = mac(macID) else { return }
            var state = states[macID] ?? MacState()
            state.reached = true
            state.problem = nil
            state.bots = list.bots
            state.waiting = list.waiting
            // Only on change, so a poll that brings nothing new redraws nothing.
            if states[macID] != state { states[macID] = state }
            await alerts.update(list.bots, on: mac, client: client, showMac: pairedMacs.count > 1,
                                waiting: waiting, quietFor: openBotID)
        } catch RemoteError.unpaired {
            guard clients[macID]?.pairing == client.pairing else { return }
            lostPairing(macID)
        } catch is CancellationError {
            return
        } catch {
            guard clients[macID]?.pairing == client.pairing else { return }
            var state = states[macID] ?? MacState()
            state.problem = error.localizedDescription
            if states[macID] != state { states[macID] = state }
        }
    }

    /// One look at every Mac while the app is closed, when iOS grants a background refresh.
    func refreshInBackground() async {
        BackgroundRefresh.schedule()
        await refreshAll()
    }

    private func learn(_ info: MacInfo, about macID: String) {
        guard let index = macs.firstIndex(where: { $0.id == macID }) else { return }
        var mac = macs[index]
        if !info.mac.isEmpty { mac.name = info.mac }
        if let kind = info.kind { mac.kind = kind }
        guard mac != macs[index] else { return }
        macs[index] = mac
        store.save(macs)
    }
}
