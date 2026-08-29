import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSCore
import WikiFSTypes

// Per-operation credential resolution (issue #1159, PR 3 —
// plans/credential-service.md §"Operation input"). The trusted host resolves
// the selected registration's authorized requirements IMMEDIATELY BEFORE each
// process launch, materializes them into a request-scoped owner-read-only
// file, and redacts every package-provided string that could echo a value.

public enum ExtractorOperationCredentialError: Error, Equatable, Sendable,
    CustomStringConvertible {
    /// The exact revision is no longer admitted (removed / failed activation).
    case packageNotAdmitted
    /// The revision is no longer in the machine catalog.
    case unknownRevision
    /// A REQUIRED requirement is unauthorized or has no stored value.
    case requiredCredentialUnavailable(requirementID: String)
    /// A required resolution step failed before launch; bounded, value-free.
    case resolutionUnavailable

    public var description: String {
        switch self {
        case .packageNotAdmitted:
            return "The installed extractor package is no longer active."
        case .unknownRevision:
            return "The installed extractor package is not in the machine catalog."
        case .requiredCredentialUnavailable(let id):
            return "A required credential (\(id)) is not authorized or not configured. Authorize it in Settings → Extraction."
        case .resolutionUnavailable:
            return "Extractor credentials could not be prepared for this run."
        }
    }
}

/// Host-owned per-operation resolution (AC.11). Called by the process
/// provider IMMEDIATELY BEFORE each launch of a credential-declaring
/// registration; implementations must recheck current state and never cache
/// values across calls.
public protocol ExtractorOperationCredentialResolving: Sendable {
    func resolveOperationCredentials(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registration: ExtractorRegistration
    ) async throws -> [ExtractorCredentialRequirementID: String]
}

/// The production resolver: rechecks admission + catalog membership, reloads
/// the authorization snapshot, validates declaration fingerprints via the
/// pure PR 2 resolver, then resolves each authorized reference ONCE. Absent
/// optional values are omitted; an absent REQUIRED value throws a bounded
/// typed error.
public struct ExtractorOperationCredentialResolver: ExtractorOperationCredentialResolving {
    private let admission: any ProcessPackageAdmissionChecking
    private let catalogReader: any ExtractorPackageCatalogReading
    private let authorizationReader: ExtractorCredentialAuthorizationReader
    private let credentials: any CredentialResolving

    public init(
        admission: any ProcessPackageAdmissionChecking,
        catalogReader: any ExtractorPackageCatalogReading,
        authorizationReader: ExtractorCredentialAuthorizationReader,
        credentials: any CredentialResolving
    ) {
        self.admission = admission
        self.catalogReader = catalogReader
        self.authorizationReader = authorizationReader
        self.credentials = credentials
    }

    public func resolveOperationCredentials(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registration: ExtractorRegistration
    ) async throws -> [ExtractorCredentialRequirementID: String] {
        // TOCTOU rechecks (plan step 12): admission + catalog membership are
        // re-observed immediately before resolution; once the launch request
        // is constructed the operation owns its value snapshot.
        guard await admission.isAdmitted(revision) else {
            throw ExtractorOperationCredentialError.packageNotAdmitted
        }
        let catalog = try catalogReader.read()
        guard catalog.records.contains(where: { $0.revision == revision }) else {
            throw ExtractorOperationCredentialError.unknownRevision
        }
        let snapshot = authorizationReader.snapshot()
        let decisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: revision.packageID,
            manifest: manifest,
            registration: registration,
            isAdmitted: true,
            snapshot: snapshot,
            descriptions: describe(candidateReferences(
                packageID: revision.packageID,
                registration: registration,
                snapshot: snapshot)))
        var resolved: [ExtractorCredentialRequirementID: String] = [:]
        for decision in decisions {
            switch decision.state {
            case .authorized(let reference):
                do {
                    resolved[decision.requirement.id] = try credentials.resolve(reference).value
                } catch {
                    if decision.requirement.isOptional { continue }
                    throw ExtractorOperationCredentialError.requiredCredentialUnavailable(
                        requirementID: decision.requirement.id.rawValue)
                }
            case .missingCredential:
                if decision.requirement.isOptional { continue }
                throw ExtractorOperationCredentialError.requiredCredentialUnavailable(
                    requirementID: decision.requirement.id.rawValue)
            case .unauthorized:
                if decision.requirement.isOptional { continue }
                throw ExtractorOperationCredentialError.requiredCredentialUnavailable(
                    requirementID: decision.requirement.id.rawValue)
            }
        }
        return resolved
    }

    /// The references granted to THIS lineage for the registration's declared
    /// requirements (fingerprint-validated candidates for description).
    private func candidateReferences(
        packageID: ExtractorPackageID,
        registration: ExtractorRegistration,
        snapshot: ExtractorCredentialAuthorizationSnapshot?
    ) -> [CredentialReference] {
        guard let snapshot else { return [] }
        return registration.credentialRequirements.compactMap { requirement in
            let authorizationID = ExtractorCredentialAuthorizationID(
                packageID: packageID, requirementID: requirement.id)
            guard let record = snapshot.record(for: authorizationID),
                  record.fingerprint == ExtractorCredentialRequirementFingerprint.compute(
                    packageID: packageID.rawValue,
                    registrationID: registration.id.rawValue,
                    kinds: registration.kinds.map(\.rawValue),
                    mimeTypes: registration.mimeTypes.map(\.rawValue),
                    requirement: requirement)
            else { return nil }
            return record.credentialReference
        }
    }

    private func describe(
        _ references: [CredentialReference]
    ) -> [CredentialReference: CredentialInfo] {
        guard let describing = credentials as? any CredentialDescribing else { return [:] }
        return describing.describe(references)
    }
}

/// Replaces every resolved operation value before any package-controlled
/// string reaches host diagnostics, logs, mapped errors, or UI (AC.15).
/// Values are captured at construction and never exposed.
public struct ExtractorSecretRedactor: Sendable {
    /// Fixed replacement token — never derived from the secret.
    private static let replacement = "[redacted]"
    private let secrets: [String]

    public init(values: [String]) {
        self.secrets = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .compactMap { $0 }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: Self.replacement)
        }
        return result
    }

    public func redactedMessage(_ error: Error) -> String {
        redact(ProcessPackageFailureMapper.message(error))
    }
}
