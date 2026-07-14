import Foundation
import WikiFSCore

// MARK: - QueueExtractionWorkerFactory

/// A `QueueWorkerFactory` that creates `QueueExtractionWorker` instances.
/// The factory resolves a provider ID (for capacity checking) by asking the
/// provider to resolve the extraction — the backend type determines whether
/// it's local (limit 1) or remote (limit 2). The worker then calls
/// `resolveExtraction` → `readiness()` → `convert()` → `persistExtraction`.
///
/// **Progress reporting:** the factory receives an `emitProgress` closure
/// that captures the engine's `AsyncStream.Continuation` (Sendable) and
/// yields `.progress(id, line)` events. The worker passes this as the
/// `onProgress` callback to `convert()`, preserving the live extraction log
/// flow that the UI consumes.
public struct QueueExtractionWorkerFactory: QueueWorkerFactory {
    private let provider: any QueueExtractionProvider
    private let emitProgress: @Sendable (QueueItem.ID, String) -> Void

    /// - Parameters:
    ///   - provider: Bridges the `@MainActor ExtractionCoordinator`.
    ///   - emitProgress: Yields `.progress(id, line)` events onto the engine's
    ///     `AsyncStream.Continuation`. The engine constructs this closure and
    ///     passes it here so the worker can emit progress without being an
    ///     actor method.
    public init(
        provider: any QueueExtractionProvider,
        emitProgress: @escaping @Sendable (QueueItem.ID, String) -> Void
    ) {
        self.provider = provider
        self.emitProgress = emitProgress
    }

    public func providerID(for item: QueueItem) async -> String? {
        // Resolve the provider for this item, respecting any backend override
        // from stageRouting (re-extraction with a specific backend). This
        // mirrors the worker's logic so the capacity pre-check uses the same
        // backend the worker will actually use.
        guard let sourceID = item.payload.sourceIDs.first else { return nil }

        let override = item.payload.stageRouting?["backend"].flatMap {
            ExtractionBackend(rawValue: $0)
        }

        // Ask the provider to resolve — if it returns nil (no PDF bytes,
        // unconfigured backend), the item stays queued and is never dispatched.
        guard let resolved = try? await provider.resolveExtraction(
            wikiID: item.wikiID,
            sourceID: sourceID,
            backendOverride: override
        ) else { return nil }

        // Map the backend to a provider ID that the engine's capacity config
        // can route: local → "local-pdf2md", remote → backend-specific.
        switch resolved.backend {
        case .localPdf2md: return "local-pdf2md"
        case .anthropic: return "remote-anthropic"
        case .gemini: return "remote-gemini"
        case .doclingServe: return "remote-docling"
        }
    }

    public func worker(for item: QueueItem) async throws -> any QueueWorker {
        QueueExtractionWorker(provider: provider, emitProgress: emitProgress)
    }
}

// MARK: - QueueExtractionWorker

/// A worker that runs one extraction: resolves the extractor + PDF bytes,
/// checks `readiness()`, calls `convert()`, and persists the result.
///
/// **Readiness preservation:** if `readiness()` returns `.needsSetup` or
/// `.notInstalled`, the worker throws `QueueExtractionError.notReady` with
/// the readiness message. The engine marks the item `.failed` with that
/// message — so the user sees "no API key — configure in Settings" instead of
/// a generic conversion error. This preserves today's graceful-fallback
/// behavior (minus the fallback to raw PDF, which is the caller's
/// responsibility now via `waitForCompletion` result handling).
///
/// **Worker idempotency:** if a worker completes after the item was already
/// requeued/cancelled by `halt`/`cancelItem`, `handleWorkerFinished`'s
/// `markCompleted` will throw `.invalidStateTransition` (caught + logged),
/// and the item will be re-dispatched on resume. Extraction is idempotent
/// (re-extraction produces the same markdown), so this is safe.
struct QueueExtractionWorker: QueueWorker {
    let provider: any QueueExtractionProvider
    let emitProgress: @Sendable (QueueItem.ID, String) -> Void

    func execute(_ item: QueueItem) async throws {
        guard let sourceID = item.payload.sourceIDs.first else {
            throw QueueExtractionError.missingSourceID
        }

        // Resolve the backend override from the payload (re-extraction).
        let backendOverride = item.payload.stageRouting?["backend"].flatMap {
            ExtractionBackend(rawValue: $0)
        }

        // Resolve the extractor + PDF bytes (main-actor hop in the app impl).
        guard let resolved = try await provider.resolveExtraction(
            wikiID: item.wikiID,
            sourceID: sourceID,
            backendOverride: backendOverride
        ) else {
            // No PDF bytes — non-PDF source or already extracted. Skip
            // extraction (the worker returns normally → item .completed).
            return
        }

        // Readiness check — preserve graceful fallback.
        let readiness = await resolved.extractor.readiness()
        guard readiness.isReady else {
            let message: String
            switch readiness {
            case .needsSetup(let msg): message = msg
            case .notInstalled(let msg): message = msg
            case .ready: message = ""  // unreachable
            }
            throw QueueExtractionError.notReady(message)
        }

        // Convert (off-main — MarkdownExtractor is Sendable).
        let markdown = try await resolved.extractor.convert(
            pdfData: resolved.pdfData,
            filename: resolved.filename
        ) { [itemID = item.id] line in
            emitProgress(itemID, line)
        }

        // Persist (main-actor hop in the app impl). Carries backend +
        // modelVersion for PROV tracking.
        try await provider.persistExtraction(
            wikiID: item.wikiID,
            sourceID: sourceID,
            markdown: markdown,
            backend: resolved.backend,
            modelVersion: resolved.modelVersion
        )
    }
}
