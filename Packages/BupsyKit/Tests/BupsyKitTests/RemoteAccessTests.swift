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
