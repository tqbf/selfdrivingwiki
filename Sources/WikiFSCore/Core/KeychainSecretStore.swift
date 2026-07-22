#if os(macOS)
import Foundation
import Security

/// Shared generic-password Keychain read/write for the three
/// `Keychain*CredentialStore` structs (`Zotero`, `ACP`, `Extraction`). The
/// SecItem query/add/update/delete boilerplate lives here once; each store keeps
/// only its `service`/`account` mapping and its own typed error.
///
/// `write` takes an `error` factory so each store can throw its own error type
/// (preserving the per-store `operation`/`status` formatting it always has) while
/// the SecItem mechanics stay shared. `read` returns `nil` for any miss or error —
/// the same "missing secret = nil" contract the stores always exposed.
///
/// # Keychain sharing (plans/keychain-sharing.md)
/// Items live on the **DataProtection keychain** (`kSecUseDataProtectionKeychain:
/// true`) tagged with a **shared access group** (`kSecAttrAccessGroup`), so the
/// `wikid` daemon — signed with the same `keychain-access-groups` entitlement —
/// can read the ACP/Extraction/Zotero secrets the app wrote. The group is a
/// compile-time constant (`GeneratedKeychain.accessGroup`, baked from
/// `signing/local.config`); the same constant reaches the app and the daemon
/// via the `WikiFSCore` dependency. Empty when unconfigured (fresh clones / CI /
/// `swift test`) → the legacy file-based keychain with no access group is used,
/// preserving the pre-sharing behavior so the un-entitled test runner round-trips
/// Keychain ops without `errSecMissingEntitlement`.
///
/// See issue #502 (cross-module dedup, L1).
public enum KeychainSecretStore {

    /// The shared Keychain access group (app + `wikid` daemon). Baked in at
    /// build time from `signing/local.config` by `tools/keychaingen/main.swift`
    /// (`make keychain`); matches the literal suffix in
    /// `signing/wikid.entitlements` (`$(AppIdentifierPrefix)com.willsargent.wiki`,
    /// which codesign resolves to this same `<TEAM_ID>.com.willsargent.wiki`).
    /// Empty when unconfigured → "no group".
    static let accessGroup: String = GeneratedKeychain.accessGroup

    /// True when a shared access group is configured → queries target the
    /// DataProtection keychain + the shared group. False (= legacy file
    /// keychain, no group) whenever `accessGroup` is empty.
    static var useDataProtectionKeychain: Bool { !accessGroup.isEmpty }

    // MARK: - Public API (used by the Keychain*CredentialStore conformers)

    /// Read a generic-password secret. Returns `nil` if the item is absent or any
    /// lookup error occurs — matching the prior per-store "missing = nil" behavior.
    static func read(service: String, account: String) -> String? {
        read(service: service, account: account,
             useDP: useDataProtectionKeychain, accessGroup: accessGroup)
    }

    /// Write (set or delete) a generic-password secret. On a non-success
    /// `OSStatus` the failing `(operation, status)` is passed to `error` and
    /// whatever it throws propagates; a delete of a missing item is a no-op
    /// success. `operation` is the bare verb (`"delete"`, `"add"`, `"update"`) so
    /// each store can decorate it (e.g. with the account) exactly as it always has.
    static func write(
        service: String,
        account: String,
        value: String?,
        error makeError: (_ operation: String, _ status: OSStatus) -> Error
    ) throws {
        try write(service: service, account: account, value: value,
                  useDP: useDataProtectionKeychain, accessGroup: accessGroup,
                  error: makeError)
    }

    // MARK: - Internal primitive (parameterized for the migration + tests)

    /// Read a generic-password secret from a specific keychain context. The
    /// `useDP`/`accessGroup` knobs let the migration read the LEGACY file
    /// keychain (`useDP: false`) while the production path reads the shared
    /// DataProtection keychain — and let tests assert behavior without touching
    /// the global config.
    static func read(
        service: String, account: String,
        useDP: Bool, accessGroup: String
    ) -> String? {
        var query = baseQuery(service: service, account: account,
                              useDP: useDP, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Write (set or delete) a generic-password secret in a specific keychain
    /// context (`useDP` + `accessGroup`). Same update-then-add /
    /// delete-missing-is-noop shape as the public API; the query now carries the
    /// DataProtection + access-group attributes when configured.
    static func write(
        service: String, account: String, value: String?,
        useDP: Bool, accessGroup: String,
        error makeError: (_ operation: String, _ status: OSStatus) -> Error
    ) throws {
        let query = baseQuery(service: service, account: account,
                              useDP: useDP, accessGroup: accessGroup)

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { return }
            throw makeError("delete", status)
        }

        let data = Data(value.utf8)
        // Try update first (the common "user is changing their key" case); if
        // nothing exists yet, add it.
        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw makeError("add", addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw makeError("update", updateStatus)
        }
    }

    /// Build the shared base query (class + service + account), conditionally
    /// adding the DataProtection-keychain flag (when `useDP`) and the
    /// access-group attribute (when `accessGroup` is non-empty). Every
    /// read/delete/update/add query flows through here so the attributes stay
    /// consistent. Internal so tests can assert the query shape without touching
    /// the real Keychain.
    static func baseQuery(
        service: String, account: String, useDP: Bool, accessGroup: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDP {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    // MARK: - One-shot migration (file → DataProtection keychain)

    /// One-time: copy any legacy file-keychain secrets onto the shared
    /// DataProtection keychain (under `accessGroup`), then delete the legacy
    /// originals. Idempotent — a no-op once migrated. Called from the app's
    /// launch path (mirrors `DatabaseLocation.migrateFromApplicationSupportIfNeeded`).
    ///
    /// No-op when `accessGroup` is empty (tests / fresh clones / unconfigured
    /// builds) — there is no group to migrate TO, so legacy items stay where they
    /// are. Best-effort: a failed DP write leaves the legacy item in place (a key
    /// is never lost); every step is surfaced via `DebugLog.config`, never thrown.
    public static func migrateLegacyItemsToDataProtection() {
        let group = accessGroup
        guard !group.isEmpty else { return }

        guard let legacy = enumerateLegacyGenericPasswords() else {
            return  // file keychain empty / unreadable
        }
        // Scope to THIS app's own items (by service-prefix convention) so
        // unrelated file-keychain items the process can see are left untouched.
        let ownItems = legacy.filter { $0.service.hasPrefix(migrationServicePrefix) }
        guard !ownItems.isEmpty else { return }

        var migrated = 0
        for item in ownItems {
            guard let value = String(data: item.data, encoding: .utf8) else { continue }
            // Write to the DP keychain under the shared group. If this fails
            // (e.g. errSecMissingEntitlement on an un-entitled build, or a
            // duplicate), leave the legacy item in place and keep going.
            do {
                try write(service: item.service, account: item.account, value: value,
                          useDP: true, accessGroup: group, error: migrationError)
            } catch {
                DebugLog.config("Keychain migration: skipped \(item.account) (service \(item.service)): \(error)")
                continue
            }
            // Now delete the legacy file-keychain original.
            do {
                try write(service: item.service, account: item.account, value: nil,
                          useDP: false, accessGroup: "", error: migrationError)
            } catch {
                DebugLog.config("Keychain migration: failed to delete legacy \(item.account) (service \(item.service)): \(error)")
            }
            migrated += 1
        }
        if migrated > 0 {
            DebugLog.config("Keychain migration: moved \(migrated) item(s) to the shared DataProtection keychain (group \(group)).")
        }
    }

    /// Service prefix shared by every `Keychain*CredentialStore` service
    /// (`org.sockpuppet.WikiFS.acp` / `.extraction` / `.zotero`). Used to scope
    /// the migration to this app's own items only.
    private static let migrationServicePrefix = "org.sockpuppet.WikiFS."

    /// Enumerate every generic-password item in the LEGACY file-based keychain
    /// (no `kSecUseDataProtectionKeychain` flag), returning `(service, account,
    /// data)` tuples. Returns nil if the file keychain is empty / unreadable
    /// (`errSecItemNotFound`). The caller filters to its own service prefix.
    private static func enumerateLegacyGenericPasswords()
    -> [(service: String, account: String, data: Data)]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { dict in
            guard let service = dict[kSecAttrService as String] as? String,
                  let account = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data else { return nil }
            return (service, account, data)
        }
    }

    /// Minimal error factory for the migration's best-effort writes — the actual
    /// `OSStatus` is logged at the call site, not surfaced to callers.
    private static func migrationError(_ operation: String, _ status: OSStatus) -> Error {
        MigrationError(operation: operation, status: status)
    }

    private struct MigrationError: Error {
        let operation: String
        let status: OSStatus
    }
}
#endif // os(macOS)
