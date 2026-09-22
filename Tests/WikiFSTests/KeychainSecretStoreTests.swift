#if os(macOS)
import Foundation
import Testing
import Security
@testable import WikiFSCore

/// `KeychainSecretStore` query-construction tests for the keychain-sharing change
/// (plans/keychain-sharing.md). The shared `baseQuery` is the single place that
/// decides whether each SecItem read/delete/update/add carries the
/// DataProtection-keychain flag (`kSecUseDataProtectionKeychain`) and the shared
/// access group (`kSecAttrAccessGroup`). Asserting its shape here — rather than
/// round-tripping through the real Keychain — keeps the tests deterministic and
/// non-polluting, matching the convention the sibling `*CredentialStoreTests`
/// files follow (they exercise the `InMemory*` doubles only).
///
/// NOT covered here (needs a real, entitled signed build — documented as a manual
/// integration runbook in plans/keychain-sharing.md §5.2):
///   - the DataProtection keychain + access group actually round-tripping
///     (`swift test` has no `keychain-access-groups` entitlement → writes hit
///     `errSecMissingEntitlement`);
///   - the file → DataProtection migration moving a real item (it is a no-op when
///     `GeneratedKeychain.accessGroup` is empty; on a configured machine it
///     requires entitlements the test runner lacks);
///   - the daemon (bundled at `Contents/XPCServices/wikid.xpc`) reading a key the app
///     wrote, which is the actual Phase B/C unblock this change delivers.
struct KeychainSecretStoreTests {

    @Test func dataProtectionQueryCarriesGroupAndDPFlag() {
        // An arbitrary (clearly fake) access group — the test asserts the query
        // SHAPE, not a real per-developer value (which comes from
        // signing/local.config at build time via tools/keychaingen).
        let group = "ABCDE12345.com.example.wiki"
        let query = KeychainSecretStore.baseQuery(
            service: "org.sockpuppet.WikiFS.acp",
            account: "acp-provider:claude",
            useDP: true,
            accessGroup: group)

        // Core attributes every query carries.
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "org.sockpuppet.WikiFS.acp")
        #expect(query[kSecAttrAccount as String] as? String == "acp-provider:claude")
        // The sharing change: DP keychain + shared access group are present.
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] as? String == group)
    }

    @Test func legacyQueryOmitsGroupAndDPFlag() {
        // useDP:false + empty group = the pre-sharing legacy file-keychain shape,
        // used by the migration's "read/delete the legacy original" path and by
        // unconfigured builds (fresh clones / `swift test` with no
        // signing/local.config). Neither the DP flag nor the access-group
        // attribute may be present, or SecItem rejects the query.
        let query = KeychainSecretStore.baseQuery(
            service: "org.sockpuppet.WikiFS.zotero",
            account: "zotero-api-key",
            useDP: false,
            accessGroup: "")

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "org.sockpuppet.WikiFS.zotero")
        #expect(query[kSecAttrAccount as String] as? String == "zotero-api-key")
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func emptyAccessGroupIsOmittedEvenWhenUseDPRequested() {
        // A non-empty access group is the only thing that adds kSecAttrAccessGroup
        // — an empty-string group must NEVER reach the query (SecItem treats a
        // bogus group as errSecMissingEntitlement). useDP is independent.
        let query = KeychainSecretStore.baseQuery(
            service: "org.sockpuppet.WikiFS.extraction",
            account: "anthropic-api-key",
            useDP: true,
            accessGroup: "")

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    // MARK: - Throwing reads (#1159 credential service backend)

    @Test func throwingReadQueryMatchesTheSharedBaseQueryShape() {
        // The throwing path queries with exactly the attributes the
        // legacy path used (service + account + optional DP/group), so a
        // legacy item is found in place. The REAL absence-vs-failure
        // semantics of `readOrThrow` need a live keychain — that coverage is
        // the opt-in `CredentialKeychainMultiprocessTests` (the configured
        // access group on signed machines makes an un-gated real read throw
        // errSecMissingEntitlement here).
        let query = KeychainSecretStore.baseQuery(
            service: "org.sockpuppet.WikiFS.credentials",
            account: "test.reference",
            useDP: KeychainSecretStore.useDataProtectionKeychain,
            accessGroup: KeychainSecretStore.accessGroup)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "org.sockpuppet.WikiFS.credentials")
        #expect(query[kSecAttrAccount as String] as? String == "test.reference")
    }

    // MARK: - Migration candidate decision (launch-migration self-delete fix)

    @Test func migrationCandidateAcceptsTrueLegacyStrays() {
        // Own service prefix with an absent access group (the pre-sharing
        // shape) or a foreign group — both are real strays worth moving.
        let shared = "ABCDE12345.com.example.wiki"
        #expect(KeychainSecretStore.isMigrationCandidate(
            service: "org.sockpuppet.WikiFS.zotero",
            accessGroup: nil,
            sharedGroup: shared))
        #expect(KeychainSecretStore.isMigrationCandidate(
            service: "org.sockpuppet.WikiFS.extraction",
            accessGroup: "FFFF9999.someother.app",
            sharedGroup: shared))
    }

    @Test func migrationCandidateRejectsForeignServicesAndSharedGroupItems() {
        let shared = "ABCDE12345.com.example.wiki"
        // Another app's service stays out of scope even with no group.
        #expect(KeychainSecretStore.isMigrationCandidate(
            service: "com.unrelated.app",
            accessGroup: nil,
            sharedGroup: shared) == false)
        // THE REGRESSION: an item already tagged with the shared group is a
        // DataProtection item surfaced by the one-store enumeration.
        // "Migrating" it re-writes it in place, and the scoped "legacy"
        // delete — its own access group IS the shared group — erased it
        // (2026-09-21: a Zotero API key was deleted 30 seconds after the
        // user saved it; the migration then logged "moved 1 item(s)").
        #expect(KeychainSecretStore.isMigrationCandidate(
            service: "org.sockpuppet.WikiFS.zotero",
            accessGroup: shared,
            sharedGroup: shared) == false)
    }

    // MARK: - Two-phase legacy enumeration (#50, the status -50 blackout)

    // NOT covered here, for the same reason the file's header lists: the real
    // failure needs a second app's generic password with a restrictive ACL in
    // the login keychain, so that the ONE bulk read returns errSecParam (-50)
    // and no items. The un-entitled `swift test` runner cannot create that
    // state, so these tests pin the query SHAPE that makes the failure
    // impossible — the absence of `kSecReturnData` in the bulk query is the
    // whole fix — plus the scoping decision that keeps other apps' secrets out
    // of the per-item read entirely.

    @Test func bulkLegacyEnumerationQueryNeverAsksForData() {
        // THE REGRESSION: the bulk query used to carry kSecReturnData, which
        // makes SecItemCopyMatching decrypt EVERY match. One item this process
        // cannot silently read fails the whole all-or-nothing query, so a
        // configured machine logged "legacy enumeration returned nothing
        // (status -50)" on nearly every launch and two stranded
        // org.sockpuppet.WikiFS.extraction keys never migrated (2026-09-21).
        // Attributes alone need no data decryption, so they cannot be poisoned.
        let query = KeychainSecretStore.legacyEnumerationQuery()

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        // It enumerates the LEGACY keychain: neither the DataProtection flag
        // nor an access group may narrow it, or the strays are invisible.
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func perItemDataQueryIsScopedAndLegacyShaped() {
        // Phase 2 reads ONE item's secret. It must keep the legacy (no-DP)
        // shape and carry the item's OWN access group: the file and
        // DataProtection keychains are one store on modern macOS, so an
        // unscoped service+account read with kSecMatchLimitOne could return
        // the DataProtection copy's data instead of the legacy stray's.
        let ownGroup = "FFFF9999.someother.app"
        let query = KeychainSecretStore.legacyItemDataQuery(
            service: "org.sockpuppet.WikiFS.extraction",
            account: "anthropic-api-key",
            accessGroup: ownGroup)

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "org.sockpuppet.WikiFS.extraction")
        #expect(query[kSecAttrAccount as String] as? String == "anthropic-api-key")
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecAttrAccessGroup as String] as? String == ownGroup)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test func perItemDataQueryOmitsAnAbsentAccessGroup() {
        // The pre-sharing shape: a file-keychain item carries no access group,
        // and an empty-string group must never reach SecItem (it reads as a
        // bogus group → errSecMissingEntitlement).
        let query = KeychainSecretStore.legacyItemDataQuery(
            service: "org.sockpuppet.WikiFS.extraction",
            account: "gemini-api-key",
            accessGroup: nil)

        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecReturnData as String] as? Bool == true)
    }

    @Test func ownServiceScopingKeepsOtherAppsOutOfThePerItemRead() {
        // Phase 2 decrypts, so the prefix filter runs BEFORE it: another app's
        // item is never read, and therefore its ACL can never fail anything.
        #expect(KeychainSecretStore.isOwnLegacyService("org.sockpuppet.WikiFS.extraction"))
        #expect(KeychainSecretStore.isOwnLegacyService("org.sockpuppet.WikiFS.zotero"))
        #expect(KeychainSecretStore.isOwnLegacyService("com.unrelated.app") == false)
        // A near-miss prefix is still someone else's.
        #expect(KeychainSecretStore.isOwnLegacyService("org.sockpuppet.WikiFSOther") == false)
    }
}
#endif // os(macOS)
