#if os(macOS)
import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// Async wrappers over the daemon's workload XPC methods. Sibling to
/// ``WikiDaemonConnection`` (registry + store lifecycle) — this client wraps
/// the workload methods (`queueSnapshot`, `registerEventSink`, and in later
/// phases `enqueue`, `extractSource`, `startChat`, …).
///
/// The app uses this instead of calling the daemon's `@objc` protocol
/// directly so callers get typed Swift returns (`QueueSnapshot`, not raw
/// `Data`) and `async throws` instead of reply-closure dances.
///
/// See `plans/daemon-workloads.md` Phase 0 §5.
public final class DaemonWorkloadClient {

    private let proxy: WikiDaemonProtocol

    /// Create a workload client from an existing daemon connection (shares the
    /// same `NSXPCConnection` — no second connection).
    public init(connection: WikiDaemonConnection) {
        self.proxy = connection.proxy
    }

    // MARK: - Queue snapshot

    /// Fetch the daemon's queue snapshot (JSON-encoded `QueueSnapshot`).
    /// The app calls this on launch to rehydrate the Activity window after a
    /// reconnect. In Phase 0 the daemon serves an empty snapshot (the stub
    /// factory produces no workers).
    public func queueSnapshot() async throws -> QueueSnapshot {
        let data = try await withCheckedThrowingContinuation { cont in
            proxy.queueSnapshot { data in
                cont.resume(returning: data)
            }
        }
        do {
            return try JSONDecoder().decode(QueueSnapshot.self, from: data)
        } catch {
            throw WikiDaemonError.unexpectedReply
        }
    }

    // MARK: - Event sink registration

    /// Register an event-sink with the daemon. The daemon captures the proxy
    /// and pushes live workload events to it via `deliverEvent(_:)`. The app
    /// calls this once after connecting.
    public func registerEventSink(_ sink: WikiDaemonEventSink) {
        proxy.registerEventSink(sink)
    }
}
#endif
