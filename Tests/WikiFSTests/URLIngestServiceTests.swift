import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the URL-ingest dispatch / filename / store pipeline, driven entirely
/// by a FAKE fetcher and an in-memory store collector — no real network. Covers
/// html→.md, pdf→.pdf (raw bytes preserved), text/plain→as-is, non-2xx error,
/// redirect→final-URL filename, missing-scheme→https, and the pure plan/helpers.
struct URLIngestServiceTests {

    // MARK: - Test doubles

    /// Records what the service asked to store.
    final class StoreCollector: @unchecked Sendable {
        private(set) var filename: String?
        private(set) var data: Data?
        var failNext = false

        func store(_ filename: String, _ data: Data) throws {
            if failNext { throw NSError(domain: "test", code: 1) }
            self.filename = filename
            self.data = data
        }
    }

    /// A fetcher returning a canned response (or throwing a canned error).
    struct FakeFetcher: URLIngestService.URLResourceFetcher {
        var response: URLIngestService.FetchResponse?
        var error: URLIngestService.IngestError?
        /// Captures the URL the service actually requested.
        let requested = Box()

        final class Box: @unchecked Sendable { var url: URL? }

        func fetch(_ url: URL) async throws -> URLIngestService.FetchResponse {
            requested.url = url
            if let error { throw error }
            return response!
        }
    }

    private func makeService(
        _ fetcher: FakeFetcher, _ collector: StoreCollector
    ) -> URLIngestService {
        URLIngestService(fetcher: fetcher) { name, data in
            try collector.store(name, data)
        }
    }

    private func response(
        _ body: String, mime: String?, url: String
    ) -> URLIngestService.FetchResponse {
        URLIngestService.FetchResponse(
            data: Data(body.utf8), contentType: mime, finalURL: URL(string: url)!)
    }

    // MARK: - HTML → markdown

    @Test func htmlIsConvertedToMarkdownFile() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response(
            "<html><head><title>Cool Page</title></head><body><h1>Hi</h1><p>Hello <strong>world</strong>.</p></body></html>",
            mime: "text/html; charset=utf-8",
            url: "https://example.com/article"
        ))
        let service = makeService(fetcher, collector)

        let outcome = try await service.ingest(rawInput: "https://example.com/article")

        #expect(outcome.kind == .htmlConverted)
        #expect(collector.filename == "Cool Page.md")
        let stored = String(data: collector.data!, encoding: .utf8)!
        #expect(stored == "# Hi\n\nHello **world**.")
        #expect(outcome.filename == "Cool Page.md")
    }

    @Test func htmlWithoutTitleFallsBackToURLStem() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response(
            "<body><p>no title here</p></body>",
            mime: "text/html",
            url: "https://example.com/guides/photosynthesis"
        ))
        let service = makeService(fetcher, collector)

        try await service.ingest(rawInput: "example.com/guides/photosynthesis")
        #expect(collector.filename == "photosynthesis.md")
    }

    @Test func xhtmlAlsoConverted() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response(
            "<html><title>X</title><body><p>x</p></body></html>",
            mime: "application/xhtml+xml",
            url: "https://example.com/x"
        ))
        try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/x")
        #expect(collector.filename == "X.md")
    }

    // MARK: - PDF → raw bytes

    @Test func pdfStoredVerbatim() async throws {
        let collector = StoreCollector()
        // Realistic-ish PDF bytes incl. a NUL to prove it's raw, not text-decoded.
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(contentsOf: [0x00, 0x01, 0x02, 0xFF, 0xFE])
        pdf.append(contentsOf: Data("trailer".utf8))
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: pdf, contentType: "application/pdf",
            finalURL: URL(string: "https://example.com/docs/report.pdf")!))
        let service = makeService(fetcher, collector)

        let outcome = try await service.ingest(rawInput: "https://example.com/docs/report.pdf")
        #expect(outcome.kind == .pdf)
        #expect(collector.filename == "report.pdf")
        #expect(collector.data == pdf)  // byte-identical
    }

    @Test func pdfFilenameGetsExtensionWhenURLLacksIt() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data("%PDF".utf8), contentType: "application/pdf",
            finalURL: URL(string: "https://example.com/download?id=99")!))
        try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/download?id=99")
        #expect(collector.filename?.hasSuffix(".pdf") == true)
    }

    // MARK: - text/plain → as-is

    @Test func plainTextStoredAsIs() async throws {
        let collector = StoreCollector()
        let body = "Just plain text.\nLine two."
        let fetcher = FakeFetcher(response: response(
            body, mime: "text/plain; charset=utf-8",
            url: "https://example.com/notes.txt"))
        let service = makeService(fetcher, collector)

        let outcome = try await service.ingest(rawInput: "https://example.com/notes.txt")
        #expect(outcome.kind == .text)
        #expect(collector.filename == "notes.txt")
        #expect(String(data: collector.data!, encoding: .utf8) == body)
    }

    @Test func markdownContentTypeKeepsMdExtension() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response(
            "# Heading\n\nbody", mime: "text/markdown",
            url: "https://example.com/raw/doc"))
        try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/raw/doc")
        #expect(collector.filename == "doc.md")
    }

    // MARK: - Binary fallback

    @Test func imageStoredWithInferredExtension() async throws {
        let collector = StoreCollector()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: bytes, contentType: "image/png",
            finalURL: URL(string: "https://example.com/logo")!))
        let outcome = try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/logo")
        #expect(outcome.kind == .binary)
        #expect(collector.filename == "logo.png")
        #expect(collector.data == bytes)
    }

    // MARK: - Content sniffing (mislabeled content)

    @Test func htmlLabeledButPDFBytesStoredAsPDFVerbatim() async throws {
        let collector = StoreCollector()
        // A Dropbox-style interstitial slip: server says text/html but the bytes are
        // a real PDF (incl. a NUL to prove it's raw, not HTML→Markdown'd).
        var pdf = Data("%PDF-1.3\n".utf8)
        pdf.append(contentsOf: [0x00, 0x01, 0xFF, 0xFE])
        pdf.append(contentsOf: Data("trailer".utf8))
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: pdf, contentType: "text/html; charset=utf-8",
            finalURL: URL(string: "https://dl.dropboxusercontent.com/scl/fi/x/CPP_behaviorgen.pdf?rlkey=k")!))

        let outcome = try await makeService(fetcher, collector).ingest(
            rawInput: "https://dl.dropboxusercontent.com/scl/fi/x/CPP_behaviorgen.pdf?rlkey=k")

        #expect(outcome.kind == .pdf)
        #expect(collector.filename == "CPP_behaviorgen.pdf")
        #expect(collector.data == pdf)  // byte-identical, NOT converted to markdown
    }

    @Test func octetStreamPNGBytesSniffedToImage() async throws {
        let collector = StoreCollector()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG magic
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: png, contentType: "application/octet-stream",
            finalURL: URL(string: "https://example.com/blob")!))

        let outcome = try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/blob")
        #expect(outcome.kind == .binary)
        #expect(collector.filename == "blob.png")
        #expect(collector.data == png)
    }

    @Test func genuineHTMLStillConvertedToMarkdown() async throws {
        // Real HTML labeled text/html must NOT trip the sniffer (no binary magic).
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response(
            "<html><head><title>Real Page</title></head><body><p>hi</p></body></html>",
            mime: "text/html", url: "https://example.com/page"))
        let outcome = try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/page")
        #expect(outcome.kind == .htmlConverted)
        #expect(collector.filename == "Real Page.md")
    }

    @Test func realPDFContentTypeStillStoredAsPDF() async throws {
        // A correctly-labeled PDF takes the application/pdf path (not sniffed away).
        let collector = StoreCollector()
        let pdf = Data("%PDF-1.7\nbody".utf8)
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: pdf, contentType: "application/pdf",
            finalURL: URL(string: "https://example.com/docs/report.pdf")!))
        let outcome = try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/docs/report.pdf")
        #expect(outcome.kind == .pdf)
        #expect(collector.filename == "report.pdf")
        #expect(collector.data == pdf)
    }

    @Test func sniffContentTypeMagicNumbers() {
        #expect(URLIngestService.sniffContentType(Data("%PDF-1.4".utf8)) == "application/pdf")
        #expect(URLIngestService.sniffContentType(Data([0x89, 0x50, 0x4E, 0x47])) == "image/png")
        #expect(URLIngestService.sniffContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(URLIngestService.sniffContentType(Data("GIF89a".utf8)) == "image/gif")
        #expect(URLIngestService.sniffContentType(Data([0x50, 0x4B, 0x03, 0x04])) == "application/zip")
        // Plain text / HTML carries no magic → nil (falls back to declared type).
        #expect(URLIngestService.sniffContentType(Data("<!DOCTYPE html>".utf8)) == nil)
        #expect(URLIngestService.sniffContentType(Data("hello".utf8)) == nil)
        #expect(URLIngestService.sniffContentType(Data()) == nil)
    }

    @Test func shouldSniffOnlyAmbiguousTypes() {
        #expect(URLIngestService.shouldSniff(nil))
        #expect(URLIngestService.shouldSniff("text/html"))
        #expect(URLIngestService.shouldSniff("application/octet-stream"))
        // A specific declared type is trusted, not sniffed.
        #expect(!URLIngestService.shouldSniff("application/pdf"))
        #expect(!URLIngestService.shouldSniff("image/png"))
        #expect(!URLIngestService.shouldSniff("text/plain"))
    }

    // MARK: - Errors

    @Test func nonHTTPSuccessSurfacedAsError() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(error: .httpStatus(404))
        let service = makeService(fetcher, collector)
        await #expect(throws: URLIngestService.IngestError.httpStatus(404)) {
            try await service.ingest(rawInput: "https://example.com/missing")
        }
        #expect(collector.filename == nil)  // nothing stored on error
    }

    @Test func emptyBodyIsError() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data(), contentType: "text/html",
            finalURL: URL(string: "https://example.com")!))
        await #expect(throws: URLIngestService.IngestError.empty) {
            try await makeService(fetcher, collector).ingest(rawInput: "https://example.com")
        }
    }

    @Test func blankInputIsInvalidURL() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response("x", mime: "text/html", url: "https://x.com"))
        await #expect(throws: (any Error).self) {
            try await makeService(fetcher, collector).ingest(rawInput: "   ")
        }
    }

    @Test func storeFailurePropagates() async throws {
        let collector = StoreCollector()
        collector.failNext = true
        let fetcher = FakeFetcher(response: response("<p>x</p>", mime: "text/html", url: "https://x.com"))
        await #expect(throws: (any Error).self) {
            try await makeService(fetcher, collector).ingest(rawInput: "https://x.com")
        }
    }

    // MARK: - Redirect / scheme normalization

    @Test func filenameDerivesFromFinalURLAfterRedirect() async throws {
        let collector = StoreCollector()
        // Asked for /short, fetcher reports it landed on /real-article.pdf.
        let fetcher = FakeFetcher(response: URLIngestService.FetchResponse(
            data: Data("%PDF".utf8), contentType: "application/pdf",
            finalURL: URL(string: "https://cdn.example.com/files/real-article.pdf")!))
        try await makeService(fetcher, collector).ingest(rawInput: "https://example.com/short")
        #expect(collector.filename == "real-article.pdf")
    }

    @Test func missingSchemeDefaultsToHTTPS() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response("<title>T</title>", mime: "text/html", url: "https://example.com"))
        let service = makeService(fetcher, collector)
        try await service.ingest(rawInput: "example.com/page")
        #expect(fetcher.requested.url?.scheme == "https")
        #expect(fetcher.requested.url?.absoluteString == "https://example.com/page")
    }

    @Test func leadingAndTrailingWhitespaceTrimmedFromInput() async throws {
        let collector = StoreCollector()
        let fetcher = FakeFetcher(response: response("<title>T</title>", mime: "text/html", url: "https://example.com"))
        let service = makeService(fetcher, collector)
        try await service.ingest(rawInput: "  https://example.com/x  ")
        #expect(fetcher.requested.url?.absoluteString == "https://example.com/x")
    }

    // MARK: - normalizeURL (pure)

    @Test func normalizeURLForms() {
        #expect(URLIngestService.normalizeURL("https://a.com")?.absoluteString == "https://a.com")
        #expect(URLIngestService.normalizeURL("http://a.com")?.absoluteString == "http://a.com")
        #expect(URLIngestService.normalizeURL("a.com/path")?.absoluteString == "https://a.com/path")
        #expect(URLIngestService.normalizeURL("//a.com")?.absoluteString == "https://a.com")
        #expect(URLIngestService.normalizeURL("") == nil)
        #expect(URLIngestService.normalizeURL("   ") == nil)
        // A bare word with no dot is not a valid host-bearing URL.
        #expect(URLIngestService.normalizeURL("ftp://a.com") == nil)  // unsupported scheme
    }

    // MARK: - Pure helpers

    @Test func normalizedMIMEStripsCharset() {
        #expect(URLIngestService.normalizedMIME("text/html; charset=UTF-8") == "text/html")
        #expect(URLIngestService.normalizedMIME("  APPLICATION/PDF ") == "application/pdf")
        #expect(URLIngestService.normalizedMIME(nil) == nil)
    }

    @Test func ensureExtensionDoesNotDouble() {
        #expect(URLIngestService.ensureExtension("file", ext: "md") == "file.md")
        #expect(URLIngestService.ensureExtension("file.md", ext: "md") == "file.md")
        #expect(URLIngestService.ensureExtension("file.MD", ext: "md") == "file.MD")
    }

    @Test func stemFromURLPrefersPathThenHost() {
        #expect(URLIngestService.stemFromURL(URL(string: "https://a.com/x/report.pdf")!) == "report")
        #expect(URLIngestService.stemFromURL(URL(string: "https://a.com/")!) == "a.com")
        #expect(URLIngestService.stemFromURL(URL(string: "https://a.com")!) == "a.com")
    }

    @Test func sanitizeStemCapsAndCleans() {
        let long = String(repeating: "x", count: 200)
        #expect(URLIngestService.sanitizeStem(long).count <= 80)
        #expect(URLIngestService.sanitizeStem("a/b:c") == "a-b-c")
        #expect(URLIngestService.sanitizeStem("   ") == "untitled")
    }
}
