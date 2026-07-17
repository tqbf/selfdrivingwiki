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
/// See issue #502 (cross-module dedup, L1).
enum KeychainSecretStore {

    /// Read a generic-password secret. Returns `nil` if the item is absent or any
    /// lookup error occurs — matching the prior per-store "missing = nil" behavior.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

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
}
