import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stores the Zotero API key — a secret, unlike `ZoteroConfig`'s library ID and
/// directory override, which are plain JSON. Behind a protocol so `ZoteroClient`
/// and tests never touch the `Security` framework directly.
public protocol ZoteroCredentialStore: Sendable {
    /// `nil` if no key has been set yet.
    func apiKey() -> String?
    /// Pass `nil` to delete the stored key.
    func setAPIKey(_ key: String?) throws
}

#if os(macOS)
import Security

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ZoteroKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus
}

/// The production `ZoteroCredentialStore`: a generic-password Keychain item.
/// `KeychainSecretStore` (the shared helper) writes items to the DataProtection
/// keychain under a shared `keychain-access-groups` access group so the
/// un-sandboxed `wikid` daemon can read them — see `plans/keychain-sharing.md`.
public struct KeychainZoteroCredentialStore: ZoteroCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.zotero"
    private static let account = "zotero-api-key"

    public init() {}

    public func apiKey() -> String? {
        KeychainSecretStore.read(service: Self.service, account: Self.account)
    }

    public func setAPIKey(_ key: String?) throws {
        try KeychainSecretStore.write(
            service: Self.service, account: Self.account, value: key,
            error: { operation, status in
                ZoteroKeychainError(operation: operation, status: status)
            })
    }
}
#endif // os(macOS)

/// In-memory test double — mirrors `URLFetchServiceTests.StoreCollector`'s
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
