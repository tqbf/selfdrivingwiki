import Foundation

/// The content-type registry — the single decision table answering "can this
/// source become markdown?" regardless of whether it arrived as a MIME type,
/// a provider embed, or sniffed bytes.
///
/// Hosts two things:
/// 1. **`ContentKind`** — a normalized closed enum collapsing every input
///    shape (`application/pdf` mimes, `.youtube` providers, `.md` extensions)
///    into the 12 logical kinds the capability table below switches on.
/// 2. **`ContentCapabilities`** — the per-kind capability struct returned by
///    `ContentKind.capabilities` (`canExtractToMarkdown`, `shouldAutoIngest`,
///    `extractionPath`).
///
/// # Why a registry?
///
/// Before this table, the extract-vs-transcribe-vs-ingest eligibility was
/// scattered across ~8 ad-hoc sites, each re-deriving "can this become
/// markdown?" from raw MIME strings or provider enums with no shared
/// decision table — they drifted (the list Extract menu offered PDF only,
/// silently omitting HTML; `canIngest` checked bytes, not a markdown path,
/// so PNG/XML sources passed and were enqueued for wasted agent runs).
/// One table makes the decision explicit and migration mechanical.
///
/// # The bug this fixes (PR1)
///
/// `BackgroundIngestCoordinator.scanWiki` enqueued every source that passed
/// `WikiStoreModel.canIngest(source)` — but `canIngest` is a **byte
/// availability** predicate (`hasProcessedMarkdown || byteSize > 0`), NOT a
/// **markdown-path** predicate. A PNG/XML with bytes sailed through. The
/// coordinator fix (PR1 §5.1) consults `ContentKind.resolve(...).capabilities
/// .shouldAutoIngest` *before* the byte gate, so a PNG (`image/png` →
/// `.image`) and an XML (`application/xml` → `.binary`) are filtered out by
/// `shouldAutoIngest == false` before enqueueing.
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the model
/// (`WikiFSCore`'s `WikiStoreModel`), the engine-layer queue providers
/// (`WikiFSEngine`), and the app-layer coordinator (`WikiFS`'s
/// `BackgroundIngestCoordinator`) all share one definition with no new
/// module edge. Mirrors `MimeType` / `SourceProvider`, which already live
/// here for the same reason.
///
/// See `plans/content-type-registry.md` for the full design + decision table.
public enum ContentTypeRegistry {

    // MARK: - MIME constants (XML exclusion, §11-C3)

    /// `application/xml` — classified as `.binary` (NOT `.text`) because XML
    /// has no markdown-extraction path. The operator decision (§11-C3): both
    /// `text/xml` AND `application/xml` are excluded.
    public static let xml = "application/xml"

    /// `text/xml` — also classified as `.binary` (defies the `text/*` prefix
    /// classification on purpose, §11-C3).
    public static let xmlText = "text/xml"
}

/// The normalized content classification a source reduces to, regardless of
/// whether it arrived as a MIME type, a provider embed, or sniffed bytes.
/// This is the single key the capability table in `ContentKind.capabilities`
/// switches on.
///
/// 12 cases — closed, exhaustive. Adding one requires adding both the case
/// arm in `capabilities` and the resolution arms in `fromMIME` / `resolve`
/// (or the compiler will fail at the table site). That intentional closedness
/// is what keeps the decision table audit-able.
public enum ContentKind: Sendable, Equatable, CaseIterable {

    // MARK: - Has a markdown path (extractable / transcriptable / native)

    /// `application/pdf`. Extraction via pdf2md / ACP / Anthropic / Gemini /
    /// Docling (`ExtractionCoordinator.current()`).
    case pdf
    /// Native markdown / mermaid — already IS the content. No extraction needed.
    case markdown
    /// `text/html`, `application/xhtml+xml`, `.html`/`.htm`/`.xhtml`. Extracted
    /// via defuddle or tag-based fallback (issue #599).
    case html
    /// Plain text / CSV / other `text/*` (except `text/xml`, which is `.binary`).
    /// Staged raw — no extraction needed.
    case text
    /// Apple Podcasts / generic RSS podcast. Transcription via TTML /
    /// `<podcast:transcript>` pipeline (provider takes precedence).
    case podcastTranscript
    /// YouTube embed. Transcription via caption-track scrape. Provider takes
    /// precedence (synthetic `video/youtube` MIME is less informative than
    /// `.youtube`).
    case youtubeTranscript

    // MARK: - No markdown path (not auto-ingestible)

    /// PNG / JPEG / GIF / WebP / SVG. No extractor; bytes present but no path
    /// to markdown.
    case image
    /// Vimeo — no caption pipeline today (future: #564).
    case videoEmbedNoTranscript
    /// Spotify / SoundCloud — no transcript API.
    case audioEmbedNoTranscript
    /// Direct mp3 / mp4 / HLS stream. Real mime, no provider iframe, no
    /// transcript, no markdown.
    case remoteMediaNoMarkdown
    /// XML / JSON / ZIP / EPUB / octet-stream / unknown bytes — the PNG/XML
    /// bug class. No extractor.
    case binary
    /// Mime nil AND provider nil AND extension unrecognized. Can't classify —
    /// fail safe (no ingest).
    case unknown
}

public extension ContentKind {

    /// The capability set for this kind — the decision the registry answers.
    ///
    /// Three fields:
    /// - `canExtractToMarkdown` — is there an Extract / Transcribe action
    ///   that produces markdown from this kind? False for native `markdown` /
    ///   `text` (already text — nothing to extract).
    /// - `shouldAutoIngest` — should the continuous-ingest coordinator enqueue
    ///   this source? Today this coincides with "has any markdown path";
    ///   false for `image` / `binary` / etc.
    /// - `extractionPath` — which pipeline produces markdown (nil when none).
    ///   Drives the Extract-vs-Transcribe button split (PR2) and the staging
    ///   path's "reuse extracted head" branch (PR2).
    var capabilities: ContentCapabilities {
        switch self {
        case .pdf:
            return .init(canExtractToMarkdown: true,  shouldAutoIngest: true,
                         extractionPath: .pdfBackend)
        case .html:
            return .init(canExtractToMarkdown: true,  shouldAutoIngest: true,
                         extractionPath: .htmlToMarkdown)
        case .markdown:
            return .init(canExtractToMarkdown: false, shouldAutoIngest: true,
                         extractionPath: nil)   // already markdown — nothing to extract
        case .text:
            return .init(canExtractToMarkdown: false, shouldAutoIngest: true,
                         extractionPath: nil)   // native text, staged raw
        case .podcastTranscript:
            return .init(canExtractToMarkdown: true,  shouldAutoIngest: true,
                         extractionPath: .podcastTranscript)
        case .youtubeTranscript:
            return .init(canExtractToMarkdown: true,  shouldAutoIngest: true,
                         extractionPath: .youtubeTranscript)
        case .image:
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        case .videoEmbedNoTranscript:   // Vimeo — no caption pipeline yet (#564)
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        case .audioEmbedNoTranscript:   // Spotify / SoundCloud — no transcript
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        case .remoteMediaNoMarkdown:    // direct mp3/mp4 stream — no markdown path
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        case .binary:                   // xml / json / zip / epub / unknown bytes
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        case .unknown:
            return .init(canExtractToMarkdown: false, shouldAutoIngest: false,
                         extractionPath: nil)
        }
    }

    // MARK: - Resolution

    /// Resolve a source to its content kind from MIME alone. Provider-less
    /// shurtcut: for byte-bearing file/website/legacy-import sources, MIME is
    /// authoritative and the provider adds nothing.
    ///
    /// Used by `WikiStoreModel.shouldAutoIngest(_:)` (which has no origin
    /// lookup) — perfect for excluding PNG/XML (the bug) without an extra
    /// DB read. NOT correct for byteless `.youtube`/`.podcast` (their
    /// synthetic MIME `video/youtube` classifies as `.binary`) — use
    /// `resolve(mimeType:provider:ext:)` for those.
    ///
    /// XML exclusion (§11-C3): both `text/xml` AND `application/xml` classify
    /// as `.binary` BEFORE the `isText` / `hasPrefix("text/")` check, so
    /// neither is auto-ingested. Neither has a markdown extraction path.
    static func fromMIME(_ mime: String?) -> ContentKind {
        guard let mime else { return .unknown }
        let lowered = mime.lowercased()

        // XML exclusion (§11-C3): both forms → .binary. Checked BEFORE the
        // isText / hasPrefix("text/") arm so text/xml doesn't leak in.
        if lowered == ContentTypeRegistry.xml
            || lowered == ContentTypeRegistry.xmlText {
            return .binary
        }

        if MimeType.isPDF(lowered)        { return .pdf }
        if MimeType.isMarkdown(lowered)  { return .markdown }
        if MimeType.isMermaid(lowered)   { return .markdown }   // mermaid is native text content
        if lowered == MimeType.html || lowered == MimeType.xhtml { return .html }
        if MimeType.isText(lowered)      { return .text }       // text/plain, text/csv, …
        if lowered.hasPrefix("image/")    { return .image }
        return .binary   // xml (already handled), json, zip, epub, octet-stream, everything else
    }

    /// Resolve a source to its content kind combining provider + MIME + ext.
    ///
    /// **Provider wins for byteless embed providers** (their synthetic MIME
    /// `video/youtube` is less informative than `.youtube`; `audio/...` for
    /// podcasts is equally ambiguous). **MIME wins for byte-bearing file /
    /// website / legacy-import sources** (where provider adds nothing).
    ///
    /// **Extension fallback** (§11-C4): before returning `.unknown`, consult
    /// the lowercased extension. A legacy markdown source (mime nil) with
    /// `.md` extension classifies as `.markdown`, not `.unknown`.
    ///
    /// - Parameters:
    ///   - mimeType: best-effort UTI→MIME; nil when unknown.
    ///   - provider: the `SourceOrigin.provider` (parsed from `agents.name`).
    ///     nil when there's no origin (e.g. before v39 legacy rows).
    ///   - ext: lowercased filename extension without leading dot (matches
    ///     `SourceSummary.ext`). Empty string is treated like nil.
    static func resolve(
        mimeType: String?,
        provider: SourceProvider?,
        ext: String? = nil
    ) -> ContentKind {
        // 1. Provider-first for byteless embed providers.
        switch provider {
        case .youtube:         return .youtubeTranscript
        case .applePodcast:    return .podcastTranscript
        case .podcast:         return .podcastTranscript
        case .spotify:         return .audioEmbedNoTranscript
        case .soundcloud:      return .audioEmbedNoTranscript
        case .vimeo:           return .videoEmbedNoTranscript
        case .remoteMedia:     return .remoteMediaNoMarkdown
        case .localFile, .website, .zotero, .markdownFolder,
             .legacyImport, .none:
            break // fall through to MIME classification
        }

        // 2. MIME-first for byte-bearing sources.
        let fromMime = Self.fromMIME(mimeType)
        if fromMime != .unknown { return fromMime }

        // 3. Extension fallback for legacy / nil-mime markdown sources
        //    (§11-C4). Without this, a legacy markdown source with mime NULL
        //    + `.md` extension would classify as `.unknown` → fail the
        //    auto-ingest gate — a regression on existing data.
        if let ext, !ext.isEmpty {
            switch ext.lowercased() {
            case "md", "markdown", "mdx":            return .markdown
            case "html", "htm", "xhtml":             return .html
            case "pdf":                              return .pdf
            default:                                 break
            }
        }
        return .unknown
    }
}

// MARK: - Capabilities value type

/// The capability set returned by `ContentKind.capabilities`. Pure value
/// type with no store / network dependency.
public struct ContentCapabilities: Sendable, Equatable {
    /// Is there an Extract / Transcribe action that produces markdown from
    /// this kind? `false` for native `markdown` / `text` (already text —
    /// nothing to *extract*); `false` for kinds with no extractor (`image`,
    /// `binary`, `.unknown`).
    public let canExtractToMarkdown: Bool
    /// Should the continuous-ingest coordinator (`BackgroundIngestCoordinator
    /// .scanWiki`) enqueue this source? `false` for kinds with no markdown
    /// path. **The auto-ingest gate.**
    public let shouldAutoIngest: Bool
    /// What produces the markdown for this kind (`nil` when none). Drives
    /// the Extract-vs-Transcribe button split (PR2) and the staging path's
    /// "reuse extracted head" branch (PR2).
    public let extractionPath: ExtractionPath?

    public init(
        canExtractToMarkdown: Bool,
        shouldAutoIngest: Bool,
        extractionPath: ExtractionPath?
    ) {
        self.canExtractToMarkdown = canExtractToMarkdown
        self.shouldAutoIngest = shouldAutoIngest
        self.extractionPath = extractionPath
    }
}

public extension ContentCapabilities {

    /// Which pipeline produces markdown for a content kind. `nil` only on
    /// kinds where `canExtractToMarkdown == false` (native markdown/text —
    /// nothing to extract — and the no-path kinds: image/binary/etc).
    enum ExtractionPath: Sendable, Equatable {
        /// pdf2md / ACP / Anthropic / Gemini / Docling (`ExtractionCoordinator.current()`).
        case pdfBackend
        /// defuddle / tag-based fallback (issue #599).
        case htmlToMarkdown
        /// TTML / `<podcast:transcript>` (RSS feed scrape).
        case podcastTranscript
        /// watch-page → caption-track scrape (pure-Swift).
        case youtubeTranscript
    }
}
