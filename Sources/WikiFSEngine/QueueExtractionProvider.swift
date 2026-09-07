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

/// The result of resolving an extraction request. The tag is the execution
/// model — staged bytes or a URL-backed fetch — so an invalid
/// bytes/transcript combination is unrepresentable and the worker switches
/// exhaustively.
public enum ExtractionResolution: Sendable {
    case bytes(BytesExtractionResolution)
    case transcript(TranscriptExtractionResolution)
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
    /// carries a package producer.
    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws

    /// Persist a transcript result with its typed mode: a built-in tool row
    /// for `.builtInTool`, or a `.transcript`-origin package row with exact
    /// provenance and the initial source-version link for `.installedPackage`.
    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
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
