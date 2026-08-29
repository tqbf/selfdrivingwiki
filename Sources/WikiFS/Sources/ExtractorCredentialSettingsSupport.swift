import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

// App-side support for extractor credential authorization in Settings
// (issue #1159, PR 2). The APP is the authorization writer; these helpers are
// the only composition points that build requirement summaries and perform
// grants/revocations. Headless and daemon surfaces get summaries from the
// same reader (or none) but never construct a writer.

enum ExtractorCredentialSettingsSupport {

    /// Compose requirement summaries for Settings: one row per DECLARED
    /// requirement of every active registration, resolved against the durable
    /// authorization snapshot + UI-safe credential descriptions. Pure with
    /// respect to the process registry — it reads only value snapshots.
    static func summaries(
        registrationSnapshots: [ExtractorRouteRegistrationSnapshot],
        authorizationSnapshot: ExtractorCredentialAuthorizationSnapshot?,
        credentials: CredentialDescribing
    ) -> [ExtractorCredentialRequirementSummary] {
        var result: [ExtractorCredentialRequirementSummary] = []
        for registration in registrationSnapshots.sorted(by: { $0.reference < $1.reference }) {
            for requirement in registration.credentialRequirements {
                result.append(
                    summary(
                        registration: registration, requirement: requirement,
                        authorizationSnapshot: authorizationSnapshot,
                        credentials: credentials))
            }
        }
        return result
    }

    /// Batch describe over the bound references (bounded by the service).
    static func summary(
        registration: ExtractorRouteRegistrationSnapshot,
        requirement: ExtractorCredentialRequirement,
        authorizationSnapshot: ExtractorCredentialAuthorizationSnapshot?,
        credentials: CredentialDescribing
    ) -> ExtractorCredentialRequirementSummary {
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: registration.reference.revision.packageID.rawValue,
            registrationID: registration.reference.registrationID.rawValue,
            kinds: registration.kinds.map(\.rawValue),
            mimeTypes: registration.mimeTypes.map(\.rawValue),
            requirement: requirement)
        let authorizationID = ExtractorCredentialAuthorizationID(
            packageID: registration.reference.revision.packageID,
            requirementID: requirement.id)
        let record = authorizationSnapshot?.record(for: authorizationID)
        let state: ExtractorCredentialRequirementSummary.AuthorizationState
        if let record {
            state = record.fingerprint == fingerprint
                ? .authorized
                : .changedContract
        } else {
            state = .needsAuthorization
        }
        var descriptions: [CredentialReference: CredentialInfo] = [:]
        if let record {
            descriptions = credentials.describe([record.credentialReference])
        }
        let configured = record.flatMap { descriptions[$0.credentialReference] }
        return ExtractorCredentialRequirementSummary(
            packageID: registration.reference.revision.packageID.rawValue,
            packageName: registration.packageName,
            packageVersion: registration.reference.revision.version.rawValue,
            registrationID: registration.reference.registrationID.rawValue,
            requirementID: requirement.id.rawValue,
            label: requirement.label,
            purpose: requirement.purpose,
            isOptional: requirement.isOptional,
            isConfigured: configured?.isConfigured ?? false,
            sourceName: "Keychain",
            authorizationState: state,
            kinds: registration.kinds.map(\.rawValue).sorted(),
            mimeTypes: registration.mimeTypes.map(\.rawValue).sorted())
    }

    /// The host's binding policy for one requirement: WHICH stored credential
    /// the package would receive. Today: a package that declares
    /// `api-token` for PDF binds to the legacy Docling Serve token reference;
    /// everything else gets a package-scoped reference under the shared
    /// credential service. Values never pass through here — references only.
    static func bindingReference(
        for summary: ExtractorCredentialRequirementSummary
    ) -> CredentialReference? {
        if summary.requirementID == "api-token" {
            return CredentialReference.extraction(.doclingServeToken)
        }
        // Package-scoped NEW reference: flatten the (dotted) package ID into
        // one grammar-valid label. The flattening is deterministic; reviewed
        // packages are identified by their lineage and legacy bindings take
        // precedence above.
        let flattened = summary.packageID
            .lowercased()
            .map { character -> Character in
                character == "." ? "-" : character
            }
        return CredentialReference(validatingLabels: [
            "extractor-package", String(flattened), summary.requirementID.lowercased(),
        ])
    }
}
