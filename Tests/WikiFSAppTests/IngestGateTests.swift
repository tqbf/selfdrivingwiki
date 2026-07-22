#if os(macOS)
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
///
/// PR1 adds a sibling gate, **`WikiStoreModel.shouldAutoIngest(_:)`** — the
/// content-type-eligibility gate ("is the content TYPE one with any markdown
/// path?"), distinct from `canIngest` ("is there content to stage?"). A PNG
/// with bytes passes `canIngest` (the bug) but fails `shouldAutoIngest`
/// (the fix). Provider-aware so byteless `.youtube`/`.podcast` WITH transcripts
/// aren't dropped (locks the §11-C1 behavior — see
/// `plans/content-type-registry.md`).
@MainActor
@Suite(.timeLimit(.minutes(5)))
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

    // MARK: - shouldAutoIngest (content-type registry wrapper, PR1)

    /// The content-type-eligibility gate, sibling to `canIngest`.
    /// Distinct from `canIngest` (which asks "is there content to stage?"):
    /// `shouldAutoIngest` asks "is the content TYPE one with any markdown
    /// path?" — `false` for PNG/XML/etc. even when they have bytes.
    ///
    /// Wrapper is provider-aware (`ContentKind.resolve(mimeType:provider:ext:)`)
    /// so byteless `.youtube`/`.podcast` sources WITH transcripts return
    /// `true` (their synthetic `video/youtube` MIME alone would classify as
    /// `.binary`). This locks the §11-C1 behavior — when PR2's chokepoint
    /// migration calls `shouldAutoIngest`, it won't reintroduce the YouTube
    /// regression the original `fromMIME`-only wrapper had.

    @Test("shouldAutoIngest is false for PNG (the bug class)")
    func shouldAutoIngestExcludesPNG() throws {
        let model = WikiStoreModel(store: try tempStore())
        model.addSource(filename: "diagram.png",
                        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        model.reloadFromStore()
        let png = try #require(model.sources.first)
        #expect(png.byteSize > 0)
        #expect(model.canIngest(png))        // passes byte gate (the bug)…
        #expect(!model.shouldAutoIngest(png)) // …but registry excludes
    }

    @Test("shouldAutoIngest is false for XML (application/xml)")
    func shouldAutoIngestExcludesXML() throws {
        let model = WikiStoreModel(store: try tempStore())
        model.addSource(filename: "feed.xml",
                        data: Data("<?xml version=\"1.0\"?><foo/>".utf8))
        model.reloadFromStore()
        let xml = try #require(model.sources.first)
        #expect(xml.byteSize > 0)
        #expect(model.canIngest(xml))        // passes byte gate (the bug)…
        #expect(!model.shouldAutoIngest(xml)) // …but registry excludes (§11-C3)
    }

    @Test("shouldAutoIngest is true for PDF")
    func shouldAutoIngestKeepsPDF() throws {
        let model = WikiStoreModel(store: try tempStore())
        model.addSource(filename: "paper.pdf", data: Data("%PDF-1.4\n".utf8))
        model.reloadFromStore()
        let pdf = try #require(model.sources.first)
        #expect(model.canIngest(pdf))
        #expect(model.shouldAutoIngest(pdf))
    }

    @Test("shouldAutoIngest is true for native markdown")
    func shouldAutoIngestKeepsMarkdown() throws {
        let model = WikiStoreModel(store: try tempStore())
        model.addSource(filename: "notes.md", data: Data("# Heading\n\nbody".utf8))
        model.reloadFromStore()
        let md = try #require(model.sources.first)
        #expect(model.canIngest(md))
        #expect(model.shouldAutoIngest(md))
    }

    @Test("shouldAutoIngest is true for byteless YouTube (provider-aware, §11-C1)")
    func shouldAutoIngestKeepsBytelessYouTube() throws {
        // The critical §11-C1 case: a byteless YouTube source whose
        // synthetic `video/youtube` mime would classify as `.binary` under
        // `fromMIME` alone. The wrapper resolves with the provider so it
        // classifies as `.youtubeTranscript` → `shouldAutoIngest == true`.
        // (Whether the agent actually runs is a separate question:
        // `canIngest` returns `false` here — no transcript yet — so the
        // byteless guard catches it. But the TYPE eligibility is `true`.)
        let store = try tempStore()
        _ = try addBytelessYouTube(to: store)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()
        let yt = try #require(model.sources.first)
        #expect(!model.canIngest(yt))         // byteless + no transcript
        #expect(model.shouldAutoIngest(yt))    // but the kind is auto-ingestible
    }

    @Test("shouldAutoIngest is true for byteless YouTube WITH transcript")
    func shouldAutoIngestKeepsYouTubeWithTranscript() throws {
        // The §11-C1 regression case: provider-aware wrapper would not drop
        // a YouTube source whose transcript has arrived.
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        _ = try store.appendProcessedMarkdown(
            sourceID: yt.id,
            content: "# Transcript\n\ncaption body",
            origin: .transcript, note: nil, technique: nil)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let source = try #require(model.sources.first(where: { $0.id == yt.id }))
        #expect(model.canIngest(source))         // transcript staged
        #expect(model.shouldAutoIngest(source))   // + content type eligible
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

    // MARK: - Chokepoint content-type gate (PR2 §5.2 / §11-C1)

    /// PR2 adds a second gate at the chokepoint — `shouldAutoIngest` — to drop
    /// byte-bearing sources with no markdown path (the bug class: PNG, XML,
    /// etc.) even when the byte gate passes them. PR1's `BackgroundIngestCoordinator`
    /// filter already excludes these at scan time (the auto-ingest path), so
    /// they never reach the chokepoint automatically — this test asserts the
    /// same drop for the **manual** path (detail-view Ingest button / list
    /// context-menu Ingest item / batch ingest) which all funnel through the
    /// chokepoint. The registry gate is provider-aware (PR1's wrapper uses
    /// `ContentKind.resolve(mimeType:provider:ext:)`, NOT `fromMIME` alone)
    /// so byteless YouTube WITH a transcript still passes — the §11-C1
    /// regression the original §5.2 plan caught.

    @Test("chokepoint drops a byte-bearing PNG (PR2 §5.2 — content-type gate)")
    func chokepointDropsPNGWithBytes() async throws {
        // A PNG with bytes: passes canIngest (bytes > 0) but fails
        // shouldAutoIngest (image/png → .image). Pre-PR2, the chokepoint
        // would have enqueued it (the bug). Post-PR2, it's dropped.
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "diagram.png",
                        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        model.reloadFromStore()
        let png = try #require(model.sources.first)
        let engine = try makeEngine()

        await enqueueIngestion(
            sourceIDs: [png.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let pngIngestionItems = snapshot.activeItems.filter {
            $0.queue == .ingestion && $0.payload.sourceIDs.contains(png.id)
        }
        #expect(pngIngestionItems.isEmpty,
               "a byte-bearing PNG must be dropped by the content-type gate (shouldAutoIngest)")
    }

    @Test("chokepoint drops byte-bearing XML (application/xml → .binary)")
    func chokepointDropsXMLWithBytes() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "feed.xml",
                        data: Data("<?xml version=\"1.0\"?><foo/>".utf8))
        model.reloadFromStore()
        let xml = try #require(model.sources.first)
        let engine = try makeEngine()

        await enqueueIngestion(
            sourceIDs: [xml.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let xmlIngestionItems = snapshot.activeItems.filter {
            $0.queue == .ingestion && $0.payload.sourceIDs.contains(xml.id)
        }
        #expect(xmlIngestionItems.isEmpty,
               "application/xml (classified .binary per §11-C3) must be dropped by shouldAutoIngest")
    }

    /// **§11-C7 — the regression case the plan-review flagged.** A byteless
    /// YouTube source (synthetic `video/youtube` mime, `byteSize == 0`)
    /// WITH a transcript must pass the PR2 chokepoint. Critical: the
    /// `shouldAutoIngest` gate is provider-aware (PR1 made
    /// `WikiStoreModel.shouldAutoIngest(_:)` resolve with the provider), so
    /// `.youtube` provider → `.youtubeTranscript` → `shouldAutoIngest == true`
    /// (NOT `.binary` from the synthetic mime alone — the §11-C1 regression
    /// guard). The byte gate (`canIngest`) is also true because
    /// `hasProcessedMarkdown == true`. Both gates pass → enqueued.
    @Test("chokepoint keeps byteless YouTube WITH a transcript (§11-C7)")
    func chokepointKeepsBytelessYouTubeWithTranscript() async throws {
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        // Seed the transcript as a processed-markdown version.
        _ = try store.appendProcessedMarkdown(
            sourceID: yt.id,
            content: "# Transcript\n\ncaption body",
            origin: .transcript, note: nil, technique: nil)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        // Sanity: provider-aware shouldAutoIngest says YES (would be NO if
        // the chokepoint used fromMIME alone — that's the C1 regression).
        let source = try #require(model.sources.first(where: { $0.id == yt.id }))
        #expect(model.canIngest(source))           // transcript staged
        #expect(model.shouldAutoIngest(source))    // provider-aware: youtube → youtubeTranscript

        let engine = try makeEngine()
        await enqueueIngestion(
            sourceIDs: [yt.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let ytIngestionItems = snapshot.activeItems.filter {
            $0.queue == .ingestion && $0.payload.sourceIDs.contains(yt.id)
        }
        #expect(ytIngestionItems.count == 1,
               "a byteless YouTube WITH a transcript must pass both chokepoint gates (§11-C1/C7)")
    }

    /// Mixed batch with the §11-C1 case + the bug class: one byteless YouTube
    /// WITH transcript (keep — provider-aware gate), one byte-bearing PNG
    /// (drop — content-type gate), one markdown file (keep — both gates
    /// pass). Verifies the two new gates coexist cleanly in a batch — the
    /// YouTube retention doesn't accidentally widen the PNG, and vice versa.
    @Test("chokepoint mixed batch: PNG dropped, YouTube-with-transcript + markdown kept")
    func chokepointMixedBatchKeepsYouTubeDropsPNG() async throws {
        let store = try tempStore()
        let yt = try addBytelessYouTube(to: store)
        _ = try store.appendProcessedMarkdown(
            sourceID: yt.id,
            content: "# Transcript\n\ncaption body",
            origin: .transcript, note: nil, technique: nil)
        let model = WikiStoreModel(store: store)
        model.addSource(filename: "diagram.png",
                        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        model.addSource(filename: "notes.md", data: Data("# body".utf8))
        model.reloadFromStore()

        let png = try #require(model.sources.first(where: { $0.ext == "png" }))
        let md  = try #require(model.sources.first(where: { $0.ext == "md" }))

        let engine = try makeEngine()
        await enqueueIngestion(
            sourceIDs: [yt.id, png.id, md.id],
            store: model,
            wikiID: "test-wiki",
            queueEngine: engine)

        let snapshot = await engine.snapshot()
        let stagedIDs = Set(snapshot.activeItems
            .filter { $0.queue == .ingestion }
            .flatMap { $0.payload.sourceIDs })
        #expect(stagedIDs.contains(yt.id),
               "YouTube WITH transcript kept (provider-aware shouldAutoIngest)")
        #expect(!stagedIDs.contains(png.id),
               "PNG dropped (content-type gate)")
        #expect(stagedIDs.contains(md.id),
               "Markdown kept (both gates pass)")
    }
}
#endif
