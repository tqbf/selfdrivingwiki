import Foundation

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

    /// Per-provider API key, keyed by provider id (#324). Default implementation
    /// falls back to the single-key store so existing conformers are unchanged;
    /// the Keychain-backed store namespaces by account suffix.
    func apiKey(forProvider id: String) -> String?
    /// Per-provider write. Pass `nil`/empty to delete.
    func setAPIKey(_ value: String?, forProvider id: String) throws
}

extension ACPCredentialStore {
    /// Default: a per-provider lookup degrades to the shared single key, so any
    /// existing conformer keeps working (the launcher only reads a per-provider
    /// key for `.acp` providers, and the single-key store is the legacy seam).
    public func apiKey(forProvider id: String) -> String? { apiKey() }
    public func setAPIKey(_ value: String?, forProvider id: String) throws {
        try setAPIKey(value)
    }
}

#if os(macOS)
import Security

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ACPKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }
}

/// The production `ACPCredentialStore`: generic-password Keychain items under
/// a shared `service` + account. The legacy single-key API uses a fixed account;
/// the per-provider API (#324) namespaces by provider id so each ACP provider
/// keeps its own secret. `WikiFS.entitlements` has no App Sandbox, so this needs
/// no keychain-access-group entitlement — same un-sandboxed access
/// `KeychainExtractionCredentialStore` already relies on.
public struct KeychainACPCredentialStore: ACPCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.acp"
    private static let account = "acp-agent-api-key"

    public init() {}

    public func apiKey() -> String? {
        KeychainSecretStore.read(service: Self.service, account: Self.account)
    }

    public func setAPIKey(_ value: String?) throws {
        try KeychainSecretStore.write(
            service: Self.service, account: Self.account, value: value,
            error: { operation, status in
                ACPKeychainError(operation: "\(operation)(\(Self.account))", status: status)
            })
    }

    // MARK: - Per-provider (#324)

    public func apiKey(forProvider id: String) -> String? {
        KeychainSecretStore.read(service: Self.service, account: Self.providerAccount(id))
    }

    public func setAPIKey(_ value: String?, forProvider id: String) throws {
        let account = Self.providerAccount(id)
        try KeychainSecretStore.write(
            service: Self.service, account: account, value: value,
            error: { operation, status in
                ACPKeychainError(operation: "\(operation)(\(account))", status: status)
            })
    }

    /// Namespace a per-provider account so each provider's key is isolated.
    private static func providerAccount(_ id: String) -> String {
        "acp-provider:\(id)"
    }
}
#endif // os(macOS)

/// In-memory test double — mirrors `InMemoryExtractionCredentialStore`'s
/// `@unchecked Sendable` shape. NOT for production use. Per-provider keys are
/// isolated in a map; the legacy single-key API reads/writes the `"claude"` slot
/// so it stays consistent with the production store's fixed account.
public final class InMemoryACPCredentialStore: ACPCredentialStore, @unchecked Sendable {
    private static let legacyKey = "__legacy__"
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public init(seed: String?) {
        if let seed, !seed.isEmpty {
            values[Self.legacyKey] = seed
        }
    }

    public func apiKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[Self.legacyKey]
    }

    public func setAPIKey(_ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            values[Self.legacyKey] = value
        } else {
            values.removeValue(forKey: Self.legacyKey)
        }
    }

    // MARK: - Per-provider (#324)

    public func apiKey(forProvider id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }

    public func setAPIKey(_ value: String?, forProvider id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            values[id] = value
        } else {
            values.removeValue(forKey: id)
        }
    }
}
