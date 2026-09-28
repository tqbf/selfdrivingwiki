import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.5/AC.4 — QueueStore-level idempotency for the follow-on format job.
///
/// The typed dedupe key makes the follow-on enqueue idempotent by
/// construction: a repeat insert (same process, another host racing on the
/// same database, or a recovery pass after the item completed) converges on
/// the SAME row instead of creating a second format job. Plain enqueues
/// without a key are unaffected.
@Suite("Fetcher queue idempotency", .serialized, .timeLimit(.minutes(2)))
struct FetcherQueueIdempotencyTests {

    private static let wikiID = WikiID(rawValue: "w")

    // MARK: - Fixtures

    private func makeQueueURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-idempotency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    private func request(
        sourceID: SourceID,
        dedupeKey: QueueItemDedupeKey? = nil
    ) -> QueueItemRequest {
        QueueItemRequest(
            queue: .extraction,
            wikiID: Self.wikiID,
            payload: QueueItemPayload(sourceIDs: [sourceID]),
            dedupeKey: dedupeKey)
    }

    private func totalCount(in queueStore: QueueStore) throws -> Int {
        try queueStore.loadActive().count + queueStore.loadRecent(limit: 100).count
    }

    // MARK: - Key scope

    @Test func followOnKeyScope() {
        let wiki = WikiID(rawValue: "01KEYWIKI0000000000000000")
        let source = SourceID(rawValue: "01KEYSOURCE00000000000000")
        let versionA = SourceVersionID(rawValue: "01KEYVERSIONA00000000000")
        let versionB = SourceVersionID(rawValue: "01KEYVERSIONB00000000000")

        let base = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: wiki, sourceID: source, acquiredContentVersionID: versionA)
        let same = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: wiki, sourceID: source, acquiredContentVersionID: versionA)
        #expect(base == same)
        #expect(base.rawValue == same.rawValue)

        // A different source or a different acquired version is a different
        // job — the key is scoped to the exact acquired content version.
        #expect(base != QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: wiki, sourceID: SourceID(rawValue: "01KEYOTHERSOURCE0000000"),
            acquiredContentVersionID: versionA))
        #expect(base != QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: wiki, sourceID: source, acquiredContentVersionID: versionB))
    }

    // MARK: - Idempotent enqueue

    @Test func dedupedEnqueueTwiceReturnsSameItem() throws {
        let queueStore = try QueueStore(databaseURL: try makeQueueURL())
        defer { queueStore.close() }
        let sourceID = SourceID(rawValue: "01IDEMSOURCE000000000000")
        let key = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: Self.wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: SourceVersionID(rawValue: "01IDEMVERSION0000000000"))

        let first = try queueStore.enqueue(request(sourceID: sourceID, dedupeKey: key))
        #expect(first.state == .queued)
        let second = try queueStore.enqueue(request(sourceID: sourceID, dedupeKey: key))
        #expect(second.id == first.id)
        #expect(try totalCount(in: queueStore) == 1)
    }

    @Test func dedupedEnqueueAfterCompletionReturnsTheCompletedItem() throws {
        let queueStore = try QueueStore(databaseURL: try makeQueueURL())
        defer { queueStore.close() }
        let sourceID = SourceID(rawValue: "01DONEITEMSOURCE000000000")
        let key = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: Self.wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: SourceVersionID(rawValue: "01DONEITEMVERSION0000000"))

        let original = try queueStore.enqueue(request(sourceID: sourceID, dedupeKey: key))
        try queueStore.markRunning(id: original.id, providerID: ProviderID(rawValue: "test"))
        try queueStore.markCompleted(id: original.id)
        #expect(original.state == .queued)

        // The retry-after-completion shape: a repeat insert returns the
        // completed row rather than opening a second format job.
        let repeatInsert = try queueStore.enqueue(request(sourceID: sourceID, dedupeKey: key))
        #expect(repeatInsert.id == original.id)
        #expect(repeatInsert.state == .completed)
        #expect(try totalCount(in: queueStore) == 1)
    }

    @Test func twoStoreHandlesOnOneDatabaseConvergeOnOneRow() throws {
        let url = try makeQueueURL()
        let app = try QueueStore(databaseURL: url)
        let daemon = try QueueStore(databaseURL: url)
        defer { app.close() }
        defer { daemon.close() }

        let sourceID = SourceID(rawValue: "01TWOSTORESOURCE00000000")
        let key = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: Self.wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: SourceVersionID(rawValue: "01TWOSTOREVERSION0000000"))

        // Serial enqueues (respecting the WAL pool rules); the ON CONFLICT
        // insert makes the race-free convergence hold for real concurrent
        // writers too.
        let fromApp = try app.enqueue(request(sourceID: sourceID, dedupeKey: key))
        let fromDaemon = try daemon.enqueue(request(sourceID: sourceID, dedupeKey: key))
        #expect(fromApp.id == fromDaemon.id)
        #expect(try totalCount(in: app) == 1)
        #expect(try totalCount(in: daemon) == 1)

        // Both handles read the same row for the key.
        let viaApp = try #require(try app.item(forDedupeKey: key))
        let viaDaemon = try #require(try daemon.item(forDedupeKey: key))
        #expect(viaApp.id == viaDaemon.id)
    }

    @Test func plainEnqueuesWithoutKeyAreUnaffected() throws {
        let queueStore = try QueueStore(databaseURL: try makeQueueURL())
        defer { queueStore.close() }
        let sourceID = SourceID(rawValue: "01PLAINENQUEUESOURCE00000")

        let first = try queueStore.enqueue(request(sourceID: sourceID))
        let second = try queueStore.enqueue(request(sourceID: sourceID))
        #expect(first.id != second.id)
        #expect(try queueStore.loadActive(for: .extraction).count == 2)
    }

    // MARK: - Marker settlement through the recovery entry

    @Test func recoverySettlesMarkerForCompletedDedupedItem() async throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try store.addBytelessSource(
            filename: "ABCD1234",
            mimeType: ContentTypeRegistry.zoteroAttachment,
            provenance: SourceProvenance(
                agentName: SourceProvider.zotero.rawValue,
                activityKind: "fetch",
                plan: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalRef: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalIdentity: "ABCD1234"),
            role: .primary)

        // Acquire bytes directly through the real mutator: the marker is
        // written in the same transaction.
        let version = try store.attachAcquiredBytes(
            sourceID: summary.id,
            bytes: Data("%PDF-1.4 settle".utf8),
            mimeType: "application/pdf",
            originalFilename: "paper.pdf",
            externalItemKey: "PARENT20",
            externalItemTitle: "A Study of Extraction",
            producer: nil)
        #expect(try store.fetchState(sourceID: summary.id) == .formatJobPending)

        let queueStore = try QueueStore(databaseURL: try makeQueueURL())
        defer { queueStore.close() }
        let key = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: Self.wikiID,
            sourceID: summary.id,
            acquiredContentVersionID: version.id)
        let item = try queueStore.enqueue(request(sourceID: summary.id, dedupeKey: key))

        // The deduped format job completed (the user retry path ends here
        // too); the recovery pass settles the marker to `complete`.
        try queueStore.markRunning(id: item.id, providerID: ProviderID(rawValue: "test"))
        try queueStore.markCompleted(id: item.id)
        await FetchFormatJobRecovery.run(
            wikiID: Self.wikiID, store: store, queueStore: queueStore)
        #expect(try store.fetchState(sourceID: summary.id) == .complete)
        #expect(try store.sourcesWithPendingFormatJobs().isEmpty)
    }

    /// The recovery settle is VERSION-AWARE: a stale scan whose deduped key
    /// was derived from an older acquired version must never clobber the
    /// `formatJobPending` marker a concurrent re-fetch wrote for a NEWER
    /// version (the skeptic-review F1 counterexample). The marker stays with
    /// the newer acquisition; only the matching version settles.
    @Test func staleRecoverySettleDoesNotClobberNewerAcquisitionMarker() throws {
        let (store, _) = try TestStoreFactory.fileBacked(prefix: "fetcher-settle-race")
        defer { store.close() }

        // Byteless fetcher source (V1 does not exist yet; marker is pending).
        let summary = try store.addBytelessSource(
            filename: "ABCD1234",
            mimeType: "application/zotero",
            provenance: SourceProvenance(
                agentName: SourceProvider.zotero.rawValue,
                activityKind: "fetch",
                plan: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalRef: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalIdentity: "ABCD1234"),
            role: .primary)
        let sourceID = summary.id

        // First acquisition commits V1 and marks formatJobPending (the
        // production attach path).
        let v1Bytes = Data("%PDF-1.4 first acquisition".utf8)
        let v1 = try store.attachAcquiredBytes(
            sourceID: sourceID,
            bytes: v1Bytes,
            mimeType: "application/pdf",
            originalFilename: "first.pdf",
            externalItemKey: "PARENT01",
            externalItemTitle: "First",
            producer: nil)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // A concurrent re-fetch commits V2 (different bytes) and re-marks
        // formatJobPending for itself.
        let v2Bytes = Data("%PDF-1.4 second acquisition".utf8)
        let v2 = try store.attachAcquiredBytes(
            sourceID: sourceID,
            bytes: v2Bytes,
            mimeType: "application/pdf",
            originalFilename: "second.pdf",
            externalItemKey: "PARENT01",
            externalItemTitle: "Second",
            producer: nil)
        #expect(v2.id != v1.id)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // The STALE scan (key derived from V1) tries to settle: it must be a
        // no-op — V2's marker survives.
        #expect(try store.markFetchComplete(
            sourceID: sourceID,
            expectedContentVersionID: v1.id) == false)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // The CURRENT scan (key derived from V2) settles.
        #expect(try store.markFetchComplete(
            sourceID: sourceID,
            expectedContentVersionID: v2.id) == true)
        #expect(try store.fetchState(sourceID: sourceID) == .complete)
    }
}
