import Foundation
import Security

/// Stores the Zotero API key — a secret, unlike `ZoteroConfig`'s library ID and
/// directory override, which are plain JSON. Behind a protocol so `ZoteroClient`
/// and tests never touch the `Security` framework directly.
public protocol ZoteroCredentialStore: Sendable {
    /// `nil` if no key has been set yet.
    func apiKey() -> String?
    /// Pass `nil` to delete the stored key.
    func setAPIKey(_ key: String?) throws
}

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ZoteroKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus
}

/// The production `ZoteroCredentialStore`: a generic-password Keychain item.
/// `WikiFS.entitlements` has no App Sandbox, so this needs no
/// keychain-access-group entitlement — same un-sandboxed access `URLSession`
/// already has for outbound network calls.
public struct KeychainZoteroCredentialStore: ZoteroCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.zotero"
    private static let account = "zotero-api-key"

    public init() {}

    public func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ key: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ZoteroKeychainError(operation: "delete", status: status)
            }
            return
        }

        let data = Data(key.utf8)
        // Try update first (the common "user is changing their key" case); if
        // nothing exists yet, add it.
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

/// In-memory test double — mirrors `URLIngestServiceTests.StoreCollector`'s
/// `@unchecked Sendable` shape. NOT for production use.
public final class InMemoryZoteroCredentialStore: ZoteroCredentialStore, @unchecked Sendable {
    private var key: String?

    public init(initialKey: String? = nil) {
        self.key = initialKey
    }

    public func apiKey() -> String? { key }

    public func setAPIKey(_ key: String?) throws {
        self.key = key
    }
}
