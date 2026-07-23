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

    func cancelItem(_ id: QueueItem.ID) async {
        try? await workloadClient.cancelItem(id)
    }

    @discardableResult
    func cancelAllInFlight() async -> Int {
        (try? await workloadClient.cancelAllInFlight()) ?? 0
    }

    func retryItem(_ id: QueueItem.ID) async throws {
        try await workloadClient.retryItem(id)
    }

    func pause(_ queue: QueueKind) async {
        try? await workloadClient.pause(queue)
    }

    func resume(_ queue: QueueKind) async {
        try? await workloadClient.resume(queue)
    }

    func halt(_ queue: QueueKind) async {
        try? await workloadClient.halt(queue)
    }

    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {
        try? await workloadClient.reorderItem(id: id, beforeItemID: beforeItemID)
    }

    func snapshot() async -> QueueSnapshot {
        (try? await workloadClient.queueSnapshot()) ?? QueueSnapshot()
    }

    func hasActiveWork(for wikiID: String) async -> Bool {
        (try? await workloadClient.hasActiveWork(for: wikiID)) ?? false
    }

    func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> {
        do {
            try await workloadClient.waitForCompletion(of: id)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] {
        (try? await workloadClient.loadTranscript(for: itemID)) ?? []
    }

    func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
        let data = (try? await workloadClient.loadAllActivitySnapshots()) ?? [:]
        var result: [QueueItem.ID: QueueEngine.ActivitySnapshot] = [:]
        for (id, snapshot) in data {
            result[id] = QueueEngine.ActivitySnapshot(
                usage: snapshot.usage,
                logURL: snapshot.logURL,
                debugURL: snapshot.debugURL,
                progressLog: snapshot.progressLog)
        }
        return result
    }
}
#endif
