import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Behavioral tests for the `SourceVersionID` boundary: live creation paths,
/// lineage, fallback selection, rollback semantics, and historical retention.
struct SourceVersionStoreTests {

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDatabaseURL(prefix: String) throws -> URL {
        let directory = repositoryRoot()
            .appendingPathComponent("tmp/\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore(prefix: String = "source-version-store") throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: temporaryDatabaseURL(prefix: prefix))
    }

    private func sourceProvenance(_ path: String) -> SourceProvenance {
        SourceProvenance(
            agentName: "website",
            activityKind: "fetch",
            plan: path,
            externalRef: path,
            externalIdentity: path
        )
    }

    @Test func liveCreationPathsUseSourceVersionIDAndBindRawValues() throws {
        let store = try tempStore()

        let regular = try store.addSource(filename: "regular.txt", data: Data("v1".utf8))
        let regularV1 = try #require(try store.activeContentVersion(sourceID: regular.id))
        #expect(regularV1.parentID == nil)
        #expect(store.scalarText(
            "SELECT version_id FROM refs WHERE kind = 'source-content' AND owner_id = '\(regular.id.rawValue)';"
        ) == regularV1.id.rawValue)

        let regularV2 = try store.appendContentVersion(sourceID: regular.id, data: Data("v2".utf8))
        #expect(regularV2.parentID == regularV1.id)
        #expect(store.scalarText(
            "SELECT parent_id FROM source_versions WHERE id = '\(regularV2.id.rawValue)';"
        ) == regularV1.id.rawValue)
        #expect(store.scalarText(
            "SELECT version_id FROM refs WHERE kind = 'source-content' AND owner_id = '\(regular.id.rawValue)';"
        ) == regularV2.id.rawValue)

        let byteless = try store.addBytelessSource(
            filename: "episode.md",
            mimeType: "text/markdown",
            provenance: sourceProvenance("https://example.com/episode"),
            role: .primary
        )
        let bytelessV1 = try #require(try store.activeContentVersion(sourceID: byteless.id))
        #expect(bytelessV1.parentID == nil)
        #expect(store.scalarText(
            "SELECT id FROM source_versions WHERE source_id = '\(byteless.id.rawValue)';"
        ) == bytelessV1.id.rawValue)

        let snapshotActivity = try store.ensureFetchActivity(
            provenance: SourceProvenance(agentName: "website", activityKind: "fetch")
        )
        let snapshot = try store.addSnapshotImage(
            filename: "child.png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            originalPath: "images/child.png",
            sourceURL: URL(string: "https://example.com/images/child.png")!,
            activityID: snapshotActivity,
            role: .media
        )
        let snapshotV1 = try #require(try store.activeContentVersion(sourceID: snapshot.id))
        #expect(snapshotV1.parentID == nil)
        #expect(store.scalarText(
            "SELECT id FROM source_versions WHERE source_id = '\(snapshot.id.rawValue)';"
        ) == snapshotV1.id.rawValue)
    }

    @Test func contentVersionHistoryPreservesLineageNewestFirst() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "history.txt", data: Data("v1".utf8))
        let v1 = try #require(try store.activeContentVersion(sourceID: source.id))
        let v2 = try store.appendContentVersion(sourceID: source.id, data: Data("v2".utf8))
        let v3 = try store.appendContentVersion(sourceID: source.id, data: Data("v3".utf8))

        let history = try store.contentVersionHistory(sourceID: source.id)
        #expect(history.map(\.id) == [v3.id, v2.id, v1.id])
        #expect(history[0].parentID == v2.id)
        #expect(history[1].parentID == v1.id)
        #expect(history[2].parentID == nil)
        #expect(try store.activeContentVersion(sourceID: source.id)?.id == v3.id)
        #expect(store.scalarText(
            "SELECT version_id FROM refs WHERE kind = 'source-content' AND owner_id = '\(source.id.rawValue)';"
        ) == v3.id.rawValue)
    }

    @Test func activeContentVersionFallsBackToMaxIDWhenSourceRefIsMissing() throws {
        let databaseURL = try temporaryDatabaseURL(prefix: "source-version-max-fallback")
        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let source = try store.addSource(filename: "fallback.txt", data: Data("v1".utf8))
        _ = try #require(try store.activeContentVersion(sourceID: source.id))
        let latest = try store.appendContentVersion(sourceID: source.id, data: Data("v2".utf8))
        store.close()

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(
            database,
            "DELETE FROM refs WHERE kind = 'source-content' AND owner_id = '\(source.id.rawValue)';",
            nil,
            nil,
            nil
        ) == SQLITE_OK)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(try reopened.activeContentVersion(sourceID: source.id)?.id == latest.id)
        #expect(try reopened.sourceOrigin(sourceID: source.id)?.versionID == latest.id)
    }

    @Test func rollbackSourceContentRequiresVersionOwnedBySource() throws {
        let store = try tempStore()
        let first = try store.addSource(filename: "first.txt", data: Data("one".utf8))
        let second = try store.addSource(filename: "second.txt", data: Data("two".utf8))
        let foreignVersion = try #require(try store.activeContentVersion(sourceID: second.id))

        do {
            try store.rollbackSourceContent(sourceID: first.id, to: foreignVersion.id)
            Issue.record("expected rollbackSourceContent to reject a foreign source version")
        } catch let error as WikiStoreError {
            switch error {
            case .sourceVersionNotFound(let missingID):
                #expect(missingID == foreignVersion.id)
            default:
                Issue.record("unexpected rollback error: \(error)")
            }
        }
    }

    @Test func rollbackSourceContentMissingVersionThrowsTypedError() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "missing.txt", data: Data("seed".utf8))
        let missing = SourceVersionID(rawValue: "01JMISSINGSOURCEVERSION000000")

        do {
            try store.rollbackSourceContent(sourceID: source.id, to: missing)
            Issue.record("expected rollbackSourceContent to throw sourceVersionNotFound")
        } catch let error as WikiStoreError {
            switch error {
            case .sourceVersionNotFound(let missingID):
                #expect(missingID == missing)
            default:
                Issue.record("unexpected rollback error: \(error)")
            }
        }
    }

    @Test func rollbackSourceContentMovesActiveRefWithoutDeletingHistory() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "rollback.txt", data: Data("v1".utf8))
        let v1 = try #require(try store.activeContentVersion(sourceID: source.id))
        let v2 = try store.appendContentVersion(sourceID: source.id, data: Data("v2".utf8))

        try store.rollbackSourceContent(sourceID: source.id, to: v1.id)

        #expect(try store.activeContentVersion(sourceID: source.id)?.id == v1.id)
        #expect(try store.sourceContent(id: source.id) == Data("v1".utf8))
        #expect(try store.contentVersionHistory(sourceID: source.id).map(\.id) == [v2.id, v1.id])
        #expect(store.scalarText(
            "SELECT version_id FROM refs WHERE kind = 'source-content' AND owner_id = '\(source.id.rawValue)';"
        ) == v1.id.rawValue)
    }

    @Test func sourceOriginAndExtractionProvenanceCarrySourceVersionID() throws {
        let store = try tempStore()
        let source = try store.addSource(
            filename: "origin.html",
            data: Data("<html>v1</html>".utf8),
            zoteroItemKey: nil,
            zoteroItemTitle: nil,
            mimeType: "text/html",
            provenance: sourceProvenance("https://example.com/origin")
        )
        let sourceVersion = try #require(try store.activeContentVersion(sourceID: source.id))
        let markdown = try store.recordMarkdownExtraction(
            sourceID: source.id,
            content: "# extracted",
            backend: .anthropic,
            sourceVersionID: sourceVersion.id,
            note: "explicit provenance",
            modelVersion: "claude-x"
        )

        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        let history = try store.sourceEditHistory(sourceID: source.id)
        let markdownHead = try #require(try store.processedMarkdownHead(sourceID: source.id))
        let agentNames = try store.processedMarkdownAgentNames(sourceID: source.id)

        #expect(origin.versionID == sourceVersion.id)
        #expect(origin.agentName == "website")
        #expect(history.first?.versionID == sourceVersion.id)
        #expect(markdown.sourceVersionID == sourceVersion.id)
        #expect(markdownHead.sourceVersionID == sourceVersion.id)
        #expect(agentNames[markdown.id.rawValue] == "claude")
        #expect(store.scalarText(
            "SELECT source_version_id FROM source_markdown_versions WHERE id = '\(markdown.id.rawValue)';"
        ) == sourceVersion.id.rawValue)
    }

    @Test func vacuumBlobsRetainsHistoricalSourceVersionBlobs() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "vacuum-blobs.txt", data: Data("v1".utf8))
        let v1 = try #require(try store.activeContentVersion(sourceID: source.id))
        let v2 = try store.appendContentVersion(sourceID: source.id, data: Data("v2".utf8))

        let report = try store.vacuumBlobs(dryRun: false)
        #expect(report.orphanCount == 0)

        try store.rollbackSourceContent(sourceID: source.id, to: v1.id)
        #expect(try store.sourceContent(id: source.id) == Data("v1".utf8))
        #expect(try store.contentVersionHistory(sourceID: source.id).map(\.id) == [v2.id, v1.id])
    }

    @Test func vacuumActivitiesRetainsHistoricalSourceVersionActivities() throws {
        let store = try tempStore()
        let source = try store.addSource(
            filename: "vacuum-activities.txt",
            data: Data("v1".utf8),
            zoteroItemKey: nil,
            zoteroItemTitle: nil,
            mimeType: "text/plain",
            provenance: sourceProvenance("https://example.com/v1")
        )
        let v1 = try #require(try store.activeContentVersion(sourceID: source.id))
        let v2 = try store.appendContentVersion(
            sourceID: source.id,
            data: Data("v2".utf8),
            provenance: sourceProvenance("https://example.com/v2")
        )
        let historyBefore = try store.contentVersionHistory(sourceID: source.id)
        let activityIDs = historyBefore.compactMap(\.activityID)
        let report = try store.vacuumActivities(dryRun: false)

        #expect(report.orphanCount == 0)
        let quotedIDs = activityIDs.map { "'\($0)'" }.joined(separator: ", ")
        #expect(store.scalarText(
            "SELECT COUNT(*) FROM activities WHERE id IN (\(quotedIDs));"
        ) == "\(activityIDs.count)")
        let historyAfter = try store.sourceEditHistory(sourceID: source.id)
        #expect(historyAfter.map(\.versionID) == [v2.id, v1.id])
        #expect(historyAfter.allSatisfy { $0.agentName == "website" })
    }
}
