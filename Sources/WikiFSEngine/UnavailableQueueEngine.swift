import Foundation
import WikiFSCore

/// A `QueueEngineClient` whose backing store could not be opened (issue #881).
///
/// Replaces the former silent `:memory:` fallback in `WikiFSApp`: when
/// `queue.sqlite` fails to open, the app now constructs an
/// `UnavailableQueueEngine` so the rest of the app stays usable for browsing,
/// while every enqueue / retry surfaces a clear, user-visible error instead of
/// silently dropping work on the floor (the in-memory fallback lost every
/// enqueued item on restart).
///
/// - `enqueue` / `retryItem` throw `UnavailableQueueEngine.Error.unavailable`
///   so the ingest/extract path can present the failure to the user.
/// - Read accessors (`snapshot`, `loadTranscript`, …) return empty results.
/// - `events` is a finished stream (no items will ever be produced).
///
/// The error message is captured at construction time so callers can surface
/// the original `QueueStore` open failure (path + underlying error).
public final class UnavailableQueueEngine: QueueEngineClient, @unchecked Sendable {

    /// The error thrown by every mutating operation on this engine.
    public enum Error: Swift.Error, LocalizedError, CustomStringConvertible {
        /// The queue database could not be opened. `reason` is the original
        /// failure (path + underlying error) captured at construction time.
        case unavailable(reason: String)

        public var description: String {
            switch self {
            case .unavailable(let reason):
                return "Queue unavailable: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// The original open-failure reason (path + underlying error). Surfaced to
    /// the user via the app-level alert in `WikiFSApp`.
    public let reason: String

    /// A finished event stream — no items are ever produced.
    private let finishedStream: AsyncStream<QueueEvent>

    public init(reason: String) {
        self.reason = reason
        // A finished stream: subscribers drain immediately with no events.
        var continuation: AsyncStream<QueueEvent>.Continuation!
        let stream = AsyncStream<QueueEvent> { c in
            continuation = c
        }
        continuation.finish()
        self.finishedStream = stream
    }

    // MARK: - QueueEngineClient conformance

    public var events: AsyncStream<QueueEvent> { finishedStream }

    @discardableResult
    public func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        throw Error.unavailable(reason: reason)
    }

    public func cancelItem(_ id: QueueItem.ID) async {}

    @discardableResult
    public func cancelAllInFlight() async -> Int { 0 }

    public func retryItem(_ id: QueueItem.ID) async throws {
        throw Error.unavailable(reason: reason)
    }

    public func pause(_ queue: QueueKind) async {}

    public func resume(_ queue: QueueKind) async {}

    public func halt(_ queue: QueueKind) async {}

    public func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {}

    public func snapshot() async -> QueueSnapshot { QueueSnapshot() }

    public func hasActiveWork(for wikiID: String) async -> Bool { false }

    public func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Swift.Error> {
        .failure(Error.unavailable(reason: reason))
    }

    public func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] { [] }

    public func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
}
