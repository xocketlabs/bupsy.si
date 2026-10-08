import Foundation
import Security

/// Keeps the pairing in the Keychain.
///
/// Not UserDefaults: the key is as good as a password to the person's Mac, able to read every
/// conversation and answer approvals. It is stored "after first unlock, this device only", so a
/// background refresh can still read it while the phone is locked, and it never travels in a
/// backup or through iCloud Keychain to another device that was never paired.
enum PairingStore {
    private static let service = "si.bupsy.ios.pairing"
    private static let account = "mac"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Pairing? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing) throws {
        let data = try JSONEncoder().encode(pairing)
        forget()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "This iPhone couldn't save the pairing in its Keychain (\(status)).",
            ])
        }
    }

    static func forget() {
        SecItemDelete(query as CFDictionary)
    }
}
