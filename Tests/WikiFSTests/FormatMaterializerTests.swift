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

    // MARK: - HTML → verbatim bytes (issue #599; no sidecar post-#799 PR3)

    @Test func htmlStoredVerbatimWithoutMarkdownSidecar() {
        let html = "<html><head><title>Cool Page</title></head><body><h1>Hi</h1><p>Hello <strong>world</strong>.</p></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html; charset=utf-8",
            stem: "article", extensionHint: nil)

        // Issue #599: HTML sources preserve the ORIGINAL HTML bytes (format
        // .html) — the source blob IS the original HTML. Issue #799 PR3: the
        // extracted-markdown sidecar is NO LONGER computed at ingest time —
        // `dispatch` returns `extractedMarkdown: nil` for HTML; the user
        // triggers extraction via the Extract button (PR2). Format detection
        // + the title-derived filename are unchanged.
        #expect(plan.format == .html)
        #expect(plan.filename == "Cool Page.html")
        // Byte-identical: the source blob IS the original HTML.
        #expect(plan.data == Data(html.utf8))
        // PR3: NO extracted-markdown sidecar.
        #expect(plan.extractedMarkdown == nil,
               "PR3: HTML dispatch must NOT auto-extract markdown")
    }

    @Test func htmlWithoutTitleFallsBackToStem() {
        let html = "<body><p>no title</p></body>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "photosynthesis", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.filename == "photosynthesis.html")
        #expect(plan.data == Data(html.utf8))
        // PR3: NO extracted-markdown sidecar (was non-nil pre-PR3).
        #expect(plan.extractedMarkdown == nil)
    }

    @Test func xhtmlAlsoStoredVerbatim() {
        let html = "<html><title>X</title><body><p>x</p></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "application/xhtml+xml",
            stem: "page", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.filename == "X.html")
        #expect(plan.data == Data(html.utf8))
        // PR3: NO extracted-markdown sidecar (was non-nil pre-PR3).
        #expect(plan.extractedMarkdown == nil)
    }

    @Test func htmlBlankBodyPreservesBytesVerbatim() {
        // Blank body still preserves the HTML bytes verbatim; no sidecar is
        // computed post-PR3 (was: the sidecar markdown was whatever
        // HTMLToMarkdown converted — likely empty/whitespace).
        let html = "<html><head><title>Empty</title></head><body></body></html>"
        let plan = FormatMaterializer.dispatch(
            data: Data(html.utf8), contentType: "text/html",
            stem: "page", extensionHint: nil)

        #expect(plan.format == .html)
        #expect(plan.data == Data(html.utf8))
        #expect(plan.extractedMarkdown == nil)
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

    /// A plain-text file with a non-txt extension keeps that extension: the
    /// sniff only says "this is text", and the extension is the format
    /// declaration extension-fallback renderers match on (an `architecture.d2`
    /// dropped into the wiki must not be silently rewritten to `.txt`).
    @Test func plainTextKeepsUnknownExtensionHint() {
        let plan = FormatMaterializer.dispatch(
            data: Data("x -> y".utf8), contentType: "text/plain; charset=utf-8",
            stem: "architecture", extensionHint: "d2")

        #expect(plan.format == .text)
        #expect(plan.filename == "architecture.d2")
        #expect(String(data: plan.data, encoding: .utf8) == "x -> y")
    }

    @Test func plainTextWithoutHintFallsBackToTxt() {
        let plan = FormatMaterializer.dispatch(
            data: Data("no extension here".utf8), contentType: "text/plain; charset=utf-8",
            stem: "notes", extensionHint: nil)

        #expect(plan.format == .text)
        #expect(plan.filename == "notes.txt")
    }

    @Test func plainTextHintMustBeACleanToken() {
        // Weird "extensions" (punctuation) are not format declarations; they
        // fall back to txt.
        let plan = FormatMaterializer.dispatch(
            data: Data("hello".utf8), contentType: "text/plain; charset=utf-8",
            stem: "weird-file", extensionHint: "v1.backup")

        #expect(plan.format == .text)
        #expect(plan.filename == "weird-file.txt")
    }

    @Test func markdownContentTypeKeepsMdExtension() {
        let plan = FormatMaterializer.dispatch(
            data: Data("# Heading\n\nbody".utf8), contentType: "text/markdown",
            stem: "doc", extensionHint: nil)

        #expect(plan.format == .text)
        #expect(plan.filename == "doc.md")
    }

    @Test func canvasExtensionSurvivesGenericJSONContentType() {
        let canvas = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let plan = FormatMaterializer.dispatch(
            data: canvas, contentType: "text/plain; charset=utf-8",
            stem: "sample", extensionHint: "canvas")

        #expect(plan.filename == "sample.canvas")
        #expect(plan.data == canvas)
    }

    @Test func canvasExtensionSurvivesApplicationJSONContentType() {
        let plan = FormatMaterializer.dispatch(
            data: Data("{\"nodes\":[],\"edges\":[]}".utf8),
            contentType: "application/json",
            stem: "sample", extensionHint: "canvas")

        #expect(plan.filename == "sample.canvas")
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
        #expect(ContentTypeDetector.normalizeMIMEType("text/html; charset=UTF-8") == "text/html")
        #expect(ContentTypeDetector.normalizeMIMEType("  APPLICATION/PDF ") == "application/pdf")
        #expect(ContentTypeDetector.normalizeMIMEType(nil) == nil)
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

    @Test func dispatchUsesDetectionResult() {
        let result = ContentTypeDetector.detect(.init(
            data: Data("%PDF-1.4".utf8),
            hints: .init(declaredMIME: .init("text/plain", origin: .httpResponse))))
        let plan = FormatMaterializer.dispatch(
            data: Data("%PDF-1.4".utf8),
            detectionResult: result,
            stem: "renamed",
            extensionHint: "txt")
        #expect(plan.format == .pdf)
        #expect(plan.detectionResult == result)
        #expect(plan.filename == "renamed.pdf")
    }

    @Test func fullPNGSignatureIsRequired() {
        let full = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let short = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(ContentTypeDetector.detect(.init(data: full)).normalizedMIMEType == "image/png")
        #expect(ContentTypeDetector.detect(.init(data: short)).normalizedMIMEType == nil)
    }

    // MARK: - AC.7: FormatMaterializer has no URL-type dependency

    /// AC.7 — `FormatMaterializer.swift` must not reference `FetchResponse`,
    /// `StorePlan`, a `: URL` parameter/return annotation, or import URL-coupled
    /// modules. This is a targeted source check, not a bare substring search.
    /// A dropped legacy Word document keeps its own `.doc` filename: the
    /// MIME subtype ("msword") must not rename the user's file. The subtype
    /// stays the extension fallback only for bytes with no filename hint.
    @Test func legacyDocKeepsOwnExtensionOverMIMESubtype() {
        let ole2Magic = Data([
            0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        let plan = FormatMaterializer.dispatch(
            data: ole2Magic + Data(repeating: 0x00, count: 64),
            contentType: "application/msword",
            stem: "legacy-notes",
            extensionHint: "doc")
        #expect(plan.format == .binary)
        #expect(plan.filename == "legacy-notes.doc")
    }

    @Test func binaryExtensionPrefersCleanHintOverSubtypeGuess() {
        #expect(FormatMaterializer.binaryExtension(
            forMIME: "application/msword", extensionHint: "doc") == "doc")
        // No filename to honor — the subtype is the guess.
        #expect(FormatMaterializer.binaryExtension(
            forMIME: "application/msword", extensionHint: nil) == "msword")
        #expect(FormatMaterializer.binaryExtension(
            forMIME: "application/octet-stream", extensionHint: "bin") == "bin")
        // The known table still canonicalizes.
        #expect(FormatMaterializer.binaryExtension(
            forMIME: "image/jpeg", extensionHint: "jpeg") == "jpg")
    }

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
