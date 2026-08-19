import Foundation
import WikiFSCore

// MARK: - QueueExtractionError

/// Errors thrown by the extraction worker.
public enum QueueExtractionError: Error, LocalizedError {
    /// The extractor's `readiness()` returned `.needsSetup` or `.notInstalled`.
    /// Carries the readiness message for the user.
    case notReady(String)
    /// No source ID in the payload (malformed request).
    case missingSourceID

    public var errorDescription: String? {
        switch self {
        case .notReady(let msg): return "Extraction not ready: \(msg)"
        case .missingSourceID: return "Extraction item has no source ID"
        }
    }
}

// MARK: - ExtractionResolution

/// The result of resolving an extraction request: a `Sendable` extractor +
/// the PDF bytes + filename + backend/modelVersion for PROV tracking.
/// Returned by `QueueExtractionProvider.resolveExtraction`.
///
/// Supports two modes:
/// - **Bytes-based extraction** (PDF, HTML, etc.): `extractor` + `pdfData`
///   are non-nil; the worker calls `extractor.convert(pdfData:…)`.
/// - **Transcript extraction** (YouTube captions, podcast feeds): no local
///   bytes — `transcriptFetch` is non-nil and `extractor` + `pdfData` are nil;
///   the worker calls the closure instead. The `technique` tag records HOW the
///   markdown was produced for PROV tracking (e.g. `"youtube-captions"`).
public struct ExtractionResolution: Sendable {
    /// The extractor for bytes-based extraction. Nil for transcript-only
    /// extraction (no local bytes — the markdown comes from `transcriptFetch`).
    public let extractor: (any MarkdownExtractor)?
    /// The source bytes to convert. Nil for transcript-only extraction.
    public let pdfData: Data?
    public let filename: String
    public let backend: ExtractionBackend
    public let modelVersion: String?

    /// Non-nil when this is a transcript extraction: no local bytes, the
    /// markdown comes from a network/subprocess fetch. When non-nil,
    /// `extractor` + `pdfData` are nil and the worker calls this closure
    /// instead of `extractor.convert(...)`.
    public let transcriptFetch: (@Sendable () async throws -> String)?

    /// PROV technique tag for the processed-markdown version row.
    /// For regular extraction: nil (the backend IS the technique).
    /// For transcript extraction: e.g. `"youtube-captions"`.
    public let technique: String?

    public init(
        extractor: any MarkdownExtractor,
        pdfData: Data,
        filename: String,
        backend: ExtractionBackend,
        modelVersion: String? = nil
    ) {
        self.extractor = extractor
        self.pdfData = pdfData
        self.filename = filename
        self.backend = backend
        self.modelVersion = modelVersion
        self.transcriptFetch = nil
        self.technique = nil
    }

    /// Transcript-only initializer: no local bytes, the markdown comes from
    /// the `fetch` closure. The `technique` tag records the provenance.
    public init(
        transcriptFetch: @escaping @Sendable () async throws -> String,
        technique: String,
        filename: String,
        backend: ExtractionBackend = .localPdf2md
    ) {
        self.extractor = nil
        self.pdfData = nil
        self.filename = filename
        self.backend = backend
        self.modelVersion = nil
        self.transcriptFetch = transcriptFetch
        self.technique = technique
    }
}

// MARK: - QueueExtractionProvider

/// Bridges source storage into the headless queue engine. App implementations
/// hop to the main actor for model reads and writes, while backend preparation
/// resolves through the Sendable extraction service. The actual `convert()`
/// runs off-main because `MarkdownExtractor` is `Sendable`.
public protocol QueueExtractionProvider: Sendable {
    /// Resolve the extractor + PDF bytes for a source. Returns `nil` if the
    /// source has no PDF bytes (non-PDF or already-extracted — skip extraction).
    ///
    /// - Parameter backendOverride: When non-nil, resolve this specific backend
    ///   instead of the configured default (used by re-extraction with a chosen
    ///   backend). The provider passes this to `ExtractionServices.prepare`.
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution?

    /// Persist extracted markdown into the store. Carries `backend` +
    /// `modelVersion` for PROV tracking (`source_markdown_versions` origin,
    /// `agents.name`).
    ///
    /// When `technique` is non-nil, this is a transcript extraction (YouTube
    /// captions, podcast feed) — the provider writes it as a `.transcript`
    /// origin processed-markdown version with the technique tag. When nil,
    /// it's a regular bytes-based extraction written via
    /// `recordMarkdownExtraction`.
    func persistExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?,
        technique: String?
    ) async throws
}

// MARK: - QueueIngestSignaling

/// Signals ingest-flag transitions so the engine preserves `isIngestInProgress`
/// timing (issue #235): the flag fires at extraction start, not completion.
/// The app's implementation hops to the main actor to set/clear
/// `WikiStoreModel.isIngestInProgress`.
public protocol QueueIngestSignaling: Sendable {
    /// Called when extraction starts for a wiki's chained PDF pair.
    /// Sets `isIngestInProgress = true` on the wiki's `WikiStoreModel`.
    func ingestBegan(wikiID: WikiID) async

    /// Called when the ingestion flow (extraction + agent spawn) ends.
    /// Clears `isIngestInProgress = false`.
    func ingestEnded(wikiID: WikiID) async
}
