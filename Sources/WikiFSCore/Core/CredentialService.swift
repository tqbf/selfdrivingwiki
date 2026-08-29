import Foundation
import WikiFSTypes

// Credential-location catalog (issue #1159, plans/credential-service.md).
// Maps each typed `CredentialReference` to its PHYSICAL Keychain
// service/account pair. The existing ACP, Extraction, and Zotero pairs are
// compatibility contracts: the shared service reads and writes them in place
// and NEVER copies or renames those items merely because the service ships.
// Any reference outside the legacy mapping lands under the shared
// `org.sockpuppet.WikiFS.credentials` service, with the validated reference
// itself as the account.
//
// This file also hosts the typed reference factories for the legacy domains —
// keeping WikiFSTypes domain-neutral (AC.2) while call sites never concatenate
// unchecked raw strings into references.

/// A physical generic-password Keychain location (service + account).
public struct CredentialKeychainLocation: Hashable, Sendable, CustomStringConvertible {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var description: String { "\(service)::\(account)" }
}

/// The host-owned mapping from typed references to Keychain locations.
public enum CredentialLocations {

    /// The Keychain service for credentials first created through the shared
    /// service (no legacy location). The account is the validated reference.
    public static let sharedCredentialService = "org.sockpuppet.WikiFS.credentials"

    // Legacy services — exact existing pairs, unchanged (AC.3).
    static let acpService = "org.sockpuppet.WikiFS.acp"
    static let extractionService = "org.sockpuppet.WikiFS.extraction"
    static let zoteroService = "org.sockpuppet.WikiFS.zotero"

    /// Map a reference to its physical location.
    public static func location(for reference: CredentialReference) -> CredentialKeychainLocation {
        let labels = reference.labels
        let second = labels.count > 1 ? labels[1] : nil
        let third = labels.count > 2 ? labels[2] : nil
        if labels.first == "acp", second == "agent-api-key", third == nil {
            return CredentialKeychainLocation(
                service: acpService, account: "acp-agent-api-key")
        }
        if labels.first == "acp", second == "provider", let providerID = third {
            return CredentialKeychainLocation(
                service: acpService, account: "acp-provider:\(providerID)")
        }
        if labels.first == "extraction", third == nil {
            switch second {
            case "anthropic-api-key":
                return CredentialKeychainLocation(
                    service: extractionService, account: "anthropic-api-key")
            case "gemini-api-key":
                return CredentialKeychainLocation(
                    service: extractionService, account: "gemini-api-key")
            case "docling-serve-token":
                return CredentialKeychainLocation(
                    service: extractionService, account: "docling-serve-token")
            default:
                break
            }
        }
        if labels.first == "zotero", second == "api-key", third == nil {
            return CredentialKeychainLocation(
                service: zoteroService, account: "zotero-api-key")
        }
        return CredentialKeychainLocation(
            service: sharedCredentialService, account: reference.rawValue)
    }
}

// MARK: - Typed reference factories (legacy + provider domains)

extension CredentialReference {

    /// Builds a reference from a FIXED list of literals that provably satisfy
    /// the grammar. A failing literal is a programming error, so this
    /// crashes loudly rather than returning an optional.
    private static func fixed(_ labels: [String]) -> CredentialReference {
        guard let reference = CredentialReference(validatingLabels: labels) else {
            preconditionFailure("static credential labels must satisfy the reference grammar: \(labels.joined(separator: "."))")
        }
        return reference
    }

    /// The ACP agent's legacy single-key credential
    /// (`org.sockpuppet.WikiFS.acp` / `acp-agent-api-key`).
    public static func acpAgent() -> CredentialReference {
        fixed(["acp", "agent-api-key"])
    }

    /// A provider-scoped ACP API-key credential, mapped to the legacy
    /// `acp-provider:<id>` account. Returns `nil` when the provider id cannot
    /// form a valid reference label — callers (the adapters) keep their
    /// legacy direct path for such ids so no existing secret is orphaned.
    public static func acpProvider(_ id: ProviderID) -> CredentialReference? {
        CredentialReference(validatingLabels: ["acp", "provider", id.rawValue])
    }

    /// An extraction secret credential (Anthropic, Gemini, Docling token) at
    /// its legacy extraction-service location.
    public static func extraction(_ key: String) -> CredentialReference? {
        CredentialReference(validatingLabels: ["extraction", key])
    }

    /// The Zotero API-key credential at its legacy zotero-service location.
    public static func zoteroAPIKey() -> CredentialReference {
        fixed(["zotero", "api-key"])
    }
}

// MARK: - Keychain-backed service

/// The production `CredentialService`: the shared facade over
/// `KeychainSecretStore` (the only file allowed to call Security). Every
/// operation resolves its reference through `CredentialLocations` first, so
/// legacy items are read and written exactly where they always lived.
///
/// Diagnostics are bounded and value-free: failures log the operation and
/// reference, never a secret. The type is stateless, hence `Sendable`.
public struct KeychainCredentialService: CredentialService {

    public init() {}

    // MARK: CredentialDescribing

    public func describe(_ reference: CredentialReference) -> CredentialInfo {
        let location = CredentialLocations.location(for: reference)
        do {
            let value = try KeychainSecretStore.readOrThrow(
                service: location.service, account: location.account)
            return CredentialInfo(
                reference: reference,
                isConfigured: value != nil,
                source: .keychain,
                isWritable: true)
        } catch {
            // A read failure is surfaced as not-configured to UI callers via
            // `describe`'s no-throw contract; privileged `resolve` callers get
            // the typed error. Bounded, value-free diagnostic:
            DebugLog.config(
                "CredentialService: describe failed for \(reference.rawValue): \(error)")
            return CredentialInfo(
                reference: reference,
                isConfigured: false,
                source: .keychain,
                isWritable: true)
        }
    }

    public func describe(
        _ references: [CredentialReference]
    ) -> [CredentialReference: CredentialInfo] {
        let bounded = references.prefix(maximumDescribeBatchSize)
        var result: [CredentialReference: CredentialInfo] = [:]
        result.reserveCapacity(bounded.count)
        for reference in bounded {
            result[reference] = describe(reference)
        }
        return result
    }

    public var maximumDescribeBatchSize: Int { 64 }

    // MARK: CredentialWriting

    public func set(_ value: String?, for reference: CredentialReference) throws {
        let normalized = CredentialValue.normalized(value)
        let location = CredentialLocations.location(for: reference)
        do {
            try KeychainSecretStore.write(
                service: location.service, account: location.account,
                value: normalized,
                error: { operation, status in
                    CredentialStoreError.writeFailed(operation: operation, status: status)
                })
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.writeFailed(operation: "write", status: -1)
        }
    }

    public func unset(_ reference: CredentialReference) throws {
        try set(nil, for: reference)
    }

    // MARK: CredentialResolving

    public func resolve(_ reference: CredentialReference) throws -> ResolvedCredential {
        let location = CredentialLocations.location(for: reference)
        guard let value = try KeychainSecretStore.readOrThrow(
            service: location.service, account: location.account)
        else { throw CredentialStoreError.notConfigured(reference) }
        return ResolvedCredential(reference: reference, value: value, source: .keychain)
    }
}

// MARK: - In-memory service (tests + previews)

/// Concurrency-safe in-memory `CredentialService` for tests and previews.
/// NOT for production use.
///
/// # Internal-lock safety proof (Swift 6 Sendable)
/// The single mutable field `values` is guarded by `lock` on EVERY access —
/// each accessor acquires the lock for its whole body and no accessor calls
/// another accessor while holding it (no re-entrancy), and no escape of the
/// guarded storage exists. The class is `final`. That is exactly the
/// lock-discipline the type checker cannot see, documented here per
/// plans/credential-service.md; the `@unchecked` scope is limited to this
/// type.
// swiftlint:disable:next unchecked_sendable
public final class InMemoryCredentialService: CredentialService, @unchecked Sendable {

    private var values: [CredentialReference: String] = [:]
    private let lock = NSLock()
    private let writable: Bool

    public init(writable: Bool = true) {
        self.writable = writable
    }

    public convenience init(seed: [CredentialReference: String]) {
        self.init()
        lock.lock()
        values = seed.filter { $0.value.isEmpty == false }
        lock.unlock()
    }

    public func describe(_ reference: CredentialReference) -> CredentialInfo {
        lock.lock(); defer { lock.unlock() }
        return CredentialInfo(
            reference: reference,
            isConfigured: values[reference] != nil,
            source: .keychain,
            isWritable: writable)
    }

    public func describe(
        _ references: [CredentialReference]
    ) -> [CredentialReference: CredentialInfo] {
        let bounded = references.prefix(maximumDescribeBatchSize)
        var result: [CredentialReference: CredentialInfo] = [:]
        result.reserveCapacity(bounded.count)
        for reference in bounded {
            result[reference] = describe(reference)
        }
        return result
    }

    public var maximumDescribeBatchSize: Int { 64 }

    public func set(_ value: String?, for reference: CredentialReference) throws {
        guard writable else { throw CredentialStoreError.notWritable(reference) }
        let normalized = CredentialValue.normalized(value)
        lock.lock(); defer { lock.unlock() }
        if let normalized {
            values[reference] = normalized
        } else {
            values.removeValue(forKey: reference)
        }
    }

    public func unset(_ reference: CredentialReference) throws {
        try set(nil, for: reference)
    }

    public func resolve(_ reference: CredentialReference) throws -> ResolvedCredential {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[reference] else {
            throw CredentialStoreError.notConfigured(reference)
        }
        return ResolvedCredential(reference: reference, value: value, source: .keychain)
    }
}
