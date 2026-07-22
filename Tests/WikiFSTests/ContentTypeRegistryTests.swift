import Foundation
import Testing
@testable import WikiFSCore

/// Exhaustive decision-table tests for the content-type registry
/// (`ContentKind` + `ContentCapabilities`).
///
/// The registry is a pure value-type decision table — closing it means we
/// can test every `ContentKind` case exhaustively and pin the capability set
/// per case. Adding a case without adding a test fails the suite; adding a
/// capability field without updating every case's assertion fails the suite.
///
/// These tests live in `WikiFSTests` (the portable target — Linux included,
/// #754) because the registry is a pure `WikiFSTypes` value type with no
/// AppKit / WebKit / store dependency. They DO need `import WikiFSCore`
/// (which `@_exported import`s `WikiFSTypes`).
///
/// See `plans/content-type-registry.md` §6.1.
struct ContentTypeRegistryTests {

    // MARK: - Capability table (one assertion per ContentKind case)

    @Test func pdfExtractsAndAutoIngests() {
        let c = ContentKind.pdf.capabilities
        #expect(c.canExtractToMarkdown == true)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == .pdfBackend)
    }

    @Test func htmlExtractsAndAutoIngests() {
        let c = ContentKind.html.capabilities
        #expect(c.canExtractToMarkdown == true)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == .htmlToMarkdown)
    }

    @Test func markdownIsNativeNoExtraction() {
        // Already markdown — nothing to extract, but auto-ingestible.
        let c = ContentKind.markdown.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == nil)
    }

    @Test func textIsNativeNoExtraction() {
        // text/plain, text/csv — already text, staged raw.
        let c = ContentKind.text.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == nil)
    }

    @Test func podcastTranscriptExtractsAndAutoIngests() {
        let c = ContentKind.podcastTranscript.capabilities
        #expect(c.canExtractToMarkdown == true)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == .podcastTranscript)
    }

    @Test func youtubeTranscriptExtractsAndAutoIngests() {
        let c = ContentKind.youtubeTranscript.capabilities
        #expect(c.canExtractToMarkdown == true)
        #expect(c.shouldAutoIngest == true)
        #expect(c.extractionPath == .youtubeTranscript)
    }

    @Test func imageNotExtractableNotAutoIngestible() {
        // PNG / JPEG / etc — the bug class.
        let c = ContentKind.image.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    @Test func videoEmbedNoTranscriptNotAutoIngestible() {
        // Vimeo — no caption pipeline today.
        let c = ContentKind.videoEmbedNoTranscript.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    @Test func audioEmbedNoTranscriptNotAutoIngestible() {
        // Spotify / SoundCloud.
        let c = ContentKind.audioEmbedNoTranscript.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    @Test func remoteMediaNoMarkdownNotAutoIngestible() {
        // Direct mp3/mp4 stream — no transcript, no markdown.
        let c = ContentKind.remoteMediaNoMarkdown.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    @Test func binaryNotExtractableNotAutoIngestible() {
        // xml / json / zip / epub / octet-stream — the bug class.
        let c = ContentKind.binary.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    @Test func unknownFailsSafeNotAutoIngestible() {
        // Can't classify — fail safe (no ingest).
        let c = ContentKind.unknown.capabilities
        #expect(c.canExtractToMarkdown == false)
        #expect(c.shouldAutoIngest == false)
        #expect(c.extractionPath == nil)
    }

    // MARK: - fromMIME resolution

    @Test("PDF mime resolves to pdf") func pdfMime() {
        #expect(ContentKind.fromMIME("application/pdf") == .pdf)
    }

    @Test("HTML mime resolves to html") func htmlMime() {
        #expect(ContentKind.fromMIME("text/html") == .html)
        #expect(ContentKind.fromMIME("application/xhtml+xml") == .html)
    }

    @Test("Markdown mimes resolve to markdown") func markdownMime() {
        #expect(ContentKind.fromMIME("text/markdown") == .markdown)
        #expect(ContentKind.fromMIME("text/x-markdown") == .markdown)
    }

    @Test("Mermaid mimes resolve to markdown (native text content)") func mermaidMime() {
        #expect(ContentKind.fromMIME("text/mermaid") == .markdown)
        #expect(ContentKind.fromMIME("text/x-mermaid") == .markdown)
    }

    @Test("Plain text mimes resolve to text") func textMime() {
        #expect(ContentKind.fromMIME("text/plain") == .text)
        #expect(ContentKind.fromMIME("text/csv") == .text)
    }

    @Test("Image mimes resolve to image") func imageMime() {
        #expect(ContentKind.fromMIME("image/png") == .image)
        #expect(ContentKind.fromMIME("image/jpeg") == .image)
        #expect(ContentKind.fromMIME("image/gif") == .image)
        #expect(ContentKind.fromMIME("image/webp") == .image)
        #expect(ContentKind.fromMIME("image/svg+xml") == .image)
    }

    @Test("nil mime resolves to unknown") func nilMime() {
        #expect(ContentKind.fromMIME(nil) == .unknown)
    }

    // MARK: - XML exclusion (§11-C3 / C6)

    @Test("application/xml excluded — classifies as .binary, not auto-ingestible")
    func applicationXMLExcluded() {
        #expect(ContentKind.fromMIME("application/xml") == .binary)
        #expect(ContentKind.fromMIME("application/xml").capabilities.shouldAutoIngest == false)
    }

    @Test("text/xml excluded — classifies as .binary, not auto-ingestible (§11-C3)")
    func textXMLExcluded() {
        // text/xml would normally be .text (its `text/*` prefix matches),
        // but the operator decision (C3) moves it to .binary because XML has
        // no markdown extraction path.
        #expect(ContentKind.fromMIME("text/xml") == .binary)
        #expect(ContentKind.fromMIME("text/xml").capabilities.shouldAutoIngest == false)
    }

    @Test("XML exclusion is case-insensitive") func xmlCaseInsensitive() {
        #expect(ContentKind.fromMIME("Application/XML") == .binary)
        #expect(ContentKind.fromMIME("TEXT/XML") == .binary)
    }

    @Test("XML exclusion runs BEFORE the text/* prefix check") func xmlBeforeTextCheck() {
        // If XML weren't excluded first, text/xml would match isText() → .text
        // (auto-ingestible). This test pins the precedence so a future
        // rearrangement doesn't silently re-enable XML ingestion.
        #expect(ContentKind.fromMIME("text/xml") != .text)
    }

    @Test("PNG excluded — the headline bug") func pngExcluded() {
        #expect(ContentKind.fromMIME("image/png") == .image)
        #expect(ContentKind.fromMIME("image/png").capabilities.shouldAutoIngest == false)
    }

    // MARK: - resolve(mimeType:provider:ext:) — provider takes precedence

    @Test("YouTube provider resolves to youtubeTranscript (synthetic mime would .binary)")
    func youtubeProviderResolves() {
        // The synthetic `video/youtube` mime alone would be `.binary` (it has
        // no real markdow path). The provider wins for byteless embed sources.
        let kind = ContentKind.resolve(mimeType: "video/youtube", provider: .youtube)
        #expect(kind == .youtubeTranscript)
        #expect(kind.capabilities.shouldAutoIngest == true)
        #expect(kind.capabilities.extractionPath == .youtubeTranscript)
    }

    @Test("Apple Podcast provider resolves to podcastTranscript") func applePodcastProvider() {
        let kind = ContentKind.resolve(mimeType: nil, provider: .applePodcast)
        #expect(kind == .podcastTranscript)
    }

    @Test("Generic RSS podcast provider resolves to podcastTranscript") func podcastProvider() {
        let kind = ContentKind.resolve(mimeType: nil, provider: .podcast)
        #expect(kind == .podcastTranscript)
    }

    @Test("Vimeo provider resolves to videoEmbedNoTranscript (no captions today)")
    func vimeoProvider() {
        let kind = ContentKind.resolve(mimeType: nil, provider: .vimeo)
        #expect(kind == .videoEmbedNoTranscript)
        #expect(kind.capabilities.shouldAutoIngest == false)
    }

    @Test("Spotify / SoundCloud resolve to audioEmbedNoTranscript") func audioEmbeds() {
        #expect(ContentKind.resolve(mimeType: nil, provider: .spotify) == .audioEmbedNoTranscript)
        #expect(ContentKind.resolve(mimeType: nil, provider: .soundcloud) == .audioEmbedNoTranscript)
    }

    @Test("remoteMedia provider resolves to remoteMediaNoMarkdown") func remoteMediaProvider() {
        #expect(ContentKind.resolve(mimeType: "audio/mpeg", provider: .remoteMedia) == .remoteMediaNoMarkdown)
    }

    // MARK: - resolve with byte-bearing provider (MIME wins)

    @Test("PNG via localFile provider still excluded (MIME wins for byte-bearing)")
    func pngViaLocalFile() {
        // source.mimeType is authoritative for byte-bearing sources — the
        // provider adds nothing. A PNG dropped as a local file stays .image.
        let kind = ContentKind.resolve(mimeType: "image/png", provider: .localFile)
        #expect(kind == .image)
        #expect(kind.capabilities.shouldAutoIngest == false)
    }

    @Test("XML via website provider still excluded (MIME wins)") func xmlViaWebsite() {
        let kind = ContentKind.resolve(mimeType: "application/xml", provider: .website)
        #expect(kind == .binary)
        #expect(kind.capabilities.shouldAutoIngest == false)
    }

    @Test("PDF via localFile provider resolves to pdf") func pdfViaLocalFile() {
        let kind = ContentKind.resolve(mimeType: "application/pdf", provider: .localFile, ext: "pdf")
        #expect(kind == .pdf)
    }

    // MARK: - Extension fallback (§11-C4 — legacy nil-mime markdown)

    @Test("nil mime + .md ext falls back to markdown (legacy sources)")
    func markdownExtFallback() {
        // A legacy markdown source whose mime is NULL (pre-v39) must still
        // classify as .markdown so it gets auto-ingested — not .unknown.
        let kind = ContentKind.resolve(mimeType: nil, provider: .legacyImport, ext: "md")
        #expect(kind == .markdown)
        #expect(kind.capabilities.shouldAutoIngest == true)
    }

    @Test("nil mime + .markdown ext falls back to markdown") func markdownLongExtFallback() {
        let kind = ContentKind.resolve(mimeType: nil, provider: nil, ext: "markdown")
        #expect(kind == .markdown)
    }

    @Test("nil mime + .html ext falls back to html") func htmlExtFallback() {
        let kind = ContentKind.resolve(mimeType: nil, provider: nil, ext: "html")
        #expect(kind == .html)
    }

    @Test("nil mime + .pdf ext falls back to pdf") func pdfExtFallback() {
        let kind = ContentKind.resolve(mimeType: nil, provider: nil, ext: "pdf")
        #expect(kind == .pdf)
    }

    @Test("nil mime + unknown ext still returns .unknown (fail safe)") func unknownExtFallback() {
        let kind = ContentKind.resolve(mimeType: nil, provider: nil, ext: "dat")
        #expect(kind == .unknown)
        #expect(kind.capabilities.shouldAutoIngest == false)
    }

    @Test("all-nil resolve returns .unknown") func allNil() {
        let kind = ContentKind.resolve(mimeType: nil, provider: nil, ext: nil)
        #expect(kind == .unknown)
    }

    // MARK: - Closed-enum exhaustiveness check

    @Test("ContentKind is closed at 12 cases") func enumIsClosedAt12() {
        // Adding a case is a deliberate decision (new content type added to
        // the table). Pin the count so the review catches any accidental
        // expansion. Update this number + add a per-case capability test
        // above when adding a case.
        #expect(ContentKind.allCases.count == 12)
    }
}
