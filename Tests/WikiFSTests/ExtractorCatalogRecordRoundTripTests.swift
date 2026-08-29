import Foundation
import Testing
import WikiFSTypes

/// Catalog records store registrations as JSON. A record's registrations
/// must decode under the record's own protocol revision: a v2 registration
/// carries credential declarations that the plain v1 decoder rejects. Before
/// the revision-aware record decode, any catalog containing one v2 record
/// (the reviewed Docling Serve package) failed to decode wholesale, which
/// blocked the reconciler and made every extractor route read as
/// Not installed.
@Suite("Extractor catalog record round trip", .serialized)
struct ExtractorCatalogRecordRoundTripTests {
    private static func makeRevision(
        packageID: String,
        version: String,
        digest: String
    ) throws -> ExtractorPackageRevisionID {
        try ExtractorPackageRevisionID(
            packageID: ExtractorPackageID(validating: packageID),
            version: #require(ExtractorPackageVersion(rawValue: version)),
            digest: ExtractorPackageDigest(hex: digest))
    }

    private static func makeRequirement() throws -> ExtractorCredentialRequirement {
        try ExtractorCredentialRequirement(
            id: ExtractorCredentialRequirementID(validating: "api-token"),
            kind: .secret,
            isOptional: true,
            label: "API token",
            purpose: "Sent only when the service requires authentication.")
    }

    private static func makeRegistration(
        requirement: ExtractorCredentialRequirement?
    ) throws -> ExtractorRegistration {
        try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "document"),
            displayName: "Document",
            kinds: [.pdf],
            mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
            credentialRequirements: requirement.map { [$0] } ?? [])
    }

    @Test func v2RecordWithCredentialRequirementsRoundTripsThroughJSON() throws {
        let record = try ExtractorPackageCatalogRecord(
            revision: Self.makeRevision(
                packageID: "org.example.docling",
                version: "1.0.0",
                digest: String(repeating: "a", count: 64)),
            displayName: "Docling Serve",
            protocolRevision: ExtractorProtocolRevision.v2,
            launch: .direct,
            registrations: [try Self.makeRegistration(requirement: Self.makeRequirement())],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ExtractorPackageCatalogRecord.self, from: data)
        let requirementID = try ExtractorCredentialRequirementID(validating: "api-token")

        #expect(decoded.protocolRevision == .v2)
        #expect(decoded.registrations[0].credentialRequirements.count == 1)
        #expect(decoded.registrations[0].credentialRequirements[0].id == requirementID)
    }

    @Test func v1RecordStillRejectsCredentialRequirementsKey() throws {
        // The v1 unknown-field policy stays intact at the record layer: a
        // v1 registration must not smuggle credential declarations.
        let v1Record = try ExtractorPackageCatalogRecord(
            revision: Self.makeRevision(
                packageID: "org.example.v1package",
                version: "1.0.0",
                digest: String(repeating: "b", count: 64)),
            displayName: "v1 Package",
            protocolRevision: ExtractorProtocolRevision.v1,
            launch: .direct,
            registrations: [try Self.makeRegistration(requirement: nil)],
            capabilities: [],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
        var fragment = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v1Record))
            as! [String: Any]
        var registration = try #require(
            (fragment["registrations"] as? [[String: Any]])?.first)
        registration["credentialRequirements"] = [["id": "api-token", "kind": "secret",
            "optional": true, "label": "API token", "purpose": "smuggled"]]
        fragment["registrations"] = [registration]
        let tampered = try JSONSerialization.data(withJSONObject: fragment)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ExtractorPackageCatalogRecord.self, from: tampered)
        }
    }

    @Test func mixedRevisionRecordsEachDecodeUnderTheirOwnRevision() throws {
        let v2 = try ExtractorPackageCatalogRecord(
            revision: Self.makeRevision(
                packageID: "org.example.docling",
                version: "1.0.0",
                digest: String(repeating: "c", count: 64)),
            displayName: "Docling Serve",
            protocolRevision: ExtractorProtocolRevision.v2,
            launch: .direct,
            registrations: [try Self.makeRegistration(requirement: Self.makeRequirement())],
            capabilities: [.network],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))
        let v1 = try ExtractorPackageCatalogRecord(
            revision: Self.makeRevision(
                packageID: "org.example.pdf2md",
                version: "1.0.0",
                digest: String(repeating: "d", count: 64)),
            displayName: "pdf2md",
            protocolRevision: ExtractorProtocolRevision.v1,
            launch: .runtime(
                command: #require(ExtractorRuntimeName(rawValue: "uv")),
                arguments: ["run"]),
            registrations: [try Self.makeRegistration(requirement: nil)],
            capabilities: [],
            installedAt: RFC3339Timestamp(date: Date(timeIntervalSince1970: 0)))

        for original in [v2, v1] {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ExtractorPackageCatalogRecord.self, from: data)
            #expect(decoded == original)
        }
    }
}
