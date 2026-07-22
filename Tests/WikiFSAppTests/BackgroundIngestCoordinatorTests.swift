#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// Tests for the per-source content-type-registry filter inside
/// `BackgroundIngestCoordinator` (the PR1 bug fix).
///
/// The continuous-ingest bug: `BackgroundIngestCoordinator.scanWiki`
/// enqueued every un-ingested source that passed `store.canIngest(source)`
/// — but `canIngest` is a **byte availability** predicate
/// (`hasProcessedMarkdown || byteSize > 0`), NOT a markdown-path predicate.
/// So a PNG / XML with bytes sailed through and got enqueued for wasted
/// agent runs.
///
/// The fix: `scanWiki` now consults
/// `BackgroundIngestCoordinator.ingestionDecision(for:store:)` which runs
/// the **registry gate** (`ContentKind.shouldAutoIngest`) BEFORE the byteless
/// guard. PNG (`image/png` → `.image`) and XML (`application/xml` →
/// `.binary`) are filtered out here. Existing byteless behavior
/// (YouTube without a transcript → `.skipByteless`) is preserved as
/// defense-in-depth.
///
/// The per-source decision is extracted as an `internal static` seam so
/// tests can exercise it directly without standing up a scan task (§11-C2).
/// The chokepoint (`QueueIngestionHelper.enqueueIngestion`) is UNCHANGED in
/// PR1 (§11-C1 — fixing it here would break YouTube/podcast ingest because
/// the `fromMIME`-only wrapper would classify their synthetic mimes as
/// `.binary`). The coordinator fix alone closes the bug for PR1 (PNG/XML
/// filtered at scan time, before they reach the chokepoint).
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct BackgroundIngestCoordinatorTests {

    // MARK: - Fixtures

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    /// A byte-bearing PNG with real magic bytes. `ContentSniff` returns
    /// `image/png`, so this is the exact shape of the bug source.
    @discardableResult
    private func addPNG(to model: WikiStoreModel) -> SourceSummary {
        model.addSource(
            filename: "diagram.png",
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        model.reloadFromStore()
        return model.sources.first(where: { $0.ext == "png" })!
    }

    /// A byte-bearing XML file. `UTType("xml")?.preferredMIMEType` →
    /// `application/xml` on macOS, which the registry classifies as
    /// `.binary` (§11-C3 XML exclusion).
    @discardableResult
    private func addXML(to model: WikiStoreModel) -> SourceSummary {
        model.addSource(
            filename: "feed.xml",
            data: Data("<?xml version=\"1.0\"?><foo/>".utf8))
        model.reloadFromStore()
        return model.sources.first(where: { $0.ext == "xml" })!
    }

    @discardableResult
    private func addPDF(to model: WikiStoreModel) -> SourceSummary {
        model.addSource(filename: "paper.pdf", data: Data("%PDF-1.4\n".utf8))
        model.reloadFromStore()
        return model.sources.first(where: { $0.ext == "pdf" })!
    }

    @discardableResult
    private func addMarkdown(to model: WikiStoreModel) -> SourceSummary {
        model.addSource(filename: "notes.md", data: Data("# Title\n\nbody".utf8))
        model.reloadFromStore()
        return model.sources.first(where: { $0.ext == "md" })!
    }

    /// A byteless YouTube embed (synthetic `video/youtube` mime, agent
    /// `youtube`). Mirrors `IngestGateTests.addBytelessYouTube`.
    ///
    /// `videoID` is parameterized so a single test can add multiple distinct
    /// YouTube sources — `addBytelessSource` dedups on `externalIdentity`, so
    /// two sources with the same ID would throw `.duplicateContent`.
    @discardableResult
    private func addBytelessYouTube(
        to store: GRDBWikiStore,
        videoID: String = "dQw4w9WgXcQ",
        withTranscript: Bool = false
    ) throws -> SourceSummary {
        let yt = try store.addBytelessSource(
            filename: "youtube-\(videoID)",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/\(videoID)",
                externalRef: "https://youtu.be/\(videoID)",
                externalIdentity: videoID),
            role: .primary)
        if withTranscript {
            _ = try store.appendProcessedMarkdown(
                sourceID: yt.id,
                content: "# Transcript\n\ncaption body",
                origin: .transcript, note: nil, technique: nil)
        }
        return yt
    }

    // MARK: - Per-source decision (ingestionDecision)

    @Test("PNG source is not enqueued (registry excludes image/*)")
    func pngIsNotIngestible() throws {
        let model = WikiStoreModel(store: try tempStore())
        let png = addPNG(to: model)

        // Sanity: the source has bytes (so the old byte-only gate would have
        // let it through — that's the bug).
        #expect(png.byteSize > 0)
        #expect(model.canIngest(png))

        // The registry gate filters it out BEFORE the byte gate runs.
        let decision = BackgroundIngestCoordinator.ingestionDecision(for: png, store: model)
        #expect(decision == .skipNonIngestible(kind: .image))
    }

    @Test("XML source is not enqueued (application/xml → .binary)")
    func xmlIsNotIngestible() throws {
        let model = WikiStoreModel(store: try tempStore())
        let xml = addXML(to: model)

        #expect(xml.byteSize > 0)
        #expect(model.canIngest(xml))

        // The XML exclusion (§11-C3) routes application/xml → .binary.
        let decision = BackgroundIngestCoordinator.ingestionDecision(for: xml, store: model)
        #expect(decision == .skipNonIngestible(kind: .binary))
    }

    @Test("PDF without extracted markdown is enqueued (extraction then ingest)")
    func pdfIsEnqueued() throws {
        let model = WikiStoreModel(store: try tempStore())
        let pdf = addPDF(to: model)

        #expect(pdf.byteSize > 0)
        #expect(!model.hasProcessedMarkdown(for: pdf.id))

        let decision = BackgroundIngestCoordinator.ingestionDecision(for: pdf, store: model)
        #expect(decision == .enqueue)
    }

    @Test("Native markdown is enqueued (already the content)")
    func markdownIsEnqueued() throws {
        let model = WikiStoreModel(store: try tempStore())
        let md = addMarkdown(to: model)

        let decision = BackgroundIngestCoordinator.ingestionDecision(for: md, store: model)
        #expect(decision == .enqueue)
    }

    @Test("Byteless YouTube WITHOUT transcript is skipped as byteless")
    func youtubeWithoutTranscriptIsSkipped() throws {
        let store = try tempStore()
        _ = try addBytelessYouTube(to: store, withTranscript: false)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let yt = try #require(model.sources.first)
        #expect(yt.byteSize == 0)
        #expect(!model.canIngest(yt))  // byteless + no transcript → canIngest false

        // The registry gate says YES (provider wins for byteless embeds: the
        // synthetic `video/youtube` mime alone would classify as `.binary`,
        // but `.youtube` provider → `.youtubeTranscript`). The byteless guard
        // catches it though — no transcript → no content to stage.
        let decision = BackgroundIngestCoordinator.ingestionDecision(for: yt, store: model)
        #expect(decision == .skipByteless)
    }

    @Test("Byteless YouTube WITH transcript is enqueued (C5 — transcript seeded)")
    func youtubeWithTranscriptIsEnqueued() throws {
        // Per §11-C5: the test description must say "YouTube WITH transcript"
        // and seed a transcript via `appendProcessedMarkdown` BEFORE the
        // decision is run. A byteless YouTube WITHOUT a transcript is
        // correctly skipped by the byteless guard (covered above).
        let store = try tempStore()
        _ = try addBytelessYouTube(to: store, withTranscript: true)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let yt = try #require(model.sources.first)
        #expect(yt.byteSize == 0)               // still byteless…
        #expect(model.hasProcessedMarkdown(for: yt.id))  // …but has a transcript now
        #expect(model.canIngest(yt))

        let decision = BackgroundIngestCoordinator.ingestionDecision(for: yt, store: model)
        #expect(decision == .enqueue)
    }

    // MARK: - Batch filter (filterIngestibleSources)

    @Test("Mixed batch: only PDF + markdown are enqueued, PNG and XML dropped")
    func batchFilterDropsPNGandXML() throws {
        let model = WikiStoreModel(store: try tempStore())
        let png = addPNG(to: model)
        let xml = addXML(to: model)
        let pdf = addPDF(to: model)
        let md = addMarkdown(to: model)

        let enqueued = BackgroundIngestCoordinator.filterIngestibleSources(
            model.sources, store: model)

        #expect(!enqueued.contains(png.id), "PNG must not be enqueued")
        #expect(!enqueued.contains(xml.id), "XML must not be enqueued")
        #expect(enqueued.contains(pdf.id),  "PDF must be enqueued")
        #expect(enqueued.contains(md.id),   "Markdown must be enqueued")
    }

    @Test("Mixed batch: YouTube-with-transcript kept, YouTube-without dropped")
    func batchFilterDistinguishesTranscriptPresence() throws {
        // Use distinct video IDs — `addBytelessSource` dedups on external_identity.
        let store = try tempStore()
        let ytWith = try addBytelessYouTube(to: store, videoID: "dQw4w9WgXcQ", withTranscript: true)
        let ytWithout = try addBytelessYouTube(to: store, videoID: "aqz-KE-bpKQ", withTranscript: false)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let enqueued = BackgroundIngestCoordinator.filterIngestibleSources(
            model.sources, store: model)

        #expect(enqueued.contains(ytWith.id),
               "YouTube WITH transcript must be enqueued")
        #expect(!enqueued.contains(ytWithout.id),
               "YouTube WITHOUT transcript must be skipped (byteless guard)")
    }

    @Test("Empty store filters to empty list") func emptyStore() throws {
        let model = WikiStoreModel(store: try tempStore())
        let enqueued = BackgroundIngestCoordinator.filterIngestibleSources(
            model.sources, store: model)
        #expect(enqueued.isEmpty)
    }
}
#endif
