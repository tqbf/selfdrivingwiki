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
    /// the package would receive. Values never pass through here — references
    /// only.
    ///
    /// Legacy bindings are reserved for their reviewed lineages (HIGH-1,
    /// security review): a package ID other than the reviewed Docling Serve
    /// lineage can never bind to `extraction.docling-serve-token`, no matter
    /// what it names its requirement. Everything else gets a package-scoped
    /// reference under the shared credential service, keyed by a SHA-256
    /// prefix of the package ID (injective, unlike dot-flattening — L-9).
    static func bindingReference(
        for summary: ExtractorCredentialRequirementSummary
    ) -> CredentialReference? {
        let packageID = summary.packageID
        if packageID == ReviewedExtractorPackages.doclingServe.packageID.rawValue,
           summary.requirementID == "api-token" {
            return CredentialReference.extraction(.doclingServeToken)
        }
        // Package-scoped NEW reference: the package ID is hashed into one
        // grammar-valid label, so two distinct lineages can never collide on
        // one reference.
        let digest = ExtractorSHA256.digest(Data(packageID.utf8)).hex
        let hashedLabel = String(digest.prefix(32))
        return CredentialReference(validatingLabels: [
            "extractor-package", hashedLabel, summary.requirementID.lowercased(),
        ])
    }

    /// The stored credential a grant for `summary` would bind, by reference
    /// identity (never a value) — surfaced in the consent dialog so the user
    /// sees WHICH stored credential is being shared (MEDIUM-8).
    static func boundReferenceName(
        for summary: ExtractorCredentialRequirementSummary
    ) -> String? {
        bindingReference(for: summary)?.rawValue
    }
}
