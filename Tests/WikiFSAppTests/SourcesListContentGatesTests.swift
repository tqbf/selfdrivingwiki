#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Tests for the PR2 §5.5 migration of `SourcesListView.canExtract` /
/// `canIngest` onto the content-type registry.
///
/// Pre-PR2 `canExtract` checked `MimeType.isPDF(source.mimeType) && head == nil`
/// — it offered the Extract Markdown context-menu item for **PDF only**. The
/// detail-view Extract button (`SourceDetailView.isExtractable`) covers HTML
/// too. So an HTML source in the list view silently had no Extract menu item,
/// even though the detail view offered extraction — a latent drift bug
/// between the two surfaces.
///
/// PR2 routes both through `ContentKind.resolve(...).capabilities
/// .hasFileExtractionBackend`, so PDF AND HTML both pop the menu. This test
/// file pins:
///
/// 1. **The drift fix** — HTML shows the Extract menu (was missing pre-PR2).
/// 2. **The PDF regression guard** — PDF still shows the Extract menu.
/// 3. **The head suppression** — Extract menu hidden when there's already an
///    extracted head (consistent with `needsExtraction` in detail view).
/// 4. **The non-extractable kinds** — markdown / text / image / binary /
///    unknown never offer the Extract menu.
///
/// The list view's helpers are `private` on `SourcesListViewController`; the
/// PR2 seam is `SourcesListContentGates.canExtract(source:
/// processedMarkdownHead:)` — a pure static helper the controller delegates
/// to (and tests invoke directly).
///
/// `canIngest` is intentionally NOT in the seam — it's the store-backed
/// double gate (`canIngest` byte + `shouldAutoIngest` content-type), exercised
/// end-to-end via `IngestGateTests` (chokepoint regression) and
/// `BackgroundIngestCoordinatorTests` (coordinator-only filter).
@Suite struct SourcesListContentGatesTests {

    // MARK: - Fixtures (constructed SourceSummaries, one per content type)

    /// A `SourceSummary` constructed directly (no store) with the minimum
    /// fields the `canExtract` seam reads (`mimeType`, `ext`).
    private func source(filename: String, mime: String?, ext: String) -> SourceSummary {
        SourceSummary(
            id: PageID(rawValue: "01J00000000000000000000FX"),
            filename: filename,
            ext: ext,
            mimeType: mime,
            byteSize: 1024,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1)
    }

    private func pdfSource() -> SourceSummary {
        source(filename: "paper.pdf", mime: "application/pdf", ext: "pdf")
    }
    private func htmlSource() -> SourceSummary {
        source(filename: "page.html", mime: "text/html", ext: "html")
    }
    private func xhtmlSource() -> SourceSummary {
        source(filename: "page.xhtml", mime: "application/xhtml+xml", ext: "xhtml")
    }
    private func markdownSource() -> SourceSummary {
        source(filename: "notes.md", mime: "text/markdown", ext: "md")
    }
    private func pngSource() -> SourceSummary {
        source(filename: "diagram.png", mime: "image/png", ext: "png")
    }
    private func xmlSource() -> SourceSummary {
        source(filename: "feed.xml", mime: "application/xml", ext: "xml")
    }
    private func textXmlSource() -> SourceSummary {
        source(filename: "feed.xml", mime: "text/xml", ext: "xml")
    }
    private func plainTextSource() -> SourceSummary {
        source(filename: "log.txt", mime: "text/plain", ext: "txt")
    }
    private func unknownSource() -> SourceSummary {
        source(filename: "blob.dat", mime: nil, ext: "dat")
    }

    /// A minimal `SourceMarkdownVersion` placeholder — only non-nil-ness
    /// matters to `canExtract`'s `processedMarkdownHead == nil` guard. Real
    /// extraction flows produce a fuller version, but the seam's contract
    /// is exactly `nil` vs `non-nil`.
    private func stubHead() -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: PageID(rawValue: "01J00000000000000000000HD"),
            sourceID: PageID(rawValue: "01J00000000000000000000FX"),
            parentID: nil,
            content: "# Extracted markdown placeholder",
            origin: .extraction,
            note: nil,
            createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - The headline drift fix (§5.5): HTML now offers Extract

    @Test("PDF — canExtract is true (head == nil)")
    func pdfOffersExtract() {
        #expect(SourcesListContentGates.canExtract(
            source: pdfSource(), processedMarkdownHead: nil))
    }

    @Test("HTML — canExtract is true (the latent drift fix)")
    func htmlOffersExtract() {
        // PRE-PR2: `MimeType.isPDF("text/html")` → false → no Extract menu.
        // POST-PR2: registry routes text/html → .html → hasFileExtractionBackend
        // == true → Extract menu shown.
        #expect(SourcesListContentGates.canExtract(
            source: htmlSource(), processedMarkdownHead: nil))
    }

    @Test("XHTML — canExtract is true")
    func xhtmlOffersExtract() {
        #expect(SourcesListContentGates.canExtract(
            source: xhtmlSource(), processedMarkdownHead: nil))
    }

    @Test("HTML via ext fallback (nil mime + .html ext) — canExtract is true")
    func htmlExtFallbackOffersExtract() {
        let s = source(filename: "page.html", mime: nil, ext: "html")
        #expect(SourcesListContentGates.canExtract(
            source: s, processedMarkdownHead: nil))
    }

    // MARK: - Head suppression (mirrors detail-view needsExtraction shape)

    @Test("PDF with a processed-markdown head — canExtract is false (use Re-extract)")
    func pdfWithHeadHidden() {
        // Even an extracted-head placeholder (any non-nil) suppresses.
        #expect(!SourcesListContentGates.canExtract(
            source: pdfSource(), processedMarkdownHead: stubHead()))
    }

    @Test("HTML with a processed-markdown head — canExtract is false")
    func htmlWithHeadHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: htmlSource(), processedMarkdownHead: stubHead()))
    }

    // MARK: - Non-extractable kinds (the bug class + native — never offer Extract)

    @Test("Markdown — canExtract is false (already the content)")
    func markdownHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: markdownSource(), processedMarkdownHead: nil))
    }

    @Test("PNG — canExtract is false (the bug class)")
    func pngHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: pngSource(), processedMarkdownHead: nil))
    }

    @Test("application/xml — canExtract is false (.binary)")
    func applicationXmlHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: xmlSource(), processedMarkdownHead: nil))
    }

    @Test("text/xml — canExtract is false (§11-C3 XML exclusion)")
    func textXmlHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: textXmlSource(), processedMarkdownHead: nil))
    }

    @Test("Plain text — canExtract is false (nothing to extract)")
    func plainTextHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: plainTextSource(), processedMarkdownHead: nil))
    }

    @Test("Unknown / binary — canExtract is false (fail safe)")
    func unknownHidden() {
        #expect(!SourcesListContentGates.canExtract(
            source: unknownSource(), processedMarkdownHead: nil))
    }

    // MARK: - Null-store shape (mirrors SourcesListViewController.canExtract)

    @Test("canExtract handles an empty SourceSummary (no fields crash)")
    func canExtractHandlesEmptyShape() {
        let minimal = SourceSummary(
            id: PageID(rawValue: "01J00000000000000000000EM"),
            filename: "x",
            ext: "",
            mimeType: nil,
            byteSize: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1)
        #expect(!SourcesListContentGates.canExtract(
            source: minimal, processedMarkdownHead: nil))
    }
}
#endif
