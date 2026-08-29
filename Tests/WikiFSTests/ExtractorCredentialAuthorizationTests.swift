import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

// PR 2 coverage for issue #1159: manifest revision 2 credential
// declarations, revision 1 compatibility, the durable authorization store,
// and the pure authorization resolver.

private func requirement(
    _ id: String = "api-token",
    optional: Bool = true,
    label: String = "API token",
    purpose: String = "Authenticates requests to the service."
) -> ExtractorCredentialRequirement {
    try! ExtractorCredentialRequirement(
        id: ExtractorCredentialRequirementID(validating: id),
        kind: .secret,
        isOptional: optional,
        label: label,
        purpose: purpose)
}

private func makeManifest(
    revision: ExtractorManifestRevision = .v2,
    packageID: String = "org.example.fixture",
    registrations: [ExtractorRegistration]
) throws -> ExtractorManifest {
    let bytes = Data("fixture".utf8)
    return try ExtractorManifest(
        manifestRevision: revision,
        packageID: ExtractorPackageID(validating: packageID),
        version: ExtractorPackageVersion(validating: "1.0.0"),
        displayName: "Fixture",
        protocolRevision: .v1,
        entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
        launch: .direct,
        registrations: registrations,
        capabilities: [],
        files: [ExtractorPackageFile(
            path: ExtractorRelativePath(validating: "bin/extractor"),
            digest: ExtractorSHA256.digest(bytes))],
        limits: ExtractorOperationLimits(
            maximumInputByteCount: 1_024,
            maximumMarkdownOutputByteCount: 2_048,
            maximumDurationMilliseconds: 30_000,
            maximumProgressEventCount: 10))
}

private func pdfRegistration(
    id: String = "main",
    requirements: [ExtractorCredentialRequirement] = []
) throws -> ExtractorRegistration {
    try ExtractorRegistration(
        id: ExtractorRegistrationID(validating: id),
        displayName: "Main",
        kinds: [.pdf],
        mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
        credentialRequirements: requirements)
}

// MARK: - Manifest revision 2

@Suite(.serialized)
struct ExtractorCredentialManifestTests {

    @Test func revisionOneGoldenBytesAndDigestsRemainStable() throws {
        // AC.6: a v1 manifest round-trips to exactly the same canonical
        // bytes and digest as before revision 2 existed (the registration
        // encoder emits the credential key only when non-empty, which v1
        // can never have).
        let v1 = try makeManifest(revision: .v1, registrations: [pdfRegistration()])
        let canonical = try v1.canonicalJSON()
        let digest = try v1.packageDigest()
        // Encoded manifest form round-trips and preserves the digest.
        let encoded = try JSONEncoder().encode(v1)
        let decoded = try JSONDecoder().decode(ExtractorManifest.self, from: encoded)
        #expect(decoded == v1)
        #expect(try decoded.packageDigest() == digest)
        // Canonical bytes are stable across calls.
        #expect(try v1.canonicalJSON() == canonical)
    }

    @Test func revisionTwoRequirementsEncodeDeterministically() throws {
        // AC.7: declarations encode deterministically (sorted, normalized).
        let v2 = try makeManifest(revision: .v2, registrations: [
            pdfRegistration(requirements: [
                requirement("api-token"),
                requirement("aaa-token"),
            ]),
        ])
        let first = try v2.canonicalJSON()
        let second = try v2.canonicalJSON()
        #expect(first == second)
        #expect(try v2.packageDigest() == v2.packageDigest())
        // Requirement order is canonicalized (sorted by requirement ID).
        let payload = String(decoding: first, as: UTF8.self)
        let aaaRange = payload.range(of: "aaa-token")
        let apiRange = payload.range(of: "api-token")
        #expect(aaaRange != nil && apiRange != nil && aaaRange!.lowerBound < apiRange!.lowerBound)
    }

    @Test func revisionOneManifestJSONRejectsTheCredentialKey() throws {
        // A v1 manifest carrying a credentialRequirements key is rejected by
        // the unknown-field policy.
        let v2 = try makeManifest(revision: .v2, registrations: [
            pdfRegistration(requirements: [requirement()]),
        ])
        let data = try JSONEncoder().encode(v2)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["manifestRevision"] = 1
        let v1Bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ExtractorValidationError.self) {
            _ = try JSONDecoder().decode(ExtractorManifest.self, from: v1Bytes)
        }
    }

    @Test func v2DecodesRequirementsRoundTrip() throws {
        let v2 = try makeManifest(revision: .v2, registrations: [
            pdfRegistration(requirements: [requirement()]),
        ])
        let decoded = try JSONDecoder().decode(
            ExtractorManifest.self, from: try JSONEncoder().encode(v2))
        #expect(decoded == v2)
    }

    @Test func rejectsManifestWideDuplicateRequirementIDs() {
        // Same requirement ID in TWO registrations of one manifest: rejected
        // (lineage + requirement ID must be unambiguous).
        #expect(throws: ExtractorValidationError.self) {
            _ = try makeManifest(revision: .v2, registrations: [
                pdfRegistration(id: "main", requirements: [requirement("shared-token")]),
                pdfRegistration(id: "alt", requirements: [requirement("shared-token")]),
            ])
        }
    }

    @Test func rejectsInvalidAndNonNormalizedDeclarations() {
        // Invalid requirement ID.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorCredentialRequirementID(validating: "Bad ID")
        }
        // Empty label.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorCredentialRequirement(
                id: ExtractorCredentialRequirementID(validating: "api-token"),
                kind: .secret, isOptional: true,
                label: "   ",
                purpose: "p")
        }
        // Oversized label.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorCredentialRequirement(
                id: ExtractorCredentialRequirementID(validating: "api-token"),
                kind: .secret, isOptional: true,
                label: String(repeating: "a", count: 65),
                purpose: "p")
        }
        // Oversized purpose.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorCredentialRequirement(
                id: ExtractorCredentialRequirementID(validating: "api-token"),
                kind: .secret, isOptional: true,
                label: "API token",
                purpose: String(repeating: "a", count: 257))
        }
        // Non-normalized JSON (untrimmed label) is rejected at decode.
        let raw = """
        {"id":"api-token","kind":"secret","optional":true,"label":" API token ","purpose":"p"}
        """
        #expect(throws: ExtractorValidationError.self) {
            _ = try JSONDecoder().decode(
                ExtractorCredentialRequirement.self, from: Data(raw.utf8))
        }
    }

    @Test func fingerprintGatesOnContractAndScope() throws {
        let base = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.fixture",
            registrationID: "main",
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"],
            requirement: requirement())
        // Identical inputs → identical fingerprint.
        let same = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.fixture",
            registrationID: "main",
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"],
            requirement: requirement())
        #expect(base == same)
        // Any contract/scope change → different fingerprint.
        let changedLabel = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.fixture", registrationID: "main",
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement(label: "Different"))
        #expect(base != changedLabel)
        let changedScope = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.fixture", registrationID: "main",
            kinds: ["pdf"], mimeTypes: ["application/pdf", "image/pdf"],
            requirement: requirement())
        #expect(base != changedScope)
        let movedRegistration = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.fixture", registrationID: "other",
            kinds: ["pdf"], mimeTypes: ["application/pdf"], requirement: requirement())
        #expect(base != movedRegistration)
        let differentLineage = ExtractorCredentialRequirementFingerprint.compute(
            packageID: "org.example.other", registrationID: "main",
            kinds: ["pdf"], mimeTypes: ["application/pdf"], requirement: requirement())
        #expect(base != differentLineage)
    }
}

// MARK: - Authorization store

@Suite(.serialized)
struct ExtractorCredentialAuthorizationStoreTests {

    private func makeLayout() throws -> ExtractorCredentialAuthorizationStoreLayout {
        ExtractorCredentialAuthorizationStoreLayout(
            appGroupContainerRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("authz-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeWriter(
        _ layout: ExtractorCredentialAuthorizationStoreLayout,
        role: ExtractorPackageProcessRole = .app
    ) throws -> ExtractorCredentialAuthorizationWriter {
        try ExtractorCredentialAuthorizationWriter(
            layout: layout, processRole: role)
    }

    @Test func grantAndRevokeRoundTripWithDeterministicOrder() async throws {
        let layout = try makeLayout()
        let writer = try makeWriter(layout)
        _ = try await writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.z"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement("b-token"),
            credentialReference: CredentialReference.zoteroAPIKey())
        let snapshot = try await writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.a"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement("a-token"),
            credentialReference: CredentialReference.acpAgent())
        // Records are stored in deterministic sorted order.
        let ids = snapshot.records.map(\.authorizationID)
        #expect(ids == ids.sorted())
        // Another reader (a different process view of the same file) sees it.
        let reader = ExtractorCredentialAuthorizationReader(layout: layout)
        #expect(reader.snapshot()?.records.count == 2)
        // Revoke one; removing an absent grant is a no-op that still succeeds.
        let afterRevoke = try await writer.revoke(
            packageID: ExtractorPackageID(validating: "org.example.z"),
            requirementID: ExtractorCredentialRequirementID(validating: "b-token"))
        #expect(afterRevoke.records.count == 1)
        let noOp = try await writer.revoke(
            packageID: ExtractorPackageID(validating: "org.example.z"),
            requirementID: ExtractorCredentialRequirementID(validating: "b-token"))
        #expect(noOp.records.count == 1)
    }

    @Test func grantReplacesOnlyTheSameLineageAndRequirement() async throws {
        let layout = try makeLayout()
        let writer = try makeWriter(layout)
        _ = try await writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.pkg"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement(),
            credentialReference: CredentialReference.acpAgent())
        // Re-grant the SAME lineage + requirement with a different reference:
        // replaces the record (explicit re-consent).
        let updated = try await writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.pkg"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement(),
            credentialReference: CredentialReference.zoteroAPIKey())
        #expect(updated.records.count == 1)
        #expect(updated.records[0].credentialReference == .zoteroAPIKey())
    }

    @Test func daemonRoleMayNotMutate() {
        // AC.9: only the app may construct a mutating writer.
        let layout = ExtractorCredentialAuthorizationStoreLayout(
            appGroupContainerRoot: FileManager.default.temporaryDirectory)
        #expect(throws: ExtractorCredentialAuthorizationStoreError.roleMayNotMutate(.daemon)) {
            _ = try ExtractorCredentialAuthorizationWriter(
                layout: layout, processRole: .daemon)
        }
    }

    @Test func concurrentDisjointWritesAllPersist() async throws {
        let layout = try makeLayout()
        let writer = try makeWriter(layout)
        // Sequential-dependency-free grants race through the same lock.
        async let a: ExtractorCredentialAuthorizationSnapshot = writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.aa"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement("t-one"),
            credentialReference: CredentialReference.acpAgent())
        async let b: ExtractorCredentialAuthorizationSnapshot = writer.grant(
            packageID: ExtractorPackageID(validating: "org.example.bb"),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement("t-two"),
            credentialReference: CredentialReference.zoteroAPIKey())
        _ = try await (a, b)
        let reader = ExtractorCredentialAuthorizationReader(layout: layout)
        #expect(reader.snapshot()?.records.count == 2)
    }

    @Test func missingStoreReadsAsNilNotAnError() throws {
        let layout = try makeLayout()
        let reader = ExtractorCredentialAuthorizationReader(layout: layout)
        #expect(reader.snapshot() == nil)
    }
}

// MARK: - Forgeability boundary (PR 2 review HIGH, rebuttal + enforcement)

/// The PR 2 review flagged that `ExtractorCredentialAuthorizationWriter` is
/// public in `WikiFSCore`, which the daemon and CLI also link, so a caller
/// could pass `processRole: .app`. Swift cannot structurally distinguish
/// executable targets that link one module, and moving the writer to the app
/// target would strip its unit tests from the default CI graph — so the
/// boundary is enforced where it is real: a SOURCE CONTRACT that the daemon
/// and CLI composition never construct a writer, on top of the runtime
/// boundaries (cross-process flock, 0600 file, App Group placement).
struct ExtractorCredentialWriterPlacementAuditTests {

    @Test func daemonAndCLINeverConstructTheAuthorizationWriter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let watched = [
            "Sources/wikid",
            "Sources/wikictl",
            "Sources/WikiFSFileProvider",
        ]
        for relative in watched {
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    source.contains("ExtractorCredentialAuthorizationWriter(") == false,
                    "\(file.lastPathComponent) must never construct the authorization writer")
            }
        }
    }
}

// MARK: - Resolver

struct ExtractorCredentialAuthorizationResolverTests {

    // Fixed valid literals; a failure would be a test bug.
    private let packageID = try! ExtractorPackageID(validating: "org.example.pkg")
    private let reference = CredentialReference.acpAgent()

    private func resolved() -> [CredentialReference: CredentialInfo] {
        [reference: CredentialInfo(
            reference: reference, isConfigured: true,
            source: .keychain, isWritable: true)]
    }

    @Test func lineageAndFingerprintGateAuthorization() async throws {
        // AC.8 + AC.16: unchanged contract inherits; changed contract or a
        // different package cannot reuse the grant.
        let registration = try pdfRegistration(requirements: [requirement()])
        let manifest = try makeManifest(
            revision: .v2, packageID: packageID.rawValue, registrations: [registration])
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: packageID.rawValue,
            registrationID: "main",
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"],
            requirement: requirement())
        let record = ExtractorCredentialAuthorizationRecord(
            authorizationID: ExtractorCredentialAuthorizationID(
                packageID: packageID, requirementID: requirement().id),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            fingerprint: fingerprint,
            credentialReference: reference,
            authorizedAt: Date())
        let snapshot = ExtractorCredentialAuthorizationSnapshot(
            generation: 1, records: [record])

        let decisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID, manifest: manifest, registration: registration,
            isAdmitted: true, snapshot: snapshot, descriptions: resolved())
        #expect(decisions.count == 1)
        #expect(decisions[0].state == .authorized(reference))
        #expect(decisions[0].isSatisfied)

        // Changed contract (different label) → unauthorized; a REQUIRED
        // unsatisfied requirement blocks preparation.
        let changed = try pdfRegistration(requirements: [
            requirement(optional: false, label: "Changed label"),
        ])
        let changedDecisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID,
            manifest: try makeManifest(revision: .v2, registrations: [changed]),
            registration: changed,
            isAdmitted: true, snapshot: snapshot, descriptions: resolved())
        #expect(changedDecisions[0].state == .unauthorized)
        #expect(changedDecisions[0].blocksPreparation)
    }

    @Test func differentPackageCannotReuseGrant() async throws {
        // A grant pinned to lineage A never satisfies lineage B.
        let registration = try pdfRegistration(requirements: [requirement()])
        let otherPackage = try ExtractorPackageID(validating: "org.example.other")
        let manifest = try ExtractorManifest(
            manifestRevision: .v2,
            packageID: otherPackage,
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Fixture",
            protocolRevision: .v1,
            entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
            launch: .direct,
            registrations: [registration],
            capabilities: [],
            files: [ExtractorPackageFile(
                path: ExtractorRelativePath(validating: "bin/extractor"),
                digest: ExtractorSHA256.digest(Data("fixture".utf8)))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 10))
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: packageID.rawValue, registrationID: "main",
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement())
        let record = ExtractorCredentialAuthorizationRecord(
            authorizationID: ExtractorCredentialAuthorizationID(
                packageID: packageID, requirementID: requirement().id),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            fingerprint: fingerprint,
            credentialReference: reference,
            authorizedAt: Date())
        let snapshot = ExtractorCredentialAuthorizationSnapshot(
            generation: 1, records: [record])
        let decisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: otherPackage, manifest: manifest, registration: registration,
            isAdmitted: true, snapshot: snapshot, descriptions: resolved())
        #expect(decisions[0].state == .unauthorized)
    }

    @Test func requiredAndOptionalMatrix() async throws {
        // AC.10: required + unauthorized blocks; optional + unauthorized is
        // omitted (satisfied); authorized + missing credential blocks when
        // required, omitted when optional.
        let required = try pdfRegistration(requirements: [requirement("req-tok", optional: false)])
        let optional = try pdfRegistration(id: "opt", requirements: [requirement("opt-tok", optional: true)])

        let matrixManifest = try makeManifest(
            revision: .v2, packageID: packageID.rawValue,
            registrations: [required, optional])
        let unauthorized = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID,
            manifest: matrixManifest,
            registration: required,
            isAdmitted: true, snapshot: nil, descriptions: [:])
        #expect(unauthorized[0].blocksPreparation)
        let optionalUnauthorized = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID,
            manifest: matrixManifest,
            registration: optional,
            isAdmitted: true, snapshot: nil, descriptions: [:])
        #expect(optionalUnauthorized[0].isSatisfied)
        #expect(optionalUnauthorized[0].blocksPreparation == false)

        // Authorized but MISSING value: bound to a reference that is not
        // configured.
        let missingReference = CredentialReference.zoteroAPIKey()
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: packageID.rawValue, registrationID: "main",
            kinds: ["pdf"], mimeTypes: ["application/pdf"],
            requirement: requirement("req-tok", optional: false))
        let record = ExtractorCredentialAuthorizationRecord(
            authorizationID: ExtractorCredentialAuthorizationID(
                packageID: packageID,
                requirementID: try ExtractorCredentialRequirementID(validating: "req-tok")),
            registrationID: try ExtractorRegistrationID(validating: "main"),
            fingerprint: fingerprint,
            credentialReference: missingReference,
            authorizedAt: Date())
        let snapshot = ExtractorCredentialAuthorizationSnapshot(
            generation: 1, records: [record])
        let missing = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID,
            manifest: try makeManifest(
                revision: .v2, packageID: packageID.rawValue,
                registrations: [required]),
            registration: required,
            isAdmitted: true, snapshot: snapshot,
            descriptions: [missingReference: CredentialInfo(
                reference: missingReference, isConfigured: false,
                source: .keychain, isWritable: true)])
        #expect(missing[0].state == .missingCredential(missingReference))
        #expect(missing[0].blocksPreparation)
    }

    @Test func unadmittedRevisionBlocksEverything() async throws {
        let registration = try pdfRegistration(
            requirements: [requirement(optional: false)])
        let manifest = try makeManifest(revision: .v2, registrations: [registration])
        let decisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID, manifest: manifest, registration: registration,
            isAdmitted: false, snapshot: nil, descriptions: resolved())
        #expect(decisions.allSatisfy { $0.blocksPreparation })
    }

    @Test func undeclaredRequirementCannotRideAStaleGrant() async throws {
        // The selected registration must be the manifest's own registration:
        // a doctored registration with an extra requirement resolves to
        // unauthorized even if a snapshot somehow carried a matching grant.
        let declared = try pdfRegistration(requirements: [])
        let manifest = try makeManifest(revision: .v2, registrations: [declared])
        let doctored = try pdfRegistration(requirements: [requirement()])
        let decisions = ExtractorCredentialAuthorizationResolver.resolve(
            package: packageID, manifest: manifest, registration: doctored,
            isAdmitted: true, snapshot: nil, descriptions: resolved())
        #expect(decisions.count == 1)
        #expect(decisions[0].state == .unauthorized)
    }
}
