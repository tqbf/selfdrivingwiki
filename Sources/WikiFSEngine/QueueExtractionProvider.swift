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

/// The typed result of one completed speech job: the transcript text plus
/// the honest engine facts and the exact acquisition identity provenance
/// persists. The AUDIO never appears here — it was consumed transiently.
public struct SpeechOutcome: Sendable {
    public let transcription: SpeechTranscription
    /// The exact acquisition fetcher identity that downloaded the audio.
    public let acquisitionFetcher: ExtractorPackageExecutionProvenance
    /// The staged file's duration in seconds, when reported.
    public let durationSeconds: Double?

    public init(
        transcription: SpeechTranscription,
        acquisitionFetcher: ExtractorPackageExecutionProvenance,
        durationSeconds: Double?
    ) {
        self.transcription = transcription
        self.acquisitionFetcher = acquisitionFetcher
        self.durationSeconds = durationSeconds
    }
}

/// Explicit-intent speech work: acquire the audio transiently through the
/// reviewed fetcher, stage it privately, run the INJECTED host engine, and
/// persist ONE transcript version. The payload carries no audio — the fetch
/// closure produces the bytes inside the worker's stage call, and nothing
/// here can persist them as a source blob.
public struct SpeechExtractionResolution: Sendable {
    /// The acquisition: the fetcher's validated `source-bytes` result. Runs
    /// inside the worker; progress lines are already redacted.
    public let acquire: @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> AudioAcquireAdapter.AcquiredAudio
    /// The injected host speech engine.
    public let speechEngine: any SpeechTranscribing
    /// The private stage manager (host-owned root).
    public let stageRoot: URL
    /// The BCP 47 locale for the transcription.
    public let localeID: String
    /// The source's canonical operation URL (the fetcher's input).
    public let sourceURL: URL
    /// Its own single-job capacity bucket.
    public let capacityID: String

    public static let defaultCapacityID = "speech"

    public init(
        acquire: @escaping @Sendable (_ onProgress: @escaping @Sendable (String) -> Void) async throws -> AudioAcquireAdapter.AcquiredAudio,
        speechEngine: any SpeechTranscribing,
        stageRoot: URL,
        localeID: String,
        sourceURL: URL,
        capacityID: String = SpeechExtractionResolution.defaultCapacityID
    ) {
        self.acquire = acquire
        self.speechEngine = speechEngine
        self.stageRoot = stageRoot
        self.localeID = localeID
        self.sourceURL = sourceURL
        self.capacityID = capacityID
    }
}

/// The result of resolving an extraction request. The tag is the execution
/// model — staged bytes, a URL-backed transcript, a URL-backed fetch, an
/// explicit-intent speech job, a package format conversion, or a source
/// refresh — so an invalid combination is unrepresentable and the worker
/// switches exhaustively.
public enum ExtractionResolution: Sendable {
    case bytes(BytesExtractionResolution)
    case transcript(TranscriptExtractionResolution)
    case fetch(FetcherResolution)
    case speech(SpeechExtractionResolution)
    /// Package format conversion (HTML / DOCX) — the durable format-job
    /// path's conversion arm.
    case html(HtmlExtractionResolution)
    case docx(DocxExtractionResolution)
    /// URL re-acquisition (source refresh) appending a content version.
    case refresh(SourceRefreshResolution)
}

/// One format-route (HTML) conversion: the prepared package adapter is
/// closed over by the resolution's `extract` closure — the worker never
/// sees the typed extractor, only the markdown the closure returns.
public struct HtmlExtractionResolution: Sendable {
    /// Runs the prepared extractor against the source's stored HTML bytes.
    /// Throws when the conversion fails or returns empty markdown — a failed
    /// queue conversion fails the item visibly (the Activity window carries
    /// the reason), never silently lands nothing.
    public let extract: @Sendable () async throws -> String
    public let filename: String
    /// The route selection the daemon resolved; the persisted note names it
    /// (parity with the model's inline write semantics).
    public let backend: HtmlExtractionBackend
    /// The exact installed-package producer when the selection resolved a
    /// package adapter; `nil` for the built-in tag-based execution floor
    /// (`.tool(.html)` producer, parity with the model's inline write).
    public let producer: ExtractionInstalledPackageProducer?
    public let technique: String
    /// The engine's capacity bucket for this resolution. Package format
    /// conversions share one non-PDF bucket — the bun-managed adapters are
    /// lightweight relative to PDF pipelines.
    public let capacityID: String

    /// Package format conversions share one non-PDF capacity bucket — the
    /// bun-managed adapters are lightweight relative to PDF pipelines.
    public static let defaultCapacityID = "package-format"

    public init(
        extract: @escaping @Sendable () async throws -> String,
        filename: String,
        backend: HtmlExtractionBackend,
        producer: ExtractionInstalledPackageProducer?,
        technique: String,
        capacityID: String = HtmlExtractionResolution.defaultCapacityID
    ) {
        self.extract = extract
        self.filename = filename
        self.backend = backend
        self.producer = producer
        self.technique = technique
        self.capacityID = capacityID
    }
}

/// The DOCX sibling of ``HtmlExtractionResolution``. DOCX is package-only:
/// the producer is part of the resolution contract (parity with the typed
/// extractor protocol).
public struct DocxExtractionResolution: Sendable {
    /// Runs the prepared docx2md adapter against the source's stored bytes.
    /// Throws on failure/empty conversion — same visible-failure contract as
    /// the HTML arm.
    public let extract: @Sendable () async throws -> String
    public let filename: String
    public let producer: ExtractionInstalledPackageProducer
    public let technique: String
    /// Shares the package-format bucket with the HTML sibling.
    public let capacityID: String

    public static let defaultCapacityID = HtmlExtractionResolution.defaultCapacityID

    public init(
        extract: @escaping @Sendable () async throws -> String,
        filename: String,
        producer: ExtractionInstalledPackageProducer,
        technique: String,
        capacityID: String = DocxExtractionResolution.defaultCapacityID
    ) {
        self.extract = extract
        self.filename = filename
        self.producer = producer
        self.technique = technique
        self.capacityID = capacityID
    }
}

/// One source refresh acquisition: the daemon re-fetches the source's
/// recorded URL off-host and returns the fresh bytes for a content-version
/// append. The transcript providers never reach this arm — the client
/// routes them to the transcript enqueue.
public struct SourceRefreshResolution: Sendable {
    public struct Outcome: Sendable {
        public let data: Data
        public let detectionHints: ContentTypeDetectionHints
        public let provenance: SourceProvenance

        public init(
            data: Data,
            detectionHints: ContentTypeDetectionHints,
            provenance: SourceProvenance
        ) {
            self.data = data
            self.detectionHints = detectionHints
            self.provenance = provenance
        }
    }

    /// Materializes the source's provider off-host (the refresh service's
    /// website arm). Throws the typed `SourceRefreshService.RefreshError`
    /// cases — notRefreshable / missingPlan / snapshotWithImages — which the
    /// worker surfaces on the item.
    public let fetch: @Sendable (_ onProgress: @Sendable (String) -> Void) async throws -> Outcome
    public let filename: String
    /// A refresh is one lightweight network acquisition; it shares the
    /// transcript bucket's non-PDF concurrency.
    public let capacityID: String

    /// A refresh is one lightweight network acquisition; it shares the
    /// transcript bucket's non-PDF concurrency.
    public static let defaultCapacityID = TranscriptExtractionResolution.defaultCapacityID

    public init(
        fetch: @escaping @Sendable (_ onProgress: @Sendable (String) -> Void) async throws -> Outcome,
        filename: String,
        capacityID: String = SourceRefreshResolution.defaultCapacityID
    ) {
        self.fetch = fetch
        self.filename = filename
        self.capacityID = capacityID
    }
}

/// The speech arm's typed resolution failures. Visible per-item failures —
/// a missing, disabled, or unavailable speech route never silently
/// completes and never falls back to captions.
public enum SpeechResolutionError: Error, LocalizedError, Equatable {
    /// Speech is explicit-only for YouTube sources in v1.
    case sourceOutsideSpeechScope
    /// The source's stored URL does not validate as a YouTube video URL.
    case sourceURLInvalid
    /// The synthetic fetcher route has no active, unambiguous selection.
    case speechFetcherUnavailable(String)
    /// The host speech engine is not ready for the requested locale.
    case engineNotReady(String)

    public var errorDescription: String? {
        switch self {
        case .sourceOutsideSpeechScope:
            return "On-device speech transcription currently supports YouTube videos only."
        case .sourceURLInvalid:
            return "This source's web address is not a supported YouTube video URL."
        case .speechFetcherUnavailable:
            return "The audio acquisition route is unavailable. Open Extraction Settings to fix the audio fetcher."
        case .engineNotReady(let message):
            return message
        }
    }
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
    /// - Parameter transcriptionIntent: The payload's normalized intent.
    ///   `nil`/`.captions` resolves the caption routes only; `.onDeviceSpeech`
    ///   resolves the explicit speech arm (which requires a YouTube source
    ///   and an active synthetic fetcher selection) BEFORE any caption or
    ///   generic fetch arm.
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?,
        transcriptionIntent: QueueItemPayload.TranscriptionIntent?
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

    /// Persist one speech job: ONE nonempty `.transcript` version with the
    /// typed host-speech producer (engine, locale) and the exact
    /// acquisition fetcher identity, linked to the source's immutable
    /// initial version, in one store transaction. Never attaches a blob and
    /// never enqueues a follow-on item.
    @discardableResult
    func persistSpeechExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        outcome: SpeechOutcome
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

    /// Resolve the source-refresh arm for one item carrying the
    /// `.refreshSource` workload intent. Returns the refresh resolution that
    /// re-fetches the source's recorded URL off-host, or `nil` when the
    /// source has no refresh route.
    func resolveSourceRefresh(
        wikiID: WikiID,
        sourceID: SourceID
    ) async throws -> ExtractionResolution?

    /// Resolve the package format route (HTML / DOCX) for one source from
    /// the active registration claims — the durable format-job path's
    /// conversion arm. Dispatched BEFORE the generic arms so a claimed
    /// source never reaches the PDF fallback. Returns `nil` when no active
    /// claim recognizes the source (the generic resolution proceeds).
    /// Preparation failures THROW: a claimed kind whose package is inactive
    /// fails the item visibly, never a silent PDF fallback.
    func resolveFormatRoute(
        wikiID: WikiID,
        sourceID: SourceID,
        htmlBackendOverride: HtmlExtractionBackend?
    ) async throws -> ExtractionResolution?

    /// Persist one format-route (HTML) conversion with the model's inline
    /// write semantics: an `.extraction`-origin derived-markdown version,
    /// the package producer (or `.tool(.html)` for the tag-based floor), and
    /// the backend-named note. `nominateActive` flips the active-markdown
    /// pointer to the new version when a head already exists — the import
    /// conversion contract (issue #1380); manual runs never nominate.
    @discardableResult
    func persistHtmlExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: HtmlExtractionResolution,
        markdown: String,
        nominateActive: Bool
    ) async throws -> QueueExtractionOutputReference?

    /// Persist one format-route (DOCX) conversion: the `.extraction`-origin
    /// derived-markdown version with the exact installed-package producer.
    @discardableResult
    func persistDocxExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: DocxExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference?

    /// Persist one source refresh: a new content version with the fresh
    /// bytes, detection hints, and the provider's provenance — the same
    /// write the model's inline refresh performed.
    @discardableResult
    func persistSourceRefresh(
        wikiID: WikiID,
        sourceID: SourceID,
        outcome: SourceRefreshResolution.Outcome
    ) async throws -> QueueExtractionOutputReference?
}

/// Default requirement bodies for the arms a queue host may not serve. The
/// defaults THROW: a provider that cannot resolve or persist an arm fails
/// its items loudly — the factory routes the item into the neutral capacity
/// bucket and the worker surfaces the message — never a silent skip.
public extension QueueExtractionProvider {
    func resolveSourceRefresh(
        wikiID: WikiID,
        sourceID: SourceID
    ) async throws -> ExtractionResolution? {
        throw QueueExtractionProviderUnsupportedError.refresh
    }

    func resolveFormatRoute(
        wikiID: WikiID,
        sourceID: SourceID,
        htmlBackendOverride: HtmlExtractionBackend?
    ) async throws -> ExtractionResolution? {
        // The nil default: a host without format-route support recognizes no
        // claimed sources, so the generic resolution proceeds unchanged.
        return nil
    }

    @discardableResult
    func persistHtmlExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: HtmlExtractionResolution,
        markdown: String,
        nominateActive: Bool
    ) async throws -> QueueExtractionOutputReference? {
        throw QueueExtractionProviderUnsupportedError.persist
    }

    @discardableResult
    func persistDocxExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: DocxExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference? {
        throw QueueExtractionProviderUnsupportedError.persist
    }

    @discardableResult
    func persistSourceRefresh(
        wikiID: WikiID,
        sourceID: SourceID,
        outcome: SourceRefreshResolution.Outcome
    ) async throws -> QueueExtractionOutputReference? {
        throw QueueExtractionProviderUnsupportedError.persist
    }
}

/// A queue-extraction provider does not serve one of the defaulted arms.
/// Carries a user-readable message the worker puts on the item.
public enum QueueExtractionProviderUnsupportedError: Error, LocalizedError {
    /// The host has no source-refresh resolution.
    case refresh
    /// The host cannot persist one of the new arms.
    case persist

    public var errorDescription: String? {
        switch self {
        case .refresh:
            return "This queue host does not support source refresh."
        case .persist:
            return "This queue host cannot persist the requested extraction result."
        }
    }
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
