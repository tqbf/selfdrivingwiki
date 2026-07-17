import Foundation
import Security

/// Per-connection secret storage — the generic form of
/// `ZoteroCredentialStore`, keyed by `(connectionID, field)` so two Zotero
/// connections (two user IDs) hold two independent API keys. Secrets never touch
/// the plaintext `connections.json`; only the Keychain.
public protocol ConnectionCredentialStore: Sendable {
    func secret(connectionID: String, field: String) -> String?
    /// Pass `nil`/empty to delete.
    func setSecret(_ value: String?, connectionID: String, field: String) throws
}

/// Keychain-backed store: one generic-password item per `(connectionID, field)`.
///
/// **Compatibility shim.** The auto-migrated default Zotero connection
/// (`zotero-default`) maps its `apiKey` to the *legacy* single-key item
/// (`KeychainZoteroCredentialStore`'s service/account) so existing users don't
/// lose their key and the legacy "Add from Zotero" button keeps reading the same
/// secret. Every other connection uses the per-connection scheme.
public struct KeychainConnectionCredentialStore: ConnectionCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.connection"

    // Legacy Zotero item (kept byte-for-byte in sync with KeychainZoteroCredentialStore).
    private static let legacyZoteroService = "org.sockpuppet.WikiFS.zotero"
    private static let legacyZoteroAccount = "zotero-api-key"

    public init() {}

    /// (service, account) for a credential — the legacy item for the default
    /// Zotero connection's key, else a per-connection account.
    private func location(connectionID: String, field: String) -> (service: String, account: String) {
        if connectionID == "zotero-default" && field == "apiKey" {
            return (Self.legacyZoteroService, Self.legacyZoteroAccount)
        }
        return (Self.service, "\(connectionID)::\(field)")
    }

    public func secret(connectionID: String, field: String) -> String? {
        let loc = location(connectionID: connectionID, field: field)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: loc.service,
            kSecAttrAccount as String: loc.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, connectionID: String, field: String) throws {
        let loc = location(connectionID: connectionID, field: field)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: loc.service,
            kSecAttrAccount as String: loc.account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ZoteroKeychainError(operation: "delete", status: status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ZoteroKeychainError(operation: "add", status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ZoteroKeychainError(operation: "update", status: updateStatus)
        }
    }
}

/// In-memory test double.
public final class InMemoryConnectionCredentialStore: ConnectionCredentialStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]

    public init() {}

    private func key(_ connectionID: String, _ field: String) -> String { "\(connectionID)::\(field)" }

    public func secret(connectionID: String, field: String) -> String? {
        secrets[key(connectionID, field)]
    }

    public func setSecret(_ value: String?, connectionID: String, field: String) throws {
        let k = key(connectionID, field)
        if let value, !value.isEmpty { secrets[k] = value } else { secrets[k] = nil }
    }
}
