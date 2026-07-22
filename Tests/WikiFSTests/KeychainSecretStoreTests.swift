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
///   - the daemon (bundled at `Contents/Helpers/wikid`) reading a key the app
///     wrote, which is the actual Phase B/C unblock this change delivers.
struct KeychainSecretStoreTests {

    @Test func dataProtectionQueryCarriesGroupAndDPFlag() {
        let group = "5YSK9BFLQH.com.willsargent.wiki"
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
}
#endif // os(macOS)
