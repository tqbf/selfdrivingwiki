import Foundation
import os
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `dispatchScan` claim correctness: a lane pause that lands during
/// provider resolution cannot be raced by a claim, and a claim whose
/// post-claim read-back fails (throw or nil) is repaired instead of stranding
/// the item `.running` with no worker.
///
/// Reuses the fake worker infrastructure from `QueueEngineTests` — do not
/// duplicate those seams here.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct QueueEngineClaimTests {

    // MARK: - Test helpers

    /// A fresh on-disk `queue.sqlite` URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-claim-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    /// A trivial payload for tests that don't care about payload specifics.
    private func makePayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [SourceID(rawValue: "CLAIMSRC001")])
    }

    // MARK: - Pause race (AC.1)

    @Test func pauseDuringProviderResolutionPreventsClaim() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let control = SuspendingProviderResolution()
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { item in await control.providerID(for: item) },
            worker: { item in recorder.record(item.id) })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        // Enqueue off the test task: `enqueue` runs `dispatchScan`, which must
        // suspend inside `providerID(for:)` while the lane is still running —
        // that is the window `pause()` needs to land mid-resolution.
        let request = QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "pause-race-wiki"),
            payload: makePayload())
        let enqueueTask = Task { try await engine.enqueue(request) }
        await control.awaitEntered()

        // The engine actor is suspended at the provider await, so `pause`
        // runs before the claim block can.
        await engine.pause(.ingestion)
        control.release()

        let itemID = try await enqueueTask.value

        // No claim raced the pause: the item is still queued and no worker ran.
        let item = try #require(try store.getItem(itemID))
        #expect(item.state == .queued)
        #expect(recorder.executedIDs.isEmpty)
        let snapshot = await engine.snapshot()
        #expect(snapshot.providerCounts.isEmpty)

        // The next `resume` re-scans and the item dispatches normally.
        try await engine.resume(.ingestion)
        try await recorder.waitForCount(1, timeoutSeconds: 5)
        #expect(recorder.executedIDs == [itemID])

        store.close()
    }

    // MARK: - Stranded-claim repair (AC.2)

    @Test func readBackThrowAfterClaimRequeuesInsteadOfStranding() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in recorder.record(item.id) })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        // Arm the one-shot read-back failure BEFORE the enqueue's dispatch
        // scan: the claim (markRunning) succeeds, then the read-back throws.
        struct ReadBackError: Error {}
        store.injectGetItemOutcome(.failure(ReadBackError()))

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "strand-throw-wiki"),
            payload: makePayload()))

        // The stranded claim was repaired: back to `.queued`, no worker ran,
        // and no provider slot leaked.
        let item = try #require(try store.getItem(itemID))
        #expect(item.state == .queued)
        #expect(item.providerID == nil)
        #expect(recorder.executedIDs.isEmpty)
        let snapshot = await engine.snapshot()
        #expect(snapshot.providerCounts.isEmpty)

        // The item is dispatchable again on the next scan.
        try await engine.resume(.ingestion)
        try await recorder.waitForCount(1, timeoutSeconds: 5)
        let completion = await engine.waitForCompletion(of: itemID)
        if case .failure(let error) = completion {
            Issue.record("repaired item should complete, got \(error)")
        }

        store.close()
    }

    @Test func readBackNilAfterClaimRequeuesInsteadOfStranding() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in recorder.record(item.id) })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)
        await engine.start()

        // One-shot nil read-back: the row "vanished" between the claim and
        // the read. The repair's requeue CAS matches the still-`.running`
        // row and returns it to `.queued`.
        store.injectGetItemOutcome(.success(nil))

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: WikiID(rawValue: "strand-nil-wiki"),
            payload: makePayload()))

        let item = try #require(try store.getItem(itemID))
        #expect(item.state == .queued)
        #expect(item.providerID == nil)
        #expect(recorder.executedIDs.isEmpty)
        let snapshot = await engine.snapshot()
        #expect(snapshot.providerCounts.isEmpty)

        try await engine.resume(.ingestion)
        try await recorder.waitForCount(1, timeoutSeconds: 5)
        let completion = await engine.waitForCompletion(of: itemID)
        if case .failure(let error) = completion {
            Issue.record("repaired item should complete, got \(error)")
        }

        store.close()
    }

    // MARK: - Durable admission status (AC.8)

    @Test func nilRouteRecordsAdmissionStatusAndResumeClearsIt() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let recorder = FakeWorkerRecorder()
        // No provider route ever resolves for this item.
        let factory = FakeWorkerFactory(
            providerID: { _ in nil },
            worker: { item in recorder.record(item.id) })
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory)

        // Collect progress events to assert the surfaced trail line. The
        // stream must be captured BEFORE start()/enqueue: `engine.events`
        // registers a new subscriber per access, and the scan's progress
        // emission can win the race against a late subscription under load.
        let events = engine.events
        let progressLines = AdmissionProgressRecorder()
        let eventsTask = Task {
            for await event in events {
                if case .progress(let id, let line) = event {
                    progressLines.record(id: id, line: line)
                }
            }
        }
        await engine.start()

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        try await Task.sleep(nanoseconds: 200_000_000)

        // The forever-queued item now carries a durable, visible reason.
        let item = try #require(try store.getItem(itemID))
        #expect(item.state == .queued)
        #expect(item.admissionReason == QueueAdmissionReason.noExtractorRoute)
        #expect(item.admissionCheckedAt != nil)
        #expect(progressLines.lines(for: itemID).contains(
            QueueAdmissionReason.noExtractorRouteProgressLine))

        // Re-scans must not duplicate the record or the progress line: poke
        // another scan and assert the recorded line count is unchanged.
        _ = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w2"), payload: makePayload()))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(progressLines.lines(for: itemID).count == 1)

        // Resume re-checks admission: the lane's recorded blockers are
        // cleared, then the scan re-records them for items whose route STILL
        // resolves to nil (a fresh checked-at timestamp). The item stays
        // queued — and the second progress line proves the clear + re-record
        // cycle ran.
        try await engine.resume(.ingestion)
        let after = try #require(try store.getItem(itemID))
        #expect(after.state == .queued)
        #expect(after.admissionReason == QueueAdmissionReason.noExtractorRoute)
        #expect(after.admissionCheckedAt != nil)
        #expect(progressLines.lines(for: itemID).count == 2)

        eventsTask.cancel()
        store.close()
    }
}

/// Collects `.progress` lines per item for trail assertions.
private final class AdmissionProgressRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: [QueueItem.ID: [String]]())

    func record(id: QueueItem.ID, line: String) {
        lock.withLock { state in
            state[id, default: []].append(line)
        }
    }

    func lines(for id: QueueItem.ID) -> [String] {
        lock.withLock { $0[id] ?? [] }
    }
}

/// Provider-resolution stub for the pause-race test: signals entry, then
/// suspends until `release()` before returning a provider ID. Streams (not
/// latches) so no cooperative-pool thread is blocked while suspended.
private final class SuspendingProviderResolution: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let releaseGate = AsyncStream<Void>.makeStream()

    func providerID(for item: QueueItem) async -> ProviderID? {
        entered.continuation.yield(())
        entered.continuation.finish()
        for await _ in releaseGate.stream { break }
        return ProviderID(rawValue: "p1")
    }

    func awaitEntered() async {
        for await _ in entered.stream { break }
    }

    func release() {
        releaseGate.continuation.yield(())
        releaseGate.continuation.finish()
    }
}
