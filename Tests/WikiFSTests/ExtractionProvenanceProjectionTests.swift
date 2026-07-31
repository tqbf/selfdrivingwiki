import Foundation
import Testing
@testable import WikiFSCore

/// Direct projection tests for immutable markdown provenance. These seed the
/// existing PROV tables through SQLite because Phase 1 deliberately adds reads
/// only; Phase 3 owns the canonical writers.
struct ExtractionProvenanceProjectionTests {
    private struct Fixture {
        let url: URL
        let sourceID: SourceID
        let sourceVersionID: SourceVersionID
    }

    private func makeFixture() throws -> Fixture {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "extraction-provenance")
        let store = try GRDBWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "evidence.pdf", data: Data("pdf".utf8))
        store.close()
        let sourceVersionID = SourceVersionID(rawValue: "source-version")
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO source_versions (id, source_id, fetched_at)
        VALUES ('\(sourceVersionID.rawValue)', '\(source.id.rawValue)', 10);
        """, at: url)
        return Fixture(url: url, sourceID: source.id, sourceVersionID: sourceVersionID)
    }

    private func insertAgentActivity(
        _ fixture: Fixture, agentID: String = "agent", activityID: String = "activity",
        provider: String = "anthropic", version: String = "claude-3-7-sonnet"
    ) throws {
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO agents (id, kind, name, version, external_ref)
        VALUES ('\(agentID)', 'software', 'extractor', '\(version)', '\(provider)');
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES ('\(activityID)', 'extract', '\(agentID)', 20, 21);
        """, at: fixture.url)
    }

    private func insertMarkdownVersion(
        _ fixture: Fixture, id: SourceMarkdownVersionID, origin: String = "extraction",
        technique: String?, activityID: String? = nil, sourceVersionID: SourceVersionID? = nil,
        createdAt: Int = 30
    ) throws {
        let techniqueSQL = technique.map { "'\($0)'" } ?? "NULL"
        let activitySQL = activityID.map { "'\($0)'" } ?? "NULL"
        let sourceVersionSQL = sourceVersionID.map { "'\($0.rawValue)'" } ?? "NULL"
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO source_markdown_versions
          (id, file_id, origin, created_at, activity_id, source_version_id, technique)
        VALUES ('\(id.rawValue)', '\(fixture.sourceID.rawValue)', '\(origin)', \(createdAt),
                \(activitySQL), \(sourceVersionSQL), \(techniqueSQL));
        """, at: fixture.url)
    }

    @Test func backendProvenanceProjectsProviderModelAndSourceVersion() throws {
        let fixture = try makeFixture()
        let markdownID = SourceMarkdownVersionID(rawValue: "backend-markdown")
        try insertAgentActivity(fixture)
        try insertMarkdownVersion(
            fixture, id: markdownID, technique: ExtractionBackend.anthropic.rawValue,
            activityID: "activity", sourceVersionID: fixture.sourceVersionID
        )

        let value = try #require(try GRDBWikiStore(databaseURL: fixture.url)
            .extractionProvenance(markdownVersionID: markdownID))
        #expect(value.markdownVersionID == markdownID)
        #expect(value.sourceID == fixture.sourceID)
        #expect(value.origin == .extraction)
        #expect(value.producer == .backend(.anthropic))
        #expect(value.providerID == ProviderID(rawValue: "anthropic"))
        #expect(value.modelID == ModelID(rawValue: "claude-3-7-sonnet"))
        #expect(value.toolVersion == nil)
        #expect(value.createdAt == Date(timeIntervalSince1970: 30))
        #expect(value.sourceVersionID == fixture.sourceVersionID)
    }

    @Test func localToolProvenanceProjectsToolVersionWithoutProviderOrModel() throws {
        let fixture = try makeFixture()
        let markdownID = SourceMarkdownVersionID(rawValue: "tool-markdown")
        try insertAgentActivity(fixture, provider: "not-a-provider", version: "1.2.3")
        try insertMarkdownVersion(fixture, id: markdownID, technique: ExtractionTool.pdf2md.rawValue, activityID: "activity")

        let value = try #require(try GRDBWikiStore(databaseURL: fixture.url)
            .extractionProvenance(markdownVersionID: markdownID))
        #expect(value.producer == .tool(.pdf2md))
        #expect(value.providerID == nil)
        #expect(value.modelID == nil)
        #expect(value.toolVersion == "1.2.3")
    }

    @Test func unknownLegacyTechniqueDoesNotClaimProviderModelOrTool() throws {
        let fixture = try makeFixture()
        let markdownID = SourceMarkdownVersionID(rawValue: "legacy-markdown")
        try insertAgentActivity(fixture)
        try insertMarkdownVersion(fixture, id: markdownID, technique: "historic-pipeline", activityID: "activity")

        let value = try #require(try GRDBWikiStore(databaseURL: fixture.url)
            .extractionProvenance(markdownVersionID: markdownID))
        #expect(value.producer == .legacy(rawTechnique: "historic-pipeline"))
        #expect(value.providerID == nil)
        #expect(value.modelID == nil)
        #expect(value.toolVersion == nil)
    }

    @Test func unknownOriginThrowsTypedCorruption() throws {
        let fixture = try makeFixture()
        let markdownID = SourceMarkdownVersionID(rawValue: "corrupt-origin")
        try insertMarkdownVersion(fixture, id: markdownID, origin: "unknown-origin", technique: nil)

        do {
            _ = try GRDBWikiStore(databaseURL: fixture.url).extractionProvenance(markdownVersionID: markdownID)
            Issue.record("expected unknown source markdown origin")
        } catch let error as WikiStoreError {
            #expect(String(describing: error).contains("unknown source markdown origin"))
        }
    }

    @Test func activeExtractionProvenanceResolvesActiveMarkdownHead() throws {
        let fixture = try makeFixture()
        let activeID = SourceMarkdownVersionID(rawValue: "active-markdown")
        let newerButInactiveID = SourceMarkdownVersionID(rawValue: "newer-markdown")
        try insertAgentActivity(fixture)
        try insertMarkdownVersion(fixture, id: activeID, technique: ExtractionBackend.gemini.rawValue, activityID: "activity")
        try insertMarkdownVersion(fixture, id: newerButInactiveID, technique: ExtractionTool.docling.rawValue, createdAt: 31)
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('source-derived', '\(fixture.sourceID.rawValue)', '\(activeID.rawValue)', 1, 30);
        """, at: fixture.url)

        let value = try #require(try GRDBWikiStore(databaseURL: fixture.url)
            .activeExtractionProvenance(sourceID: fixture.sourceID))
        #expect(value.markdownVersionID == activeID)
        #expect(value.producer == .backend(.gemini))
    }

    @Test func nilActivityAndTechniqueRemainCompatibilityOmission() throws {
        let fixture = try makeFixture()
        let markdownID = SourceMarkdownVersionID(rawValue: "legacy-nil-markdown")
        try insertMarkdownVersion(fixture, id: markdownID, origin: "source", technique: nil)

        let value = try #require(try GRDBWikiStore(databaseURL: fixture.url)
            .extractionProvenance(markdownVersionID: markdownID))
        #expect(value.origin == .source)
        #expect(value.producer == .legacy(rawTechnique: nil))
        #expect(value.providerID == nil)
        #expect(value.modelID == nil)
        #expect(value.toolVersion == nil)
        #expect(value.sourceVersionID == nil)
    }
}
