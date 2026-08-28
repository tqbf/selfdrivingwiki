import Foundation
import Testing
@testable import WikiFSCore

struct ExtractionActivityPlanCodecTests {
    @Test func currentVersionRoundTripsEveryField() throws {
        let value = ExtractionActivityPlan(
            producer: .backend(.acp), origin: .extraction,
            providerID: ProviderID(rawValue: "acme"), modelID: ModelID(rawValue: "model-1"),
            toolVersion: nil, sourceVersionID: SourceVersionID(rawValue: "source-v1"), note: "queued")
        let decoded = try ExtractionActivityPlanCodec.decode(ExtractionActivityPlanCodec.encode(value))
        #expect(decoded.version == ExtractionActivityPlan.currentVersion)
        #expect(decoded.producer == value.producer)
        #expect(decoded.origin == value.origin)
        #expect(decoded.providerID == value.providerID)
        #expect(decoded.modelID == value.modelID)
        #expect(decoded.sourceVersionID == value.sourceVersionID)
        #expect(decoded.note == value.note)
    }

    @Test func legacyBackendModelShapeDecodes() throws {
        let decoded = try ExtractionActivityPlanCodec.decode(#"{"backend":"gemini","model":"gemini-test"}"#)
        #expect(decoded.producer == .backend(.gemini))
        #expect(decoded.modelID == ModelID(rawValue: "gemini-test"))
        #expect(decoded.origin == .extraction)
    }

    @Test func unsupportedVersionThrowsTypedError() {
        #expect(throws: ExtractionPlanCodecError.unsupportedVersion(9)) {
            _ = try ExtractionActivityPlanCodec.decode(#"{"version":9,"origin":"extraction"}"#)
        }
    }

    @Test func malformedJSONFallsBackAndRetainsNormalizedColumns() throws {
        let fixture = try MetadataSQLiteFixtureSupport.fileURL(prefix: "extraction-plan-fallback")
        let store = try GRDBWikiStore(databaseURL: fixture)
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        store.close()
        let markdownID = SourceMarkdownVersionID(rawValue: "fallback-markdown")
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO agents (id, kind, name, version, external_ref)
        VALUES ('agent', 'software', 'claude', 'model-1', 'anthropic');
        INSERT INTO activities (id, kind, agent_id, plan, started_at, ended_at)
        VALUES ('activity', 'extract', 'agent', '{bad', 1, 1);
        INSERT INTO source_markdown_versions (id, file_id, origin, created_at, activity_id, technique)
        VALUES ('\(markdownID.rawValue)', '\(source.id.rawValue)', 'extraction', 1, 'activity', 'anthropic');
        """, at: fixture)
        let value = try #require(try GRDBWikiStore(databaseURL: fixture)
            .extractionProvenance(markdownVersionID: markdownID))
        #expect(value.producer == .backend(.anthropic))
        #expect(value.providerID == ProviderID(rawValue: "anthropic"))
        #expect(value.modelID == ModelID(rawValue: "model-1"))
    }

    @Test func nilOptionalFieldsRoundTrip() throws {
        let value = ExtractionActivityPlan(producer: .tool(.pdf2md), origin: .extraction)
        let decoded = try ExtractionActivityPlanCodec.decode(ExtractionActivityPlanCodec.encode(value))
        #expect(decoded.providerID == nil)
        #expect(decoded.modelID == nil)
        #expect(decoded.toolVersion == nil)
        #expect(decoded.sourceVersionID == nil)
        #expect(decoded.note == nil)
    }

    @Test func bytelessOEmbedSyntheticToolRoundTrips() throws {
        let value = ExtractionActivityPlan(
            producer: .tool(.bytelessOEmbedSynthetic), origin: .transcript)
        let decoded = try ExtractionActivityPlanCodec.decode(ExtractionActivityPlanCodec.encode(value))
        #expect(decoded.producer == .tool(.bytelessOEmbedSynthetic))
    }

    @Test func installedPackageRoundTripsExactIdentityAndReportedMetadata() throws {
        let package = ExtractionInstalledPackageProducer(
            revision: ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: "org.example.extractor"),
                version: try ExtractorPackageVersion(validating: "2.3.4"),
                digest: try ExtractorPackageDigest(hex: String(repeating: "ab", count: 32))),
            registrationID: try ExtractorRegistrationID(validating: "document"),
            protocolRevision: .v1,
            reportedMetadata: try ExtractorReportedMetadata(
                toolName: "example", toolVersion: "4.5", modelName: "model"))
        let value = ExtractionActivityPlan(
            producer: .installedPackage(package), origin: .extraction,
            toolVersion: "4.5", note: "package extraction")
        let decoded = try ExtractionActivityPlanCodec.decode(
            ExtractionActivityPlanCodec.encode(value))
        #expect(decoded.producer == .installedPackage(package))
        #expect(decoded.toolVersion == "4.5")
        #expect(decoded.note == "package extraction")
    }

    @Test func unknownProducerKindPreservesEveryValidOuterField() throws {
        let json = #"{"version":1,"producer":{"kind":"future-package","payload":{"x":1}},"origin":"extraction","providerID":"provider","modelID":"model","toolVersion":"tool-1","sourceVersionID":"source-v1","note":"keep me"}"#
        let decoded = try ExtractionActivityPlanCodec.decode(json)
        #expect(decoded.producer == nil)
        #expect(decoded.origin == .extraction)
        #expect(decoded.providerID == ProviderID(rawValue: "provider"))
        #expect(decoded.modelID == ModelID(rawValue: "model"))
        #expect(decoded.toolVersion == "tool-1")
        #expect(decoded.sourceVersionID == SourceVersionID(rawValue: "source-v1"))
        #expect(decoded.note == "keep me")
    }

    @Test func malformedInstalledPackagePreservesEveryValidOuterField() throws {
        let json = #"{"version":1,"producer":{"kind":"installedPackage","installedPackage":{"revision":{"packageID":"bad"}}},"origin":"extraction","providerID":"provider","modelID":"model","toolVersion":"tool-1","sourceVersionID":"source-v1","note":"keep me"}"#
        let decoded = try ExtractionActivityPlanCodec.decode(json)
        #expect(decoded.producer == nil)
        #expect(decoded.origin == .extraction)
        #expect(decoded.providerID == ProviderID(rawValue: "provider"))
        #expect(decoded.modelID == ModelID(rawValue: "model"))
        #expect(decoded.toolVersion == "tool-1")
        #expect(decoded.sourceVersionID == SourceVersionID(rawValue: "source-v1"))
        #expect(decoded.note == "keep me")
    }
}
