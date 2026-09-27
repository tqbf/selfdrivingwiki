import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.4 — the acquisition pipeline end to end, over the REAL store mutators.
///
/// A byteless `application/zotero` source is acquired by a fake fetcher
/// resolution (the fetch itself is stubbed; every store and queue write is
/// real): `persistFetch(.sourceBytes)` stores the blob with the real
/// MIME/ext/filename and the `formatJobPending` marker in one transaction,
/// the follow-on format job is enqueued under its typed dedupe key, and the
/// crash-gap between the two writes is closed by `FetchFormatJobRecovery`
/// — including across a full close/reopen of both databases.
@Suite("Fetcher queue pipeline", .serialized, .timeLimit(.minutes(3)))
struct FetcherQueuePipelineTests {

    private static let wikiID = WikiID(rawValue: "w")
    private static let fileURL = "https://api.zotero.org/users/12345/items/ABCD1234/file"

    // MARK: - Fixtures

    /// A minimal queue-extraction provider that delegates to the REAL
    /// `GRDBWikiStore` mutators exactly like the app's
    /// `AppQueueExtractionProvider`: markdown results append a
    /// package-provenance Markdown version and complete the source;
    /// source-bytes results attach the blob and the marker in one
    /// transaction. Only the session-hop differs (the store is held
    /// directly — no main-actor model). Shared with the markdown and
    /// neutrality suites in this target.
    struct PipelineProvider: QueueExtractionProvider {
        let store: GRDBWikiStore
        let queueStore: QueueStore

        func resolveExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            backendOverride: ExtractionBackend?
        ) async throws -> ExtractionResolution? { nil }

        func persistBytesExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: BytesExtractionResolution,
            markdown: String
        ) async throws -> QueueExtractionOutputReference? { nil }

        func persistTranscriptExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: TranscriptExtractionResolution,
            outcome: TranscriptFetchOutcome
        ) async throws -> QueueExtractionOutputReference? { nil }

        @discardableResult
        func persistFetch(
            wikiID: WikiID,
            sourceID: SourceID,
            resolution: FetcherResolution,
            outcome: FetchOutcome
        ) async throws -> QueueExtractionOutputReference? {
            switch outcome {
            case .markdown(let markdown):
                guard let initial = try store.initialContentVersion(sourceID: sourceID) else {
                    throw AppendDerivedMarkdownError.missingInitialSourceVersion(sourceID)
                }
                let producer = ExtractionInstalledPackageProducer(
                    revision: resolution.producer.revision,
                    registrationID: resolution.producer.registrationID,
                    protocolRevision: resolution.producer.protocolRevision,
                    reportedMetadata: markdown.reportedMetadata)
                let version = try store.appendInstalledPackageMarkdown(
                    sourceID: sourceID,
                    content: markdown.markdown,
                    package: producer,
                    origin: .extraction,
                    toolVersion: nil,
                    sourceVersionID: initial.id,
                    note: nil)
                try store.setAcquisitionProvenance(
                    sourceID: sourceID,
                    externalItemKey: markdown.articleMetadata?.identifier,
                    externalItemTitle: markdown.articleMetadata?.title,
                    displayName: markdown.articleMetadata?.title)
                try store.markFetchComplete(sourceID: sourceID)
                return QueueExtractionOutputReference(versionID: version.id.rawValue)

            case .sourceBytes(let bytes):
                let version = try store.attachAcquiredBytes(
                    sourceID: sourceID,
                    bytes: bytes.bytes,
                    mimeType: bytes.mimeType.rawValue,
                    originalFilename: bytes.originalFilename,
                    externalItemKey: bytes.articleMetadata?.identifier,
                    externalItemTitle: bytes.articleMetadata?.title,
                    producer: ExtractionInstalledPackageProducer(
                        revision: resolution.producer.revision,
                        registrationID: resolution.producer.registrationID,
                        protocolRevision: resolution.producer.protocolRevision,
                        reportedMetadata: bytes.reportedMetadata))
                return QueueExtractionOutputReference(versionID: version.id.rawValue)
            }
        }

        func enqueueFollowOnExtraction(
            wikiID: WikiID,
            sourceID: SourceID,
            acquiredContentVersionID: SourceVersionID,
            dedupeKey: QueueItemDedupeKey
        ) async throws {
            _ = try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]),
                dedupeKey: dedupeKey))
        }
    }

    /// Seeds one byteless zotero source (the sync command's output shape).
    private func seedSource(_ store: GRDBWikiStore, key: String = "ABCD1234") throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: key,
            mimeType: ContentTypeRegistry.zoteroAttachment,
            provenance: SourceProvenance(
                agentName: SourceProvider.zotero.rawValue,
                activityKind: "fetch",
                plan: Self.fileURL,
                externalRef: Self.fileURL,
                externalIdentity: key),
            role: .primary)
        return summary.id
    }

    /// The fake fetcher resolution: no process, one canned typed outcome
    /// with the reviewed Zotero provenance.
    private func fetcherResolution(
        outcome: @escaping @Sendable () throws -> FetchOutcome
    ) throws -> FetcherResolution {
        FetcherResolution(
            fetch: { _ in try outcome() },
            claimedMIMEType: try ExtractorMIMEType(
                validating: ContentTypeRegistry.zoteroAttachment),
            filename: "ABCD1234",
            producer: ExtractionInstalledPackageProducer(
                revision: ReviewedExtractorPackages.zotero.revision,
                registrationID: try ExtractorRegistrationID(validating: "attachment"),
                protocolRevision: .v5,
                reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero")))
    }

    private func pdfOutcome(identifier: String) throws -> FetchOutcome {
        let bytes = Data("%PDF-1.4 fixture bytes".utf8)
        return .sourceBytes(FetchedSourceBytes(
            bytes: bytes,
            mimeType: try ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "paper.pdf",
            reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero"),
            articleMetadata: try ExtractorArticleMetadata(
                title: "A Study of Extraction", identifier: identifier)))
    }

    private func makeQueueURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    private func dedupeKey(
        sourceID: SourceID, acquiredVersionID: SourceVersionID
    ) -> QueueItemDedupeKey {
        .followOnFormatExtraction(
            wikiID: Self.wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID)
    }

    private func totalCount(in queueStore: QueueStore) throws -> Int {
        try queueStore.loadActive().count + queueStore.loadRecent(limit: 100).count
    }

    // MARK: - persistFetch(.sourceBytes) + follow-on enqueue

    @Test func persistFetchSourceBytesStoresBlobProvenanceAndEnqueuesFollowOn() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()
        let queueStore = try QueueStore(databaseURL: queueURL)
        defer { queueStore.close() }
        let provider = PipelineProvider(store: store, queueStore: queueStore)

        let resolution = try fetcherResolution { try self.pdfOutcome(identifier: "PARENT01") }
        let outcome = try await resolution.fetch { _ in }
        let reference = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)

        // The blob IS the source content; MIME/ext/filename come from the
        // result frame; the neutral external provenance columns come from
        // articleMetadata; the marker is `formatJobPending`.
        let summary = try #require(try store.listSources().first { $0.id == sourceID })
        let pdfBytes = Data("%PDF-1.4 fixture bytes".utf8)
        #expect(summary.byteSize == pdfBytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.ext == "pdf")
        #expect(summary.filename == "paper.pdf")
        #expect(summary.externalItemKey == "PARENT01")
        #expect(summary.externalItemTitle == "A Study of Extraction")
        #expect(try store.sourceContent(id: sourceID) == pdfBytes)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)
        #expect(try store.sourcesWithPendingFormatJobs() == [sourceID])

        // The follow-on format route is enqueued exactly once, scoped to
        // the acquired content version; a repeat enqueue returns the SAME
        // item id.
        let acquiredVersionID = SourceVersionID(
            rawValue: try #require(reference?.versionID))
        let key = dedupeKey(sourceID: sourceID, acquiredVersionID: acquiredVersionID)
        try await provider.enqueueFollowOnExtraction(
            wikiID: Self.wikiID, sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID, dedupeKey: key)
        let first = try #require(try queueStore.item(forDedupeKey: key))
        #expect(first.state == .queued)
        #expect(first.payload.sourceIDs == [sourceID])
        try await provider.enqueueFollowOnExtraction(
            wikiID: Self.wikiID, sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID, dedupeKey: key)
        let second = try #require(try queueStore.item(forDedupeKey: key))
        #expect(second.id == first.id)
        #expect(try queueStore.loadActive(for: .extraction).count == 1)
    }

    // MARK: - Recovery

    @Test func recoveryAddsNothingWhenEnqueuedAndSettlesCompletedItems() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()
        let writer = try QueueStore(databaseURL: queueURL)
        let provider = PipelineProvider(store: store, queueStore: writer)

        let resolution = try fetcherResolution { try self.pdfOutcome(identifier: "PARENT02") }
        let outcome = try await resolution.fetch { _ in }
        let reference = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        let acquiredVersionID = SourceVersionID(rawValue: try #require(reference?.versionID))
        let key = dedupeKey(sourceID: sourceID, acquiredVersionID: acquiredVersionID)
        try await provider.enqueueFollowOnExtraction(
            wikiID: Self.wikiID, sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID, dedupeKey: key)
        writer.close()

        // A SECOND QueueStore instance on the same database — the "other
        // host opens the wiki" shape. With the item already enqueued, the
        // recovery pass adds nothing.
        let reader = try QueueStore(databaseURL: queueURL)
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: reader)
        #expect(try totalCount(in: reader) == 1)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // Settle: the format job runs and completes; the next pass settles
        // the marker to `complete`.
        let item = try #require(try reader.item(forDedupeKey: key))
        try reader.markRunning(id: item.id, providerID: ProviderID(rawValue: "test"))
        try reader.markCompleted(id: item.id)
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: reader)
        #expect(try store.fetchState(sourceID: sourceID) == .complete)
        #expect(try store.sourcesWithPendingFormatJobs().isEmpty)
        reader.close()
    }

    @Test func crashGapRecoveryEnqueuesExactlyOnce() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()

        // The crash gap: bytes persisted (marker written in the same
        // transaction) but the follow-on enqueue never happened.
        let provider = PipelineProvider(store: store, queueStore: try QueueStore(databaseURL: queueURL))
        let resolution = try fetcherResolution { try self.pdfOutcome(identifier: "PARENT03") }
        let outcome = try await resolution.fetch { _ in }
        _ = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        let recoveryStore = try QueueStore(databaseURL: queueURL)
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: recoveryStore)
        #expect(try totalCount(in: recoveryStore) == 1)
        // Running the pass a second time (both hosts racing the scan) still
        // converges on one item — the dedupe key makes it idempotent.
        let secondPass = try QueueStore(databaseURL: queueURL)
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: secondPass)
        #expect(try totalCount(in: secondPass) == 1)
        recoveryStore.close()
        secondPass.close()
    }

    @Test func pipelineSurvivesProcessRestart() async throws {
        // Durable halves: a file-backed wiki store and a persisted queue.
        let pair = try TestStoreFactory.fileBacked(prefix: "fetcher-restart")
        let store = pair.store
        let storeURL = pair.url
        let queueURL = try makeQueueURL()
        let sourceID = try seedSource(store)

        let writer = try QueueStore(databaseURL: queueURL)
        let provider = PipelineProvider(store: store, queueStore: writer)
        let resolution = try fetcherResolution { try self.pdfOutcome(identifier: "PARENT04") }
        let outcome = try await resolution.fetch { _ in }
        let reference = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)

        // "Process restart": close both databases, reopen both.
        writer.close()
        store.close()
        let reopenedStore = try GRDBWikiStore(databaseURL: storeURL)
        let reopenedQueue = try QueueStore(databaseURL: queueURL)
        defer { reopenedQueue.close() }

        // The blob, the marker, and the acquired version survived.
        #expect(try reopenedStore.sourceContent(id: sourceID) == Data("%PDF-1.4 fixture bytes".utf8))
        #expect(try reopenedStore.fetchState(sourceID: sourceID) == .formatJobPending)
        #expect(try reopenedStore.sourcesWithPendingFormatJobs() == [sourceID])

        let reopenedProvider = PipelineProvider(store: reopenedStore, queueStore: reopenedQueue)
        let acquiredVersionID = SourceVersionID(rawValue: try #require(reference?.versionID))
        let key = dedupeKey(sourceID: sourceID, acquiredVersionID: acquiredVersionID)
        try await reopenedProvider.enqueueFollowOnExtraction(
            wikiID: Self.wikiID, sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID, dedupeKey: key)

        // The recovery pass over the reopened state settles after completion.
        let item = try #require(try reopenedQueue.item(forDedupeKey: key))
        try reopenedQueue.markRunning(id: item.id, providerID: ProviderID(rawValue: "test"))
        try reopenedQueue.markCompleted(id: item.id)
        await FetchFormatJobRecovery.run(
            wikiID: Self.wikiID, store: reopenedStore, queueStore: reopenedQueue)
        #expect(try reopenedStore.fetchState(sourceID: sourceID) == .complete)
    }

    @Test func failedFormatItemIsNotDuplicatedAndSettlesAfterUserRetry() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()
        let queueStore = try QueueStore(databaseURL: queueURL)
        defer { queueStore.close() }
        let provider = PipelineProvider(store: store, queueStore: queueStore)

        let resolution = try fetcherResolution { try self.pdfOutcome(identifier: "PARENT05") }
        let outcome = try await resolution.fetch { _ in }
        let reference = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        let acquiredVersionID = SourceVersionID(rawValue: try #require(reference?.versionID))
        let key = dedupeKey(sourceID: sourceID, acquiredVersionID: acquiredVersionID)
        try await provider.enqueueFollowOnExtraction(
            wikiID: Self.wikiID, sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID, dedupeKey: key)
        let original = try #require(try queueStore.item(forDedupeKey: key))

        // The format job failed: recovery must NOT create a second item and
        // must leave the marker pending — the user retry path owns it.
        try queueStore.markRunning(id: original.id, providerID: ProviderID(rawValue: "test"))
        try queueStore.markFailed(id: original.id, error: "format extraction failed")
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: queueStore)
        let afterFailure = try #require(try queueStore.item(forDedupeKey: key))
        #expect(afterFailure.id == original.id)
        #expect(afterFailure.state == .failed)
        #expect(try totalCount(in: queueStore) == 1)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // The user retry succeeds: the failed item requeues, runs, and
        // completes; the next recovery pass settles the marker.
        try queueStore.retryItem(id: original.id)
        try queueStore.markRunning(id: original.id, providerID: ProviderID(rawValue: "test"))
        try queueStore.markCompleted(id: original.id)
        await FetchFormatJobRecovery.run(wikiID: Self.wikiID, store: store, queueStore: queueStore)
        #expect(try store.fetchState(sourceID: sourceID) == .complete)
    }
}
