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

    public func providerID(for item: QueueItem) async -> ProviderID? {
        // Resolve the provider for this item, respecting any backend override
        // from stageRouting (re-extraction with a specific backend). This
        // mirrors the worker's logic so the capacity pre-check uses the same
        // backend the worker will actually use.
        guard let sourceID = item.payload.sourceIDs.first else { return nil }

        let override = item.payload.stageRouting?[StageRoutingKey.backend.rawValue].flatMap {
            ExtractionBackend(rawValue: $0)
        }

        // Ask the provider to resolve — if it returns nil (no bytes, no
        // route), the item stays queued and is never dispatched.
        let resolved: ExtractionResolution?
        do {
            resolved = try await provider.resolveExtraction(
                wikiID: item.wikiID,
                sourceID: sourceID,
                backendOverride: override
            )
        } catch let error as ExtractionServicesError {
            // An unavailable explicit extractor selection is an actionable
            // per-item failure, never an indefinite stay in .queued. Hand the
            // item a neutral capacity bucket so dispatch claims it and the
            // worker surfaces the typed error through the normal failed path.
            DebugLog.store("QueueExtractionWorker.resolveExtraction blocked: \(error)")
            return ProviderID(rawValue: "blocked-extraction")
        } catch {
            DebugLog.store("QueueExtractionWorker.resolveExtraction: \(error)")
            return nil
        }
        guard let resolved else { return nil }

        switch resolved {
        case .transcript(let transcript):
            // Transcript sources get their own (non-PDF) capacity bucket.
            return ProviderID(rawValue: transcript.capacityID)
        case .bytes(let bytes):
            // Map the backend to a provider ID that the engine's capacity
            // config can route: local → "local-pdf2md", remote → backend-specific.
            switch bytes.backend {
            case .localPdf2md: return ProviderID(rawValue: "local-pdf2md")
            case .acp: return ProviderID(rawValue: "remote-acp")
            case .anthropic: return ProviderID(rawValue: "remote-anthropic")
            case .gemini: return ProviderID(rawValue: "remote-gemini")
            case .doclingServe: return ProviderID(rawValue: "remote-docling")
            }
        }
    }

    public func worker(for item: QueueItem) async throws -> any QueueWorker {
        QueueExtractionWorker(provider: provider, emitProgress: emitProgress)
    }

    public func worker(for item: QueueItem, output: QueueWorkerOutputScope) async throws -> any QueueWorker {
        QueueExtractionWorker(provider: provider, emitProgress: { id, line in
            output.emitProgress(itemID: id, line: line)
        })
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
        let startedAt = ContinuousClock.now
        // Every progress line carries its elapsed time ([mm:ss]) so a silent
        // stretch is visible in the Activity trail without a debugger.
        @Sendable func stamp(_ line: String) -> String {
            let seconds = Int((ContinuousClock.now - startedAt).components.seconds)
            return String(format: "[%02d:%02d] %@", (seconds / 60) % 100, seconds % 60, line)
        }

        guard let sourceID = item.payload.sourceIDs.first else {
            throw QueueExtractionError.missingSourceID
        }

        // Resolve the backend override from the payload (re-extraction).
        let backendOverride = item.payload.stageRouting?[StageRoutingKey.backend.rawValue].flatMap {
            ExtractionBackend(rawValue: $0)
        }

        // Resolve the extraction (main-actor hop in the app impl).
        guard let resolved = try await provider.resolveExtraction(
            wikiID: item.wikiID,
            sourceID: sourceID,
            backendOverride: backendOverride
        ) else {
            // No bytes and no transcript route — skip extraction (the worker
            // returns normally → item .completed).
            return
        }

        // Exhaustive over the tagged execution model: a bytes conversion and
        // a transcript fetch cannot be confused, and every resolution carries
        // exactly its own persistence payload.
        switch resolved {
        case .bytes(let bytes):
            // Readiness check — preserve graceful fallback.
            let readiness = await bytes.extractor.readiness()
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
            let markdown = try await bytes.extractor.convert(
                pdfData: bytes.sourceBytes,
                filename: bytes.filename
            ) { [itemID = item.id] line in
                emitProgress(itemID, stamp(line))
            }

            try await provider.persistBytesExtraction(
                wikiID: item.wikiID,
                sourceID: sourceID,
                resolution: bytes,
                markdown: markdown)

        case .transcript(let transcript):
            emitProgress(item.id, stamp("Fetching transcript…"))
            let outcome = try await transcript.fetch { [itemID = item.id] line in
                emitProgress(itemID, stamp(line))
            }

            try await provider.persistTranscriptExtraction(
                wikiID: item.wikiID,
                sourceID: sourceID,
                resolution: transcript,
                outcome: outcome)
        }
    }
}
