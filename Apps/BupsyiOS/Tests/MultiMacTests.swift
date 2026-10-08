import Foundation
import Testing
@testable import Bupsy

/// Two Macs, as the person might have them: a laptop and a desktop, each with its own sections,
/// sharing one section name and one bot name.
private enum Fixture {
    static let laptop = PairedMac(id: "L", name: "MacBook Air", address: URL(string: "https://air.tail1.ts.net:8443")!, kind: "laptop")
    static let desktop = PairedMac(id: "D", name: "Mac mini", address: URL(string: "https://mini.tail1.ts.net:8443")!, kind: "desktop")

    static func bot(_ mac: PairedMac, _ id: String, _ name: String, _ section: String? = nil, needsYou: Bool = false) -> Bot {
        Bot(ref: BotRef(macID: mac.id, botID: id), name: name, section: section, colour: "#e075c8", needsYou: needsYou)
    }

    /// The laptop: Lead pinned, then Work (Scout, Writer), then Home.
    static let laptopBots = [
        bot(laptop, "b1", "Lead"),
        bot(laptop, "b2", "Scout", "Work"),
        bot(laptop, "b3", "Writer", "Work"),
        bot(laptop, "b4", "Chef", "Home"),
    ]

    /// The desktop: Builder unsectioned, then Work (a second Scout, Tester), then Ops. Its ids
    /// deliberately repeat the laptop's.
    static let desktopBots = [
        bot(desktop, "b1", "Builder"),
        bot(desktop, "b2", "scout", "Work", needsYou: true),
        bot(desktop, "b3", "Tester", "Work", needsYou: true),
        bot(desktop, "b4", "Deployer", "Ops"),
    ]

    static func states(laptopOnline: Bool = true, desktopOnline: Bool = true) -> [String: MacState] {
        [laptop.id: MacState(reached: true, problem: laptopOnline ? nil : "Couldn't reach it", bots: laptopBots, waiting: 0),
         desktop.id: MacState(reached: true, problem: desktopOnline ? nil : "Couldn't reach it", bots: desktopBots, waiting: 2)]
    }
}

@Suite("Several Macs: one list")
struct BotDirectoryTests {
    private let macs = [Fixture.laptop, Fixture.desktop]

    @Test("two Macs' bots share sections by name, each Mac in its own order, unsectioned first")
    func merged() {
        let sections = BotDirectory.sections(macs: macs, states: Fixture.states())
        #expect(sections.map(\.title) == [nil, "Work", "Home", "Ops"])
        let names = sections.map { $0.bots.map(\.bot.name) }
        #expect(names == [["Lead", "Builder"], ["Scout", "Writer", "scout", "Tester"], ["Chef"], ["Deployer"]])
        // Not grouped by Mac: Work holds both Macs' bots, the laptop's first as it was paired first.
        #expect(sections[1].bots.map(\.mac.id) == ["L", "L", "D", "D"])
    }

    @Test("a name on two Macs gets its Mac's name; a name on one Mac doesn't")
    func duplicateNames() {
        let listed = BotDirectory.list(macs: macs, states: Fixture.states())
        let names = Set(listed.map(\.name))
        #expect(names.contains("Scout · MacBook Air"))
        #expect(names.contains("scout · Mac mini"))
        #expect(names.contains("Lead") && names.contains("Tester"))

        // Two bots of one name on the same Mac: adding that Mac's name to both would tell nothing apart.
        let twins = [Fixture.bot(Fixture.laptop, "x", "Echo"), Fixture.bot(Fixture.laptop, "y", "Echo")]
        let same = BotDirectory.list(macs: [Fixture.laptop], states: ["L": MacState(reached: true, bots: twins)])
        #expect(same.map(\.name) == ["Echo", "Echo"])
    }

    @Test("the same bot id on two Macs is two bots, and a bot's id carries its Mac")
    func idsDontCollide() throws {
        let listed = BotDirectory.list(macs: macs, states: Fixture.states())
        #expect(listed.count == 8)
        #expect(Set(listed.map(\.id)).count == 8)
        #expect(listed.first { $0.id == BotRef(macID: "L", botID: "b2") }?.bot.name == "Scout")
        #expect(listed.first { $0.id == BotRef(macID: "D", botID: "b2") }?.bot.name == "scout")

        let ref = BotRef(macID: "D", botID: "b2")
        #expect(ref.description == "D:b2")
        #expect(BotRef(ref.description) == ref)
        // The Mac id never holds a colon, so a bot id that does survives the round trip.
        #expect(BotRef("D:odd:id") == BotRef(macID: "D", botID: "odd:id"))
        #expect(BotRef("no-mac") == nil)
    }

    @Test("the device icon shows only when there's more than one Mac")
    func deviceIcon() {
        #expect(BotDirectory.list(macs: macs, states: Fixture.states()).allSatisfy { $0.showsMac })
        let one = BotDirectory.list(macs: [Fixture.laptop], states: Fixture.states())
        #expect(!one.isEmpty && one.allSatisfy { !$0.showsMac })
        #expect(Fixture.laptop.symbol == "laptopcomputer" && Fixture.desktop.symbol == "desktopcomputer")
    }

    @Test("the waiting pill sums every Mac that answered")
    func waiting() {
        var states = Fixture.states()
        states["L"]?.waiting = 1
        #expect(BotDirectory.waiting(macs: macs, states: states) == 3)
        // What an offline Mac last said may be answered there already.
        states["D"]?.problem = "Couldn't reach it"
        #expect(BotDirectory.waiting(macs: macs, states: states) == 1)
    }

    @Test("an offline Mac's bots are greyed while the other Mac's carry on")
    func offline() {
        let listed = BotDirectory.list(macs: macs, states: Fixture.states(desktopOnline: false))
        #expect(listed.filter { $0.mac.id == "D" }.allSatisfy { !$0.online })
        #expect(listed.filter { $0.mac.id == "L" }.allSatisfy { $0.online })
        #expect(BotDirectory.status(of: Fixture.desktop, Fixture.states(desktopOnline: false)["D"]) == .offline)
        #expect(BotDirectory.status(of: Fixture.laptop, Fixture.states()["L"]) == .connected)
        #expect(BotDirectory.status(of: Fixture.laptop, nil) == .connecting)
    }

    @Test("a notification names the Mac only when there's more than one")
    func notificationTitle() {
        #expect(NeedsYouAlerts.title("Lead", on: nil) == "Lead needs you")
        #expect(NeedsYouAlerts.title("Lead", on: "Mac mini") == "Lead needs you on Mac mini")
    }
}

@Suite("Several Macs: keeping them")
struct MacStoreTests {
    @Test("the one-Mac version's pairing becomes the first Mac on the list, with its key moved")
    func migratesLegacyPairing() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let address = URL(string: "https://studio.tail1234.ts.net:8443")!
        let keys = MemoryKeys(legacy: Pairing(address: address, key: "SECRET"))
        defaults.set(["b1", "b2"], forKey: "alerts.waiting")
        let store = MacStore(defaults: defaults, keys: keys)

        let macs = store.load()
        let mac = try #require(macs.first)
        #expect(macs.count == 1)
        #expect(mac.address == address && !mac.unpaired)
        #expect(mac.displayName == "studio") // until it says its own name
        #expect(keys.key(for: mac.id) == "SECRET")
        #expect(keys.legacyPairing() == nil)
        // Its waiting bots are filed under it, so the update doesn't announce them again.
        let known = defaults.dictionary(forKey: "alerts.waitingByMac") as? [String: [String]]
        #expect(known?[mac.id] == ["\(mac.id):b1", "\(mac.id):b2"])
        #expect(defaults.object(forKey: "alerts.waiting") == nil)

        // Done once: the next launch reads the list, with the same id.
        #expect(store.load() == macs)
    }

    @Test("a fresh install has no Macs, and each Mac's key is its own item")
    func separateKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let keys = MemoryKeys()
        let store = MacStore(defaults: defaults, keys: keys)
        #expect(store.load().isEmpty)
        try keys.setKey("A", for: "L")
        try keys.setKey("B", for: "D")
        keys.removeKey(for: "L")
        #expect(keys.key(for: "L") == nil && keys.key(for: "D") == "B")
    }
}

/// The session against stand-ins for two or three Macs at once, through URLSession.
@Suite("Several Macs: talking to them", .serialized)
@MainActor
struct MultiMacSessionTests {
    private nonisolated static let botsJSON = """
        {"bots":[{"id":"b1","name":"Lead","role":null,"section":"Work","colour":"#e075c8","mood":"waitingForYou",
        "running":false,"needsYou":true,"unread":false,"preview":"Can I push?"}],"waiting":1}
        """

    private func session(_ macs: [PairedMac], keys: MemoryKeys, answer: @escaping MacsStub.Handler) throws -> AppSession {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let store = MacStore(defaults: defaults, keys: keys)
        store.save(macs)
        for mac in macs { try keys.setKey("key-\(mac.id)", for: mac.id) }
        return AppSession(store: store, network: MacsStub.session(answer))
    }

    @Test("a 401 from one Mac unpairs only that Mac; the other keeps working")
    func unpairedOnOneMac() async throws {
        let keys = MemoryKeys()
        let session = try session([Fixture.laptop, Fixture.desktop], keys: keys) { request in
            if request.url?.host == "air.tail1.ts.net" {
                return (401, #"{"error":"This device isn't paired."}"#)
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == "bupsy_device=key-D")
            return request.url?.path == "/api/session" ? (200, #"{"mac":"Mac mini","kind":"desktop"}"#) : (200, Self.botsJSON)
        }
        session.drafts[BotRef(macID: "L", botID: "b1")] = "half a thought"
        await session.refreshAll()

        #expect(session.mac("L")?.unpaired == true)
        #expect(keys.key(for: "L") == nil)
        #expect(session.mac("L").map(session.status(of:)) == .notPaired)
        #expect(session.mac("D")?.unpaired == false)
        #expect(session.phase == .ready)
        #expect(session.listed.map(\.id) == [BotRef(macID: "D", botID: "b1")])
        #expect(session.waiting == 1)
        // Kept for when it's paired again at the same address.
        #expect(session.drafts[BotRef(macID: "L", botID: "b1")] == "half a thought")
        #expect(session.cannotSend(to: BotRef(macID: "L", botID: "b1")) == "MacBook Air isn't paired with this iPhone any more.")
    }

    @Test("every Mac removing this phone goes back to pairing, naming the Mac")
    func unpairedEverywhere() async throws {
        let session = try session([Fixture.laptop], keys: MemoryKeys()) { _ in (401, "") }
        await session.refreshAll()
        #expect(session.phase == .unpaired("This iPhone isn't paired with MacBook Air any more. Make a new code on your Mac to pair it again."))
    }

    @Test("one Mac asleep greys its bots and blocks sending to them, while the other works")
    func oneOffline() async throws {
        let session = try session([Fixture.laptop, Fixture.desktop], keys: MemoryKeys()) { request in
            if request.url?.host == "mini.tail1.ts.net" { throw URLError(.cannotConnectToHost) }
            return request.url?.path == "/api/session" ? (200, #"{"mac":"MacBook Air","kind":"laptop"}"#) : (200, Self.botsJSON)
        }
        await session.refreshAll()
        #expect(session.phase == .ready)
        #expect(session.status(of: Fixture.desktop) == .offline)
        #expect(session.status(of: Fixture.laptop) == .connected)
        #expect(session.offlineMacs.map(\.id) == ["D"])
        #expect(session.listed.allSatisfy { $0.online })
        #expect(session.cannotSend(to: BotRef(macID: "D", botID: "b1"))
            == "Mac mini is offline. You can send again when it's awake and on Tailscale.")
        #expect(session.cannotSend(to: BotRef(macID: "L", botID: "b1")) == nil)
        // Each call goes to the bot's own Mac.
        #expect(session.client(for: BotRef(macID: "L", botID: "b1"))?.pairing.address == Fixture.laptop.address)
        #expect(session.client(for: BotRef(macID: "D", botID: "b1"))?.pairing.address == Fixture.desktop.address)
    }

    @Test("the first look learns each Mac's name and kind; an older Mac without a kind stays a desktop")
    func learnsNames() async throws {
        let unnamed = PairedMac(id: "N", name: "", address: URL(string: "https://studio.tail1.ts.net:8443")!)
        let session = try session([unnamed], keys: MemoryKeys()) { request in
            request.url?.path == "/api/session" ? (200, #"{"mac":"Studio"}"#) : (200, Self.botsJSON)
        }
        await session.refreshAll()
        #expect(session.mac("N")?.name == "Studio")
        #expect(session.mac("N")?.kind == "desktop")
    }

    @Test("a notification from the one-Mac version still opens its bot")
    func legacyNotification() throws {
        let session = try session([Fixture.laptop], keys: MemoryKeys()) { _ in (200, "{}") }
        #expect(session.ref(fromNotification: "b7") == BotRef(macID: "L", botID: "b7"))
        #expect(session.ref(fromNotification: "L:b7") == BotRef(macID: "L", botID: "b7"))
    }
}

/// Keys in memory, standing in for the Keychain.
final class MemoryKeys: KeyStore {
    private var keys: [String: String] = [:]
    private var legacy: Pairing?

    init(legacy: Pairing? = nil) { self.legacy = legacy }

    func key(for macID: String) -> String? { keys[macID] }
    func setKey(_ key: String, for macID: String) throws { keys[macID] = key }
    func removeKey(for macID: String) { keys[macID] = nil }
    func legacyPairing() -> Pairing? { legacy }
    func removeLegacyPairing() { legacy = nil }
}

/// Answers URLSession requests from a closure, standing in for several Macs at once, told apart
/// by host. Separate from `StubProtocol` so the two suites can run side by side.
final class MacsStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)

    nonisolated(unsafe) private static var handler: Handler?

    static func session(_ handler: @escaping Handler) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacsStub.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
