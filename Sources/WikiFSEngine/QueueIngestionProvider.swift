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
    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void
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

    public init(
        provider: any QueueIngestionProvider,
        emitProgress: @escaping @Sendable (QueueItem.ID, String) -> Void
    ) {
        self.provider = provider
        self.emitProgress = emitProgress
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
        QueueIngestionWorker(provider: provider, emitProgress: emitProgress)
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

    func execute(_ item: QueueItem) async throws {
        let sourceIDs = item.payload.sourceIDs
        guard !sourceIDs.isEmpty else {
            throw QueueIngestionError.noSources
        }

        try await provider.runIngestion(
            wikiID: item.wikiID,
            sourceIDs: sourceIDs
        ) { [itemID = item.id] line in
            emitProgress(itemID, line)
        }
    }
}
