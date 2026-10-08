import Foundation
import Security

/// The person's paired Macs, and the key for each.
///
/// The list (names, addresses, kinds) is in UserDefaults: nothing in it opens a Mac. Each Mac's key
/// is in the Keychain, one item per Mac, because a key is as good as a password to that Mac, able
/// to read every conversation and answer approvals. The Mac app keeps its linked Macs the same way.
struct MacStore {
    var defaults: UserDefaults = .standard
    var keys: any KeyStore = KeychainKeys()

    static let listKey = "macs"

    /// Every paired Mac, in the order they were added. The first launch after an update from the
    /// one-Mac version moves that Mac in here, so nobody has to pair again.
    func load() -> [PairedMac] {
        if let data = defaults.data(forKey: Self.listKey),
           let macs = try? JSONDecoder().decode([PairedMac].self, from: data) {
            return macs
        }
        return migrate()
    }

    func save(_ macs: [PairedMac]) {
        guard let data = try? JSONEncoder().encode(macs) else { return }
        defaults.set(data, forKey: Self.listKey)
    }

    /// Version one kept a single Mac, address and key together, in one Keychain item. It becomes
    /// the first Mac on the list with its key in an item of its own. Its name and kind are filled
    /// in when it next answers.
    ///
    /// The old item goes only once the new one is safely written: a failure leaves it for the next
    /// launch to try again, never a phone with no pairing at all.
    private func migrate() -> [PairedMac] {
        guard let old = keys.legacyPairing() else { return [] }
        let mac = PairedMac(name: "", address: old.address)
        do {
            try keys.setKey(old.key, for: mac.id)
        } catch {
            return []
        }
        save([mac])
        keys.removeLegacyPairing()
        NeedsYouAlerts.adoptLegacyWaits(for: mac.id, in: defaults)
        return [mac]
    }
}

/// Where each Mac's key is kept. The Keychain on a phone; memory in the tests.
protocol KeyStore {
    func key(for macID: String) -> String?
    func setKey(_ key: String, for macID: String) throws
    func removeKey(for macID: String)
    /// The one pairing the first version kept, if this phone still has it.
    func legacyPairing() -> Pairing?
    func removeLegacyPairing()
}

/// The Keychain, one generic-password item per Mac.
///
/// Stored "after first unlock, this device only", so a background refresh can still read a key
/// while the phone is locked, and no key ever travels in a backup or through iCloud Keychain to a
/// device that was never paired.
struct KeychainKeys: KeyStore {
    private static let service = "si.bupsy.ios.pairing"
    /// The account the first version kept its single pairing under.
    private static let legacyAccount = "mac"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// "mac.<id>", which can never be the old item's plain "mac".
    private static func account(_ macID: String) -> String { "mac.\(macID)" }

    func key(for macID: String) -> String? {
        Self.read(Self.account(macID)).map { String(decoding: $0, as: UTF8.self) }
    }

    func setKey(_ key: String, for macID: String) throws {
        let account = Self.account(macID)
        SecItemDelete(Self.query(account) as CFDictionary)
        var item = Self.query(account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "This iPhone couldn't save the pairing in its Keychain (\(status)).",
            ])
        }
    }

    func removeKey(for macID: String) {
        SecItemDelete(Self.query(Self.account(macID)) as CFDictionary)
    }

    func legacyPairing() -> Pairing? {
        Self.read(Self.legacyAccount).flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) }
    }

    func removeLegacyPairing() {
        SecItemDelete(Self.query(Self.legacyAccount) as CFDictionary)
    }

    private static func read(_ account: String) -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
