import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.extractHtml(for:backend:)` — the HTML extraction
/// trigger added in issue #799 PR2. Mirrors the PDF extraction tests but uses
/// the inline path (NOT the queue engine, which is PDF-coupled via
/// `ExtractionResolution.pdfData` / `convert(pdfData:)` / `seedPdfMarkdown`).
///
/// Covers AC.5–AC.8 from `plans/extraction-framework-pr2.md`:
/// - AC.5: tag-based extraction stamps the matching technique
///   (`"html-to-markdown"`) and produces non-empty markdown.
/// - AC.6: defuddle extraction without an injected `htmlMarkdownExtractor`
///   degrades to tag-based (same fallback semantics as
///   `FormatMaterializer.enrich` at ingest) rather than silently returning nil.
/// - AC.7: re-extraction appends a coexisting alternative
///   (`appendProcessedMarkdown` always appends — first version is HEAD by the
///   default-active rule, later versions ride as alternatives until nominated).
/// - AC.8: existing auto-extraction at ingest still runs (the `enrichWithDefuddle`
///   callers are NOT touched in PR2 — PR3 removes them).
@MainActor
struct WikiStoreModelHtmlExtractionTests {

    /// Minimal `URLFetchService.URLResourceFetcher` conformer for the
    /// auto-extraction test. Mirrors the `FakeFetcher` pattern in
    /// `WikiStoreModelAddURLTests` — returns a canned HTML response with the
    /// content-type set explicitly, which works cross-platform (vs.
    /// `addFiles`'s `LocalFileMaterializer` which needs `UniformTypeIdentifiers`
    /// for extension → MIME — an Apple-only framework).
    struct AutoExtractionFakeFetcher: URLFetchService.URLResourceFetcher {
        let response: URLFetchService.FetchResponse
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse { response }
    }

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-htmlextract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// A non-trivial HTML fixture with a title, body, and noise containers
    /// (`<nav>`/`<footer>`) — exercises `HTMLToMarkdown`'s title extraction +
    /// content scoping so the test catches a regression if the conformer is
    /// ever wired to a no-op path.
    private let sampleHTML = #"""
    <!DOCTYPE html>
    <html>
    <head><title>Sample Article</title></head>
    <body>
        <nav><a href="/home">Home</a> <a href="/about">About</a></nav>
        <article>
            <h1>Sample Article</h1>
            <p>This is the <strong>first</strong> paragraph with a
            <a href="https://example.com/page">link</a> in it.</p>
            <p>The second paragraph has <em>italic</em> text.</p>
            <ul><li>One</li><li>Two</li></ul>
        </article>
        <footer>© 2026 Example Corp</footer>
    </body>
    </html>
    """#

    /// Summons a wiki + model with one bare-HTML source already ingested (no
    /// extracted-markdown sidecar — simulating the state after PR3 lands; in
    /// PR2 the ingest path still auto-extracts, but `extractHtml` reads the
    /// HTML source bytes directly and is independent of any sidecar the ingest
    /// path may already have written). Returns the new source's id.
    private func modelWithHTMLSource() throws -> (GRDBWikiStore, WikiStoreModel, PageID) {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test-html-extract")
        let model = WikiStoreModel(store: store)
        let summary = try store.addSource(
            filename: "article.html",
            data: Data(sampleHTML.utf8))
        return (store, model, summary.id)
    }

    // MARK: - AC.5 — tag-based extraction stamps the matching technique

    @Test func extractHtmlWithTagBasedStampsHtmlToMarkdownTechnique() async throws {
        let (store, model, sourceID) = try modelWithHTMLSource()

        let version = await model.extractHtml(for: sourceID, backend: .tagBased)

        let head = try #require(version)
        #expect(head.origin == .extraction)
        #expect(head.technique == "html-to-markdown")
        #expect(!head.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Tag-based extraction scopes to <article>; the noise containers
        // (<nav>/<footer>) must NOT appear in the body.
        #expect(!head.content.contains("Home"))
        #expect(!head.content.contains("Example Corp"))
        // The body should include the article's prose.
        #expect(head.content.contains("first") || head.content.contains("second"))
        // Re-read from the store to confirm the write landed and the head
        // resolves to the version we just wrote (default-active rule).
        let headFromStore = try store.processedMarkdownHead(sourceID: sourceID)
        #expect(headFromStore?.id == head.id)
    }

    // MARK: - AC.6 — defuddle fallback when no extractor is injected

    @Test func extractHtmlWithDefuddleDegradesToTagBasedWhenExtractorNotInjected() async throws {
        // No `htmlMarkdownExtractor` injection — the model's `nil` represents
        // CI / clean dev before `make build` (where the AppKit-coupled
        // `LocalDefuddleExtractor` in the WikiFS app target can't be linked).
        // The defuddle branch must degrade to tag-based (same fallback
        // semantics as `FormatMaterializer.enrich`) rather than silently
        // returning nil — so the user always gets a markdown version on Extract.
        let (store, model, sourceID) = try modelWithHTMLSource()
        #expect(model.htmlMarkdownExtractor == nil,
               "test precondition: no extractor injected")

        let version = await model.extractHtml(for: sourceID, backend: .defuddle)

        let head = try #require(version)
        #expect(head.origin == .extraction)
        // Degrade-to-tag-based: the defuddle path failed (no extractor) and
        // the call fell through to `TagBasedHtmlExtractor`, which stamps
        // "html-to-markdown" — NOT "defuddle".
        #expect(head.technique == "html-to-markdown")
        #expect(!head.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        _ = store  // silence unused-binding warning
    }

    // MARK: - AC.7 — re-extract appends a coexisting alternative

    @Test func reExtractHtmlAppendsCoexistingAlternative() async throws {
        let (store, model, sourceID) = try modelWithHTMLSource()

        // First extraction (tag-based via the explicit backend).
        let v1 = try #require(await model.extractHtml(for: sourceID, backend: .tagBased))
        #expect(v1.parentID == nil, "first version is the lineage root")

        // Second extraction — same backend, would produce identical bytes,
        // but `appendProcessedMarkdown` CASes the body so the version row
        // still appends a NEW id pointing to the SAME blob hash.
        let v2 = try #require(await model.extractHtml(for: sourceID, backend: .tagBased))
        #expect(v2.id != v1.id, "a new version was appended — re-extract never clobbers")
        #expect(v2.parentID == v1.id, "lineage: v2 chains off v1")

        // Both versions must coexist in the history (alternatives UI).
        let history = try store.processedMarkdownHistory(sourceID: sourceID)
        #expect(history.count == 2)
        let historyIDs = Set(history.map(\.id))
        #expect(historyIDs.contains(v1.id))
        #expect(historyIDs.contains(v2.id))

        // The newer of the two is HEAD by the default-active rule (MAX id
        // wins). THE key invariant for the "Re-extract with" menu: a fresh
        // extraction becomes the new HEAD without deleting the prior — the
        // user can switch back via the alternatives menu.
        let head = try store.processedMarkdownHead(sourceID: sourceID)
        #expect(head?.id == v2.id)
    }

    // MARK: - AC.8 — auto-extraction at ingest still runs

    @Test func autoExtractionStillRunsAtIngestInPR2() async throws {
        // PR2 does NOT remove the `enrichWithDefuddle` calls at ingest — that's
        // PR3. So ingesting an HTML source via the regular path (which routes
        // through `FormatMaterializer.dispatch` → `extractedMarkdown` sidecar →
        // `appendExtractedMarkdown`) must still produce a markdown version
        // alongside the source bytes. This test will START FAILING in PR3 —
        // it's the regression guard that PR3's "remove auto-extraction" work is
        // intentionally deleting this behavior. (See AC.9–AC.13 in the parent
        // plan: PR3 removes the three `enrichWithDefuddle` callers.)
        //
        // Uses `addURL` + a fake HTTP fetcher (mirrors the existing
        // `WikiStoreModelAddURLTests.htmlURLLandsVerbatimWithMarkdownSidecar`)
        // rather than `addFiles` because `addFiles` routes through
        // `LocalFileMaterializer`, which derives MIME from the file extension
        // via `UTType(filenameExtension:)`. `UniformTypeIdentifiers` is an
        // Apple-only framework, so on Linux the MIME resolves to nil, the
        // dispatch falls through to binary storage, and no markdown sidecar is
        // written — a pre-existing Linux limitation unrelated to this PR. The
        // HTTP fetcher provides the content-type explicitly, which works cross-
        // platform and is the same path the existing test uses.
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test-autoextract")
        let model = WikiStoreModel(store: store)
        let fetcher = AutoExtractionFakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(sampleHTML.utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/article")!))
        let outcome = try await model.addURL("example.com/article", fetcher: fetcher)
        model.reloadFromStore()

        #expect(outcome.kind == .html, "PR2 invariant: HTML source preserves its bytes and lands an extracted-markdown sidecar")

        let sourceID = try #require(model.sources.first?.id)
        let head = try store.processedMarkdownHead(sourceID: sourceID)
        let headGeneratedByIngest = try #require(
            head,
            "PR2 invariant: ingesting an HTML source auto-extracts a markdown sidecar")
        // The ingest path's auto-extraction stamps "html-to-markdown" (the
        // tag-based converter) when no defuddle extractor is injected — same
        // technique as the explicit extractHtml trigger above.
        #expect(headGeneratedByIngest.technique == "html-to-markdown")
        // The original HTML bytes are preserved as the source blob alongside
        // the extracted-markdown version (issue #599 two-layer model).
        let originalBytes = try store.sourceContent(id: sourceID)
        #expect(originalBytes == Data(sampleHTML.utf8))
    }

    // MARK: - guard: empty / unreadable bytes

    @Test func extractHtmlOnEmptySourceReturnsNil() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test-empty")
        let model = WikiStoreModel(store: store)
        let summary = try store.addSource(
            filename: "empty.html",
            data: Data())  // zero bytes — `sourceContent` returns empty

        let version = await model.extractHtml(for: summary.id, backend: .tagBased)
        #expect(version == nil, "empty source bytes must not append an empty markdown version")
    }
}
