import Foundation
import Testing
@testable import Bupsy

@Suite("Pairing: links and codes")
struct PairingLinkTests {
    @Test("the Mac's QR code gives the address and the code")
    func scanned() throws {
        let link = try #require(PairingLink(scanned: "https://studio.tail1234.ts.net:8443/?code=ABC123"))
        #expect(link.address.absoluteString == "https://studio.tail1234.ts.net:8443")
        #expect(link.code == "ABC123")
    }

    @Test("a scanned link with a messy or missing code still gives the address")
    func scannedWithoutCode() throws {
        #expect(PairingLink(scanned: "https://studio.tail1234.ts.net:8443/?code=abc-123")?.code == "ABC123")
        let bare = try #require(PairingLink(scanned: "https://studio.tail1234.ts.net:8443/"))
        #expect(bare.code == nil)
        #expect(PairingLink(scanned: "https://studio.tail1234.ts.net:8443/?code=AB")?.code == nil)
    }

    @Test("a typed Mac name gets HTTPS and Bupsy's port")
    func typed() throws {
        let link = try #require(PairingLink(address: "  Studio.tail1234.ts.net ", code: "abc 123"))
        #expect(link.address.absoluteString == "https://studio.tail1234.ts.net:8443")
        #expect(link.code == "ABC123")
        #expect(PairingLink(address: "https://studio.tail1234.ts.net:9000/x?y=1", code: "ABC123")?.address.absoluteString
            == "https://studio.tail1234.ts.net:9000")
    }

    @Test("a short code, an empty address or plain HTTP to another machine is refused")
    func refused() {
        #expect(PairingLink(address: "studio.tail1234.ts.net", code: "ABC12") == nil)
        #expect(PairingLink(address: "  ", code: "ABC123") == nil)
        #expect(PairingLink(address: "http://studio.tail1234.ts.net:8443", code: "ABC123") == nil)
        #expect(PairingLink(scanned: "ftp://studio.tail1234.ts.net") == nil)
        #expect(PairingLink(scanned: "hello") != nil) // a bare word could be a Mac's short name
    }

    @Test("plain HTTP is allowed on this device's own loopback, for the debug server and tests")
    func loopback() {
        #expect(PairingLink(scanned: "http://127.0.0.1:47815/?code=ABC123")?.address.absoluteString
            == "http://127.0.0.1:47815")
    }
}

@Suite("Pairing: the device cookie")
struct DeviceCookieTests {
    @Test("the key comes out of the Mac's Set-Cookie header")
    func macHeader() {
        let header = "bupsy_device=k3y_-AbC; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Strict"
        #expect(DeviceCookie.key(fromSetCookie: header) == "k3y_-AbC")
    }

    @Test("it's found among other cookies, past an Expires date's comma")
    func folded() {
        let header = "other=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, bupsy_device=\"KEY\"; Path=/"
        #expect(DeviceCookie.key(fromSetCookie: header) == "KEY")
    }

    @Test("no cookie, an empty one or a lookalike name gives nothing")
    func missing() {
        #expect(DeviceCookie.key(fromSetCookie: "session=abc; Path=/") == nil)
        #expect(DeviceCookie.key(fromSetCookie: "bupsy_device=; Path=/") == nil)
        #expect(DeviceCookie.key(fromSetCookie: "xbupsy_device=abc") == nil)
    }

    @Test("requests carry the key as the cookie the Mac reads")
    func header() {
        let pairing = Pairing(address: URL(string: "https://m.ts.net:8443")!, key: "KEY")
        #expect(pairing.cookieHeader == "bupsy_device=KEY")
    }
}

@Suite("Remote API: errors")
struct RemoteErrorTests {
    private func error(_ status: Int, _ body: String = "") -> RemoteError? {
        RemoteError(status: status, body: Data(body.utf8))
    }

    @Test("a success is no error")
    func success() {
        #expect(error(200, #"{"ok":true}"#) == nil)
    }

    @Test("the Mac's own words are kept")
    func messages() {
        #expect(error(401, #"{"error":"That code has expired. Make a new one on your Mac."}"#)
            == .unpaired("That code has expired. Make a new one on your Mac."))
        #expect(error(429, #"{"error":"Too many wrong tries. Make a new code on your Mac."}"#)
            == .refused(status: 429, message: "Too many wrong tries. Make a new code on your Mac."))
        #expect(error(409, #"{"error":"That request was already answered."}"#)?.isAlreadyAnswered == true)
        #expect(error(404, #"{"error":"Not found"}"#)?.isGone == true)
        #expect(error(503, #"{"error":"Bupsy is closing"}"#) == .refused(status: 503, message: "Bupsy is closing"))
    }

    @Test("without words, a 401 still means unpaired and a proxy's 502 means unreachable")
    func silent() {
        #expect(error(401) == .unpaired("This iPhone isn't paired with Bupsy."))
        #expect(error(502, "<html>Bad Gateway</html>") == .unreachable)
        #expect(error(400) == .refused(status: 400, message: "Something went wrong (400)."))
    }

    @Test("ids are encoded one segment at a time")
    func paths() {
        let url = RemoteClient.url(URL(string: "https://m.ts.net:8443")!, ["bots", "a/b c", "messages"])
        #expect(url.absoluteString == "https://m.ts.net:8443/api/bots/a%2Fb%20c/messages")
    }
}

/// The client against a stand-in for the Mac, through URLSession, so what goes over the wire is
/// what the tests check.
@Suite("Remote API: requests", .serialized)
struct RemoteClientTests {
    private let address = URL(string: "https://studio.tail1234.ts.net:8443")!

    @Test("pairing posts the code and keeps the key from Set-Cookie")
    func pairs() async throws {
        let session = StubProtocol.session { request in
            #expect(request.url?.path == "/api/pair")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: String]
            #expect(body == ["code": "ABC123", "name": "iPhone"])
            return (200, ["Set-Cookie": "bupsy_device=SECRET; Path=/; HttpOnly; Secure"], #"{"ok":true}"#)
        }
        let link = try #require(PairingLink(address: address.absoluteString, code: "ABC123"))
        let pairing = try await RemoteClient.pair(link, name: "iPhone", session: session)
        #expect(pairing == Pairing(address: address, key: "SECRET"))
    }

    @Test("a refused code surfaces the Mac's message")
    func refusedCode() async throws {
        let session = StubProtocol.session { _ in
            (401, [:], #"{"error":"That code didn't work. Check it, or make a new one on your Mac."}"#)
        }
        let link = try #require(PairingLink(address: address.absoluteString, code: "ABC123"))
        await #expect(throws: RemoteError.unpaired("That code didn't work. Check it, or make a new one on your Mac.")) {
            try await RemoteClient.pair(link, name: "iPhone", session: session)
        }
    }

    @Test("every later request sends the key as a cookie")
    func sendsCookie() async throws {
        let session = StubProtocol.session { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "bupsy_device=SECRET")
            #expect(request.url?.path == "/api/bots/b1/approvals/a1")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: Bool]
            #expect(body == ["allow": true])
            return (200, [:], #"{"ok":true}"#)
        }
        let client = RemoteClient(pairing: Pairing(address: address, key: "SECRET"), session: session)
        try await client.decide("a1", allow: true, for: "b1")
    }

    @Test("an answer already given elsewhere comes back as a 409")
    func alreadyAnswered() async throws {
        let session = StubProtocol.session { _ in (409, [:], #"{"error":"That question was already answered."}"#) }
        let client = RemoteClient(pairing: Pairing(address: address, key: "K"), session: session)
        do {
            try await client.answer("q1", with: "main", for: "b1")
            Issue.record("expected a 409")
        } catch let error as RemoteError {
            #expect(error.isAlreadyAnswered)
        }
    }
}

/// Answers URLSession requests from a closure, standing in for the Mac.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], String)

    nonisolated(unsafe) private static var handler: Handler?

    static func session(_ handler: @escaping Handler) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    /// URLSession hands a protocol the body as a stream, not as `httpBody`.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
