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
public struct ExtractionResolution: Sendable {
    public let extractor: any MarkdownExtractor
    public let pdfData: Data
    public let filename: String
    public let backend: ExtractionBackend
    public let modelVersion: String?

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
    }
}

// MARK: - QueueExtractionProvider

/// Bridges the `@MainActor ExtractionCoordinator` into the headless queue
/// engine. The app provides a concrete implementation that hops to the main
/// actor internally; the engine sees only this `Sendable` protocol.
///
/// **Two main-actor hops per extraction:**
/// - `resolveExtraction` → calls `ExtractionCoordinator.current()` (main actor)
///   + reads source bytes from the store (main actor).
/// - `persistExtraction` → calls `store.seedPdfMarkdown` or `reExtractMarkdown`
///   (main actor).
///
/// The actual `convert()` runs off-main (the `MarkdownExtractor` is `Sendable`).
public protocol QueueExtractionProvider: Sendable {
    /// Resolve the extractor + PDF bytes for a source. Returns `nil` if the
    /// source has no PDF bytes (non-PDF or already-extracted — skip extraction).
    ///
    /// - Parameter backendOverride: When non-nil, resolve this specific backend
    ///   instead of the configured default (used by re-extraction with a chosen
    ///   backend). The provider passes this to `ExtractionCoordinator`.
    func resolveExtraction(
        wikiID: String,
        sourceID: PageID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution?

    /// Persist extracted markdown into the store. Carries `backend` +
    /// `modelVersion` for PROV tracking (`source_markdown_versions` origin,
    /// `agents.name`).
    func persistExtraction(
        wikiID: String,
        sourceID: PageID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?
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
    func ingestBegan(wikiID: String) async

    /// Called when the ingestion flow (extraction + agent spawn) ends.
    /// Clears `isIngestInProgress = false`.
    func ingestEnded(wikiID: String) async
}
