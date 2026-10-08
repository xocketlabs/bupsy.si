import Foundation

/// The Mac this iPhone talks to, and the key that proves it was paired there.
///
/// The key is what the Mac's `Set-Cookie` carried. A browser keeps it in its cookie jar; this app
/// keeps it in the Keychain and sends it itself, so it never sits in a shared cookie store.
struct Pairing: Codable, Equatable, Sendable {
    /// Scheme, host and port only, e.g. `https://studio.tail1234.ts.net:8443`.
    let address: URL
    let key: String

    var cookieHeader: String { "\(DeviceCookie.name)=\(key)" }
}

/// Where to pair, and with which code: what the Mac's QR code says, or what the person typed.
///
/// The QR code encodes `https://<mac>.<tailnet>.ts.net:8443/?code=ABC123`. Typed by hand, the
/// address is usually just the Mac's Tailscale name, so the scheme and port are filled in.
struct PairingLink: Equatable {
    let address: URL
    /// Six letters and digits, or nil when the link carried none.
    let code: String?

    /// The port Tailscale Serve carries Bupsy on (`Tailscale.httpsPort` on the Mac).
    static let port = 8443

    /// From a scanned QR code. Nil when it isn't a link to a Mac.
    init?(scanned text: String) {
        guard let address = Self.address(from: text) else { return nil }
        self.address = address
        let item = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?
            .queryItems?.first { $0.name == "code" }
        code = item?.value.map(Self.normalise).flatMap { $0.count == 6 ? $0 : nil }
    }

    /// From what the person typed.
    init?(address typed: String, code typedCode: String) {
        guard let address = Self.address(from: typed) else { return nil }
        let code = Self.normalise(typedCode)
        guard code.count == 6 else { return nil }
        self.address = address
        self.code = code
    }

    /// Upper-case letters and digits only, at most six: "abc-123 " becomes "ABC123".
    static func normalise(_ code: String) -> String {
        String(code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
    }

    /// Scheme, host and port, with the path and query dropped.
    ///
    /// HTTPS only, because the key travels with every request. Plain HTTP is accepted for this
    /// device's own loopback, which is where the Mac's debug server and the tests listen; Apple's
    /// transport security would refuse it anywhere else regardless.
    static func address(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let parsed = URLComponents(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host?.lowercased(), !host.isEmpty
        else { return nil }
        let loopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        // Bupsy never serves on 443, so a bare name means its usual port.
        components.port = parsed.port ?? (scheme == "https" ? port : nil)
        return components.url
    }
}

/// The cookie the Mac pairs a device with.
enum DeviceCookie {
    static let name = "bupsy_device"

    /// The key from a `Set-Cookie` header, or nil when the header doesn't set this cookie.
    ///
    /// URLSession folds several `Set-Cookie` headers into one, separated by commas, and an
    /// `Expires` date has a comma of its own, so this looks for the name at the start of any
    /// comma-separated piece rather than trusting the header to hold one cookie.
    static func key(fromSetCookie header: String) -> String? {
        for piece in header.components(separatedBy: ",") {
            let pair = piece.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix(name + "=") else { continue }
            var value = String(pair.dropFirst(name.count + 1))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
