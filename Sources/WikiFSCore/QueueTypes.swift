import Foundation

// MARK: - Queue kinds

/// The two persistent processing queues. Each `QueueItem` belongs to exactly
/// one queue, and each queue has its own independent run state (running /
/// paused) and ordering-key sequence.
public enum QueueKind: String, Codable, Sendable {
    /// PDF / document extraction (source → extracted markdown).
    case extraction
    /// Content ingestion (extracted markdown → wiki pages).
    case ingestion
}

// MARK: - Item lifecycle states

/// The lifecycle state of a single `QueueItem`. State transitions are guarded
/// by `QueueStore` — only valid transitions are allowed; all others throw
/// `QueueStoreError.invalidStateTransition`.
public enum QueueItemState: String, Codable, Sendable {
    /// Waiting to be picked up by a worker. Terminal: no.
    case queued
    /// A worker has claimed the item and is actively processing it. Terminal: no.
    case running
    /// Processing finished successfully. Terminal: yes.
    case completed
    /// Processing failed (error recorded). Terminal: yes (but retriable via
    /// `retryItem`).
    case failed
    /// Cancelled by the user / engine. Terminal: yes.
    case cancelled
}

// MARK: - Queue run state

/// Whether a whole queue (extraction or ingestion) is running or paused.
/// Persisted in `queue_state`; the engine reads this at launch to honour
/// a user-initiated pause across app restarts.
public enum QueueRunState: String, Codable, Sendable {
    case running
    case paused
}

// MARK: - Payload

/// The work description for a queue item — what the worker should process.
/// Encoded as JSON text in the `payload` column of `queue_items`.
public struct QueueItemPayload: Codable, Sendable {
    /// The source IDs this item operates on. For extraction, the sources to
    /// extract; for ingestion, the extracted-markdown sources to ingest.
    public var sourceIDs: [PageID]

    /// Ingest-stage → provider ID routing (Phase 5 refinement). `nil` means
    /// the engine uses its default provider selection.
    public var stageRouting: [String: String]?

    /// The linked `QueueItem.ID` when one item chains into another (e.g. PDF
    /// extraction completes → enqueues an ingestion item referencing this ID).
    /// `nil` for standalone items.
    public var chainedItemID: String?

    public init(
        sourceIDs: [PageID],
        stageRouting: [String: String]? = nil,
        chainedItemID: String? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.stageRouting = stageRouting
        self.chainedItemID = chainedItemID
    }
}

// MARK: - Queue item

/// A single unit of work in the persistent queue. Durable across app restarts;
/// state transitions are written through immediately by `QueueStore`.
///
/// `Identifiable` + `Sendable` so it can cross actor boundaries (the
/// `QueueEngine` actor in Phase 2) and drive SwiftUI lists in later phases.
public struct QueueItem: Codable, Sendable, Identifiable {
    /// ULID-based string identifier (see ``ULID``).
    public typealias ID = String

    public let id: ID
    public let queue: QueueKind
    public let wikiID: String
    public let payload: QueueItemPayload
    public var state: QueueItemState
    /// Monotonically increasing within a queue kind, spaced by 1000. Determines
    /// processing order; lower keys are picked up first.
    public var orderingKey: Int64
    public var providerID: String?
    /// Number of times this item has been retried (incremented by `retryItem`).
    public var attempt: Int
    public var error: String?
    /// Epoch milliseconds when the item was enqueued.
    public var createdAt: Int64
    /// Epoch milliseconds when processing started (set by `markRunning`).
    public var startedAt: Int64?
    /// Epoch milliseconds when processing finished (set by terminal transitions).
    public var finishedAt: Int64?

    public init(
        id: ID,
        queue: QueueKind,
        wikiID: String,
        payload: QueueItemPayload,
        state: QueueItemState,
        orderingKey: Int64,
        providerID: String? = nil,
        attempt: Int,
        error: String? = nil,
        createdAt: Int64,
        startedAt: Int64? = nil,
        finishedAt: Int64? = nil
    ) {
        self.id = id
        self.queue = queue
        self.wikiID = wikiID
        self.payload = payload
        self.state = state
        self.orderingKey = orderingKey
        self.providerID = providerID
        self.attempt = attempt
        self.error = error
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - Enqueue request

/// The caller-facing request to enqueue a new item. The store assigns the `id`,
/// `orderingKey`, `state`, `attempt`, and timestamps; the caller only specifies
/// what to do and for which wiki.
public struct QueueItemRequest: Codable, Sendable {
    public var queue: QueueKind
    public var wikiID: String
    public var payload: QueueItemPayload

    public init(queue: QueueKind, wikiID: String, payload: QueueItemPayload) {
        self.queue = queue
        self.wikiID = wikiID
        self.payload = payload
    }
}
