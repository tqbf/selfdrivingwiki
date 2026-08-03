import Foundation
import Testing
@testable import WikiFSCore

/// Exercises `InMemoryZoteroCredentialStore`'s round-trip contract only.
/// `KeychainZoteroCredentialStore` is NOT covered here — a real-Keychain
/// integration test would pollute the test runner's Keychain; it gets a manual
/// smoke test instead (see PR description / plan).
struct ZoteroCredentialStoreTests {

    @Test func startsWithNoKeyByDefault() {
        let store = InMemoryZoteroCredentialStore()
        #expect(store.apiKey() == nil)
    }

    @Test func setAndGetRoundTrips() throws {
        let store = InMemoryZoteroCredentialStore()
        try store.setAPIKey("abc123")
        #expect(store.apiKey() == "abc123")
    }

    @Test func settingNilDeletesTheKey() throws {
        let store = InMemoryZoteroCredentialStore(initialKey: "abc123")
        try store.setAPIKey(nil)
        #expect(store.apiKey() == nil)
    }

    @Test func overwritingReplacesThePreviousKey() throws {
        let store = InMemoryZoteroCredentialStore(initialKey: "old")
        try store.setAPIKey("new")
        #expect(store.apiKey() == "new")
    }
}
