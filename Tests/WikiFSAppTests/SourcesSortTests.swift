#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for `SourcesContainerView.SourceSortOrder.sorted` — the pure display
/// sort for the Sources sidebar list. `lastUpdated` is the store's native
/// `ORDER BY updated_at DESC` order and the default; equal keys tie-break on
/// `id.rawValue` (a ULID, monotonic by ingest time).
@Suite struct SourcesSortTests {

    private func source(
        _ id: String,
        name: String,
        createdAt: Date,
        updatedAt: Date
    ) -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: id),
            filename: "\(id).pdf",
            ext: "pdf",
            mimeType: "application/pdf",
            byteSize: 10,
            createdAt: createdAt,
            updatedAt: updatedAt,
            version: 1,
            displayName: name)
    }

    private static let epoch = Date(timeIntervalSince1970: 0)

    @Test func lastUpdatedSortsByUpdatedAtDescending() {
        let sources = [
            source("a", name: "Alpha", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 100)),
            source("b", name: "Beta", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 300)),
            source("c", name: "Gamma", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 200)),
        ]
        let result = SourcesContainerView.SourceSortOrder.lastUpdated.sorted(sources)
        #expect(result.map { $0.id.rawValue } == ["b", "c", "a"])
    }

    @Test func newestFirstSortsByCreatedAtDescending() {
        let sources = [
            source("a", name: "Alpha", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Self.epoch),
            source("b", name: "Beta", createdAt: Date(timeIntervalSince1970: 300), updatedAt: Self.epoch),
            source("c", name: "Gamma", createdAt: Date(timeIntervalSince1970: 200), updatedAt: Self.epoch),
        ]
        let result = SourcesContainerView.SourceSortOrder.newestFirst.sorted(sources)
        #expect(result.map { $0.id.rawValue } == ["b", "c", "a"])
    }

    @Test func titleAZSortsByEffectiveNameCaseInsensitively() {
        // displayName participates via effectiveName and wins over filename.
        let renamed = SourceSummary(
            id: SourceID(rawValue: "r"),
            filename: "renamed-file.pdf",
            ext: "pdf",
            mimeType: nil,
            byteSize: 10,
            createdAt: Self.epoch,
            updatedAt: Self.epoch,
            version: 1,
            displayName: "Zebra Report")
        let sources = [
            source("c", name: "charlie", createdAt: Self.epoch, updatedAt: Self.epoch),
            source("a", name: "Alpha", createdAt: Self.epoch, updatedAt: Self.epoch),
            renamed,
        ]
        let result = SourcesContainerView.SourceSortOrder.titleAZ.sorted(sources)
        // Alpha, charlie, then the renamed "Zebra Report" (displayName wins).
        #expect(result.map { $0.effectiveName } == ["Alpha", "charlie", "Zebra Report"])
    }

    @Test func equalUpdatedAtTieBreaksOnID() {
        let stamp = Date(timeIntervalSince1970: 500)
        let sources = [
            source("b", name: "Beta", createdAt: Self.epoch, updatedAt: stamp),
            source("a", name: "Alpha", createdAt: Self.epoch, updatedAt: stamp),
        ]
        let result = SourcesContainerView.SourceSortOrder.lastUpdated.sorted(sources)
        #expect(result.map { $0.id.rawValue } == ["a", "b"])
    }

    @Test func lastUpdatedMatchesStoreOrder() {
        // The default order must reproduce the store's
        // `ORDER BY updated_at DESC` exactly — today's behavior.
        let sources = [
            source("old", name: "Old", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 10)),
            source("new", name: "New", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 90)),
            source("mid", name: "Mid", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 50)),
        ]
        let result = SourcesContainerView.SourceSortOrder.lastUpdated.sorted(sources)
        #expect(result.map { $0.id.rawValue } == ["new", "mid", "old"])
    }
}
#endif
