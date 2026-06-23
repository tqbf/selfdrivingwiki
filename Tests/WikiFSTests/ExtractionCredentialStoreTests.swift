import Foundation
import Testing
@testable import WikiFSCore

/// Exercises `InMemoryExtractionCredentialStore`'s round-trip contract only.
/// `KeychainExtractionCredentialStore` is NOT covered here — a real-Keychain
/// integration test would pollute the test runner's Keychain; it gets a manual
/// smoke test instead (mirrors `ZoteroCredentialStoreTests`).
struct ExtractionCredentialStoreTests {

    @Test func startsWithNoSecretsByDefault() {
        let store = InMemoryExtractionCredentialStore()
        #expect(store.secret(.anthropicAPIKey) == nil)
        #expect(store.secret(.geminiAPIKey) == nil)
        #expect(store.secret(.doclingServeToken) == nil)
    }

    @Test func anthropicKeyRoundTrips() throws {
        let store = InMemoryExtractionCredentialStore()
        try store.setSecret("sk-ant-abc", .anthropicAPIKey)
        #expect(store.secret(.anthropicAPIKey) == "sk-ant-abc")
    }

    @Test func geminiKeyRoundTrips() throws {
        let store = InMemoryExtractionCredentialStore()
        try store.setSecret("AIza-xyz", .geminiAPIKey)
        #expect(store.secret(.geminiAPIKey) == "AIza-xyz")
    }

    @Test func doclingTokenRoundTrips() throws {
        let store = InMemoryExtractionCredentialStore()
        try store.setSecret("doc-token", .doclingServeToken)
        #expect(store.secret(.doclingServeToken) == "doc-token")
    }

    @Test func secretsAreIndependent() throws {
        let store = InMemoryExtractionCredentialStore()
        try store.setSecret("key-a", .anthropicAPIKey)
        try store.setSecret("gem-b", .geminiAPIKey)
        try store.setSecret("tok-c", .doclingServeToken)
        #expect(store.secret(.anthropicAPIKey) == "key-a")
        #expect(store.secret(.geminiAPIKey) == "gem-b")
        #expect(store.secret(.doclingServeToken) == "tok-c")
    }

    @Test func settingNilDeletesTheSecret() throws {
        let store = InMemoryExtractionCredentialStore(
            seeds: [.anthropicAPIKey: "old", .doclingServeToken: "old"])
        try store.setSecret(nil, .anthropicAPIKey)
        try store.setSecret(nil, .doclingServeToken)
        #expect(store.secret(.anthropicAPIKey) == nil)
        #expect(store.secret(.doclingServeToken) == nil)
    }

    @Test func overwritingReplacesThePreviousValue() throws {
        let store = InMemoryExtractionCredentialStore(seeds: [.anthropicAPIKey: "old"])
        try store.setSecret("new", .anthropicAPIKey)
        #expect(store.secret(.anthropicAPIKey) == "new")
    }

    @Test func settingEmptyStringDeletesTheSecret() throws {
        // Empty string is treated as "unset", matching the Keychain store's
        // `guard let value, !value.isEmpty` delete path.
        let store = InMemoryExtractionCredentialStore(seeds: [.doclingServeToken: "x"])
        try store.setSecret("", .doclingServeToken)
        #expect(store.secret(.doclingServeToken) == nil)
    }
}
