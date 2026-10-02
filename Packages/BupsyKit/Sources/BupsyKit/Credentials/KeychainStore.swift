#if canImport(Security)
import Foundation
import Security

/// The macOS Keychain, for **our own** keys only.
///
/// The distinction this type exists to enforce: a user's *compute* key (boat, Freestyle) is
/// something bupsy must present on every API call, so it has to be stored somewhere. A user's
/// *model* credential (Claude, Codex) is not — the engine binaries read their own sign-in from
/// files the user owns, and bupsy never sees it.
///
/// So this holds compute keys and nothing else. If a model credential ever ends up here, the
/// product has broken the one promise it cannot break. See docs/00-compliance-and-auth.md, and
/// `KeychainStoreTests.onlyComputeKeysAreStorable`, which enforces it rather than trusting review.
public struct KeychainStore: Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case boatAPIKey = "compute.boat"
        case freestyleAPIKey = "compute.freestyle"

        /// Every case must be compute. The test iterates `allCases` and checks this prefix, so
        /// adding a non-compute key here fails the build's conscience before it fails a user.
        var isComputeKey: Bool { rawValue.hasPrefix("compute.") }
    }

    let service: String

    public init(service: String = "si.bupsy") {
        self.service = service
    }

    public func set(_ value: String, for key: Key) throws {
        try remove(key)
        guard !value.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: Data(value.utf8),
            // Available only when this Mac is unlocked, and never copied to another device by
            // iCloud Keychain or a backup. A rented machine's key is this Mac's business.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func has(_ key: Key) -> Bool { get(key) != nil }

    public func remove(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
#endif
