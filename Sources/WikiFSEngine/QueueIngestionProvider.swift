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
    ///   - onLiveUsage: Called on each `usage_update` notification during the
    ///     run with the in-progress token/cost snapshot. `nil` for callers
    ///     that don't need live progress (#544). May never fire if the backend
    ///     doesn't stream usage updates.
    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?
    ) async throws

    /// Run a whole-wiki lint health-check. Returns when the agent finishes.
    ///
    /// - Parameters:
    ///   - wikiID: The wiki to lint.
    ///   - onProgress: Called with progress lines to emit as `.progress` events.
    ///   - onTranscript: Called with each typed agent event for this item.
    ///   - onUsage: Called after the run with cumulative usage, if captured.
    ///   - onLiveUsage: Called on each `usage_update` during the run (#544).
    func runLint(
        wikiID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?
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
    ///   - onLiveUsage: Called on each `usage_update` during the run (#544).
    func runLintPages(
        wikiID: String,
        pageIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?
    ) async throws

    /// Quick readiness probe: checks whether the selected agent provider's
    /// command binary exists on PATH (or is the bundled bun helper). Returns
    /// `nil` when ready, or a user-facing message explaining what to fix and
    /// how. Called before `runIngestion`/`runLint`/`runLintPages` so the user
    /// gets actionable guidance instead of a cryptic spawn error like
    /// `"bun: not found"`.
    ///
    /// **Not a network call** — a synchronous `which`-style check wrapped in
    /// async for actor-hopping. Fast enough to run on every dispatch without
    /// blocking the queue engine.
    func readiness() async -> String?
}

// MARK: - QueueIngestionError

public enum QueueIngestionError: Error, LocalizedError {
    case noSources
    case spawnFailed(String)
    /// The agent provider's binary was not found on PATH (or the provider has
    /// no command configured). Carries the readiness message for the user.
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: return "Ingestion item has no valid sources"
        case .spawnFailed(let msg): return "Agent spawn failed: \(msg)"
        case .notReady(let msg): return msg
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
    private let emitLiveUsage: @Sendable (QueueItem.ID, SessionUsage) -> Void

    public init(
        provider: any QueueIngestionProvider,
        emitProgress: @escaping @Sendable (QueueItem.ID, String) -> Void,
        emitTranscript: @escaping @Sendable (QueueItem.ID, AgentEvent) -> Void,
        emitUsage: @escaping @Sendable (QueueItem.ID, SessionUsage) -> Void,
        emitLiveUsage: @escaping @Sendable (QueueItem.ID, SessionUsage) -> Void
    ) {
        self.provider = provider
        self.emitProgress = emitProgress
        self.emitTranscript = emitTranscript
        self.emitUsage = emitUsage
        self.emitLiveUsage = emitLiveUsage
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
        QueueIngestionWorker(provider: provider, emitProgress: emitProgress, emitTranscript: emitTranscript, emitUsage: emitUsage, emitLiveUsage: emitLiveUsage)
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
    let emitLiveUsage: @Sendable (QueueItem.ID, SessionUsage) -> Void

    func execute(_ item: QueueItem) async throws {
        // Pre-dispatch readiness gate (#440): check the agent provider's binary
        // is on PATH BEFORE running the full pipeline. If the binary is missing,
        // fail the item with a clear, user-facing message instead of a cryptic
        // spawn error like "bun: not found". This mirrors the extraction worker's
        // `readiness()` check on `MarkdownExtractor`.
        if let message = await provider.readiness() {
            throw QueueIngestionError.notReady(message)
        }

        let onTranscript: (@Sendable (AgentEvent) -> Void)? = { [itemID = item.id] event in
            emitTranscript(itemID, event)
        }
        let onUsage: (@Sendable (SessionUsage?) -> Void)? = { [itemID = item.id] usage in
            guard let usage else { return }
            emitUsage(itemID, usage)
        }
        // #544 live progress: forward each in-progress usage snapshot to the
        // engine's broadcaster so the Activity window updates during the run.
        let onLiveUsage: (@Sendable (SessionUsage) -> Void)? = { [itemID = item.id] usage in
            emitLiveUsage(itemID, usage)
        }

        if let pageIDs = item.payload.lintPageIDs, !pageIDs.isEmpty {
            // Page-level lint.
            try await provider.runLintPages(
                wikiID: item.wikiID,
                pageIDs: pageIDs,
                onProgress: { [itemID = item.id] line in emitProgress(itemID, line) },
                onTranscript: onTranscript,
                onUsage: onUsage,
                onLiveUsage: onLiveUsage
            )
        } else if item.payload.lintPageIDs != nil {
            // lintPageIDs is non-nil but empty → whole-wiki lint.
            try await provider.runLint(
                wikiID: item.wikiID,
                onProgress: { [itemID = item.id] line in emitProgress(itemID, line) },
                onTranscript: onTranscript,
                onUsage: onUsage,
                onLiveUsage: onLiveUsage
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
                onUsage: onUsage,
                onLiveUsage: onLiveUsage
            )
        }
    }
}
