import Foundation
import Security

/// Stores the ACP agent's auth secret (the API key) behind a protocol so clients
/// and tests never touch the `Security` framework directly. Mirrors
/// `ExtractionCredentialStore` / `ZoteroCredentialStore`: the secret lives in the
/// macOS Keychain, NEVER in the plaintext `acp-agent-config.json`.
///
/// Slice 3 of `plans/acp-backend-and-permissions.md`: the ACP config is now a
/// dedicated type (`ACPAgentConfig` for plain prefs, this store for the key), so
/// ACP agents that require auth actually work.
public protocol ACPCredentialStore: Sendable {
    /// `nil` if no API key has been stored.
    func apiKey() -> String?
    /// Pass `nil` (or an empty string) to delete the stored value.
    func setAPIKey(_ value: String?) throws
}

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ACPKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }
}

/// The production `ACPCredentialStore`: one generic-password Keychain item under
/// a shared `service` + account. `WikiFS.entitlements` has no App Sandbox, so
/// this needs no keychain-access-group entitlement — same un-sandboxed access
/// `KeychainExtractionCredentialStore` already relies on.
public struct KeychainACPCredentialStore: ACPCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.acp"
    private static let account = "acp-agent-api-key"

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

    public func setAPIKey(_ value: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ACPKeychainError(operation: "delete(\(Self.account))", status: status)
            }
            return
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
            guard addStatus == errSecSuccess else {
                throw ACPKeychainError(operation: "add(\(Self.account))", status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ACPKeychainError(operation: "update(\(Self.account))", status: updateStatus)
        }
    }
}

/// In-memory test double — mirrors `InMemoryExtractionCredentialStore`'s
/// `@unchecked Sendable` shape. NOT for production use.
public final class InMemoryACPCredentialStore: ACPCredentialStore, @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    public init() {}

    public init(seed: String?) {
        self.value = seed
    }

    public func apiKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func setAPIKey(_ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            self.value = value
        } else {
            self.value = nil
        }
    }
}
