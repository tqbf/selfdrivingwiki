import Foundation
import WikiFSCore

// MARK: - QueueIngestionProvider

/// Bridges the `@MainActor` agent-launcher + store model into the headless
/// queue engine for ingestion. The app provides a concrete implementation
/// that hops to the main actor internally; the engine sees only this
/// `Sendable` protocol.
///
/// The ingestion worker calls `runIngestion(...)` which does the full
/// pipeline previously in `AgentOperationRunner.runMultiIngest`:
/// 1. `beginIngest` signaling (issue #235)
/// 2. Source reading + staging (reusing any already-extracted markdown)
/// 3. Workspace create (if `workspacesEnabled`)
/// 4. Agent spawn via `launcher.run(...)`
/// 5. Workspace auto-merge on completion
/// 6. `endIngest` signaling
///
/// Extraction for PDFs is handled separately: the call site enqueues an
/// extraction item (Phase 4), waits for it, then enqueues the ingestion
/// item. Or, for the chained path, extraction completion enqueues the
/// linked ingestion item.
public protocol QueueIngestionProvider: Sendable {
    /// Run the full ingestion pipeline for the given sources. Returns when
    /// the agent finishes (success or failure).
    ///
    /// - Parameters:
    ///   - wikiID: The wiki to ingest into.
    ///   - sourceIDs: The source IDs to ingest.
    ///   - onProgress: Called with progress lines (agent stdout/stderr) to
    ///     emit as `.progress` events.
    ///   - onTranscript: Called with each typed agent event for this item,
    ///     so the tracker can build a per-item transcript for the Activity
    ///     window. `nil` for callers that don't need transcript forwarding.
    ///   - onUsage: Called once after the run finishes with the cumulative
    ///     token/cost usage (`SessionUsage`), if captured. `nil` when the
    ///     backend did not report usage data. #528 spike.
    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?
    ) async throws

    /// Run a whole-wiki lint health-check. Returns when the agent finishes.
    ///
    /// - Parameters:
    ///   - wikiID: The wiki to lint.
    ///   - onProgress: Called with progress lines to emit as `.progress` events.
    ///   - onTranscript: Called with each typed agent event for this item.
    ///   - onUsage: Called after the run with cumulative usage, if captured.
    func runLint(
        wikiID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?
    ) async throws

    /// Run a page-level lint health-check for the given pages. Returns when
    /// the agent finishes.
    ///
    /// - Parameters:
    ///   - wikiID: The wiki to lint.
    ///   - pageIDs: The page IDs to lint.
    ///   - onProgress: Called with progress lines to emit as `.progress` events.
    ///   - onTranscript: Called with each typed agent event for this item.
    ///   - onUsage: Called after the run with cumulative usage, if captured.
    func runLintPages(
        wikiID: String,
        pageIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?
    ) async throws
}

// MARK: - QueueIngestionError

public enum QueueIngestionError: Error, LocalizedError {
    case noSources
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: return "Ingestion item has no valid sources"
        case .spawnFailed(let msg): return "Agent spawn failed: \(msg)"
        }
    }
}

// MARK: - QueueIngestionWorkerFactory

/// A `QueueWorkerFactory` that creates `QueueIngestionWorker` instances.
/// Resolves the provider ID from the `QueueIngestionProvider` — the
/// resolved provider determines which per-provider concurrency limit applies.
///
/// **Progress reporting:** receives an `emitProgress` closure that captures
/// the engine's `AsyncStream.Continuation` (Sendable) and yields
/// `.progress(id, line)` events. The worker passes this as `onProgress` to
/// `runIngestion`.
public struct QueueIngestionWorkerFactory: QueueWorkerFactory {
    private let provider: any QueueIngestionProvider
    private let emitProgress: @Sendable (QueueItem.ID, String) -> Void
    private let emitTranscript: @Sendable (QueueItem.ID, AgentEvent) -> Void
    private let emitUsage: @Sendable (QueueItem.ID, SessionUsage) -> Void

    public init(
        provider: any QueueIngestionProvider,
        emitProgress: @escaping @Sendable (QueueItem.ID, String) -> Void,
        emitTranscript: @escaping @Sendable (QueueItem.ID, AgentEvent) -> Void,
        emitUsage: @escaping @Sendable (QueueItem.ID, SessionUsage) -> Void
    ) {
        self.provider = provider
        self.emitProgress = emitProgress
        self.emitTranscript = emitTranscript
        self.emitUsage = emitUsage
    }

    public func providerID(for item: QueueItem) async -> String? {
        // The provider ID for ingestion is resolved from the agent provider
        // config. For now, we use a fixed default — the app's provider
        // resolution happens inside runIngestion when launcher.run() resolves
        // the selected provider. The engine uses this ID for per-provider
        // concurrency limits.
        //
        // TODO: Phase 5+ — resolve the actual provider from config so
        // per-provider limits are enforced. For now, all ingestion items
        // share one "default" provider slot.
        return "default-ingest"
    }

    public func worker(for item: QueueItem) async throws -> any QueueWorker {
        QueueIngestionWorker(provider: provider, emitProgress: emitProgress, emitTranscript: emitTranscript, emitUsage: emitUsage)
    }
}

// MARK: - QueueIngestionWorker

/// A worker that runs one ingestion: calls `provider.runIngestion(...)` which
/// does the full planner→executor→finalizer pipeline (source staging, agent
/// spawn, workspace merge). The provider hops to `@MainActor` internally.
///
/// **Worker idempotency:** if the agent spawn succeeds but the item is
/// cancelled mid-run, the worker throws `CancellationError` and the engine
/// handles the state transition. Workspace auto-merge is best-effort inside
/// the provider.
struct QueueIngestionWorker: QueueWorker {
    let provider: any QueueIngestionProvider
    let emitProgress: @Sendable (QueueItem.ID, String) -> Void
    let emitTranscript: @Sendable (QueueItem.ID, AgentEvent) -> Void
    let emitUsage: @Sendable (QueueItem.ID, SessionUsage) -> Void

    func execute(_ item: QueueItem) async throws {
        let onTranscript: (@Sendable (AgentEvent) -> Void)? = { [itemID = item.id] event in
            emitTranscript(itemID, event)
        }
        let onUsage: (@Sendable (SessionUsage?) -> Void)? = { [itemID = item.id] usage in
            guard let usage else { return }
            emitUsage(itemID, usage)
        }

        if let pageIDs = item.payload.lintPageIDs, !pageIDs.isEmpty {
            // Page-level lint.
            try await provider.runLintPages(
                wikiID: item.wikiID,
                pageIDs: pageIDs,
                onProgress: { [itemID = item.id] line in emitProgress(itemID, line) },
                onTranscript: onTranscript,
                onUsage: onUsage
            )
        } else if item.payload.lintPageIDs != nil {
            // lintPageIDs is non-nil but empty → whole-wiki lint.
            try await provider.runLint(
                wikiID: item.wikiID,
                onProgress: { [itemID = item.id] line in emitProgress(itemID, line) },
                onTranscript: onTranscript,
                onUsage: onUsage
            )
        } else {
            // Normal ingestion.
            let sourceIDs = item.payload.sourceIDs
            guard !sourceIDs.isEmpty else {
                throw QueueIngestionError.noSources
            }
            try await provider.runIngestion(
                wikiID: item.wikiID,
                sourceIDs: sourceIDs,
                onProgress: { [itemID = item.id] line in emitProgress(itemID, line) },
                onTranscript: onTranscript,
                onUsage: onUsage
            )
        }
    }
}
