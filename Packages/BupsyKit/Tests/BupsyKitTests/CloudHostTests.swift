import Foundation
import Testing
@testable import BupsyKit

/// Captures requests and replays canned responses, so these tests never touch the network.
/// Response bodies are shaped from boat's published docs — the same source `BoatAPI` was written
/// from, so these tests pin our *reading* of the docs, not the live service's behaviour.
final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol strips httpBody into a stream, so read it back for assertions.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let body = request.httpBody {
            Self.lastBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        } else {
            Self.lastBody = nil
        }

        let (status, data) = Self.handler?(request) ?? (200, Data("{\"ok\":true}".utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reply(_ status: Int = 200, _ json: String) {
        handler = { _ in (status, Data(json.utf8)) }
    }
}

/// Both inner suites drive the same `MockProtocol` statics, so the whole tree is serialized.
/// `.serialized` on a suite only orders its own tests — sibling suites still run in parallel,
/// which is exactly how two of these raced each other into reading another test's canned reply.
@Suite("Boat", .serialized)
struct BoatTests {

@Suite("API client", .serialized)
struct BoatAPITests {
    private func api() -> BoatAPI {
        BoatAPI(apiKey: "test-key", session: MockProtocol.session())
    }

    @Test("sends the user's key as a bearer token")
    func sendsBearerToken() async throws {
        MockProtocol.reply(200, #"{"ok":true,"sandbox":{"id":"sb_1","state":"running"}}"#)
        _ = try await api().get("sb_1")
        #expect(MockProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
            == "Bearer test-key")
    }

    /// An always-on machine needs auto-stop disabled. `ttlSeconds` defaults to one hour and
    /// counts from *creation*, so a missing explicit null means the machine disappears
    /// mid-afternoon and every scheduled routine silently stops.
    @Test("alwaysOn sends an explicit null ttlSeconds")
    func alwaysOnDisablesAutoStop() async throws {
        MockProtocol.reply(200, #"{"ok":true,"sandbox":{"id":"sb_1","state":"running"}}"#)
        _ = try await api().create(.alwaysOn())

        let body = try #require(MockProtocol.lastBody)
        #expect(body["ttlSeconds"] is NSNull)
        #expect(body["type"] as? String == "small")
        // boat's multi-tenant guidance: a user's machine must not inherit account secrets.
        #expect(body["noEnv"] as? Bool == true)
    }

    @Test("defaults to withholding account secrets")
    func defaultsToNoEnv() async throws {
        MockProtocol.reply(200, #"{"ok":true,"sandbox":{"id":"sb_1"}}"#)
        _ = try await api().create(CreateOptions())
        #expect(MockProtocol.lastBody?["noEnv"] as? Bool == true)
    }

    @Test("surfaces an auth failure distinctly, since the user fixes it elsewhere")
    func authFailure() async throws {
        MockProtocol.reply(401, #"{"ok":false,"code":"unauthorized","message":"bad key"}"#)
        await #expect(throws: BoatError.self) { _ = try await api().get("sb_1") }

        do {
            _ = try await api().get("sb_1")
        } catch let error as BoatError {
            #expect(error.isAuthFailure)
            #expect(error.message == "bad key")
        }
    }

    @Test("reads a sandbox whether the fields are nested or flat")
    func tolerantSandboxDecoding() async throws {
        MockProtocol.reply(200, #"{"ok":true,"id":"sb_flat","state":"archived"}"#)
        let flat = try await api().get("sb_flat")
        #expect(flat.id == "sb_flat")
        #expect(flat.isStopped)

        MockProtocol.reply(200, #"{"ok":true,"sandbox":{"id":"sb_nested","state":"running"}}"#)
        #expect(try await api().get("sb_nested").isRunning)
    }

    /// The figure the always-on tier is sold on. If this breaks, PLAN.md §8 is wrong.
    @Test("always-on cost arithmetic matches the plan")
    func alwaysOnCost() {
        #expect(abs(MachineSize.small.alwaysOnMonthlyUSD - 12.96) < 0.01)
        #expect(abs(MachineSize.default.alwaysOnMonthlyUSD - 25.92) < 0.01)
        #expect(MachineSize.small.alwaysOnMonthlyUSD < 20, "small must fit boat's $20 minimum")
    }

    @Test("idle estimate is a third of always-on at eight hours a day")
    func idleCost() {
        #expect(abs(MachineSize.small.idleMonthlyUSD - 4.32) < 0.01)
        #expect(MachineSize.large.idleMonthlyUSD < MachineSize.large.alwaysOnMonthlyUSD)
    }

    @Test("checking a key lists machines and creates nothing")
    func checkKeyLists() async throws {
        MockProtocol.reply(200, #"{"ok":true,"sandboxes":[{"id":"sb_1","state":"running"},{"state":"x"}]}"#)
        try await api().checkKey()
        #expect(MockProtocol.lastRequest?.httpMethod == "GET")
        #expect(MockProtocol.lastRequest?.url?.path.hasSuffix("/sandboxes") == true)

        let list = try await api().list()
        #expect(list.map(\.id) == ["sb_1"], "an entry without an id is skipped")
    }

    @Test("a refused key fails the check with boat's own message")
    func checkKeyRefused() async throws {
        MockProtocol.reply(401, #"{"ok":false,"code":"unauthorized","message":"bad key"}"#)
        do {
            try await api().checkKey()
            Issue.record("a refused key must throw")
        } catch let error as BoatError {
            #expect(error.isAuthFailure)
            #expect(error.message == "bad key")
        }
    }
}

@Suite("CloudHost", .serialized)
struct CloudHostTests {
    private func host() -> CloudHost {
        CloudHost(api: BoatAPI(apiKey: "k", session: MockProtocol.session()), sandboxID: "sb_1")
    }

    @Test("a cloud host survives the Mac sleeping; that is the point of paying for one")
    func survivesSleep() {
        #expect(host().survivesSleep)
        #expect(host().id == .cloud(provider: .boat))
    }

    @Test("splits a command result into lines and a final exit code")
    func streamsResult() async throws {
        MockProtocol.reply(200, """
        {"ok":true,"exitCode":0,"stdout":"{\\"type\\":\\"a\\"}\\n{\\"type\\":\\"b\\"}","stderr":""}
        """)
        var collected: [HostOutput] = []
        for try await output in try await host().spawn(
            EngineInvocation(executable: "claude", arguments: ["-p", "hi"]))
        {
            collected.append(output)
        }
        #expect(collected.contains(.stdout(#"{"type":"a"}"#)))
        #expect(collected.contains(.stdout(#"{"type":"b"}"#)))
        #expect(collected.last == .exit(code: 0))
    }

    /// A prompt is arbitrary user text on its way to a shell. Quoting is the only thing standing
    /// between a bot name with an apostrophe and command injection.
    @Test("quotes every argument, including quotes themselves")
    func quotesArguments() {
        let command = CloudHost.shellCommand(for: EngineInvocation(
            executable: "claude",
            arguments: ["-p", "it's; rm -rf /", "--output-format", "stream-json"]))

        #expect(command.contains(#"'it'\''s; rm -rf /'"#))
        #expect(!command.contains("; rm -rf / "))
        #expect(command.hasPrefix("'claude'"))
    }

    /// Codex hangs on an open stdin. Locally `LocalHost` closes it; remotely the shell has to.
    @Test("closes stdin when none is supplied")
    func closesStdin() {
        let command = CloudHost.shellCommand(for: EngineInvocation(executable: "codex", arguments: []))
        #expect(command.contains("< /dev/null"))
    }

    @Test("pipes supplied stdin instead of leaving it open")
    func pipesStdin() {
        let command = CloudHost.shellCommand(
            for: EngineInvocation(executable: "cat", arguments: [], stdin: "hello"))
        #expect(command.hasPrefix("printf '%s' 'hello' | 'cat'"))
    }

    @Test("translates cron into a systemd OnCalendar expression")
    func cronTranslation() throws {
        #expect(try CloudHost.onCalendar(fromCron: "0 7 * * 1-5") == ["Mon..Fri *-*-* 7:0:00"])
        #expect(try CloudHost.onCalendar(fromCron: "30 9 * * *") == ["*-*-* 9:30:00"])
        #expect(try CloudHost.onCalendar(fromCron: "0 6 1 * *") == ["*-*-1 6:0:00"])
        #expect(try CloudHost.onCalendar(fromCron: "0 8 * * 1,3") == ["Mon,Wed *-*-* 8:0:00"])
    }

    /// Splitting the text on "," and "-" read `1-3,5` as `Mon..Tue..Wed..Fri`, which systemd
    /// rejects, and put an hour range's "-" where systemd expects the date separator.
    @Test("translates mixed lists and ranges into systemd's own syntax")
    func cronListsAndRanges() throws {
        #expect(try CloudHost.onCalendar(fromCron: "0 9 * * 1-3,5")
            == ["Mon..Wed,Fri *-*-* 9:0:00"])
        #expect(try CloudHost.onCalendar(fromCron: "0,30 9-17 * * *")
            == ["*-*-* 9..17:0,30:00"])
        #expect(try CloudHost.onCalendar(fromCron: "0 7 1-3,15 6-8 *")
            == ["*-6..8-1..3,15 7:0:00"])
        // Sunday is 0 or 7 in cron and last in systemd's Monday-first week.
        #expect(try CloudHost.onCalendar(fromCron: "0 10 * * 5-7") == ["Fri..Sun *-*-* 10:0:00"])
        #expect(try CloudHost.onCalendar(fromCron: "0 10 * * 0,6") == ["Sat,Sun *-*-* 10:0:00"])
    }

    /// cron fires when EITHER restricted day field matches; one systemd expression needs both.
    @Test("day-of-month and weekday together become two calendars, as cron's either-or")
    func cronDayFieldsUnion() throws {
        #expect(try CloudHost.onCalendar(fromCron: "0 9 1 * 1")
            == ["*-*-1 9:0:00", "Mon *-*-* 9:0:00"])
    }

    /// A schedule that quietly fires at the wrong time is worse than one that refuses to install.
    @Test("refuses step syntax and other unsupported forms rather than mistranslating them")
    func rejectsUnsupportedCron() {
        for cron in ["*/5 * * * *", "0 7 * *", "0 9 * * MON", "0 9 * * 5-1", "0 25 * * *",
                     "0 9 * JAN *"] {
            #expect(throws: HostError.self, "\(cron)") { try CloudHost.onCalendar(fromCron: cron) }
        }
    }

    /// systemd expands `$` and `%` on an ExecStart line, even inside quotes, so the command is
    /// shipped as a script file and ExecStart names only that file.
    @Test("the routine's command reaches bash verbatim, never through ExecStart")
    func triggerCommandIsAScript() async throws {
        MockProtocol.reply(200, #"{"ok":true,"exitCode":0,"stdout":"","stderr":""}"#)
        let command = #"bupsy-run "50% done" $HOME 'it''s'"#
        try await host().installTrigger(
            HostTrigger(id: "brief", cron: "0 7 * * 1-5", command: command))
        let body = try #require(MockProtocol.lastBody)
        let install = (body["command"] as? String) ?? ""
        #expect(install.contains("'/tmp/bupsy-brief.sh' '/usr/local/lib/bupsy/bupsy-brief.sh'"))
        #expect(!install.contains("50%"))
    }

    @Test("refuses a routine id that is not safe as a unit and file name")
    func rejectsUnsafeTriggerID() async throws {
        for id in ["a b", "x;rm -rf /", "../up", "", "it's"] {
            await #expect(throws: HostError.self, "\(id)") {
                try await host().installTrigger(
                    HostTrigger(id: id, cron: "0 7 * * *", command: "true"))
            }
        }
    }

    @Test("installs a systemd timer, not a crontab")
    func installsSystemdTimer() async throws {
        MockProtocol.reply(200, #"{"ok":true,"exitCode":0,"stdout":"","stderr":""}"#)
        try await host().installTrigger(
            HostTrigger(id: "brief", cron: "0 7 * * 1-5", command: "bupsy-run brief"))

        let body = try #require(MockProtocol.lastBody)
        let command = (body["command"] as? String) ?? ""
        #expect(command.contains("systemctl enable --now 'bupsy-brief.timer'"))
        #expect(command.contains("daemon-reload"))
        #expect(!command.contains("crontab"))
    }
}

} // BoatTests
