import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

// Manifest revision 3 coverage: the registration-scoped `sync` declaration
// (package-declared acquisition syncability). Validation bounds, key-policy
// compatibility for revisions 1–2, canonical-byte stability, catalog record
// round-trip, and the unknown-revision read tolerance.

private func makeManifest(
    revision: ExtractorManifestRevision,
    registrations: [ExtractorRegistration]
) throws -> ExtractorManifest {
    try ExtractorManifest(
        manifestRevision: revision,
        packageID: ExtractorPackageID(validating: "org.example.fixture"),
        version: ExtractorPackageVersion(validating: "1.0.0"),
        displayName: "Fixture",
        protocolRevision: .v1,
        entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
        launch: .direct,
        registrations: registrations,
        capabilities: [],
        files: [ExtractorPackageFile(
            path: ExtractorRelativePath(validating: "bin/extractor"),
            digest: ExtractorSHA256.digest(Data("fixture".utf8)))],
        limits: try ExtractorOperationLimits(
            maximumInputByteCount: 1024,
            maximumMarkdownOutputByteCount: 1024,
            maximumDurationMilliseconds: 10_000,
            maximumProgressEventCount: 10))
}

private func syncDeclaration(
    template: String = "https://api.example.org/users/{libraryID}/items/{itemKey}/file",
    fields: [ExtractorSyncFieldDeclaration]? = nil,
    itemValidation: ExtractorSyncItemValidation? = nil,
    sourceMIMEType: ExtractorMIMEType? = nil
) throws -> ExtractorSyncDeclaration {
    try ExtractorSyncDeclaration(
        configFileName: "fixture-config.json",
        urlTemplate: template,
        fields: fields ?? [
            ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
            ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
        ],
        itemValidation: itemValidation,
        sourceMIMEType: sourceMIMEType)
}

private func attachmentRegistration(
    sync: ExtractorSyncDeclaration? = nil,
    requirements: [ExtractorCredentialRequirement] = [],
    mimeTypes: [ExtractorMIMEType]? = nil
) throws -> ExtractorRegistration {
    try ExtractorRegistration(
        id: ExtractorRegistrationID(validating: "attachment"),
        displayName: "Fixture Attachment",
        kinds: [.pdf],
        mimeTypes: Set(try mimeTypes ?? [ExtractorMIMEType(validating: "application/x-fixture")]),
        credentialRequirements: requirements,
        sync: sync)
}

private func requirement(
    _ id: String = "api-token",
    optional: Bool = false
) -> ExtractorCredentialRequirement {
    try! ExtractorCredentialRequirement(
        id: ExtractorCredentialRequirementID(validating: id),
        kind: .secret,
        isOptional: optional,
        label: "API token",
        purpose: "Authenticates requests to the service.")
}

@Suite("Extractor sync declaration (manifest revision 3)")
struct ExtractorSyncDeclarationTests {

    // MARK: - Revision 3 decode/encode

    @Test func revisionThreeSyncDeclarationRoundTrips() throws {
        let declaration = try syncDeclaration(
            itemValidation: try ExtractorSyncItemValidation(
                minimumLength: 8, maximumLength: 8,
                alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        let manifest = try makeManifest(revision: .v3, registrations: [
            try attachmentRegistration(sync: declaration),
        ])
        let decoded = try JSONDecoder().decode(
            ExtractorManifest.self, from: try JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
        #expect(decoded.registrations.first?.sync == declaration)
        // Canonical bytes are stable across calls.
        #expect(try manifest.canonicalJSON() == manifest.canonicalJSON())
    }

    @Test func revisionTwoManifestJSONRejectsTheSyncKey() throws {
        // A v2 manifest carrying a `sync` key is rejected by the
        // unknown-field policy — syncability is a revision-3 fact.
        let v3 = try makeManifest(revision: .v3, registrations: [
            try attachmentRegistration(sync: syncDeclaration()),
        ])
        let data = try JSONEncoder().encode(v3)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["manifestRevision"] = 2
        let v2Bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ExtractorValidationError.self) {
            _ = try JSONDecoder().decode(ExtractorManifest.self, from: v2Bytes)
        }
    }

    @Test func revisionOneAndTwoConstructionRejectsSyncDeclarations() {
        // The in-memory guard mirrors the JSON key policy: only revision 3
        // can carry a sync declaration.
        #expect(throws: ExtractorValidationError.self) {
            _ = try makeManifest(revision: .v2, registrations: [
                try attachmentRegistration(sync: syncDeclaration()),
            ])
        }
        #expect(throws: ExtractorValidationError.self) {
            _ = try makeManifest(revision: .v1, registrations: [
                try attachmentRegistration(sync: syncDeclaration()),
            ])
        }
    }

    @Test func revisionThreeWithoutSyncRemainsValid() throws {
        // Revision 3 is backward-compatible: registrations without a sync
        // declaration decode exactly as revision 2 ones do.
        let manifest = try makeManifest(revision: .v3, registrations: [
            try attachmentRegistration(requirements: [requirement()]),
        ])
        #expect(manifest.registrations.first?.sync == nil)
        let decoded = try JSONDecoder().decode(
            ExtractorManifest.self, from: try JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
    }

    // MARK: - Canonical bytes (compat)

    @Test func revisionTwoCanonicalBytesAndDigestsRemainStable() throws {
        // Load-bearing compat pin: adding the revision-3 `sync` key must not
        // change revision-2 canonical bytes or package digests, or every
        // reviewed package's golden digest drifts. The digest below is the
        // literal golden value captured on the pre-revision-3 substrate and
        // re-verified after the change — byte-for-byte identical.
        let v2 = try makeManifest(revision: .v2, registrations: [
            try attachmentRegistration(requirements: [requirement()]),
        ])
        #expect(try v2.packageDigest().hex == "84389199d181a2266346e2fa5ccebadb81b85d71d11a0e14424e900a8798c34b")
        // Round-tripping through encode/decode preserves the digest.
        let decoded = try JSONDecoder().decode(
            ExtractorManifest.self, from: try JSONEncoder().encode(v2))
        #expect(try decoded.packageDigest() == v2.packageDigest())
    }

    // MARK: - Declaration validation

    @Test func templatePlaceholderRules() {
        // Undeclared placeholder.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(
                template: "https://api.example.org/{libraryID}/{unknown}/{itemKey}")
        }
        // Missing {itemKey}: every item would produce the same URL.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(
                template: "https://api.example.org/users/{libraryID}/items/file")
        }
        // Duplicate {itemKey}.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(
                template: "https://api.example.org/{itemKey}/{itemKey}")
        }
        // Malformed braces.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(template: "https://api.example.org/{libraryID")
        }
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(template: "https://api.example.org/}libraryID{")
        }
        // Not HTTPS.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(
                template: "http://api.example.org/users/{libraryID}/items/{itemKey}")
        }
        // Not absolute.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(
                template: "/users/{libraryID}/items/{itemKey}")
        }
    }

    @Test func fieldRules() {
        // Duplicate field names.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "libraryID", required: false, isList: true),
            ])
        }
        // No list field: the sync has nothing to iterate.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
            ])
        }
        // Two list fields.
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(fields: [
                ExtractorSyncFieldDeclaration(name: "libraryID", required: true),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
                ExtractorSyncFieldDeclaration(name: "more", required: true, isList: true),
            ])
        }
        // Invalid field name (hyphen is not part of the field grammar).
        #expect(throws: ExtractorValidationError.self) {
            _ = try syncDeclaration(fields: [
                ExtractorSyncFieldDeclaration(name: "library-id", required: true),
                ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
            ])
        }
    }

    @Test func patternRules() throws {
        // A non-compiling pattern is rejected at decode time.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorSyncFieldDeclaration(
                name: "libraryID", required: true, pattern: "[unclosed")
        }
        // An oversize pattern is rejected by host policy.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorSyncFieldDeclaration(
                name: "libraryID", required: true,
                pattern: String(repeating: "a", count: ExtractorHostLimits.maximumSyncPatternByteCount + 1))
        }
        // A compiling pattern is accepted and round-trips.
        let field = try ExtractorSyncFieldDeclaration(
            name: "libraryID", required: true, pattern: "^[0-9]{1,10}$")
        let declaration = try syncDeclaration(fields: [
            field,
            ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true),
        ])
        let decoded = try JSONDecoder().decode(
            ExtractorSyncDeclaration.self, from: try JSONEncoder().encode(declaration))
        #expect(decoded == declaration)
    }

    @Test func itemValidationRules() throws {
        // Both alphabet and pattern is ambiguous — rejected.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorSyncItemValidation(
                minimumLength: 1, maximumLength: 8,
                alphabet: "AB", pattern: "^A")
        }
        // Nonsense length bounds.
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorSyncItemValidation(minimumLength: 0, maximumLength: 8, alphabet: "AB")
        }
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorSyncItemValidation(
                minimumLength: 4, maximumLength: 2, alphabet: "AB")
        }
        // Length-only validation is allowed (no alphabet, no pattern).
        let lengthOnly = try ExtractorSyncItemValidation(minimumLength: 1, maximumLength: 64)
        #expect(lengthOnly.alphabet == nil && lengthOnly.pattern == nil)
    }

    @Test func configFileNameRules() {
        for name in ["", "nested/config.json", "back\\slash.json", ".", ".."] {
            #expect(throws: ExtractorValidationError.self) {
                _ = try ExtractorSyncDeclaration(
                    configFileName: name,
                    urlTemplate: "https://api.example.org/{itemKey}",
                    fields: [ExtractorSyncFieldDeclaration(name: "items", required: true, isList: true)])
            }
        }
    }

    @Test func sourceMIMEDefaultRequiresExactlyOneRegistrationMIME() throws {
        // Default: the registration's single declared MIME is the source MIME.
        let single = try attachmentRegistration(sync: syncDeclaration())
        #expect(single.sync?.sourceMIMEType == nil)
        // Two registration MIME types require an explicit source MIME.
        #expect(throws: ExtractorValidationError.self) {
            _ = try attachmentRegistration(
                sync: syncDeclaration(),
                mimeTypes: [
                    try ExtractorMIMEType(validating: "application/x-fixture-a"),
                    try ExtractorMIMEType(validating: "application/x-fixture-b"),
                ])
        }
        // …unless one is declared explicitly.
        _ = try attachmentRegistration(
            sync: syncDeclaration(
                sourceMIMEType: try ExtractorMIMEType(validating: "application/x-fixture-a")),
            mimeTypes: [
                try ExtractorMIMEType(validating: "application/x-fixture-a"),
                try ExtractorMIMEType(validating: "application/x-fixture-b"),
            ])
    }

    @Test func syncSupportsAtMostOneRequiredCredentialRequirement() throws {
        // Zero required requirements: syncable without the credential gate
        // (the second-package contract — no host-side binding needed).
        _ = try attachmentRegistration(sync: syncDeclaration(), requirements: [])
        // One required requirement: the gate's subject.
        _ = try attachmentRegistration(sync: syncDeclaration(), requirements: [requirement()])
        // Two required requirements: the gate's subject would be ambiguous.
        #expect(throws: ExtractorValidationError.self) {
            _ = try attachmentRegistration(sync: syncDeclaration(), requirements: [
                requirement("api-token"),
                requirement("other-token"),
            ])
        }
        // Optional requirements never gate the sync.
        _ = try attachmentRegistration(sync: syncDeclaration(), requirements: [
            requirement("api-token", optional: true),
            requirement("other-token", optional: true),
        ])
    }

    // MARK: - Catalog round-trip and read tolerance

    @Test func catalogRecordRoundTripsTheSyncDeclaration() throws {
        // Publish → read: the declaration survives the catalog record's
        // persisted-revision decode path.
        let manifest = try makeManifest(revision: .v3, registrations: [
            try attachmentRegistration(
                sync: syncDeclaration(),
                requirements: [requirement()]),
        ])
        let record = try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: ExtractorPackageRevisionID(
                packageID: manifest.packageID,
                version: manifest.version,
                digest: try manifest.packageDigest()),
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
        let catalog = try ExtractorPackageCatalog(records: [record])
        let decoded = try JSONDecoder().decode(
            ExtractorPackageCatalog.self, from: try JSONEncoder().encode(catalog))
        #expect(decoded == catalog)
        #expect(decoded.records.first?.registrations.first?.sync == manifest.registrations.first?.sync)
    }

    @Test func catalogReadSkipsRecordsWithANewerManifestRevision() throws {
        // A record persisted by a newer host (manifest revision this build
        // does not know) must degrade to skipped-with-diagnostic, not
        // corruptCatalog for the whole read.
        let manifest = try makeManifest(revision: .v2, registrations: [
            try attachmentRegistration(requirements: [requirement()]),
        ])
        let known = try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: ExtractorPackageRevisionID(
                packageID: manifest.packageID,
                version: manifest.version,
                digest: try manifest.packageDigest()),
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
        let catalog = try ExtractorPackageCatalog(records: [known])

        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(catalog)) as! [String: Any]
        var records = object["records"] as! [[String: Any]]
        var newer = records[0]
        newer["manifestRevision"] = ExtractorManifestRevision.maximumKnownRawValue + 1
        // A revision this build cannot decode would otherwise poison the
        // array decode; rewrite its registrations to arbitrary bytes too, so
        // the test proves the skip happens before any record decoding.
        newer["registrations"] = [["nonsense": true]]
        records.append(newer)
        object["records"] = records
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ExtractorPackageCatalog.self, from: data)
        #expect(decoded.records.count == 1)
        #expect(decoded.records.first?.revision == known.revision)
        #expect(decoded.skippedUnknownRevisionRecordCount == 1)
    }

    @Test func catalogSkippedRecordCountIsNeverEncoded() throws {
        // The skip count is a read-time observation; a catalog decoded from
        // a file with skips re-encodes to the same bytes as one without.
        // (`.sortedKeys` pins encoder key order: two fresh JSONEncoder
        // instances are otherwise free to order keys independently.)
        let manifest = try makeManifest(revision: .v2, registrations: [
            try attachmentRegistration(requirements: [requirement()]),
        ])
        let record = try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: ExtractorPackageRevisionID(
                packageID: manifest.packageID,
                version: manifest.version,
                digest: try manifest.packageDigest()),
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
        let plain = try ExtractorPackageCatalog(records: [record])
        let skipped = try ExtractorPackageCatalog(
            records: [record], skippedUnknownRevisionRecordCount: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(plain) == encoder.encode(skipped))
    }
}
