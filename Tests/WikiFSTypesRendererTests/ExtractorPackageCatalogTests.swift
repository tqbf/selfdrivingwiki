import Foundation
import Testing
import WikiFSTypes

struct ExtractorPackageCatalogTests {
    @Test func recordPreservesExactValidatedMetadata() throws {
        let manifest = try makeManifest(version: "1.2.3", byte: 1)
        let revision = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())
        let record = try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: revision,
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)))

        #expect(record.revision == revision)
        #expect(record.registrations == manifest.registrations)
        #expect(record.protocolRevision == .v1)
        #expect(record.admissionDiagnostics.isEmpty)
    }

    @Test func replacingIncrementsGenerationAndSortsRecords() throws {
        let later = try makeRecord(version: "2.0.0", byte: 2)
        let earlier = try makeRecord(version: "1.0.0", byte: 1)
        let initial = try ExtractorPackageCatalog()
        let next = try initial.replacing(records: [later, earlier])

        #expect(next.generation == 1)
        #expect(next.records.map(\.revision.version.rawValue) == ["1.0.0", "2.0.0"])
    }

    @Test func duplicateAndConflictingReservationsAreRejected() throws {
        let first = try makeRecord(version: "1.0.0", byte: 1)
        #expect(throws: ExtractorPackageCatalogError.duplicateRevision) {
            _ = try ExtractorPackageCatalog(records: [first, first])
        }

        let conflict = try makeRecord(version: "1.0.0", byte: 2)
        #expect(throws: ExtractorPackageCatalogError.conflictingRevision) {
            _ = try ExtractorPackageCatalog(records: [first, conflict])
        }
    }

    @Test func decodingReappliesCatalogAndDiagnosticValidation() throws {
        let valid = try ExtractorPackageCatalog(records: [makeRecord(version: "1.0.0", byte: 1)])
        let encoded = try JSONEncoder().encode(valid)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ExtractorPackageCatalogError.unsupportedSchemaVersion) {
            _ = try JSONDecoder().decode(ExtractorPackageCatalog.self, from: unsupported)
        }

        object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        object["records"] = records + records
        let duplicate = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ExtractorPackageCatalogError.duplicateRevision) {
            _ = try JSONDecoder().decode(ExtractorPackageCatalog.self, from: duplicate)
        }

        let diagnostic = Data(#"{"message":"failed at /private/package"}"#.utf8)
        #expect(throws: ExtractorPackageCatalogError.invalidDiagnostic) {
            _ = try JSONDecoder().decode(ExtractorPackageAdmissionDiagnostic.self, from: diagnostic)
        }
    }

    @Test func generationOverflowIsRejected() throws {
        let catalog = try ExtractorPackageCatalog(generation: UInt64.max)
        #expect(throws: ExtractorPackageCatalogError.generationOverflow) {
            _ = try catalog.replacing(records: [])
        }
    }

    @Test func replacementPreservesImmutableDigestReservations() throws {
        let record = try makeRecord(version: "1.0.0", byte: 1)
        let installed = try ExtractorPackageCatalog(records: [record])
        let removed = try installed.replacing(records: [])

        #expect(removed.records.isEmpty)
        #expect(removed.reservations == [
            ExtractorPackageReservationRecord(
                reservation: ExtractorPackageReservation(
                    packageID: record.revision.packageID,
                    version: record.revision.version),
                digest: record.revision.digest)
        ])

        let conflicting = try makeRecord(version: "1.0.0", byte: 2)
        #expect(throws: ExtractorPackageCatalogError.conflictingRevision) {
            _ = try removed.replacing(records: [conflicting])
        }
    }

    @Test func duplicateReservationRecordsAreRejected() throws {
        let record = try makeRecord(version: "1.0.0", byte: 1)
        let reservation = ExtractorPackageReservationRecord(
            reservation: ExtractorPackageReservation(
                packageID: record.revision.packageID,
                version: record.revision.version),
            digest: record.revision.digest)
        #expect(throws: ExtractorPackageCatalogError.duplicateReservation) {
            _ = try ExtractorPackageCatalog(reservations: [reservation, reservation])
        }
    }

    @Test func diagnosticRejectsPathsAndExcessText() throws {
        #expect(throws: ExtractorPackageCatalogError.invalidDiagnostic) {
            _ = try ExtractorPackageAdmissionDiagnostic(message: "failed at /private/package")
        }
        #expect(throws: ExtractorPackageCatalogError.invalidDiagnostic) {
            _ = try ExtractorPackageAdmissionDiagnostic(
                message: String(repeating: "x", count: ExtractorPackageAdmissionDiagnostic.maximumMessageByteCount + 1))
        }
        #expect(try ExtractorPackageAdmissionDiagnostic(message: "entry point mode changed").message == "entry point mode changed")
    }

    private func makeRecord(version: String, byte: UInt8) throws -> ExtractorPackageCatalogRecord {
        let manifest = try makeManifest(version: version, byte: byte)
        return try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: ExtractorPackageRevisionID(
                packageID: manifest.packageID,
                version: manifest.version,
                digest: manifest.packageDigest()),
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func makeManifest(version: String, byte: UInt8) throws -> ExtractorManifest {
        let entry = ExtractorPackageFile(
            path: try ExtractorRelativePath(validating: "bin/extractor"),
            digest: try ExtractorPackageDigest(bytes: Array(repeating: byte, count: 32)))
        let registration = try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "pdf"),
            displayName: "PDF",
            kinds: [.pdf],
            mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
            filenameExtensions: [ExtractorFileExtension(validating: "pdf")])
        return try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.extractor"),
            version: ExtractorPackageVersion(validating: version),
            displayName: "Example Extractor",
            protocolRevision: .v1,
            entryPoint: entry.path,
            launch: .direct,
            registrations: [registration],
            capabilities: [],
            files: [entry],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 20))
    }

    /// A manifest-revision-1 package with protocol revision 3 is the reviewed
    /// podcast transcript shape: a new kind is registration data, not a new
    /// manifest field. Its catalog record round-trips with the explicit
    /// manifest revision persisted.
    @Test func manifestOneProtocolThreeRecordRoundTrips() throws {
        let manifest = try makeManifest(version: "3.0.0", byte: 3, protocolRevision: .v3)
        let revision = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())
        let record = try ExtractorPackageCatalogRecord(
            validatedManifest: manifest,
            revision: revision,
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)))

        #expect(record.manifestRevision == .v1)
        #expect(record.protocolRevision == .v3)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ExtractorPackageCatalogRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.manifestRevision == .v1)
        #expect(decoded.protocolRevision == .v3)
        #expect(decoded.registrations == manifest.registrations)

        // The whole catalog stays readable with such a record inside.
        let catalog = try ExtractorPackageCatalog(records: [record])
        let catalogDecoded = try JSONDecoder().decode(
            ExtractorPackageCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(catalogDecoded.records == [record])
    }

    /// Records written before `manifestRevision` was persisted carry only the
    /// protocol revision; decoding derives the manifest revision exactly as
    /// before, so an older host's catalog stays readable.
    @Test func legacyRecordWithoutManifestRevisionFieldDerivesIt() throws {
        let record = try makeRecord(version: "1.2.3", byte: 4)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "manifestRevision")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ExtractorPackageCatalogRecord.self, from: legacyBytes)
        #expect(decoded == record)
        #expect(decoded.manifestRevision == record.manifestRevision)
    }

    private func makeManifest(
        version: String,
        byte: UInt8,
        protocolRevision: ExtractorProtocolRevision = .v1
    ) throws -> ExtractorManifest {
        let entry = ExtractorPackageFile(
            path: try ExtractorRelativePath(validating: "bin/extractor"),
            digest: try ExtractorPackageDigest(bytes: Array(repeating: byte, count: 32)))
        let registration: ExtractorRegistration
        if protocolRevision == .v3 {
            registration = try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "feed"),
                displayName: "RSS Podcast Transcript",
                kinds: [.podcastTranscript],
                mimeTypes: [ExtractorMIMEType(validating: "audio/podcast")])
        } else {
            registration = try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
                filenameExtensions: [ExtractorFileExtension(validating: "pdf")])
        }
        return try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.extractor"),
            version: ExtractorPackageVersion(validating: version),
            displayName: "Example Extractor",
            protocolRevision: protocolRevision,
            entryPoint: entry.path,
            launch: .direct,
            registrations: [registration],
            capabilities: protocolRevision == .v3 ? [.network] : [],
            files: [entry],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 20))
    }
}
