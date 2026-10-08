import CryptoKit
import Foundation
import Security

/// A device the person paired to use Bupsy from: their phone, another Mac.
public struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// SHA-256 of the device's key, hex. The key itself is never written anywhere on this Mac:
    /// the file is readable by any program the person runs, their bots included, and a hash
    /// is no use for getting in.
    public let keyHash: String
    public let pairedAt: Date
    public var lastSeen: Date?
}

/// Which devices may use Bupsy from elsewhere, and how a new one is let in.
///
/// A device is let in once, by a short code shown on this Mac's screen, and from then on carries a
/// long random key in a cookie. The code is the part a person types or scans; it only ever lives
/// in memory here, lasts ten minutes, works once, and stops working after a few wrong guesses,
/// so it cannot be found by trying. The key is what every later request is checked against.
@MainActor
public final class RemoteDevices {
    public private(set) var devices: [PairedDevice] = []
    /// The code currently on screen, if one is.
    public private(set) var code: PairingCode?

    public struct PairingCode: Equatable, Sendable {
        public let value: String
        public let expires: Date
        var wrongTries = 0
    }

    public enum PairingError: Error, Equatable {
        case noCode, wrongCode, expired, tooManyTries
    }

    private let file: URL
    private let now: () -> Date

    public static let codeLifetime: TimeInterval = 10 * 60
    public static let maxWrongTries = 5
    /// Letters and digits that cannot be misread for each other: no 0/O, 1/I/L.
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder.iso.decode([PairedDevice].self, from: data) {
            devices = saved
        }
    }

    /// A fresh code, replacing any earlier one.
    @discardableResult
    public func newCode() -> PairingCode {
        let value = String((0..<6).map { _ in Self.codeAlphabet[Self.randomIndex(Self.codeAlphabet.count)] })
        let fresh = PairingCode(value: value, expires: now().addingTimeInterval(Self.codeLifetime))
        code = fresh
        return fresh
    }

    public func cancelCode() { code = nil }

    /// Trades the code for a new device's key. Returns the key, to hand to the device once.
    public func pair(code typed: String, name: String) throws -> (device: PairedDevice, key: String) {
        guard var current = code else { throw PairingError.noCode }
        guard now() < current.expires else { code = nil; throw PairingError.expired }
        let normalised = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard Self.constantTimeEqual(Data(normalised.utf8), Data(current.value.utf8)) else {
            current.wrongTries += 1
            if current.wrongTries >= Self.maxWrongTries {
                code = nil
                throw PairingError.tooManyTries
            }
            code = current
            throw PairingError.wrongCode
        }
        code = nil

        let key = Self.randomKey()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(id: UUID().uuidString,
                                  name: trimmed.isEmpty ? "Device" : String(trimmed.prefix(40)),
                                  keyHash: Self.hash(key), pairedAt: now(), lastSeen: now())
        devices.append(device)
        save()
        return (device, key)
    }

    /// The device a key belongs to, or nil. Marks it seen.
    public func device(forKey key: String?) -> PairedDevice? {
        guard let key, !key.isEmpty else { return nil }
        let hashed = Data(Self.hash(key).utf8)
        guard let index = devices.firstIndex(where: {
            Self.constantTimeEqual(Data($0.keyHash.utf8), hashed)
        }) else { return nil }
        // Saved at most once a minute: a page polling every second would otherwise rewrite the file
        // every second.
        if let seen = devices[index].lastSeen, now().timeIntervalSince(seen) < 60 { return devices[index] }
        devices[index].lastSeen = now()
        save()
        return devices[index]
    }

    public func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    public func removeAll() {
        devices.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(devices) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Randomness and comparison

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomIndex(_ count: Int) -> Int {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        // Rejection sampling, so no letter is likelier than another.
        let limit = UInt32.max - UInt32.max % UInt32(count)
        while value >= limit {
            _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        }
        return Int(value % UInt32(count))
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without returning early, so how long a check takes says nothing about how much
    /// of a guess was right.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
