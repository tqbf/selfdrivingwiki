import Foundation
import WikiFSCore

// MARK: - QueueTranscriptionWorkerFactory

/// A `QueueWorkerFactory` that creates `QueueTranscriptionWorker` instances.
/// Mirrors `QueueExtractionWorkerFactory` but for the `.transcription` queue
/// kind — no PDF bytes, no backend selection, just a network/subprocess
/// transcript fetch.
///
/// **Progress reporting:** the factory receives an `emitProgress` closure
/// (same pattern as extraction) that yields `.progress(id, line)` events onto
/// the engine's broadcaster. Today the transcript fetchers produce no
/// streamed log (unlike pdf2md), so the worker emits a single "Fetching…"
/// line so the Activity detail pane isn't empty.
public struct QueueTranscriptionWorkerFactory: QueueWorkerFactory {
    private let provider: any QueueTranscriptionProvider
    private let emitProgress: @Sendable (QueueItem.ID, String) -> Void

    /// - Parameters:
    ///   - provider: Bridges the `@MainActor WikiStoreModel`.
    ///   - emitProgress: Yields `.progress(id, line)` events onto the engine's
    ///     `AsyncStream.Continuation`.
    public init(
        provider: any QueueTranscriptionProvider,
        emitProgress: @escaping @Sendable (QueueItem.ID, String) -> Void
    ) {
        self.provider = provider
        self.emitProgress = emitProgress
    }

    public func providerID(for item: QueueItem) async -> String? {
        // Resolve to preflight: nil → item stays queued (never dispatched).
        // A found resolution → "transcription" provider (capacity bucket).
        guard let sourceID = item.payload.sourceIDs.first,
              (try? await provider.resolveTranscription(
                wikiID: item.wikiID, sourceID: sourceID)) != nil
        else { return nil }
        return "transcription"
    }

    public func worker(for item: QueueItem) async throws -> any QueueWorker {
        QueueTranscriptionWorker(provider: provider, emitProgress: emitProgress)
    }
}

// MARK: - QueueTranscriptionWorker

/// A worker that runs one transcription: resolves the fetch closure,
/// runs it off-main, and persists the transcript markdown. Mirrors
/// `QueueExtractionWorker` minus the PDF bytes + readiness check.
///
/// **Worker idempotency:** like extraction, re-transcription produces the
/// same/similar markdown (append-processed-markdown adds a new version row),
/// so a re-dispatch after `halt`/`cancelItem` is safe.
struct QueueTranscriptionWorker: QueueWorker {
    let provider: any QueueTranscriptionProvider
    let emitProgress: @Sendable (QueueItem.ID, String) -> Void

    func execute(_ item: QueueItem) async throws {
        guard let sourceID = item.payload.sourceIDs.first else {
            throw QueueTranscriptionError.missingSourceID
        }

        // Resolve the fetch closure + technique (main-actor hop in the app
        // impl).
        guard let resolved = try await provider.resolveTranscription(
            wikiID: item.wikiID, sourceID: sourceID
        ) else {
            // Not transcribable (no video ID / feed URL) — skip (item
            // .completed), mirroring extraction's nil-return.
            return
        }

        // Network/subprocess fetch off-main. Emit a single progress line so
        // the Activity detail pane isn't empty (today's fetchers don't
        // stream).
        emitProgress(item.id, "Fetching transcript…")
        let markdown = try await resolved.fetch()

        // Persist the transcript markdown (main-actor hop in the app impl).
        try await provider.persistTranscription(
            wikiID: item.wikiID,
            sourceID: sourceID,
            markdown: markdown,
            technique: resolved.technique
        )
    }
}
