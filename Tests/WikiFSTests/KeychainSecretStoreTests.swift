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
}
#endif // os(macOS)
