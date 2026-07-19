import Foundation
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// Tests for the centralized "don't ingest sources without content" gate.
///
/// The rule lives in two coordinated places:
/// - **`WikiStoreModel.canIngest(_:)`** — the shared predicate a source is
///   ingestible iff it has processed markdown (a transcript, extracted PDF)
///   **or** raw bytes (`byteSize > 0`) the staging path reads directly.
/// - **`enqueueIngestion`** — the single chokepoint every UI entry point
///   (detail-view button, list context menu, batch re-ingest) funnels
///   through; it drops a non-ingestible source rather than enqueuing a run
///   the staging path would hand empty bytes to.
///
/// A **byteless** source (e.g. a YouTube video, `video/youtube` mime,
/// `byteSize == 0`) whose transcript never arrived has neither, so it must
/// not be ingested. That is the regression these tests pin down.
@MainActor
@Suite(.tags(.integration))
struct IngestGateTests {

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    /// A byteless YouTube source — synthetic mime `video/youtube`,
    /// `byteSize == 0`, no blob. This is the regression source.
    @discardableResult
    private func addBytelessYouTube(to store: GRDBWikiStore) throws -> SourceSummary {
        try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)
    }

    // MARK: - canIngest predicate

    @Test func bytelessYouTubeWithoutTranscriptIsNotIngestible() throws {
        let store = try tempStore()
        _ = try addBytelessYouTube(to: store)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let yt = try #require(model.sources.first)
        #expect(yt.byteSize == 0)
        #expect(!model.canIngest(yt))
    }

    @Test func nativeMarkdownFileIsIngestible() throws {
        let model = WikiStoreModel(store: try tempStore())
        model.addSource(filename: "notes.md", data: Data("# Heading\n\nbody".utf8))
        model.reloadFromStore()

        let md = try #require(model.sources.first)
        #expect(md.byteSize > 0)
        #expect(model.canIngest(md))
    }

    @Test func pdfWithBytesIsIngestible() throws {
        let model = WikiStoreModel(store: try tempStore())
        // Raw PDF bytes (header only) — the staging path extracts markdown
        // first, but `canIngest` is true because there are bytes to act on.
        model.addSource(filename: "paper.pdf", data: Data("%PDF-1.4\n".utf8))
        model.reloadFromStore()

        let pdf = try #require(model.sources.first)
        #expect(pdf.byteSize > 0)
        #expect(model.canIngest(pdf))
    }

    @Test func bytelessSourceWithTranscriptIsIngestible() throws {
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        // The transcript arrives as a processed-markdown version.
        _ = try store.appendProcessedMarkdown(
            sourceID: yt.id,
            content: "# Transcript\n\ntranscript body",
            origin: .transcript, note: nil, technique: nil)

        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let source = try #require(model.sources.first(where: { $0.id == yt.id }))
        #expect(source.byteSize == 0)  // still byteless…
        #expect(model.hasProcessedMarkdown(for: source.id))  // …but has a transcript
        #expect(model.canIngest(source))
    }

    // MARK: - enqueueIngestion chokepoint

    /// A no-op worker factory: workers succeed but do nothing. We only care
    /// whether a `.ingestion` queue item is created for the source at all.
    private struct NoopWorkerFactory: QueueWorkerFactory {
        func providerID(for item: QueueItem) async -> String? { "test-ingest" }
        func worker(for item: QueueItem) async throws -> any QueueWorker {
            struct W: QueueWorker { func execute(_ item: QueueItem) async throws {} }
            return W()
        }
    }

    private func makeEngine() throws -> QueueEngine {
        let queueStore = try QueueStore(
            databaseURL: URL(fileURLWithPath: ":memory:"))
        return QueueEngine(store: queueStore, workerFactory: NoopWorkerFactory())
    }

    @Test func chokepointDropsBytelessYouTubeFromIngestionQueue() async throws {
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()
        let engine = try makeEngine()

        // The detail-view button / list menu would call this with the
        // byteless YouTube source. No extraction is needed (it's not a PDF),
        // and it has no markdown — the chokepoint must drop it.
        await enqueueIngestion(
            sourceIDs: [yt.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let ingestionItemsForYT = snapshot.activeItems.filter {
            $0.queue == .ingestion
                && $0.payload.sourceIDs.contains(yt.id)
        }
        #expect(ingestionItemsForYT.isEmpty,
               "a byteless source with no markdown must not be enqueued for ingestion")
    }

    @Test func chokepointKeepsNativeMarkdown() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "notes.md", data: Data("# Heading\n\nbody".utf8))
        model.reloadFromStore()
        let md = try #require(model.sources.first)
        let engine = try makeEngine()

        await enqueueIngestion(
            sourceIDs: [md.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let ingestionItems = snapshot.activeItems.filter {
            $0.queue == .ingestion
                && $0.payload.sourceIDs.contains(md.id)
        }
        #expect(ingestionItems.count == 1,
               "a native markdown file must pass the chokepoint and be enqueued")
    }

    @Test func chokepointDropsBytelessKeepsMarkdownInBatch() async throws {
        // A mixed batch: one byteless YouTube (drop) + one markdown file (keep).
        // Only the markdown file should reach the ingestion queue.
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "notes.md", data: Data("# body".utf8))
        model.reloadFromStore()
        let md = try #require(model.sources.first(where: { $0.id != yt.id }))
        let engine = try makeEngine()

        await enqueueIngestion(
            sourceIDs: [yt.id, md.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let ingestionItems = snapshot.activeItems.filter { $0.queue == .ingestion }
        let stagedIDs = Set(ingestionItems.flatMap { $0.payload.sourceIDs })
        #expect(!stagedIDs.contains(yt.id),
               "the byteless YouTube source must be dropped from the batch")
        #expect(stagedIDs.contains(md.id),
               "the markdown file in the same batch must still be enqueued")
    }
}
