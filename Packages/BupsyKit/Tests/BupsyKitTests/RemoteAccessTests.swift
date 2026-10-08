import Foundation
import Testing
@testable import BupsyKit

@Suite("Remote access: HTTP")
struct HTTPParserTests {
    @Test("a request with a body parses once all of it has arrived")
    func parsesWhenComplete() throws {
        let raw = "POST /api/bots/x/messages?since=3&q=a+b HTTP/1.1\r\nHost: m\r\nContent-Length: 13\r\nCookie: a=1; bupsy_device=KEY\r\n\r\n{\"text\":\"hi\"}"
        let partial = Data(raw.utf8).dropLast(4)
        #expect(try HTTPParser.parse(Data(partial)) == nil)
        let request = try #require(try HTTPParser.parse(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/api/bots/x/messages")
        #expect(request.query == ["since": "3", "q": "a b"])
        #expect(request.cookie("bupsy_device") == "KEY")
        #expect(request.json?["text"] as? String == "hi")
    }

    @Test("oversized and malformed requests are refused")
    func refuses() {
        #expect(throws: HTTPParser.Failure.tooLarge) {
            try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8))
        }
        #expect(throws: HTTPParser.Failure.malformed) {
            try HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8))
        }
        #expect(throws: HTTPParser.Failure.malformed) {
            try HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
    }

    @Test("responses close the connection and are never cached or framed")
    func responseHeaders() {
        let text = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Connection: close"))
        #expect(text.contains("Cache-Control: no-store"))
        #expect(text.contains("X-Frame-Options: DENY"))
        #expect(text.hasSuffix("{\"ok\":true}"))
    }

    @Test("the server answers on this Mac's loopback")
    func serves() async throws {
        let server = LocalHTTPServer { request in .json(["path": request.path]) }
        let port = try await server.start(preferredPort: 0)
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "{\"path\":\"/hello\"}")
    }
}

@Suite("Remote access: pairing")
@MainActor
struct RemoteDevicesTests {
    private func store(_ clock: @escaping () -> Date = Date.init) -> (RemoteDevices, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString).json")
        return (RemoteDevices(file: file, now: clock), file)
    }

    @Test("a code pairs a device once, and its key is kept only as a hash")
    func pairsOnce() throws {
        let (devices, file) = store()
        let code = devices.newCode()
        #expect(code.value.count == 6)
        #expect(code.value.allSatisfy { RemoteDevices.codeAlphabet.contains($0) })
        let (device, key) = try devices.pair(code: code.value.lowercased(), name: "iPhone")
        #expect(devices.device(forKey: key)?.id == device.id)
        #expect(devices.device(forKey: key + "x") == nil)
        #expect(devices.device(forKey: nil) == nil)
        // Used up: the same code does not let a second device in.
        #expect(throws: RemoteDevices.PairingError.noCode) { try devices.pair(code: code.value, name: "Other") }
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains(key))
        #expect(saved.contains(device.keyHash))
        // Survives a relaunch.
        #expect(RemoteDevices(file: file).device(forKey: key)?.name == "iPhone")
    }

    @Test("wrong guesses run out, and codes expire")
    func guessesAndExpiry() throws {
        var now = Date()
        let (devices, _) = store { now }
        devices.newCode()
        for _ in 1..<RemoteDevices.maxWrongTries {
            #expect(throws: RemoteDevices.PairingError.wrongCode) { try devices.pair(code: "ZZZZZZ", name: "x") }
        }
        #expect(throws: RemoteDevices.PairingError.tooManyTries) { try devices.pair(code: "ZZZZZZ", name: "x") }
        #expect(devices.code == nil)

        let code = devices.newCode()
        now = now.addingTimeInterval(RemoteDevices.codeLifetime + 1)
        #expect(throws: RemoteDevices.PairingError.expired) { try devices.pair(code: code.value, name: "x") }
    }

    @Test("removing a device locks it out")
    func removal() throws {
        let (devices, _) = store()
        let (device, key) = try devices.pair(code: devices.newCode().value, name: "Mac mini")
        devices.remove(device.id)
        #expect(devices.device(forKey: key) == nil)
    }
}

@Suite("Remote access: Tailscale and sleep")
struct TailscaleAndSleepTests {
    @Test("status reads connection and this Mac's name")
    func status() {
        let running = Tailscale.parseStatus(#"{"BackendState":"Running","Self":{"DNSName":"mac.tail1.ts.net."}}"#)
        #expect(running == TailscaleStatus(state: .connected, dnsName: "mac.tail1.ts.net"))
        if case .notConnected = Tailscale.parseStatus(#"{"BackendState":"NeedsLogin","Self":{}}"#).state {} else {
            Issue.record("signed out should read as not connected")
        }
        if case .notConnected = Tailscale.parseStatus("not json").state {} else {
            Issue.record("garbage should read as not connected")
        }
    }

    @Test("only Macs with a name are offered for linking, online first")
    func peers() {
        let json = #"{"Peer":{"a":{"HostName":"funnel-ingress-node","DNSName":"","OS":"","Online":true},"b":{"HostName":"Mac mini","DNSName":"mini.tail1.ts.net.","OS":"macOS","Online":false},"c":{"HostName":"arya","DNSName":"arya.tail1.ts.net.","OS":"linux","Online":true},"d":{"HostName":"Studio","DNSName":"studio.tail1.ts.net.","OS":"macOS","Online":true}}}"#
        #expect(Tailscale.parsePeers(json).map(\.name) == ["Studio", "Mac mini"])
        #expect(Tailscale.parsePeers(json).last?.dnsName == "mini.tail1.ts.net")
    }

    @Test("an HTTPS error keeps Tailscale's own link")
    func explainsHTTPS() {
        let message = Tailscale.explain("Serve is not enabled... HTTPS is not enabled. To enable, visit: https://login.tailscale.com/f/serve?node=abc")
        #expect(message.contains("https://login.tailscale.com/f/serve?node=abc"))
    }

    @Test("lid sleep reads pmset, and the switch needs Sleepless's rule both ways")
    func lidSleep() {
        #expect(LidSleep.parseState(" SleepDisabled\t\t1\n sleep 1") == .survives)
        #expect(LidSleep.parseState(" sleep 1\n") == .sleeps)
        let rule = "User me may run:\n    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        #expect(LidSleep.allowsSwitch(rule))
        #expect(!LidSleep.allowsSwitch("(root) /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))
        #expect(!LidSleep.allowsSwitch("(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"))
    }
}

@Suite("Remote access: This Mac only")
struct SharedWithDevicesTests {
    @Test("bots are shared by default, and This Mac only is kept")
    func storesTheChoice() throws {
        let store = try Store.inMemory()
        try store.save(BotRecord(id: "a", name: "Scout", engine: "claude"))
        try store.save(BotRecord(id: "b", name: "Private", engine: "claude", sharedWithDevices: false))
        let saved = Dictionary(uniqueKeysWithValues: try store.bots().map { ($0.id, $0) })
        #expect(saved["a"]?.sharedWithDevices == true)
        #expect(saved["b"]?.sharedWithDevices == false)
    }
}

@Suite("Remote access: one Mac talking to another")
struct RemoteClientTests {
    /// A stand-in for another Mac's Bupsy, recording what it was asked.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func fakeMac(_ log: Log) async throws -> (LocalHTTPServer, URL) {
        let server = LocalHTTPServer { request in
            log.add("\(request.method) \(request.path) cookie=\(request.cookie("bupsy_device") ?? "-") body=\(String(decoding: request.body, as: UTF8.self))")
            switch (request.method, request.path) {
            case ("POST", "/api/pair"):
                guard request.json?["code"] as? String == "ABC234" else {
                    return .error("That code didn't work.", status: 401)
                }
                var response = HTTPResponse.json(["ok": true])
                response.headers["Set-Cookie"] = "bupsy_device=KEY123; Path=/; HttpOnly; Secure; SameSite=Strict"
                return response
            default:
                guard request.cookie("bupsy_device") == "KEY123" else { return .error("Not paired.", status: 401) }
            }
            switch request.path {
            case "/api/session":
                return .json(["mac": "Mac mini", "kind": "desktop"])
            case "/api/bots":
                return .json(["waiting": 1, "bots": [[
                    "id": "b1", "name": "Lead", "role": "Lead", "section": "Frontier & Co",
                    "colour": "#82a820", "mood": "waitingForYou", "running": true, "needsYou": true,
                    "unread": false, "preview": "Wants to push",
                    "face": ["shape": "bup", "colour": 3, "hue": 0.25],
                ]]])
            case "/api/bots/b1/messages":
                return .json(["entries": [
                    ["id": "E1", "kind": "you", "at": "2026-10-08T12:00:00Z", "text": "ship it"],
                    ["id": "E2", "kind": "approval", "at": "2026-10-08T12:00:05Z",
                     "approval": ["id": "t1", "tool": "Bash", "summary": "git push", "reason": "asks first", "decided": NSNull()]],
                ]])
            default:
                return .json(["ok": true])
            }
        }
        let port = try await server.start(preferredPort: 0)
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    @Test("pairs, keeps the key, and uses it on every later call")
    func pairsAndReads() async throws {
        let log = Log()
        let (server, address) = try await fakeMac(log)
        defer { server.stop() }

        let wrong = RemoteClient(address: address, key: nil)
        await #expect(throws: RemoteClient.Failure.notPaired("That code didn't work.")) {
            try await wrong.pair(code: "WRONG1", name: "MacBook Pro")
        }
        let key = try await wrong.pair(code: "ABC234", name: "MacBook Pro")
        #expect(key == "KEY123")

        let client = RemoteClient(address: address, key: key)
        #expect(try await client.sessionInfo() == RemoteSession(mac: "Mac mini", kind: "desktop"))
        let bots = try await client.bots()
        #expect(bots.first?.name == "Lead")
        #expect(bots.first?.face?.colour == 3)
        #expect(bots.first?.needsYou == true)
        let entries = try await client.entries(bot: "b1")
        #expect(entries.map(\.kind) == ["you", "approval"])
        #expect(entries.last?.approval?.decided == nil)

        try await client.send("hello", to: "b1")
        try await client.decide("t1", allow: true, bot: "b1")
        try await client.stop(bot: "b1")
        let calls = log.all
        #expect(calls.contains { $0.hasPrefix("POST /api/bots/b1/messages cookie=KEY123") && $0.contains("hello") })
        #expect(calls.contains { $0.hasPrefix("POST /api/bots/b1/approvals/t1 cookie=KEY123") && $0.contains("true") })
        #expect(calls.contains { $0.hasPrefix("POST /api/bots/b1/stop cookie=KEY123") })
    }

    @Test("a removed device and an asleep Mac read differently")
    func failures() async throws {
        let log = Log()
        let (server, address) = try await fakeMac(log)
        await #expect(throws: RemoteClient.Failure.notPaired("Not paired.")) {
            try await RemoteClient(address: address, key: "OLD").bots()
        }
        server.stop()
        await #expect(throws: RemoteClient.Failure.unreachable) {
            try await RemoteClient(address: address, key: "KEY123").bots()
        }
    }

    @Test("a typed name becomes Bupsy's HTTPS address")
    func addresses() {
        #expect(RemoteClient.normalisedAddress("vanshs-mac-mini.tail1.ts.net")?.absoluteString == "https://vanshs-mac-mini.tail1.ts.net:8443")
        #expect(RemoteClient.normalisedAddress("https://m.tail1.ts.net:8443/?code=ABC234")?.absoluteString == "https://m.tail1.ts.net:8443")
        #expect(RemoteClient.normalisedAddress("  ") == nil)
        #expect(RemoteClient.deviceKey(fromSetCookie: "bupsy_device=K; Path=/; HttpOnly") == "K")
    }
}

@Suite("Remote access: files for a bot on another Mac")
struct RemoteUploadTests {
    @Test("only the route meant for files takes a large body")
    func perRouteLimit() throws {
        let big = 5 * 1024 * 1024
        let head = { (path: String) in Data("POST \(path) HTTP/1.1\r\nContent-Length: \(big)\r\n\r\n".utf8) }
        let limit: (String, String) -> Int = { method, path in
            method == "POST" && path.hasSuffix("/files") ? 50 * 1024 * 1024 : HTTPParser.maxBodyBytes
        }
        #expect(throws: HTTPParser.Failure.tooLarge) { try HTTPParser.parse(head("/api/bots/x/messages"), bodyLimit: limit) }
        // Allowed, and still waiting for the rest of the body.
        #expect(try HTTPParser.parse(head("/api/bots/x/files"), bodyLimit: limit) == nil)
    }

    @Test("a file goes to the bot's Mac and comes back as its path there")
    func uploads() async throws {
        let server = LocalHTTPServer(bodyLimit: { _, _ in 10 * 1024 * 1024 }) { request in
            guard request.path == "/api/bots/b1/files", request.cookie("bupsy_device") == "K" else {
                return .error("nope", status: 401)
            }
            let name = request.headers["x-file-name"]?.removingPercentEncoding ?? "?"
            return .json(["path": "/Users/mini/bupsy/b1/Attachments/\(name)", "bytes": request.body.count])
        }
        let port = try await server.start(preferredPort: 0)
        defer { server.stop() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brief notes.txt")
        try Data(repeating: 65, count: 2 * 1024 * 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let client = RemoteClient(address: URL(string: "http://127.0.0.1:\(port)")!, key: "K")
        #expect(try await client.upload(file, to: "b1") == "/Users/mini/bupsy/b1/Attachments/brief notes.txt")
    }
}
