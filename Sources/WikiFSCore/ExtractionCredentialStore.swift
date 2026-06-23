import Foundation
import Security

/// Stores extraction secrets — the Anthropic + Gemini API keys and an optional
/// Docling Serve bearer token — behind a protocol so clients and tests never
/// touch the `Security` framework directly. Mirrors `ZoteroCredentialStore`.
public protocol ExtractionCredentialStore: Sendable {
    /// `nil` if no value has been set for this secret.
    func secret(_ secret: ExtractionSecret) -> String?
    /// Pass `nil` to delete the stored value.
    func setSecret(_ value: String?, _ secret: ExtractionSecret) throws
}

/// The secrets an extraction backend may need.
public enum ExtractionSecret: String, Sendable {
    case anthropicAPIKey
    case geminiAPIKey
    case doclingServeToken
}

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ExtractionKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus
}

/// The production `ExtractionCredentialStore`: one generic-password Keychain
/// item per secret, under a shared `service`. `WikiFS.entitlements` has no App
/// Sandbox, so this needs no keychain-access-group entitlement — the same
/// un-sandboxed access `URLSession` already has for outbound network calls.
public struct KeychainExtractionCredentialStore: ExtractionCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.extraction"

    public init() {}

    private func account(for secret: ExtractionSecret) -> String {
        switch secret {
        case .anthropicAPIKey: return "anthropic-api-key"
        case .geminiAPIKey: return "gemini-api-key"
        case .doclingServeToken: return "docling-serve-token"
        }
    }

    public func secret(_ secret: ExtractionSecret) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(for: secret),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, _ secret: ExtractionSecret) throws {
        let account = account(for: secret)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ExtractionKeychainError(operation: "delete(\(account))", status: status)
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
                throw ExtractionKeychainError(operation: "add(\(account))", status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ExtractionKeychainError(operation: "update(\(account))", status: updateStatus)
        }
    }
}

/// In-memory test double — mirrors `InMemoryZoteroCredentialStore`'s
/// `@unchecked Sendable` shape. NOT for production use.
public final class InMemoryExtractionCredentialStore: ExtractionCredentialStore, @unchecked Sendable {
    private var values: [ExtractionSecret: String] = [:]
    private let lock = NSLock()

    public init() {}

    public init(seeds: [ExtractionSecret: String]) {
        self.values = seeds
    }

    public func secret(_ secret: ExtractionSecret) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[secret]
    }

    public func setSecret(_ value: String?, _ secret: ExtractionSecret) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            values[secret] = value
        } else {
            values.removeValue(forKey: secret)
        }
    }
}
