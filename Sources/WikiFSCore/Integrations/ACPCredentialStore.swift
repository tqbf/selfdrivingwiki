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
/// keeps its own secret.
///
/// Issue #1159: this store is now a THIN ADAPTER over the shared
/// `KeychainCredentialService` — it translates its per-domain API into typed
/// `CredentialReference` values (`.acpAgent()` / `.acpProvider(_:)`) and maps
/// service errors back to this store's historical `ACPKeychainError` shape.
/// The physical locations are unchanged: the location catalog maps those
/// references to the exact `org.sockpuppet.WikiFS.acp` accounts this store
/// always used, so existing secrets are read and written in place with no
/// copy (AC.3, plans/credential-service.md).
///
/// Provider ids that cannot form a valid reference label (arbitrary
/// user-chosen ids with characters outside the credential grammar) keep the
/// legacy direct `KeychainSecretStore` path — the exact pre-service behavior —
/// so no existing secret is orphaned by the grammar.
public struct KeychainACPCredentialStore: ACPCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.acp"
    private static let account = "acp-agent-api-key"

    public init() {}

    public func apiKey() -> String? {
        Self.read(reference: .acpAgent())
    }

    public func setAPIKey(_ value: String?) throws {
        try Self.write(
            CredentialValue.normalized(value), reference: .acpAgent(),
            errorAccount: Self.account)
    }

    // MARK: - Per-provider (#324)

    public func apiKey(forProvider id: String) -> String? {
        guard let reference = CredentialReference.acpProvider(ProviderID(rawValue: id)) else {
            // Provider id outside the credential grammar: legacy direct path,
            // preserving the physical `acp-provider:<id>` account exactly.
            return KeychainSecretStore.read(
                service: Self.service, account: Self.providerAccount(id))
        }
        return Self.read(reference: reference)
    }

    public func setAPIKey(_ value: String?, forProvider id: String) throws {
        let account = Self.providerAccount(id)
        guard let reference = CredentialReference.acpProvider(ProviderID(rawValue: id)) else {
            try KeychainSecretStore.write(
                service: Self.service, account: account, value: value,
                error: { operation, status in
                    ACPKeychainError(operation: "\(operation)(\(account))", status: status)
                })
            return
        }
        try Self.write(
            CredentialValue.normalized(value), reference: reference,
            errorAccount: account)
    }

    /// Namespace a per-provider account so each provider's key is isolated.
    private static func providerAccount(_ id: String) -> String {
        "acp-provider:\(id)"
    }

    /// Shared read: resolve through the service; preserve the historical
    /// "missing OR failed = nil" optional contract with a bounded, value-free
    /// diagnostic for real Keychain failures (Risk 4, plans/credential-service.md).
    private static func read(reference: CredentialReference) -> String? {
        do {
            return try KeychainCredentialService().resolve(reference).value
        } catch CredentialStoreError.notConfigured {
            return nil
        } catch {
            DebugLog.config(
                "ACP credential read failed for \(reference.rawValue): \(error)")
            return nil
        }
    }

    /// Shared write: normalize through `CredentialValue` (whitespace-only =
    /// unset), then map the typed service error back to `ACPKeychainError`.
    private static func write(
        _ value: String?, reference: CredentialReference, errorAccount: String
    ) throws {
        do {
            try KeychainCredentialService().set(value, for: reference)
        } catch let error as CredentialStoreError {
            switch error {
            case .writeFailed(let status):
                throw ACPKeychainError(operation: "write(\(errorAccount))", status: status)
            default:
                throw ACPKeychainError(operation: "write(\(errorAccount))", status: -1)
            }
        }
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
