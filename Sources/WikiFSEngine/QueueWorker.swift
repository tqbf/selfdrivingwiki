import Foundation
import WikiFSCore

// MARK: - CompositeWorkerFactory

/// A `QueueWorkerFactory` that delegates to per-queue-kind sub-factories.
/// The engine has a single `workerFactory`, so this composite routes
/// extraction items to the extraction factory and ingestion items to the
/// ingestion factory based on `item.queue`.
public struct CompositeWorkerFactory: QueueWorkerFactory {
    private let factories: [QueueKind: any QueueWorkerFactory]

    /// - Parameter factories: A mapping from queue kind to its worker factory.
    ///   Every `QueueKind` must have an entry; a missing entry causes
    ///   `providerID(for:)` to return `nil` (item stays queued).
    public init(factories: [QueueKind: any QueueWorkerFactory]) {
        self.factories = factories
    }

    public func providerID(for item: QueueItem) async -> String? {
        guard let factory = factories[item.queue] else { return nil }
        return await factory.providerID(for: item)
    }

    public func worker(for item: QueueItem) async throws -> any QueueWorker {
        guard let factory = factories[item.queue] else {
            throw QueueIngestionError.noSources
        }
        return try await factory.worker(for: item)
    }
}

// MARK: - QueueWorker

/// A worker that executes a single `QueueItem`. The engine spawns a `Task`
/// per claimed item that calls `execute(_:)`. On throw, the item is marked
/// `.failed` with the error message; on normal return, `.completed`.
///
/// Real implementations (Phases 4–5): extraction workers call
/// `ExtractionCoordinator`; ingestion workers run the planner→executor→
/// finalizer pipeline via `QueueSessionResolving`. Phase 2 tests inject
/// fakes.
public protocol QueueWorker: Sendable {
    func execute(_ item: QueueItem) async throws
}

// MARK: - QueueWorkerFactory

/// Resolves a worker for an item during dispatch. Called in two phases:
///
/// 1. `providerID(for:)` — during the dispatch scan, BEFORE an item is claimed.
///    Returns the provider ID that WOULD handle this item, or `nil` if no
///    provider is available (the item stays queued). The engine uses this to
///    check per-provider slot capacity.
/// 2. `worker(for:)` — AFTER the item is marked `.running`. Returns the actual
///    worker that will execute the item.
///
/// Splitting resolution from execution lets the engine check capacity without
/// committing to a worker (and without the factory "opening" a connection
/// before a slot is confirmed free).
public protocol QueueWorkerFactory: Sendable {
    func providerID(for item: QueueItem) async -> String?
    func worker(for item: QueueItem) async throws -> any QueueWorker
}

// MARK: - QueueEvent

/// Every significant state change in the engine emits a `QueueEvent` on the
/// `AsyncStream`. The UI (Phase 6) observes this to update its view-model;
/// the JSONL log (Phase 3) writes each event as a line.
public enum QueueEvent: Sendable {
    /// A new item was enqueued (or re-enqueued by chaining).
    case enqueued(QueueItem)
    /// An item transitioned to `.running` — a worker started executing it.
    case started(QueueItem)
    /// Progress line from a running worker (e.g. extraction log output).
    /// Carries the item ID + the progress text line.
    case progress(QueueItem.ID, line: String)
    /// A typed agent event forwarded from a running ingestion/lint worker.
    /// Carries the item ID + the event. Used by the Activity window to
    /// build per-item transcripts (decoupled from the launcher instance).
    case transcript(QueueItem.ID, AgentEvent)
    /// Live (in-progress) token/cost usage for a running ingestion or lint
    /// run. Emitted on each `usage_update` notification during the run so the
    /// Activity window can show running token counts + model name before
    /// completion. Distinct from `.usage`, which fires once after the run
    /// finishes with the final cumulative totals. See #544 live progress.
    case liveUsage(QueueItem.ID, SessionUsage)
    /// Final cumulative token/cost usage for a completed ingestion or lint
    /// run. Emitted once, after the run finishes. #528 spike — surfaces
    /// per-run usage in the Activity window and aggregates a daily total.
    case usage(QueueItem.ID, SessionUsage)
    /// An item transitioned to `.completed`.
    case completed(QueueItem)
    /// An item transitioned to `.failed`. Carries the error message.
    case failed(QueueItem, error: String)
    /// An item transitioned to `.cancelled`.
    case cancelled(QueueItem)
    /// A queue was paused or resumed.
    case runStateChanged(queue: QueueKind, state: QueueRunState)
    /// A queued item was reordered (dragged to a new position). Carries the
    /// updated item with its new `orderingKey`.
    case reordered(QueueItem)
    /// The run's lightweight log file (`run.jsonl`) and verbose debug folder
    /// (`debug/`) URLs, forwarded from the launcher after the run starts so
    /// the Activity window can offer "Reveal Log" / "Reveal Debug Folder".
    /// `nil` when the run didn't create them (not started, preflight failure).
    case runPaths(QueueItem.ID, logURL: URL?, debugURL: URL?)
    /// The run is parked on an always-ask permission prompt (issue #608).
    /// Carries the pending permission request the launcher surfaced from the
    /// backend via `pendingPollTask`. `nil` clears the Activity window's
    /// yellow "Permission pending" row — the continuation resolved (approve,
    /// reject) or the S1 auto-reject timer fired. Mirrors how `transcript` /
    /// `liveUsage` flow: launcher → emit closure → engine broadcaster →
    /// `QueueActivityTracker` → `ActivityWindowView`. ACP agents gate one
    /// write at a time, so at most one pending request per item at a time.
    case pendingPermission(QueueItem.ID, PendingPermission?)

    /// The item this event pertains to (if any).
    public var item: QueueItem? {
        switch self {
        case .enqueued(let i), .started(let i), .completed(let i),
             .cancelled(let i), .reordered(let i):
            return i
        case .failed(let i, _):
            return i
        case .progress, .transcript, .liveUsage, .usage, .runPaths, .runStateChanged, .pendingPermission:
            return nil
        }
    }
}

// MARK: - QueueSnapshot

/// A point-in-time view of the engine's full state, for UI bootstrap (Phase 6)
/// and test assertions. Contains only `Sendable` value types so it can cross
/// actor boundaries.
public struct QueueSnapshot: Sendable {
    /// All non-terminal items (`.queued` + `.running`), ordered by
    /// `orderingKey` ascending.
    public var activeItems: [QueueItem]
    /// Terminal items (`.completed`, `.failed`, `.cancelled`), newest first.
    public var recentItems: [QueueItem]
    /// Per-queue run state (`.running` or `.paused`).
    public var runStates: [QueueKind: QueueRunState]
    /// Per-provider active (running) item counts.
    public var providerCounts: [String: Int]
    /// Wikis with an active ingestion item (the per-wiki invariant).
    public var activeIngestionWikis: Set<String>

    public init(
        activeItems: [QueueItem] = [],
        recentItems: [QueueItem] = [],
        runStates: [QueueKind: QueueRunState] = [:],
        providerCounts: [String: Int] = [:],
        activeIngestionWikis: Set<String> = []
    ) {
        self.activeItems = activeItems
        self.recentItems = recentItems
        self.runStates = runStates
        self.providerCounts = providerCounts
        self.activeIngestionWikis = activeIngestionWikis
    }
}

// MARK: - QueueEngineConfig

/// Capacity limits for the engine. The engine does not own provider
/// configuration — it receives limits at construction. Per-provider ingestion
/// limits are sourced from `AgentProvidersConfig.maxConcurrent` (or default 1).
public struct QueueEngineConfig: Sendable {
    /// Per-provider concurrent ingestion limits. A missing key defaults to 1.
    /// Sourced from `AgentProvidersConfig.maxConcurrent`.
    public var ingestionLimits: [String: Int]

    /// Maximum concurrent extractions using the local pdf2md backend.
    /// Default 1 (local subprocess, must be serialized).
    public var localExtractionLimit: Int

    /// Maximum concurrent extractions using a remote backend (Claude,
    /// Docling Serve). Default 2.
    public var remoteExtractionLimit: Int

    /// How many terminal items to load for the snapshot's `recentItems`.
    public var recentLimit: Int

    public init(
        ingestionLimits: [String: Int] = [:],
        localExtractionLimit: Int = 1,
        remoteExtractionLimit: Int = 2,
        recentLimit: Int = 200
    ) {
        self.ingestionLimits = ingestionLimits
        self.localExtractionLimit = localExtractionLimit
        self.remoteExtractionLimit = remoteExtractionLimit
        self.recentLimit = recentLimit
    }

    /// The concurrency limit for a given provider ID. Missing key → 1.
    public func ingestionLimit(for providerID: String) -> Int {
        ingestionLimits[providerID] ?? 1
    }

    /// The extraction limit for a given provider/extraction-backend ID.
    /// Local backends (containing "local" or "pdf2md") get `localExtractionLimit`;
    /// everything else gets `remoteExtractionLimit`.
    public func extractionLimit(for providerID: String) -> Int {
        let lowered = providerID.lowercased()
        if lowered.contains("local") || lowered.contains("pdf2md") {
            return localExtractionLimit
        }
        return remoteExtractionLimit
    }
}
