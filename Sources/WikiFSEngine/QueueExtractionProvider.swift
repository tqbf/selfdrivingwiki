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

/// The result of one completed transcript fetch: the Markdown product plus
/// the package-reported metadata (empty for built-in tools).
public struct TranscriptFetchOutcome: Sendable, Hashable {
    public let markdown: String
    public let reportedMetadata: ExtractorReportedMetadata

    public init(markdown: String, reportedMetadata: ExtractorReportedMetadata = .empty) {
        self.markdown = markdown
        self.reportedMetadata = reportedMetadata
    }
}

/// Typed result mode for one transcript job. Persistence consumes the case
/// tag directly — it never infers the mode from a raw technique string.
public enum TranscriptResultMode: Sendable, Hashable {
    /// A built-in transcript tool (YouTube captions, Apple TTML). Persists a
    /// `.transcript` row with the typed tool producer and no source-version
    /// link. The queue Apple path's nil linkage predates package transcripts
    /// and is a deliberate carry-over the Apple TTML follow-up aligns.
    case builtInTool(ExtractionTool)
    /// An installed package transcript. Persists with `.transcript` origin,
    /// the exact package producer (revision, registration, protocol
    /// revision, reported metadata), and the source's REQUIRED initial
    /// version link — the write fails before persisting when the source has
    /// no initial version.
    case installedPackage(ExtractionInstalledPackageProducer)
}

/// URL-backed transcript work. No local bytes exist: the fetch operation
/// resolves the transcript itself. The payload carries the typed producer,
/// the persistence intent, and a non-PDF capacity identity — never
/// `pdfData`, an `ExtractionBackend`, or a nullable technique field.
public struct TranscriptExtractionResolution: Sendable {
    /// The fetch. Progress lines are already redacted by the producer.
    public let fetch: @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> TranscriptFetchOutcome
    public let filename: String
    /// The typed persistence mode for the produced alternative.
    public let resultMode: TranscriptResultMode
    /// Non-PDF capacity bucket for the queue engine's concurrency config.
    public let capacityID: String

    public static let defaultCapacityID = "transcript"

    public init(
        fetch: @escaping @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> TranscriptFetchOutcome,
        filename: String,
        resultMode: TranscriptResultMode,
        capacityID: String = TranscriptExtractionResolution.defaultCapacityID
    ) {
        self.fetch = fetch
        self.filename = filename
        self.resultMode = resultMode
        self.capacityID = capacityID
    }
}

/// File-backed conversion. The extractor converts the staged source bytes;
/// the backend identity, model metadata, and optional exact package producer
/// ride along for capacity routing and persistence.
public struct BytesExtractionResolution: Sendable {
    public let extractor: any MarkdownExtractor
    public let sourceBytes: Data
    public let filename: String
    public let backend: ExtractionBackend
    public let modelVersion: String?
    /// Exact package provenance for a process-backed extraction. Built-in
    /// backends leave this nil.
    public let packageProducer: ExtractionInstalledPackageProducer?

    public init(
        extractor: any MarkdownExtractor,
        sourceBytes: Data,
        filename: String,
        backend: ExtractionBackend,
        modelVersion: String? = nil,
        packageProducer: ExtractionInstalledPackageProducer? = nil
    ) {
        self.extractor = extractor
        self.sourceBytes = sourceBytes
        self.filename = filename
        self.backend = backend
        self.modelVersion = modelVersion
        self.packageProducer = packageProducer
    }
}

/// The typed result of one completed fetch acquisition, keyed exactly as the
/// fetcher stated it: `markdown` (the product itself) or `sourceBytes`
/// (source content plus its concrete MIME and optional display filename).
/// The persistence layer consumes the case tag directly — never a MIME
/// inference.
public enum FetchOutcome: Sendable, Hashable {
    case markdown(FetchedMarkdown)
    case sourceBytes(FetchedSourceBytes)
}

/// The `markdown` fetch result. The bytes arrived as valid UTF-8 at the
/// protocol edge — this carries the decoded text plus the package-reported
/// metadata (article metadata holds the acquisition-provenance fields).
public struct FetchedMarkdown: Sendable, Hashable {
    public let markdown: String
    public let reportedMetadata: ExtractorReportedMetadata
    public let articleMetadata: ExtractorArticleMetadata?

    public init(
        markdown: String,
        reportedMetadata: ExtractorReportedMetadata = .empty,
        articleMetadata: ExtractorArticleMetadata? = nil
    ) {
        self.markdown = markdown
        self.reportedMetadata = reportedMetadata
        self.articleMetadata = articleMetadata
    }
}

/// The `source-bytes` fetch result. The bytes are the acquired source
/// content; `mimeType` is the concrete MIME the fetcher declared;
/// `originalFilename` is optional validated display data (never a path).
public struct FetchedSourceBytes: Sendable, Hashable {
    public let bytes: Data
    public let mimeType: ExtractorMIMEType
    public let originalFilename: String?
    public let reportedMetadata: ExtractorReportedMetadata
    public let articleMetadata: ExtractorArticleMetadata?

    public init(
        bytes: Data,
        mimeType: ExtractorMIMEType,
        originalFilename: String? = nil,
        reportedMetadata: ExtractorReportedMetadata = .empty,
        articleMetadata: ExtractorArticleMetadata? = nil
    ) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.reportedMetadata = reportedMetadata
        self.articleMetadata = articleMetadata
    }
}

/// URL-backed fetcher work. No local bytes exist: the fetch operation
/// acquires one remote source per run and reports its exact package
/// provenance. The persistence intent follows the typed result — `markdown`
/// appends a package-provenance Markdown version; `source-bytes` stores the
/// blob and queues the format route.
public struct FetcherResolution: Sendable {
    /// The fetch. Progress lines are already redacted by the producer.
    public let fetch: @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> FetchOutcome
    /// The claimed synthetic source MIME of the fetcher route.
    public let claimedMIMEType: ExtractorMIMEType
    /// The display filename fallback (the configured item key).
    public let filename: String
    /// Exact package provenance for the acquisition.
    public let producer: ExtractionInstalledPackageProducer
    /// Shares the transcript (non-PDF) capacity bucket.
    public let capacityID: String

    public static let defaultCapacityID = TranscriptExtractionResolution.defaultCapacityID

    public init(
        fetch: @escaping @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> FetchOutcome,
        claimedMIMEType: ExtractorMIMEType,
        filename: String,
        producer: ExtractionInstalledPackageProducer,
        capacityID: String = FetcherResolution.defaultCapacityID
    ) {
        self.fetch = fetch
        self.claimedMIMEType = claimedMIMEType
        self.filename = filename
        self.producer = producer
        self.capacityID = capacityID
    }
}

/// The result of resolving an extraction request. The tag is the execution
/// model — staged bytes, a URL-backed transcript, or a URL-backed fetch —
/// so an invalid combination is unrepresentable and the worker switches
/// exhaustively.
public enum ExtractionResolution: Sendable {
    case bytes(BytesExtractionResolution)
    case transcript(TranscriptExtractionResolution)
    case fetch(FetcherResolution)
}

// MARK: - QueueExtractionProvider

/// Bridges source storage into the headless queue engine. App implementations
/// hop to the main actor for model reads and writes, while backend preparation
/// resolves through the Sendable extraction service. The actual `convert()`
/// runs off-main because `MarkdownExtractor` is `Sendable`.
public protocol QueueExtractionProvider: Sendable {
    /// Resolve the extraction for a source. Returns `nil` when there is
    /// nothing to extract (no bytes, no route — skip extraction).
    ///
    /// - Parameter backendOverride: When non-nil, resolve this specific PDF
    ///   backend instead of the configured default (re-extraction with a
    ///   chosen backend). Transcript routes ignore it; their selection is
    ///   registration-driven through the extraction services.
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution?

    /// Persist a bytes-based extraction result: the legacy seeded-PDF path
    /// for built-in backends, the exact-package path when the resolution
    /// carries a package producer. Returns the output reference ONLY where
    /// the persistence layer knows the created version (`nil` otherwise) —
    /// the worker emits the target's output result only on that evidence.
    @discardableResult
    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference?

    /// Persist a transcript result with its typed mode: a built-in tool row
    /// for `.builtInTool`, or a `.transcript`-origin package row with exact
    /// provenance and the initial source-version link for `.installedPackage`.
    /// Returns the created version's output reference when known.
    @discardableResult
    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference?

    /// Persist one fetch acquisition. A `markdown` result appends a
    /// package-provenance Markdown version and marks the source complete; a
    /// `source-bytes` result attaches the blob — real MIME, ext, byte size,
    /// the validated display filename, the neutral external provenance from
    /// `articleMetadata`, and the `formatJobPending` marker — all in one
    /// transaction. Returns the created version's output reference when
    /// known.
    @discardableResult
    func persistFetch(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: FetcherResolution,
        outcome: FetchOutcome
    ) async throws -> QueueExtractionOutputReference?

    /// Enqueue the follow-on `.extraction` queue item for a source that just
    /// gained bytes (the fetch's format route). The caller supplies the
    /// acquired content-version ID and the typed dedupe key scoped to wiki +
    /// source + that version, so a crash between persistence and enqueue is
    /// recoverable and a repeat insert returns the SAME item (including a
    /// completed one) instead of creating a second format job. Never called
    /// for a Markdown result (the Markdown IS the product).
    func enqueueFollowOnExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        acquiredContentVersionID: SourceVersionID,
        dedupeKey: QueueItemDedupeKey
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
