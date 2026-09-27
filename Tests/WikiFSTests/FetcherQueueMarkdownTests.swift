import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// AC.5 — the `markdown` fetch result and the no-second-fetch invariant.
///
/// A fetcher that returns finished Markdown appends exactly one
/// installed-package Markdown version (package provenance, `.extraction`
/// origin) and completes the source — no follow-on format job exists. A
/// source that already holds bytes never re-enters the fetch route: the
/// shared `FetchRouteDecision` resolves it through the format route, and a
/// failed byte read surfaces as an error rather than an empty source.
@Suite("Fetcher queue markdown results", .serialized, .timeLimit(.minutes(2)))
struct FetcherQueueMarkdownTests {

    private static let wikiID = WikiID(rawValue: "w")
    private typealias PipelineProvider = FetcherQueuePipelineTests.PipelineProvider

    // MARK: - Fixtures

    private func seedSource(_ store: GRDBWikiStore) throws -> SourceID {
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
        return summary.id
    }

    private func markdownOutcome(identifier: String) throws -> FetchOutcome {
        .markdown(FetchedMarkdown(
            markdown: "# Converted notes\n",
            reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero"),
            articleMetadata: try ExtractorArticleMetadata(
                title: "A Study of Extraction", identifier: identifier)))
    }

    private func makeQueueURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    // MARK: - Markdown persistence

    @Test func markdownResultAppendsOnePackageMarkdownVersionAndCompletes() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()
        let queueStore = try QueueStore(databaseURL: queueURL)
        defer { queueStore.close() }
        let provider = PipelineProvider(store: store, queueStore: queueStore)

        let resolution = FetcherResolution(
            fetch: { _ in try self.markdownOutcome(identifier: "PARENT10") },
            claimedMIMEType: try ExtractorMIMEType(
                validating: ContentTypeRegistry.zoteroAttachment),
            filename: "ABCD1234",
            producer: ExtractionInstalledPackageProducer(
                revision: ReviewedExtractorPackages.zotero.revision,
                registrationID: try ExtractorRegistrationID(validating: "attachment"),
                protocolRevision: .v5,
                reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero")))
        let outcome = try await resolution.fetch { _ in }
        let reference = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        #expect(reference != nil)

        // Exactly one Markdown version, with the fetch producer's package
        // provenance and the extraction origin.
        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.content == "# Converted notes\n")
        #expect(head.origin == .extraction)
        #expect(head.technique == "extractor-package:org.selfdrivingwiki.zotero")
        #expect(head.parentID == nil)

        // The Markdown IS the product: no format job was enqueued and the
        // source is complete.
        #expect(try queueStore.loadActive().isEmpty)
        #expect(try queueStore.loadRecent(limit: 100).isEmpty)
        #expect(try store.fetchState(sourceID: sourceID) == .complete)
        #expect(try store.sourcesWithPendingFormatJobs().isEmpty)

        // The acquisition provenance columns are populated from
        // articleMetadata.
        let summary = try #require(try store.listSources().first { $0.id == sourceID })
        #expect(summary.externalItemKey == "PARENT10")
        #expect(summary.externalItemTitle == "A Study of Extraction")
    }

    // MARK: - No second fetch

    @Test func acquiredBytesNeverReEnterTheFetchRoute() async throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)
        let queueURL = try makeQueueURL()
        let queueStore = try QueueStore(databaseURL: queueURL)
        defer { queueStore.close() }
        let provider = PipelineProvider(store: store, queueStore: queueStore)

        // One acquisition, counted at the fetch closure — the only place a
        // fetch can start.
        let counter = FetchCounter()
        let resolution = FetcherResolution(
            fetch: { _ in
                counter.increment()
                let bytes = Data("%PDF-1.4 no-refetch".utf8)
                return .sourceBytes(FetchedSourceBytes(
                    bytes: bytes,
                    mimeType: try ExtractorMIMEType(validating: "application/pdf"),
                    originalFilename: "paper.pdf",
                    reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero"),
                    articleMetadata: try ExtractorArticleMetadata(
                        title: "A Study of Extraction", identifier: "PARENT11")))
            },
            claimedMIMEType: try ExtractorMIMEType(
                validating: ContentTypeRegistry.zoteroAttachment),
            filename: "ABCD1234",
            producer: ExtractionInstalledPackageProducer(
                revision: ReviewedExtractorPackages.zotero.revision,
                registrationID: try ExtractorRegistrationID(validating: "attachment"),
                protocolRevision: .v5,
                reportedMetadata: try ExtractorReportedMetadata(toolName: "zotero")))

        let outcome = try await resolution.fetch { _ in }
        _ = try await provider.persistFetch(
            wikiID: Self.wikiID, sourceID: sourceID,
            resolution: resolution, outcome: outcome)
        #expect(counter.value == 1)
        #expect(try store.fetchState(sourceID: sourceID) == .formatJobPending)

        // The worker's skip path is this decision: once the source holds
        // bytes it resolves through the format route, so no code path can
        // reach the fetch closure again (the counter stays at one).
        let summary = try #require(try store.listSources().first { $0.id == sourceID })
        let route = FetchRouteDecision.resolve(
            hasBytes: summary.byteSize > 0,
            planURL: "https://api.zotero.org/users/12345/items/ABCD1234/file",
            mimeType: ContentTypeRegistry.zoteroAttachment,
            fetcherClaimedMIMETypes: [ContentTypeRegistry.zoteroAttachment])
        #expect(route == .format)
        #expect(counter.value == 1)
    }

    // MARK: - Route decision matrix

    @Test func routeDecisionMatrix() {
        let claimed = Set([ContentTypeRegistry.zoteroAttachment])
        let validURL = "https://api.zotero.org/users/1/items/ABCD1234/file"

        // Bytes on hand: the format route, always — re-acquiring is never
        // a decision this function makes.
        #expect(FetchRouteDecision.resolve(
            hasBytes: true, planURL: validURL,
            mimeType: ContentTypeRegistry.zoteroAttachment,
            fetcherClaimedMIMETypes: claimed) == .format)

        // Byteless with an invalid plan URL: nothing to launch.
        #expect(FetchRouteDecision.resolve(
            hasBytes: false, planURL: "not a url",
            mimeType: ContentTypeRegistry.zoteroAttachment,
            fetcherClaimedMIMETypes: claimed) == nil)
        #expect(FetchRouteDecision.resolve(
            hasBytes: false, planURL: nil,
            mimeType: ContentTypeRegistry.zoteroAttachment,
            fetcherClaimedMIMETypes: claimed) == nil)

        // Byteless with a valid URL but an unclaimed MIME: no fetcher is
        // eligible (provider-neutral — claims, never provider names).
        #expect(FetchRouteDecision.resolve(
            hasBytes: false, planURL: validURL,
            mimeType: "text/html",
            fetcherClaimedMIMETypes: claimed) == nil)

        // Byteless with a valid URL and a claimed MIME: the fetch route.
        #expect(FetchRouteDecision.resolve(
            hasBytes: false, planURL: validURL,
            mimeType: ContentTypeRegistry.zoteroAttachment,
            fetcherClaimedMIMETypes: claimed) == .fetch)
    }

    // MARK: - Failed byte reads never produce an empty source

    @Test func emptyAcquisitionIsRejectedAtTheStoreBoundary() throws {
        let store = try TestStoreFactory.inMemory()
        let sourceID = try seedSource(store)

        // A fetch whose bytes read produced nothing fails instead of
        // persisting an empty source: an empty blob would re-enter the
        // fetch route and loop forever.
        #expect(throws: (any Error).self) {
            _ = try store.attachAcquiredBytes(
                sourceID: sourceID,
                bytes: Data(),
                mimeType: "application/pdf",
                originalFilename: "paper.pdf",
                externalItemKey: nil,
                externalItemTitle: nil,
                producer: nil)
        }
        // Nothing was persisted — the source is still byteless and pending.
        let summary = try #require(try store.listSources().first { $0.id == sourceID })
        #expect(summary.byteSize == 0)
        #expect(try store.fetchState(sourceID: sourceID) == .pending)
    }

    /// A tiny atomic counter the fetch closure uses to prove single
    /// execution. `Mutex` keeps it sendable without blocking the pool.
    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }
}
