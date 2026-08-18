#if os(macOS)
import Foundation
import WikiFSCore
import WikiCtlCore
import WikiFSEngine

/// A `QueueEngineClient` that proxies ALL 13 methods to the daemon's
/// `QueueEngine` via XPC. This is the Phase A+B pure pass-through — the app
/// no longer constructs its own `QueueEngine`. One DB, one engine, one owner
/// (the daemon).
///
/// The `events` property returns the `DaemonQueueEventSink`'s stream, fed by
/// the daemon's `deliverEvent` callbacks. Consumers (`QueueActivityTracker`,
/// `OperationNotifier`, `MenuBarItemController`) see a single unified
/// `QueueEvent` stream — identical to what they'd see from a local engine.
///
/// RC1: single owner — the daemon owns `queue.sqlite` exclusively. No local
/// engine, no snapshot merging, no split DBs.
/// RC3: pure pass-through — every call goes to the daemon's `QueueEngine`.
/// RC4: all XPC calls go through `DaemonWorkloadClient` which adds a 30s
/// timeout + error envelope.
///
/// Error visibility: no call swallows XPC failures silently. Every `try?`
/// that previously fell back to an empty/default value is now a `do/catch`
/// that logs the failure via `DebugLog.ingest` before returning the fallback,
/// so a daemon-side error (timeout, connection drop, decode failure) is always
/// visible in Console.app instead of looking like an empty queue (#867).
final class XPCQueueEngineProxy: QueueEngineClient {
    private let workloadClient: DaemonWorkloadClient
    private let eventSink: DaemonQueueEventSink

    init(workloadClient: DaemonWorkloadClient, eventSink: DaemonQueueEventSink) {
        self.workloadClient = workloadClient
        self.eventSink = eventSink
    }

    var events: AsyncStream<QueueEvent> { eventSink.events }

    @discardableResult
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        try await workloadClient.enqueue(request)
    }

    func cancelItem(_ id: QueueItem.ID) async throws {
        do {
            try await workloadClient.cancelItem(id)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.cancelItem failed for \(id.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    func cancelAllInFlight() async throws -> Int {
        do {
            return try await workloadClient.cancelAllInFlight()
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.cancelAllInFlight failed: \(error.localizedDescription)")
            throw error
        }
    }

    func retryItem(_ id: QueueItem.ID) async throws {
        do {
            try await workloadClient.retryItem(id)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.retryItem failed for \(id.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    func pause(_ queue: QueueKind) async throws {
        do {
            try await workloadClient.pause(queue)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.pause(\(queue)) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func resume(_ queue: QueueKind) async throws {
        do {
            try await workloadClient.resume(queue)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.resume(\(queue)) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func halt(_ queue: QueueKind) async throws {
        do {
            try await workloadClient.halt(queue)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.halt(\(queue)) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        do {
            try await workloadClient.reorderItem(id: id, beforeItemID: beforeItemID)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.reorderItem failed for \(id.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    func snapshot() async throws -> QueueSnapshot {
        do {
            return try await workloadClient.queueSnapshot()
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.snapshot failed: \(error.localizedDescription)")
            throw error
        }
    }

    func hasActiveWork(for wikiID: WikiID) async throws -> Bool {
        do {
            return try await workloadClient.hasActiveWork(for: wikiID)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.hasActiveWork failed for \(wikiID): \(error.localizedDescription)")
            throw error
        }
    }

    func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> {
        do {
            let payload = try await workloadClient.waitForCompletion(of: id)
            if payload.completed { return .success(()) }
            return .failure(QueueItemCompletionError(
                message: payload.errorMessage ?? "Queue item did not complete"))
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.waitForCompletion transport failed for \(id.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] {
        do {
            return try await workloadClient.loadTranscript(for: itemID)
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.loadTranscript failed for \(itemID.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
        let data: [String: QueueEngine.ActivitySnapshotData]
        do {
            data = try await workloadClient.loadAllActivitySnapshots()
        } catch {
            DebugLog.ingest("XPCQueueEngineProxy.loadAllActivitySnapshots failed: \(error.localizedDescription)")
            throw error
        }
        var result: [QueueItem.ID: QueueEngine.ActivitySnapshot] = [:]
            for (id, snapshot) in data {
                result[QueueItemID(rawValue: id)] = QueueEngine.ActivitySnapshot(
                usage: snapshot.usage,
                logURL: snapshot.logURL,
                debugURL: snapshot.debugURL,
                progressLog: snapshot.progressLog)
        }
        return result
    }
}
#endif
