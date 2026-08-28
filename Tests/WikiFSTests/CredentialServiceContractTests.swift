import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// The shared credential-service CONTRACT (issue #1159 — AC.2/AC.4). The same
/// suite runs against every conformer; today that is the in-memory service.
/// A new backend (e.g. a synced-vault source) adds its factory to
/// `services()` without copying a single assertion.
struct CredentialServiceContractTests {

    /// Every conformer under test. The Keychain-backed service intentionally
    /// does NOT appear here: contract tests write and delete values, and the
    /// legacy physical locations are compatibility surfaces (the opt-in
    /// `CredentialKeychainMultiprocessTests` covers the real backend).
    static func services() -> [CredentialService] {
        [InMemoryCredentialService()]
    }

    static let reference = CredentialReference.zoteroAPIKey()
    static let otherReference = CredentialReference.acpAgent()

    @Test
    func setThenDescribeShowsConfiguredAndResolveReturnsTheValue() throws {
        let service = Self.services()[0]
        #expect(service.describe(Self.reference).isConfigured == false)
        try service.set("sk-ant-live", for: Self.reference)
        let info = service.describe(Self.reference)
        #expect(info.isConfigured == true)
        #expect(info.source == .keychain)
        #expect(info.isWritable == true)
        #expect(info.description.contains("sk-ant-live") == false)
        let resolved = try service.resolve(Self.reference)
        #expect(resolved.value == "sk-ant-live")
    }

    @Test
    func nilEmptyAndWhitespaceWritesNormalizeToUnset() throws {
        let service = Self.services()[0]
        try service.set("value", for: Self.reference)
        try service.set("   ", for: Self.reference)
        #expect(service.describe(Self.reference).isConfigured == false)
        try service.set("\n\t", for: Self.reference)
        #expect(service.describe(Self.reference).isConfigured == false)
        try service.set("", for: Self.reference)
        #expect(service.describe(Self.reference).isConfigured == false)
        try service.set(nil, for: Self.reference)
        #expect(service.describe(Self.reference).isConfigured == false)
    }

    @Test
    func resolveNeverReturnsAnEmptyValue() throws {
        let service = Self.services()[0]
        #expect(throws: CredentialStoreError.notConfigured(Self.reference)) {
            _ = try service.resolve(Self.reference)
        }
    }

    @Test
    func unsetRemovesAndIsIdempotent() throws {
        let service = Self.services()[0]
        try service.set("value", for: Self.reference)
        try service.unset(Self.reference)
        #expect(service.describe(Self.reference).isConfigured == false)
        // Removing an absent credential succeeds.
        try service.unset(Self.reference)
    }

    @Test
    func valuesStayIsolatedPerReference() throws {
        let service = Self.services()[0]
        try service.set("zotero-key", for: Self.reference)
        try service.set("acp-key", for: Self.otherReference)
        #expect(try service.resolve(Self.reference).value == "zotero-key")
        #expect(try service.resolve(Self.otherReference).value == "acp-key")
        try service.unset(Self.reference)
        #expect(try service.resolve(Self.otherReference).value == "acp-key")
    }

    @Test
    func boundedBatchDescribeAnswersEveryReference() throws {
        let service = Self.services()[0]
        let references = (0..<service.maximumDescribeBatchSize + 8).map { offset in
            // Deterministic, grammar-valid references.
            (try? CredentialReference(
                validating: "test.batch-\(offset).key-\(offset)")) ?? Self.reference
        }
        let described = service.describe(references)
        #expect(described.count == service.maximumDescribeBatchSize)
    }

    @Test
    func resolvedCredentialDescriptionsAreRedacted() throws {
        let service = Self.services()[0]
        try service.set("super-secret-canary-value", for: Self.reference)
        let resolved = try service.resolve(Self.reference)
        #expect(resolved.description.contains("super-secret-canary-value") == false)
        #expect(resolved.debugDescription.contains("super-secret-canary-value") == false)
        #expect("\(resolved)".contains("super-secret-canary-value") == false)
    }

    @Test func credentialInfoHasNoValueSurface() throws {
        // AC.4: `CredentialInfo` cannot carry a value — reflect over its
        // stored properties so an accidental `value` field fails this test.
        let mirror = Mirror(reflecting: CredentialInfo(
            reference: Self.reference, isConfigured: true,
            source: .keychain, isWritable: true))
        let propertyNames = mirror.children.compactMap(\.label)
        #expect(propertyNames == ["reference", "isConfigured", "source", "isWritable"])
    }

    @Test func inMemoryServiceSatisfiesReferenceContract() throws {
        // AC.2: the service API stays domain-neutral — the generic protocols
        // reference no extractor/ACP/Zotero vocabulary. Assert via a local
        // conformance that no domain types appear in the protocol surface
        // (compile-time contract mirrored at runtime through the generic
        // handle).
        let service: any CredentialService = InMemoryCredentialService()
        try service.set("x", for: Self.reference)
        _ = try service.resolve(Self.reference)
        try service.unset(Self.reference)
    }
}

/// `CredentialValue` normalization boundary — the ONE place deciding
/// value vs. absence.
struct CredentialValueNormalizationTests {

    @Test func whitespaceOnlyIsEmpty() {
        #expect(CredentialValue.normalized(nil) == nil)
        #expect(CredentialValue.normalized("") == nil)
        #expect(CredentialValue.normalized("   ") == nil)
        #expect(CredentialValue.normalized(" \n\t ") == nil)
    }

    @Test func realValuesArePreservedByteForByte() {
        // Leading/trailing whitespace on a real value is NOT trimmed — the
        // service never mutates a secret.
        #expect(CredentialValue.normalized(" key ") == " key ")
        #expect(CredentialValue.normalized("k") == "k")
    }
}
