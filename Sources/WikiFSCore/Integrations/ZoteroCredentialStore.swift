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
///
/// Issue #1159: a thin adapter over the shared `KeychainCredentialService`.
/// The typed `.zoteroAPIKey()` reference maps to the exact
/// `org.sockpuppet.WikiFS.zotero` / `zotero-api-key` location this store
/// always used — existing keys are read and written in place, no copy.
public struct KeychainZoteroCredentialStore: ZoteroCredentialStore {
    private static let service = "org.sockpuppet.WikiFS.zotero"
    private static let account = "zotero-api-key"

    public init() {}

    public func apiKey() -> String? {
        do {
            return try KeychainCredentialService()
                .resolve(.zoteroAPIKey()).value
        } catch CredentialStoreError.notConfigured {
            return nil
        } catch {
            DebugLog.config("Zotero credential read failed: \(error)")
            return nil
        }
    }

    public func setAPIKey(_ key: String?) throws {
        do {
            try KeychainCredentialService().set(
                CredentialValue.normalized(key), for: .zoteroAPIKey())
        } catch let error as CredentialStoreError {
            switch error {
            case .writeFailed(let status):
                throw ZoteroKeychainError(operation: "write", status: status)
            default:
                throw ZoteroKeychainError(operation: "write", status: -1)
            }
        }
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
