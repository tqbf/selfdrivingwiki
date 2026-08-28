import Foundation
import Testing
@testable import WikiFSCore

/// Adapter-parity + physical-location tests for the legacy credential stores
/// (issue #1159 — AC.3). The migration must NOT copy or rename secrets: every
/// legacy API must map to the EXACT service/account pair it always used.
///
/// The parity here is asserted at the mapping layer (`CredentialLocations` +
/// the typed reference factories the adapters call) — the same code the
/// adapters execute — so no test writes to the real Keychain (matching the
/// non-polluting convention of the sibling `*CredentialStoreTests`). The
/// opt-in `CredentialKeychainMultiprocessTests` round-trips the real backend.
struct LegacyCredentialAdapterTests {

    @Test func allLegacyReferencesKeepPhysicalLocations() throws {
        let acpProviderClaude = try #require(
            CredentialReference.acpProvider(ProviderID(rawValue: "claude-acp")))
        let anthropic = try #require(CredentialReference.extraction("anthropic-api-key"))
        let gemini = try #require(CredentialReference.extraction("gemini-api-key"))
        let docling = try #require(CredentialReference.extraction("docling-serve-token"))

        let cases: [(reference: CredentialReference, service: String, account: String)] = [
            // ACP legacy single key + per-provider accounts (#324).
            (.acpAgent(), "org.sockpuppet.WikiFS.acp", "acp-agent-api-key"),
            (acpProviderClaude, "org.sockpuppet.WikiFS.acp", "acp-provider:claude-acp"),
            // Extraction: anthropic, gemini, docling token.
            (anthropic, "org.sockpuppet.WikiFS.extraction", "anthropic-api-key"),
            (gemini, "org.sockpuppet.WikiFS.extraction", "gemini-api-key"),
            (docling, "org.sockpuppet.WikiFS.extraction", "docling-serve-token"),
            // Zotero.
            (.zoteroAPIKey(), "org.sockpuppet.WikiFS.zotero", "zotero-api-key"),
        ]
        for entry in cases {
            let location = CredentialLocations.location(for: entry.reference)
            #expect(location.service == entry.service)
            #expect(location.account == entry.account)
        }
    }

    @Test func extractionSecretEnumKeepsLegacyAccounts() throws {
        // The typed ExtractionSecret factory must keep producing the exact
        // legacy accounts the KeychainExtractionCredentialStore always used.
        let expected: [ExtractionSecret: String] = [
            .anthropicAPIKey: "anthropic-api-key",
            .geminiAPIKey: "gemini-api-key",
            .doclingServeToken: "docling-serve-token",
        ]
        for (secret, account) in expected {
            let reference = try #require(CredentialReference.extraction(secret))
            let location = CredentialLocations.location(for: reference)
            #expect(location.account == account)
            #expect(location.service == "org.sockpuppet.WikiFS.extraction")
        }
    }

    @Test func newReferencesUseTheSharedCredentialService() throws {
        // Provider env secrets are NEW locations: the shared service, with
        // the validated reference as the account.
        let reference = try #require(CredentialReference.providerSecret(
            providerID: ProviderID(rawValue: "claude-acp"),
            variable: .anthropic))
        let location = CredentialLocations.location(for: reference)
        #expect(location.service == "org.sockpuppet.WikiFS.credentials")
        #expect(location.account == reference.rawValue)
    }

    @Test func adaptersFallbackForIdsOutsideTheGrammar() throws {
        // A provider id that cannot form a typed reference keeps the legacy
        // direct path (physical account `acp-provider:<id>`), so an exotic
        // custom id's stored key is never orphaned. The read contract is
        // optional-nil without a stored value (no test Keychain pollution:
        // the legacy path reads, finds nothing, returns nil).
        let store = KeychainACPCredentialStore()
        #expect(store.apiKey(forProvider: "my agent") == nil)
    }
}
