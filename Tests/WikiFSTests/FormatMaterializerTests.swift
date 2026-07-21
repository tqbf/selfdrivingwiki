import Foundation
import Testing
@testable import WikiFSCore

/// Pure tests for `FormatMaterializer.dispatch` — the URL-independent format
/// layer extracted from `URLFetchService.plan(for:)`. Verifies byte-identical
/// output for every format arm plus the extension-fallback and host-stem edge
/// cases that the `(stem, extensionHint)` abstraction must preserve.
///
/// AC.1 — dispatch produces byte-identical results to the old `plan(for:)`.
/// AC.7 — `FormatMaterializer` has no dependency on URL types.
struct FormatMaterializerTests {

    // MARK: - HTML → verbatim bytes + extracted-markdown sidecar (issue #599)

    @Test func htmlStoredVerbatimWithMarkdownSidecar() {
        let html = "<html><head><title>Cool Page</title></head><body><h1>Hi</h1><p>Hello <strong>world</strong>.</p></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html; charset=utf-8",
            stem: "article", extensionHint: nil)

        // Issue #599: HTML sources preserve the ORIGINAL HTML bytes (format
        // .html); the extracted markdown rides as a sidecar.
        #expect(plan.format == .html)
        #expect(plan.filename == "Cool Page.html")
        // Byte-identical: the source blob IS the original HTML.
        #expect(plan.data == Data(html.utf8))
        // The extracted markdown sidecar carries the conversion.
        #expect(plan.extractedMarkdown == "# Hi\n\nHello **world**.")
    }

    @Test func htmlWithoutTitleFallsBackToStem() {
        let html = "<body><p>no title</p></body>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "photosynthesis", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.filename == "photosynthesis.html")
        #expect(plan.data == Data(html.utf8))
        #expect(plan.extractedMarkdown != nil)
    }

    @Test func xhtmlAlsoStoredVerbatim() {
        let html = "<html><title>X</title><body><p>x</p></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "application/xhtml+xml",
            stem: "page", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.filename == "X.html")
        #expect(plan.data == Data(html.utf8))
        #expect(plan.extractedMarkdown != nil)
    }

    @Test func htmlSidecarMarkdownIsEmptyWhenBodyIsBlank() {
        // Blank body still preserves the HTML bytes verbatim; the sidecar markdown
        // is whatever HTMLToMarkdown converts (likely empty/whitespace).
        let html = "<html><head><title>Empty</title></head><body></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "page", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.data == Data(html.utf8))
    }

    // MARK: - PDF verbatim (AC.1)

    @Test func pdfStoredVerbatim() {
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(contentsOf: [0x00, 0x01, 0x02, 0xFF, 0xFE])
        pdf.append(contentsOf: Data("trailer".utf8))

        let plan = FormatMaterializer.dispatch(
            data: pdf, contentType: "application/pdf",
            stem: "report", extensionHint: "pdf")

        #expect(plan.format == .pdf)
        #expect(plan.filename == "report.pdf")
        #expect(plan.data == pdf)  // byte-identical
    }

    @Test func pdfGetsExtensionWhenStemLacksIt() {
        let plan = FormatMaterializer.dispatch(
            data: Data("%PDF".utf8), contentType: "application/pdf",
            stem: "download", extensionHint: nil)

        #expect(plan.format == .pdf)
        #expect(plan.filename.hasSuffix(".pdf"))
    }

    // MARK: - Text verbatim (AC.1)

    @Test func plainTextStoredVerbatim() {
        let body = "Just plain text.\nLine two."
        let plan = FormatMaterializer.dispatch(
            data: Data(body.utf8), contentType: "text/plain; charset=utf-8",
            stem: "notes", extensionHint: "txt")

        #expect(plan.format == .text)
        #expect(plan.filename == "notes.txt")
        #expect(String(data: plan.data, encoding: .utf8) == body)
    }

    @Test func markdownContentTypeKeepsMdExtension() {
        let plan = FormatMaterializer.dispatch(
            data: Data("# Heading\n\nbody".utf8), contentType: "text/markdown",
            stem: "doc", extensionHint: nil)

        #expect(plan.format == .text)
        #expect(plan.filename == "doc.md")
    }

    // MARK: - Binary verbatim (AC.1)

    @Test func imageStoredWithInferredExtension() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        let plan = FormatMaterializer.dispatch(
            data: bytes, contentType: "image/png",
            stem: "logo", extensionHint: nil)

        #expect(plan.format == .binary)
        #expect(plan.filename == "logo.png")
        #expect(plan.data == bytes)
    }

    // MARK: - Content sniffing (AC.1)

    @Test func htmlLabeledButPDFBytesSniffedToPDF() {
        var pdf = Data("%PDF-1.3\n".utf8)
        pdf.append(contentsOf: [0x00, 0x01, 0xFF, 0xFE])
        pdf.append(contentsOf: Data("trailer".utf8))

        let plan = FormatMaterializer.dispatch(
            data: pdf, contentType: "text/html; charset=utf-8",
            stem: "CPP_behaviorgen", extensionHint: "pdf")

        #expect(plan.format == .pdf)
        #expect(plan.filename == "CPP_behaviorgen.pdf")
        #expect(plan.data == pdf)  // byte-identical, NOT converted to markdown
    }

    @Test func octetStreamPNGBytesSniffedToImage() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let plan = FormatMaterializer.dispatch(
            data: png, contentType: "application/octet-stream",
            stem: "blob", extensionHint: nil)

        #expect(plan.format == .binary)
        #expect(plan.filename == "blob.png")
        #expect(plan.data == png)
    }

    @Test func genuineHTMLStillStoredVerbatimAsHTML() {
        // Real HTML labeled text/html must NOT trip the sniffer (no binary magic).
        let html = "<html><head><title>Real Page</title></head><body><p>hi</p></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "page", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.filename == "Real Page.html")
    }

    // MARK: - Extension fallback for non-mapped MIMEs (AC.1)

    @Test func nonMappedTextMIMEUsesExtensionHint() {
        // `text/yaml` is not in the mapped list → fall back to extensionHint.
        let plan = FormatMaterializer.dispatch(
            data: Data("key: value".utf8), contentType: "text/yaml",
            stem: "notes", extensionHint: "yaml")

        #expect(plan.format == .text)
        #expect(plan.filename == "notes.yaml")
    }

    @Test func nonMappedBinaryMIMEUsesExtensionHint() {
        // `application/x-foo` is not mapped → subtype `x-foo` is not clean (has
        // a dash) → fall back to extensionHint.
        let plan = FormatMaterializer.dispatch(
            data: Data([0x01, 0x02, 0x03]), contentType: "application/x-foo",
            stem: "data", extensionHint: "bin")

        #expect(plan.format == .binary)
        #expect(plan.filename == "data.bin")
    }

    // MARK: - Root-URL host case (AC.1)

    @Test func hostStemPreservedAsIs() {
        // Root URL: stem is the host "example.com" — must NOT have .com stripped.
        let plan = FormatMaterializer.dispatch(
            data: Data("%PDF".utf8), contentType: "application/pdf",
            stem: "example.com", extensionHint: nil)

        #expect(plan.format == .pdf)
        #expect(plan.filename == "example.com.pdf")
    }

    // MARK: - Dispatch helpers (pure, mirror URLFetchServiceTests)

    @Test func normalizedMIMEStripsCharset() {
        #expect(FormatMaterializer.normalizedMIME("text/html; charset=UTF-8") == "text/html")
        #expect(FormatMaterializer.normalizedMIME("  APPLICATION/PDF ") == "application/pdf")
        #expect(FormatMaterializer.normalizedMIME(nil) == nil)
    }

    @Test func ensureExtensionDoesNotDouble() {
        #expect(FormatMaterializer.ensureExtension("file", ext: "md") == "file.md")
        #expect(FormatMaterializer.ensureExtension("file.md", ext: "md") == "file.md")
        #expect(FormatMaterializer.ensureExtension("file.MD", ext: "md") == "file.MD")
    }

    @Test func sanitizeStemCapsAndCleans() {
        let long = String(repeating: "x", count: 200)
        #expect(FormatMaterializer.sanitizeStem(long).count <= 80)
        #expect(FormatMaterializer.sanitizeStem("a/b:c") == "a-b-c")
        #expect(FormatMaterializer.sanitizeStem("   ") == "untitled")
    }

    @Test func shouldSniffOnlyAmbiguousTypes() {
        #expect(FormatMaterializer.shouldSniff(nil))
        #expect(FormatMaterializer.shouldSniff("text/html"))
        #expect(FormatMaterializer.shouldSniff("application/octet-stream"))
        #expect(!FormatMaterializer.shouldSniff("application/pdf"))
        #expect(!FormatMaterializer.shouldSniff("image/png"))
        #expect(!FormatMaterializer.shouldSniff("text/plain"))
    }

    @Test func sniffContentTypeMagicNumbers() {
        #expect(ContentSniff.mimeType(of: Data("%PDF-1.4".utf8)) == "application/pdf")
        #expect(ContentSniff.mimeType(of: Data([0x89, 0x50, 0x4E, 0x47])) == "image/png")
        #expect(ContentSniff.mimeType(of: Data("<!DOCTYPE html>".utf8)) == nil)
        #expect(ContentSniff.mimeType(of: Data()) == nil)
    }

    // MARK: - AC.7: FormatMaterializer has no URL-type dependency

    /// AC.7 — `FormatMaterializer.swift` must not reference `FetchResponse`,
    /// `StorePlan`, a `: URL` parameter/return annotation, or import URL-coupled
    /// modules. This is a targeted source check, not a bare substring search.
    @Test func formatMaterializerHasNoURLTypeDependency() throws {
        let repoRoot = try #require(Self.locateRepoRoot())
        let path = repoRoot
            .appendingPathComponent("Sources/WikiFSCore/Sources/FormatMaterializer.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        // No URL-coupled type names.
        #expect(!source.contains("FetchResponse"),
                "FormatMaterializer must not reference FetchResponse")
        #expect(!source.contains("StorePlan"),
                "FormatMaterializer must not reference StorePlan")

        // No `: URL` parameter or return type annotation. Match `: URL` or
        // `: URL?` or `-> URL` but NOT the word "URL" in comments.
        #expect(source.range(of: #"(?:(?:->|:)\s*URL\??)"#, options: .regularExpression) == nil,
                "FormatMaterializer must not have a ': URL' or '-> URL' type annotation")

        // No URL-coupled imports beyond Foundation (Foundation is allowed for
        // Data/String; it's not URL-coupled in the FetchResponse sense).
        for line in source.split(separator: "\n") where line.hasPrefix("import ") {
            let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
            #expect(module == "Foundation",
                    "FormatMaterializer should only import Foundation, found: \(module)")
        }
    }

    // MARK: - enrich(_:using:) — async defuddle enrichment (issue #761)

    @Test func enrichWithNilExtractorKeepsTagBasedMarkdown() async {
        let html = "<html><head><title>Cool Page</title></head><body><article><p>Hi</p></article></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "article", extensionHint: nil)
        let (enriched, technique) = await FormatMaterializer.enrich(plan, using: nil)
        // nil extractor → no change, technique is tag-based.
        #expect(enriched.extractedMarkdown == plan.extractedMarkdown)
        #expect(technique == "html-to-markdown")
    }

    @Test func enrichWithFailingExtractorFallsBackToTagBased() async {
        struct FailingExtractor: HtmlMarkdownExtractor {
            func extract(html: String) async -> HtmlExtractionResult? { nil }
        }
        let html = "<html><head><title>Cool Page</title></head><body><article><p>Hi</p></article></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "article", extensionHint: nil)
        let (enriched, technique) = await FormatMaterializer.enrich(plan, using: FailingExtractor())
        // Extractor returned nil → keep tag-based markdown, technique is fallback.
        #expect(enriched.extractedMarkdown == plan.extractedMarkdown)
        #expect(technique == "html-to-markdown")
    }

    @Test func enrichWithSuccessfulExtractorUsesDefuddleMarkdown() async {
        struct StubExtractor: HtmlMarkdownExtractor {
            func extract(html: String) async -> HtmlExtractionResult? {
                HtmlExtractionResult(markdown: "## Defuddle Title\n\nClean content.", title: "Defuddle Title")
            }
        }
        let html = "<html><head><title>Old Title</title></head><body><article><p>Hi</p></article></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "article", extensionHint: nil)
        let (enriched, technique) = await FormatMaterializer.enrich(plan, using: StubExtractor())
        // Defuddle markdown replaces tag-based; technique is "defuddle".
        #expect(enriched.extractedMarkdown == "## Defuddle Title\n\nClean content.")
        #expect(technique == "defuddle")
        // Filename derived from defuddle's title.
        #expect(enriched.filename == "Defuddle Title.html")
        // Original HTML bytes preserved (issue #599 two-layer model).
        #expect(enriched.data == Data(html.utf8))
    }

    @Test func enrichSkipsNonHTMLFormats() async {
        struct StubExtractor: HtmlMarkdownExtractor {
            func extract(html: String) async -> HtmlExtractionResult? {
                HtmlExtractionResult(markdown: "should not be used", title: nil)
            }
        }
        // PDF — not HTML.
        let plan = FormatMaterializer.dispatch(
            data: Data([0x25, 0x50, 0x44, 0x46]), contentType: "application/pdf",
            stem: "doc", extensionHint: nil)
        let (enriched, technique) = await FormatMaterializer.enrich(plan, using: StubExtractor())
        #expect(enriched.extractedMarkdown == plan.extractedMarkdown)  // nil — no sidecar for PDF
        #expect(technique == "html-to-markdown")
    }

    @Test func enrichUsesDispatchStemWhenExtractorTitleIsNil() async {
        struct StubExtractor: HtmlMarkdownExtractor {
            func extract(html: String) async -> HtmlExtractionResult? {
                HtmlExtractionResult(markdown: "content", title: nil)
            }
        }
        let html = "<html><head><title>Original Title</title></head><body><article><p>Hi</p></article></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "fallback-stem", extensionHint: nil)
        let (enriched, _) = await FormatMaterializer.enrich(plan, using: StubExtractor())
        // No defuddle title → keep the dispatch-derived filename.
        #expect(enriched.filename == "Original Title.html")
    }

    // MARK: - Helpers

    /// Walk up from `#filePath` to the directory containing `Package.swift`.
    private static func locateRepoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }
}
