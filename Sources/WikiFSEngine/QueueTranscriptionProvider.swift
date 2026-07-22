import Foundation
import WikiFSCore

// MARK: - QueueTranscriptionError

/// Errors thrown by the transcription worker.
public enum QueueTranscriptionError: Error, LocalizedError {
    /// No source ID in the payload (malformed request).
    case missingSourceID

    public var errorDescription: String? {
        switch self {
        case .missingSourceID: return "Transcription item has no source ID"
        }
    }
}

// MARK: - TranscriptionResolution

/// A resolved transcription request: enough to run the fetch off-main and
/// persist the result. No `pdfData` — this is a network/subprocess fetch,
/// mirroring `ExtractionResolution` minus the PDF bytes.
///
/// The `fetch` closure is `@Sendable` so the worker can run it off-main
/// (the actual fetcher instances — `YouTubeTranscriptService`,
/// `RSSPodcastTranscriptService`, `ApplePodcastMaterializer` — are all
/// `Sendable`). The provider (app layer, `@MainActor`) builds the right
/// fetcher from `origin.provider` and hands the worker a closure; the
/// worker stays fetcher-agnostic and never sees `@MainActor` types.
public struct TranscriptionResolution: Sendable {
    /// The off-main transcript fetch closure. Returns the transcript
    /// markdown string.
    public let fetch: @Sendable () async throws -> String

    /// Technique tag for the processed-markdown version row (PROV).
    /// e.g. `"youtube-captions"`, `"rss-podcast-transcript"`,
    /// `"apple-ttml"`.
    public let technique: String

    public init(fetch: @escaping @Sendable () async throws -> String, technique: String) {
        self.fetch = fetch
        self.technique = technique
    }
}

// MARK: - QueueTranscriptionProvider

/// Bridges the `@MainActor WikiStoreModel` into the headless queue engine for
/// transcription (YouTube captions + podcast feeds). The app provides a
/// concrete implementation that hops to the main actor internally; the engine
/// sees only this `Sendable` protocol.
///
/// **Two main-actor hops per transcription:**
/// - `resolveTranscription` → calls `store.sourceOrigin(for:)` (main actor) +
///   builds the right `@Sendable` fetch closure from `origin.provider`.
/// - `persistTranscription` → calls `store.appendProcessedMarkdown(origin:
///   .transcript, ...)` (main actor).
///
/// The actual fetch runs off-main inside the worker (the closure is
/// `@Sendable` and the fetchers are `Sendable`).
public protocol QueueTranscriptionProvider: Sendable {
    /// Resolve the fetch closure + technique for a source. Returns `nil` if
    /// the source isn't transcribable (no provider / no video ID / no feed
    /// URL) — the item stays queued and is never dispatched (mirrors
    /// extraction's nil-return).
    func resolveTranscription(
        wikiID: String,
        sourceID: PageID
    ) async throws -> TranscriptionResolution?

    /// Persist the transcript markdown (app impl:
    /// `store.appendProcessedMarkdown(origin: .transcript, ...)`).
    func persistTranscription(
        wikiID: String,
        sourceID: PageID,
        markdown: String,
        technique: String
    ) async throws
}
