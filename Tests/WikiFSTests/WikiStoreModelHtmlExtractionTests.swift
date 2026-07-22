import Foundation
import Testing
@testable import WikiFSCore

/// Verifies `WikiStoreModel.extractHtml(for:backend:)` — the HTML extraction
/// trigger added in issue #799 PR2. Mirrors the PDF extraction tests but uses
/// the inline path (NOT the queue engine, which is PDF-coupled via
/// `ExtractionResolution.pdfData` / `convert(pdfData:)` / `seedPdfMarkdown`).
///
/// Covers AC.5–AC.7 from `plans/extraction-framework-pr2.md` + AC.9/AC.10/
/// AC.13 from `plans/extraction-framework-pr3.md`:
/// - AC.5: tag-based extraction stamps the matching technique
///   (`"html-to-markdown"`) and produces non-empty markdown.
/// - AC.6: defuddle extraction without an injected `htmlMarkdownExtractor`
///   degrades to tag-based (same fallback semantics as
///   `FormatMaterializer.enrich` at ingest) rather than silently returning nil.
/// - AC.7: re-extraction appends a coexisting alternative
///   (`appendProcessedMarkdown` always appends — first version is HEAD by the
///   default-active rule, later versions ride as alternatives until nominated).
/// - AC.9/AC.13: PR3 made `addURL` HTML ingest store raw bytes with NO
///   extracted-markdown sidecar; the Extract button then works on the
///   un-extracted source to create the first markdown version (proven here
///   in one test).
/// - AC.10: PR3 made `addFiles` HTML ingest store raw bytes with NO markdown
///   sidecar (LocalFileMaterializer → `FormatMaterializer.dispatch` HTML branch).
@MainActor
struct WikiStoreModelHtmlExtractionTests {

    /// Minimal `URLFetchService.URLResourceFetcher` conformer for the URL-
    /// ingest tests. Mirrors the `FakeFetcher` pattern in
    /// `WikiStoreModelAddURLTests` — returns a canned HTML response with the
    /// content-type set explicitly, which works cross-platform (vs.
    /// `addFiles`'s `LocalFileMaterializer` which needs `UniformTypeIdentifiers`
    /// for extension → MIME — an Apple-only framework).
    struct HTMLFakeFetcher: URLFetchService.URLResourceFetcher {
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

    // MARK: - PR3 — no auto-extraction at ingest + Extract button works on
    //   un-extracted sources (AC.9 / AC.10 / AC.13)

    /// PR3 AC.9 + AC.13: ingesting an HTML URL stores the raw bytes with NO
    /// extracted-markdown sidecar (`FormatMaterializer.dispatch` returns
    /// `extractedMarkdown: nil` for HTML post-PR3), AND the Extract button
    /// (`model.extractHtml(for:backend:)`) then works on that un-extracted
    /// source to create the first markdown version.
    ///
    /// This test REPLACES the deleted PR2 regression guard
    /// `autoExtractionStillRunsAtIngestInPR2` (which asserted the OPPOSITE —
    /// that an `addURL` HTML ingest auto-extracted a `"html-to-markdown"`
    /// sidecar). PR3 deliberately removes that behavior; the guard is updated
    /// here to assert the new invariant instead.
    @Test func extractHtmlWorksOnUnextractedURLIngest() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test-pr3-url")
        let model = WikiStoreModel(store: store)
        let fetcher = HTMLFakeFetcher(response: URLFetchService.FetchResponse(
            data: Data(sampleHTML.utf8),
            contentType: "text/html",
            finalURL: URL(string: "https://example.com/article")!))

        // 1. Ingest the HTML source via the regular URL path.
        let outcome = try await model.addURL("example.com/article", fetcher: fetcher)
        model.reloadFromStore()

        #expect(outcome.kind == .html, "format is still detected as .html post-PR3")
        let sourceID = try #require(model.sources.first?.id)

        // 2. PR3 AC.9: NO extracted-markdown sidecar landed. The store has
        //    zero `source_markdown_versions` rows for this source — the user
        //    must trigger extraction explicitly.
        #expect(try store.processedMarkdownHead(sourceID: sourceID) == nil,
               "PR3: URL HTML ingest must NOT auto-extract markdown")
        #expect(try store.processedMarkdownHistory(sourceID: sourceID).isEmpty)

        // The original HTML bytes ARE preserved as the source blob (issue #599
        // two-layer model is intact — only the sidecar extraction is gone).
        #expect(try store.sourceContent(id: sourceID) == Data(sampleHTML.utf8))

        // 3. PR3 AC.13: the Extract button (PR2's `extractHtml`) works on the
        //    un-extracted source — it creates the first markdown version.
        let version = await model.extractHtml(for: sourceID, backend: .tagBased)
        let head = try #require(version)
        #expect(head.origin == .extraction)
        #expect(head.technique == "html-to-markdown")
        #expect(!head.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Tag-based extraction scopes to <article>; noise containers must NOT appear.
        #expect(!head.content.contains("Home"))
        #expect(!head.content.contains("Example Corp"))

        // 4. The store now reflects the new head version (default-active rule).
        let headFromStore = try store.processedMarkdownHead(sourceID: sourceID)
        #expect(headFromStore?.id == head.id)
        #expect(try store.processedMarkdownHistory(sourceID: sourceID).count == 1)
    }

    /// PR3 AC.10: ingesting an HTML FILE via `addFiles` (the drag-drop / file-
    /// picker path) stores the raw bytes with NO extracted-markdown sidecar.
    /// `LocalFileMaterializer` derives the MIME from the `.html` extension via
    /// `UTType(filenameExtension: "html")` (Apple-only — see caveat below), so
    /// `FormatMaterializer.dispatch` hits the HTML branch and returns
    /// `extractedMarkdown: nil` post-PR3.
    ///
    /// Caveat: on Linux `UniformTypeIdentifiers` is unavailable, so the MIME
    /// resolves to nil → dispatch falls through to binary storage → no sidecar
    /// (the test passes for the wrong reason on Linux). CI is macOS-only per
    /// AGENTS.md so the macOS assertion is authoritative.
    @Test func htmlFileIngestDoesNotAutoExtract() async throws {
        let store = try tempStore()
        store.eventBus = WikiEventBus(wikiID: "test-pr3-file")
        let model = WikiStoreModel(store: store)

        // Write an HTML fixture to a real temp file so `LocalFileMaterializer`
        // can read + dispatch it (mirrors what `addFiles` does on drag-drop).
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pr3-file-\(UUID().uuidString).html")
        try Data(sampleHTML.utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        await model.addFiles([tmpFile])
        model.reloadFromStore()

        #expect(model.sources.count == 1, "the HTML file landed as a source")
        let id = try #require(model.sources.first?.id)

        // The original HTML bytes are preserved verbatim as the source blob.
        #expect(try store.sourceContent(id: id) == Data(sampleHTML.utf8))

        // PR3 AC.10: NO extracted-markdown sidecar — `source_markdown_versions`
        // for this source is empty until the user clicks Extract.
        #expect(try store.processedMarkdownHead(sourceID: id) == nil,
               "PR3: HTML file ingest (addFiles) must NOT auto-extract markdown")
        #expect(try store.processedMarkdownHistory(sourceID: id).isEmpty)

        // Sanity: the Extract button works on the un-extracted file-ingested
        // source too (mirrors the URL path's AC.13 assertion above).
        let version = await model.extractHtml(for: id, backend: .tagBased)
        let head = try #require(version)
        #expect(head.origin == .extraction)
        #expect(head.technique == "html-to-markdown")
        #expect(!head.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
