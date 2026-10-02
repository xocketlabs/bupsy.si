import Foundation
import Testing
@testable import BupsyKit

/// Uses a test-only service name so nothing here can touch a real key.
@Suite("Keychain", .serialized)
struct KeychainStoreTests {
    private func store() -> KeychainStore {
        KeychainStore(service: "si.bupsy.tests.\(UUID().uuidString)")
    }

    /// The rule this type exists to enforce, checked rather than trusted: bupsy stores *compute*
    /// keys, which it must present on every API call, and never a *model* credential, which the
    /// engine binaries read from files the user owns. If someone adds a `claudeToken` case here,
    /// this fails.
    @Test("only compute keys are storable")
    func onlyComputeKeysAreStorable() {
        for key in KeychainStore.Key.allCases where !key.isComputeKey {
            Issue.record("""
                \(key.rawValue) is not a compute key. bupsy never stores a model credential —
                see docs/00-compliance-and-auth.md.
                """)
        }
        let allCompute = KeychainStore.Key.allCases.filter { !$0.isComputeKey }
        #expect(allCompute.isEmpty)
    }

    @Test("round-trips a key")
    func roundTrips() throws {
        let keychain = store()
        #expect(!keychain.has(.boatAPIKey))

        try keychain.set("boat_test_abc123", for: .boatAPIKey)
        #expect(keychain.get(.boatAPIKey) == "boat_test_abc123")
        #expect(keychain.has(.boatAPIKey))

        try keychain.remove(.boatAPIKey)
        #expect(keychain.get(.boatAPIKey) == nil)
    }

    /// Pasting a new key over an old one is the common case — a rotated key, or one pasted with
    /// a stray space the first time.
    @Test("replaces rather than duplicating")
    func replaces() throws {
        let keychain = store()
        try keychain.set("first", for: .boatAPIKey)
        try keychain.set("second", for: .boatAPIKey)
        #expect(keychain.get(.boatAPIKey) == "second")
        try keychain.remove(.boatAPIKey)
    }

    @Test("storing an empty value clears the key instead of saving nothing")
    func emptyClears() throws {
        let keychain = store()
        try keychain.set("something", for: .boatAPIKey)
        try keychain.set("", for: .boatAPIKey)
        #expect(!keychain.has(.boatAPIKey))
    }

    @Test("removing a key that was never set is not an error")
    func removeIsIdempotent() throws {
        let keychain = store()
        try keychain.remove(.freestyleAPIKey)
        try keychain.remove(.freestyleAPIKey)
    }
}
