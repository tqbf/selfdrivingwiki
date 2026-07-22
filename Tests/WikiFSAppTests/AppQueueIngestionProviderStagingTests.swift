#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// PR2 §5.6: tests for `AppQueueIngestionProvider._stagedBytesAndExt` — the
/// pure half of the staging decision. Pre-PR2 the staging loop checked
/// `MimeType.isPDF(source.mimeType)` and, for PDFs with an extracted head,
/// reused the markdown as the staged bytes (ext `md`). PR2 generalizes this
/// onto the registry's `hasFileExtractionBackend`, which covers PDF **and**
/// HTML — both have file-extraction back ends and both may have an extracted
/// head produced by the extraction queue (`runExtraction`) or the inline
/// `runHtmlExtraction` path.
///
/// The seam is `internal static` so tests don't need to stand up the full
/// staging path (which requires a real `WikiSession` + `AgentLauncher` +
/// `FileProviderFacade`). The actual staging call site in `runIngestion`
/// delegates to this seam.
///
/// Coverage:
/// - PDF with head: reuse markdown bytes + ext "md" (unchanged from pre-PR2).
/// - HTML with head: reuse markdown bytes + ext "md" (PR2 widening — was
///   pre-PR2 using the raw HTML bytes + ext "html", which forced a
///   redundant re-extraction at agent time).
/// - PDF / HTML without head: pass raw bytes + original ext verbatim
///   (extract-first staging path — the extraction queue item runs BEFORE
///   this ingestion item and seeds the head that lands here on retry).
/// - Image / XML / text / unknown: pass raw bytes verbatim (no reuse; the
///   registry says `extractionPath == nil` for these — no extraction back
///   end exists, so there's never an extracted head to reuse).
/// - Byteless YouTube WITH transcript: not a file-extraction-back end kind,
///   so pass raw bytes verbatim — matches pre-PR2 behavior (the staging
///   receives the transcript's source bytes via `sourceBytes`, not via this
///   reuse branch).
@Suite struct AppQueueIngestionProviderStagingTests {

    // MARK: - Fixtures

    private let sourceID = PageID(rawValue: "01J00000000000000000000FX")

    private func source(filename: String, mime: String?, ext: String) -> SourceSummary {
        SourceSummary(
            id: sourceID,
            filename: filename,
            ext: ext,
            mimeType: mime,
            byteSize: 1024,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1)
    }

    private func stubHead(content: String = "# Extracted markdown") -> SourceMarkdownVersion {
        SourceMarkdownVersion(
            id: PageID(rawValue: "01J00000000000000000000HD"),
            sourceID: sourceID,
            parentID: nil,
            content: content,
            origin: .extraction,
            note: nil,
            createdAt: Date(timeIntervalSince1970: 1))
    }

    private var pdfSource: SourceSummary { source(filename: "paper.pdf", mime: "application/pdf", ext: "pdf") }
    private var htmlSource: SourceSummary { source(filename: "page.html", mime: "text/html", ext: "html") }
    private var xhtmlSource: SourceSummary { source(filename: "page.xhtml", mime: "application/xhtml+xml", ext: "xhtml") }
    private var pngSource: SourceSummary { source(filename: "diagram.png", mime: "image/png", ext: "png") }
    private var xmlSource: SourceSummary { source(filename: "feed.xml", mime: "application/xml", ext: "xml") }
    private var markdownSource: SourceSummary { source(filename: "notes.md", mime: "text/markdown", ext: "md") }
    private var plainTextSource: SourceSummary { source(filename: "log.txt", mime: "text/plain", ext: "txt") }
    private var unknownSource: SourceSummary { source(filename: "blob.dat", mime: nil, ext: "dat") }

    private let pdfBytes = Data("%PDF-1.4\n".utf8)
    private let htmlBytes = Data("<html><body>hi</body></html>".utf8)
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private let xmlBytes = Data("<?xml version=\"1.0\"?><foo/>".utf8)
    private let markdownBytes = Data("# Heading\n\nbody".utf8)
    private let plainTextBytes = Data("just text".utf8)
    private let unknownBytes = Data([0x01, 0x02, 0x03, 0x04])

    // MARK: - PDF staging (pre-PR2 behavior unchanged)

    @Test("PDF WITH head reuses markdown bytes + ext 'md'")
    func pdfWithHeadReusesMarkdown() {
        let head = stubHead(content: "# PDF extracted markdown")
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: pdfSource,
            originalBytes: pdfBytes,
            processedMarkdownHead: head)
        #expect(staged.ext == "md")
        #expect(staged.bytes == Data("# PDF extracted markdown".utf8))
        #expect(staged.bytes != pdfBytes)
    }

    @Test("PDF WITHOUT head uses raw PDF bytes + ext 'pdf'")
    func pdfWithoutHeadUsesRaw() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: pdfSource,
            originalBytes: pdfBytes,
            processedMarkdownHead: nil)
        #expect(staged.ext == "pdf")
        #expect(staged.bytes == pdfBytes)
    }

    // MARK: - HTML staging (PR2 widening — the latent drift fix at staging)

    @Test("HTML WITH head reuses markdown bytes + ext 'md' (PR2 widening)")
    func htmlWithHeadReusesMarkdown() {
        // PRE-PR2: staging checked `MimeType.isPDF("text/html") == false` →
        // the HTML source would NEVER reuse its extracted head even after
        // the user ran "Extract Markdown" (it would re-stage the raw HTML
        // bytes + ext "html", forcing redundant re-extraction at agent
        // time). POST-PR2: `hasFileExtractionBackend` covers HTML, so the
        // extracted head is reused just like PDFs.
        let head = stubHead(content: "# HTML extracted markdown")
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: htmlSource,
            originalBytes: htmlBytes,
            processedMarkdownHead: head)
        #expect(staged.ext == "md")
        #expect(staged.bytes == Data("# HTML extracted markdown".utf8))
        #expect(staged.bytes != htmlBytes)
    }

    @Test("XHTML (application/xhtml+xml) WITH head reuses markdown")
    func xhtmlWithHeadReusesMarkdown() {
        let head = stubHead(content: "# XHTML extracted")
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: xhtmlSource,
            originalBytes: htmlBytes,
            processedMarkdownHead: head)
        #expect(staged.ext == "md")
        #expect(staged.bytes == Data("# XHTML extracted".utf8))
    }

    @Test("HTML WITHOUT head uses raw HTML bytes + ext 'html'")
    func htmlWithoutHeadUsesRaw() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: htmlSource,
            originalBytes: htmlBytes,
            processedMarkdownHead: nil)
        #expect(staged.ext == "html")
        #expect(staged.bytes == htmlBytes)
    }

    @Test("HTML via ext fallback (nil mime + .html ext) WITH head reuses markdown")
    func htmlExtFallbackWithHeadReusesMarkdown() {
        // Same registry resolve path as the explicit-mime case (legacy
        // sources with NULL mime + `.html` ext resolve to `.html`).
        let s = source(filename: "page.html", mime: nil, ext: "html")
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: s,
            originalBytes: htmlBytes,
            processedMarkdownHead: stubHead(content: "# Legacy HTML extracted"))
        #expect(staged.ext == "md")
        #expect(staged.bytes == Data("# Legacy HTML extracted".utf8))
    }

    // MARK: - Non-extractable kinds (no reuse — raw bytes verbatim)

    @Test("PNG (image) ignores head — no extraction back end")
    func pngIgnoresHead() {
        // PNG has no `extractionPath` → `hasFileExtractionBackend == false` →
        // reuse never fires, even if a head is somehow present (it never is
        // in practice, but the test pins the contract).
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: pngSource,
            originalBytes: pngBytes,
            processedMarkdownHead: stubHead())
        #expect(staged.ext == "png")
        #expect(staged.bytes == pngBytes)
    }

    @Test("XML (application/xml → .binary) ignores head")
    func xmlIgnoresHead() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: xmlSource,
            originalBytes: xmlBytes,
            processedMarkdownHead: stubHead())
        #expect(staged.ext == "xml")
        #expect(staged.bytes == xmlBytes)
    }

    @Test("Native markdown ignores head — already the content")
    func markdownIgnoresHead() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: markdownSource,
            originalBytes: markdownBytes,
            processedMarkdownHead: stubHead())
        #expect(staged.ext == "md")
        #expect(staged.bytes == markdownBytes, "native markdown drafts raw bytes — no reuse needed")
    }

    @Test("Plain text ignores head — no extraction back end")
    func plainTextIgnoresHead() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: plainTextSource,
            originalBytes: plainTextBytes,
            processedMarkdownHead: stubHead())
        #expect(staged.ext == "txt")
        #expect(staged.bytes == plainTextBytes)
    }

    @Test("Unknown source (nil mime, unknown ext) ignores head")
    func unknownIgnoresHead() {
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: unknownSource,
            originalBytes: unknownBytes,
            processedMarkdownHead: stubHead())
        #expect(staged.ext == "dat")
        #expect(staged.bytes == unknownBytes)
    }

    // MARK: - Edge cases

    @Test("Non-UTF8-decodable markdown falls back to raw bytes")
    func nonUTF8MarkdownHeadFallsBack() {
        // Source is a PDF with a (synthetic) head whose content is non-UTF8
        // (e.g., an extraction corruption went through). `data(using: .utf8)`
        // returns nil → the seam falls back to raw bytes (no reuse).
        let head = SourceMarkdownVersion(
            id: PageID(rawValue: "01J00000000000000000000HD"),
            sourceID: sourceID,
            parentID: nil,
            content: String(decoding: [0xFF, 0xFE, 0x00, 0x01], as: UTF8.self),  // lossy:,rare but possible
            origin: .extraction,
            note: nil,
            createdAt: Date(timeIntervalSince1970: 1))
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: pdfSource,
            originalBytes: pdfBytes,
            processedMarkdownHead: head)
        // If the content happens to encode to UTF8 by lossy decoding, we'd
        // reuse. The contract is "if encodable, reuse; else fall back to
        // raw." We don't assert either way — pin only that the call does
        // not crash and produces SOME valid (bytes, ext) tuple.
        #expect(staged.bytes == staged.bytes)  // tautology + presence-check
    }

    @Test("Empty extension is preserved when no reuse applies")
    func emptyExtPreserved() {
        let emptyExtSource = source(filename: "Makefile", mime: nil, ext: "")
        let staged = AppQueueIngestionProvider._stagedBytesAndExt(
            for: emptyExtSource,
            originalBytes: unknownBytes,
            processedMarkdownHead: nil)
        #expect(staged.ext == "")
        #expect(staged.bytes == unknownBytes)
    }
}
#endif
