import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

extension CredentialReference {
    /// The typed reference for an extraction secret at its legacy
    /// extraction-service location (`org.sockpuppet.WikiFS.extraction`).
    public static func extraction(_ secret: ExtractionSecret) -> CredentialReference? {
        switch secret {
        case .anthropicAPIKey: return extraction("anthropic-api-key")
        case .geminiAPIKey: return extraction("gemini-api-key")
        case .doclingServeToken: return extraction("docling-serve-token")
        }
    }
}

#if os(macOS)
import Security

/// Errors from the Keychain-backed store, with the raw `OSStatus` for debugging.
public struct ExtractionKeychainError: Error, Equatable {
    public let operation: String
    public let status: OSStatus
}

/// The production `ExtractionCredentialStore`: one generic-password Keychain
/// item per secret, under a shared `service`.
///
/// Issue #1159: a thin adapter over the shared `KeychainCredentialService`.
/// Each `ExtractionSecret` maps to a typed reference under the `extraction`
/// domain; the location catalog resolves those references to the exact
/// `org.sockpuppet.WikiFS.extraction` accounts this store always used, so
/// existing secrets are read and written in place with no copy (AC.3).
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

    private func reference(for secret: ExtractionSecret) -> CredentialReference? {
        CredentialReference.extraction(account(for: secret))
    }

    public func secret(_ secret: ExtractionSecret) -> String? {
        guard let reference = reference(for: secret) else {
            return KeychainSecretStore.read(
                service: Self.service, account: account(for: secret))
        }
        do {
            return try KeychainCredentialService().resolve(reference).value
        } catch CredentialStoreError.notConfigured {
            return nil
        } catch {
            DebugLog.config(
                "Extraction credential read failed for \(reference.rawValue): \(error)")
            return nil
        }
    }

    public func setSecret(_ value: String?, _ secret: ExtractionSecret) throws {
        let accountName = account(for: secret)
        guard let reference = reference(for: secret) else {
            try KeychainSecretStore.write(
                service: Self.service, account: accountName, value: value,
                error: { operation, status in
                    ExtractionKeychainError(operation: "\(operation)(\(accountName))", status: status)
                })
            return
        }
        do {
            try KeychainCredentialService().set(
                CredentialValue.normalized(value), for: reference)
        } catch let error as CredentialStoreError {
            switch error {
            case .writeFailed(let operation, let status):
                throw ExtractionKeychainError(operation: "\(operation)(\(accountName))", status: status)
            default:
                throw ExtractionKeychainError(operation: "write(\(accountName))", status: -1)
            }
        }
    }
}
#endif // os(macOS)

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
