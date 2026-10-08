import Observation
import UIKit

/// The app's one source of truth: which Mac, whether it can be reached, and its bots.
///
/// It polls rather than holding a connection open, like the web app. A phone sleeps, changes
/// networks and drops off Tailscale far more often than a desktop does, and a poll simply carries
/// on afterwards where a socket would need reconnecting. Polling runs only while the app is in
/// the foreground (see `RootView`), so an idle phone costs the Mac nothing.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        /// No Mac yet, or the Mac removed this phone. The message says why, when there is a why.
        case unpaired(String?)
        /// Paired, and trying to reach the Mac. The message is why the last try failed.
        case connecting(String?)
        case ready
    }

    private(set) var phase: Phase
    /// The Mac's own name, under the wordmark.
    private(set) var mac = ""
    private(set) var bots: [Bot] = []
    /// How many bots need the person, for the pill at the top of the list.
    private(set) var waiting = 0
    /// The last look at the Mac failed, so what's on screen may be out of date.
    private(set) var offline = false
    /// The chats open on top of the list, newest last: the list's navigation path.
    var path: [String] = []
    /// Unsent text per bot, so leaving a chat never loses a half-typed message.
    var drafts: [String: String] = [:]
    /// The Mac's address, kept after it unpairs this phone so pairing again needs only a new code.
    private(set) var lastAddress = ""

    @ObservationIgnored private(set) var client: RemoteClient?
    @ObservationIgnored let alerts = NeedsYouAlerts()

    init() {
        let pairing = PairingStore.load()
        client = pairing.map { RemoteClient(pairing: $0) }
        phase = pairing == nil ? .unpaired(nil) : .connecting(nil)
    }

    var isPaired: Bool {
        if case .unpaired = phase { return false }
        return true
    }

    var openBotID: String? { path.last }

    func bot(_ id: String) -> Bot? {
        bots.first { $0.id == id }
    }

    /// Opens a chat on its own, as a tap on its notification does.
    func open(_ botID: String) {
        path = [botID]
    }

    // MARK: - Pairing

    func pair(_ link: PairingLink) async throws {
        let pairing = try await RemoteClient.pair(link, name: UIDevice.current.model)
        try PairingStore.save(pairing)
        client = RemoteClient(pairing: pairing)
        lastAddress = ""
        phase = .connecting(nil)
        await connect()
        // Asked for now, once something works, rather than at first launch: a permission
        // prompt before the app has done anything is the one people deny.
        await alerts.requestPermission()
    }

    /// Forgets the Mac on this phone. The Mac still lists this phone until it's removed there.
    func forget() {
        PairingStore.forget()
        client = nil
        alerts.reset()
        mac = ""
        bots = []
        waiting = 0
        offline = false
        path = []
        drafts = [:]
        phase = .unpaired(nil)
    }

    /// The Mac turned this phone's key away: it was removed in Bupsy's settings there.
    func lostPairing() {
        let address = client?.pairing.address.absoluteString ?? ""
        forget()
        lastAddress = address
        phase = .unpaired("This iPhone isn't paired any more. Make a new code on your Mac to pair it again.")
    }

    // MARK: - Staying current

    /// Runs for as long as the app is in the foreground: reaches the Mac, then keeps the list fresh.
    func keepFresh() async {
        while !Task.isCancelled {
            switch phase {
            case .unpaired: return
            case .connecting: await connect()
            case .ready: await refreshBots()
            }
            // The list every 3 seconds. A Mac that can't be reached is tried less often: it is
            // usually asleep, and will wake on its own.
            try? await Task.sleep(for: phase == .ready ? .seconds(3) : .seconds(5))
        }
    }

    func connect() async {
        guard let client else { return }
        do {
            mac = try await client.mac().mac
            phase = .ready
            await refreshBots()
        } catch RemoteError.unpaired {
            lostPairing()
        } catch let error as RemoteError {
            phase = .connecting(error.localizedDescription)
        } catch {
            // Cancelled: the app went to the background mid-request. The next look will retry.
        }
    }

    func refreshBots() async {
        guard let client else { return }
        do {
            let list = try await client.bots()
            offline = false
            // Only on change, so a poll that brings nothing new redraws nothing.
            if list.bots != bots { bots = list.bots }
            if list.waiting != waiting { waiting = list.waiting }
            await alerts.update(list.bots, waiting: list.waiting, client: client, quietFor: openBotID)
        } catch RemoteError.unpaired {
            lostPairing()
        } catch is CancellationError {
            return
        } catch {
            offline = true
        }
    }

    /// One look at the Mac while the app is closed, when iOS grants a background refresh.
    func refreshInBackground() async {
        BackgroundRefresh.schedule()
        guard let client, let list = try? await client.bots() else { return }
        await alerts.update(list.bots, waiting: list.waiting, client: client, quietFor: nil)
    }
}
