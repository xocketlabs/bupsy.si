#if canImport(Security)
import Foundation
import Security

/// The keys this Mac holds for the person's *other* Bupsy Macs, one per linked Mac.
///
/// Kept apart from `KeychainStore` on purpose. That type holds compute keys and nothing else, a
/// rule its test enforces; these are neither compute keys nor anyone's model credential, but the
/// device keys one of the person's own Bupsys handed another when they were paired. They live in
/// the Keychain rather than a file because the person's bots run as the same user and can read
/// any file Bupsy can: a key in a file would let a bot drive the bots on another Mac.
public struct LinkedMacKeys: Sendable {
    let service: String

    public init(service: String = "si.bupsy.linked-macs") {
        self.service = service
    }

    public func set(_ key: String, for macID: String) throws {
        try remove(macID)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func get(_ macID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(_ macID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
