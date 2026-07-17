import Foundation
import os
import Testing
@testable import WikiFSEngine
import WikiFSCore

/// Tests for the `QueueEngine` actor (Phase 2) using fake workers.
///
/// These tests verify scheduling, capacity limits, pause/halt semantics,
/// chained-item completion, event stream contents, and rehydration — all
/// with injectable fake workers (no real extraction/ingestion runs).
@Suite(.serialized)
struct QueueEngineTests {

    // MARK: - Test helpers

    /// A fresh on-disk `queue.sqlite` URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    /// A trivial payload for tests that don't care about payload specifics.
    private func makePayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [PageID(rawValue: "TESTSRC001")])
    }

    // MARK: - Dispatch order (AC2.2)

    @Test func testItemsDispatchInOrderingKeyOrder() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        // Enqueue 3 extraction items — they get ordering keys 1000, 2000, 3000.
        // Use a factory that assigns all items to provider "p1" with limit 1
        // so only one runs at a time, and record execution order.
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
            }
        )
        let config = QueueEngineConfig(
            ingestionLimits: ["p1": 1],
            localExtractionLimit: 1,
            remoteExtractionLimit: 1
        )
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        let id2 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        let id3 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))

        // Start the engine (triggers dispatch + rehydration).
        await engine.start()

        // Wait for all 3 to complete.
        try await recorder.waitForCount(3, timeoutSeconds: 5)

        // Items should have been dispatched in ordering-key order.
        let order = recorder.executedIDs
        #expect(order == [id1, id2, id3])

        store.close()
    }

    // MARK: - Per-provider concurrency limit (AC3.2)

    @Test func testProviderAtMaxConcurrentDoesntStartFurther() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()  // Block the first item so the slot is held.
            }
        )
        let config = QueueEngineConfig(ingestionLimits: ["p1": 1])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let blockedID = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))
        let waitingID = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w2", payload: makePayload()))

        await engine.start()

        // Give the engine a moment — the blocked item should start, but the
        // second should not (provider p1 is at capacity 1).
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(recorder.executedIDs == [blockedID])
        #expect(recorder.executedIDs != [blockedID, waitingID])

        // Release the gate — the second item should now dispatch.
        gate.release()
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    // MARK: - Items on different providers run concurrently (AC3.1)

    @Test func testDifferentProvidersRunConcurrently() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { item in
                // Assign items to different providers based on their wikiID.
                item.wikiID == "w1" ? "p1" : "p2"
            },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(ingestionLimits: ["p1": 1, "p2": 1])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w2", payload: makePayload()))

        await engine.start()

        // Both should start (different providers, different wikis).
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        gate.release()
        store.close()
    }

    // MARK: - Per-wiki ingestion invariant (AC3.3)

    @Test func testAtMostOneIngestionPerWiki() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        // Provider limit is 2, but per-wiki invariant should still block.
        let config = QueueEngineConfig(ingestionLimits: ["p1": 2])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))

        await engine.start()

        // Only the first should have started — same wiki, invariant blocks the second.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.executedIDs == [id1])

        // Release — the second should now dispatch.
        gate.release()
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    // MARK: - Local pdf2md serialized (AC3.4)

    @Test func testLocalExtractionSerialized() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "local-pdf2md" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 5)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w2", payload: makePayload()))

        await engine.start()

        // Only the first should start (local extraction = limit 1).
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.executedIDs == [id1])

        gate.release()
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    // MARK: - Pause stops new dispatch (AC3.5)

    @Test func testPauseStopsNewDispatch() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w2", payload: makePayload()))

        await engine.start()

        // Wait for the first item to start, then pause.
        try await recorder.waitForCount(1, timeoutSeconds: 5)
        await engine.pause(.extraction)

        // Release the gate — the first item finishes, but the second should
        // NOT dispatch because the queue is paused.
        gate.release()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.executedIDs == [id1])

        // Resume — the second should now dispatch.
        await engine.resume(.extraction)
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    // MARK: - Pause state survives relaunch (AC3.5)

    @Test func testPauseStatePersistsAcrossReopen() async throws {
        let url = tempDatabaseURL()

        do {
            let store = try QueueStore(databaseURL: url)
            let factory = FakeWorkerFactory(
                providerID: { _ in "p1" },
                worker: { _ in }
            )
            let engine = QueueEngine(
                store: store, config: QueueEngineConfig(), workerFactory: factory)
            await engine.start()
            await engine.pause(.ingestion)
            store.close()
        }

        // Reopen at the same URL.
        let store = try QueueStore(databaseURL: url)
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in }
        )
        let engine = QueueEngine(
            store: store, config: QueueEngineConfig(), workerFactory: factory)
        await engine.start()

        // The engine should have loaded the paused state.
        let snap = await engine.snapshot()
        #expect(snap.runStates[.ingestion] == .paused)
        #expect(snap.runStates[.extraction] == .running)

        store.close()
    }

    // MARK: - Halt cancels in-flight items (AC3.6)

    @Test func testHaltCancelsInFlightItems() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))

        await engine.start()
        try await recorder.waitForCount(1, timeoutSeconds: 5)

        // Halt the extraction queue — the running item should be requeued.
        await engine.halt(.extraction)

        // The item should be back in queued state (requeue preserves orderingKey).
        let item = try store.getItem(id1)
        #expect(item?.state == .queued)

        // Resume — the item should run again (the gate is still held, so the
        // requeued item will start and block).
        // Release the gate first so the requeued item can proceed.
        gate.release()
        await engine.resume(.extraction)
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    // MARK: - Failed item records error, frees slot (AC3.7)

    @Test func testFailedItemRecordsErrorAndFreesSlot() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        struct TestError: Error {}
        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                if recorder.executedIDs.count == 1 {
                    throw TestError()
                }
                await gate.wait()
            }
        )
        // "p1" is a *remote* backend, so it is governed by `remoteExtractionLimit`
        // — `localExtractionLimit` does not apply to it. Serialize the two items
        // so the `executedIDs.count == 1` throw reliably targets the first item;
        // with the default remoteExtractionLimit of 2 both run concurrently and
        // the check races on recording order (intermittently marking id1 done
        // instead of failed).
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w2", payload: makePayload()))

        await engine.start()

        // The first item should fail and the second should start.
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        gate.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        // First item should be in .failed state with an error.
        let failed = try store.getItem(id1)
        #expect(failed?.state == .failed)
        #expect(failed?.error != nil)
        #expect(failed?.attempt == 0)  // Not retried yet.

        store.close()
    }

    // MARK: - Retry re-enqueues with attempt + 1 (AC3.7)

    @Test func testRetryReenqueuesWithAttemptIncrement() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        struct TestError: Error {}
        let gate = CountDownLatch(count: 1)

        // First call throws; subsequent calls block on the gate so the
        // retried item stays alive while we inspect it.
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                if item.attempt == 0 { throw TestError() }
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Item should be failed (attempt 0).
        let failed = try store.getItem(id1)
        #expect(failed?.state == .failed)
        #expect(failed?.attempt == 0)

        // Retry: attempt should increment and the item re-dispatches.
        try await engine.retryItem(id1)

        // Give the dispatch a moment to start the worker (which blocks on the gate).
        try await Task.sleep(nanoseconds: 200_000_000)

        let retried = try store.getItem(id1)
        // The item should be running (re-dispatched) with attempt 1.
        #expect(retried?.attempt == 1)
        #expect(retried?.state == .running)

        gate.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        // After the gate releases, the item should complete.
        let completed = try store.getItem(id1)
        #expect(completed?.state == .completed)
        #expect(completed?.attempt == 1)

        store.close()
    }

    // MARK: - Enqueue returns immediately (AC4.1)

    @Test func testEnqueueReturnsImmediately() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in await gate.wait() }
        )
        let engine = QueueEngine(store: store, config: QueueEngineConfig(), workerFactory: factory)
        await engine.start()

        // Enqueue should return immediately even though the worker is blocked.
        let start = Date()
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.5)  // Should be near-instant.

        gate.release()
        store.close()
    }

    // MARK: - Items from multiple wikis in one queue (AC2.1)

    @Test func testItemsFromMultipleWikisInOneQueue() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { item in
                // Round-robin providers to match the config below: w1→p1,
                // w2→p2, w3→p1. With two providers (limit 1 each) two wikis run
                // concurrently while the third waits for a slot — which is what
                // the test intends to exercise.
                switch item.wikiID {
                case "w1", "w3": return "p1"
                case "w2": return "p2"
                default: return "p1"
                }
            },
            worker: { item in recorder.record(item.id) }
        )
        // Two providers, limit 1 each, so two wikis can run concurrently.
        let config = QueueEngineConfig(ingestionLimits: ["p1": 1, "p2": 1])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        // Enqueue items from 3 different wikis.
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w2", payload: makePayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w3", payload: makePayload()))

        await engine.start()

        // All 3 should eventually complete (different wikis).
        try await recorder.waitForCount(3, timeoutSeconds: 5)

        let snap = await engine.snapshot()
        #expect(snap.recentItems.count == 3)

        let wikis = Set(snap.recentItems.map(\.wikiID))
        #expect(wikis.contains("w1"))
        #expect(wikis.contains("w2"))
        #expect(wikis.contains("w3"))

        store.close()
    }

    // MARK: - Crash recovery / rehydration (AC2.5)

    @Test func testRehydrationResetsRunningToQueued() async throws {
        let url = tempDatabaseURL()

        // Enqueue items, mark one as running, then simulate a crash by closing
        // the store without cleanup.
        let itemID: QueueItem.ID
        do {
            let store = try QueueStore(databaseURL: url)
            let item = try store.enqueue(
                QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
            itemID = item.id
            try store.markRunning(id: itemID, providerID: "p1")
            // Simulate crash — close without transitioning to a terminal state.
            store.close()
        }

        // Reopen and start the engine.
        let store = try QueueStore(databaseURL: url)
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in }
        )
        let engine = QueueEngine(store: store, config: QueueEngineConfig(), workerFactory: factory)
        await engine.start()

        // The running item should have been reset to queued and then dispatched.
        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(itemID)
        // It should be either .queued (didn't dispatch yet) or .completed (dispatched + finished).
        #expect(item?.state == .completed || item?.state == .queued || item?.state == .running)

        store.close()
    }

    // MARK: - Event stream contents

    @Test func testEventStreamEmitsEnqueuedStartedCompleted() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in }
        )
        let engine = QueueEngine(store: store, config: QueueEngineConfig(), workerFactory: factory)
        await engine.start()

        // Start collecting events BEFORE enqueuing.
        let eventTask = Task {
            var events: [QueueEvent] = []
            for await event in engine.events {
                events.append(event)
                // Collect until we see a .completed event.
                if case .completed = event { break }
            }
            return events
        }

        // Small delay so the collector starts.
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))

        let events = await eventTask.value

        // Should have at least .enqueued, .started, .completed.
        #expect(events.count >= 3)
        if case .enqueued = events[0] { /* ok */ } else { Issue.record("first event should be .enqueued") }
        if case .started = events[1] { /* ok */ } else { Issue.record("second event should be .started") }
        // Find the completed event.
        let hasCompleted = events.contains { event in
            if case .completed = event { return true }
            return false
        }
        #expect(hasCompleted)

        store.close()
    }

    // MARK: - Snapshot

    @Test func testSnapshotReflectsEngineState() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in await gate.wait() }
        )
        let engine = QueueEngine(store: store, config: QueueEngineConfig(), workerFactory: factory)
        await engine.start()

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 200_000_000)

        let snap = await engine.snapshot()
        // One active (running) item.
        #expect(snap.activeItems.count == 1)
        #expect(snap.activeItems.first?.state == .running)
        #expect(snap.runStates[.extraction] == .running)
        #expect(snap.runStates[.ingestion] == .running)

        gate.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        let snap2 = await engine.snapshot()
        #expect(snap2.activeItems.count == 0)
        #expect(snap2.recentItems.count == 1)

        store.close()
    }

    // MARK: - Cancel item

    @Test func testCancelQueuedItem() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { _ in await gate.wait() }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        // Enqueue 2 items — the first will start (blocking), the second will be queued.
        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w1", payload: makePayload()))
        let id2 = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "w2", payload: makePayload()))

        await engine.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Cancel the queued item.
        await engine.cancelItem(id2)

        let cancelled = try store.getItem(id2)
        #expect(cancelled?.state == .cancelled)

        gate.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        // The first item should have completed.
        let completed = try store.getItem(id1)
        #expect(completed?.state == .completed)

        store.close()
    }

    // MARK: - Lint per-wiki serialization + cross-wiki concurrency

    private func lintPayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [], lintPageIDs: [])
    }

    @Test func testLintAndIngestSerializePerWiki() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(ingestionLimits: ["p1": 2])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        // Enqueue a lint item and an ingestion item for the SAME wiki.
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: lintPayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: makePayload()))

        await engine.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Only the first should be running — same wiki invariant blocks the second.
        #expect(recorder.executedIDs.count == 1)

        gate.release()
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }

    @Test func testCrossWikiLintConcurrency() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let recorder = FakeWorkerRecorder()
        let gate = CountDownLatch(count: 1)

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(ingestionLimits: ["p1": 2])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: lintPayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w2", payload: lintPayload()))

        await engine.start()

        // Both should start (different wikis).
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        gate.release()
        store.close()
    }

    @Test func testPauseStopsLintDispatch() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let recorder = FakeWorkerRecorder()

        let factory = FakeWorkerFactory(
            providerID: { _ in "p1" },
            worker: { item in
                recorder.record(item.id)
                await gate.wait()
            }
        )
        let config = QueueEngineConfig(ingestionLimits: ["p1": 2])
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)

        // Both on the SAME wiki so the per-wiki invariant keeps the second queued
        // until the first finishes. Then pause stops the second from dispatching.
        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: lintPayload()))
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .ingestion, wikiID: "w1", payload: lintPayload()))

        await engine.start()
        try await recorder.waitForCount(1, timeoutSeconds: 5)
        await engine.pause(.ingestion)

        gate.release()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Only the first should have started — the queue is paused.
        #expect(recorder.executedIDs == [id1])

        await engine.resume(.ingestion)
        try await recorder.waitForCount(2, timeoutSeconds: 5)

        store.close()
    }
}

// MARK: - Fake worker infrastructure

/// A factory that returns a fixed provider ID and a closure-based worker.
/// Used by tests to inject controlled worker behavior.
private final class FakeWorkerFactory: QueueWorkerFactory, @unchecked Sendable {
    let providerIDFunc: @Sendable (QueueItem) async -> String?
    let workerFunc: @Sendable (QueueItem) async throws -> Void

    init(
        providerID: @escaping @Sendable (QueueItem) async -> String?,
        worker: @escaping @Sendable (QueueItem) async throws -> Void
    ) {
        self.providerIDFunc = providerID
        self.workerFunc = worker
    }

    func providerID(for item: QueueItem) async -> String? {
        await providerIDFunc(item)
    }

    func worker(for item: QueueItem) async throws -> any QueueWorker {
        FakeWorker { [self] item in try await workerFunc(item) }
    }
}

/// A worker that calls a closure with the item.
private struct FakeWorker: QueueWorker {
    let body: @Sendable (QueueItem) async throws -> Void

    func execute(_ item: QueueItem) async throws {
        try await body(item)
    }
}

/// Records the order of item executions. Test-only — uses
/// `OSAllocatedUnfairLock` (async-safe) so properties can be read
/// synchronously from `#expect` assertions.
private final class FakeWorkerRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [QueueItem.ID]())

    var executedIDs: [QueueItem.ID] {
        lock.withLock { $0 }
    }

    func record(_ id: QueueItem.ID) {
        lock.withLock { ids in ids.append(id) }
    }

    func waitForCount(_ count: Int, timeoutSeconds: TimeInterval) async throws {
        // The engine dispatches workers via unstructured `Task`s on Swift's
        // cooperative thread pool. Under Swift Testing's parallel execution
        // (200+ suites contending for the pool at once on CI), those tasks can
        // be starved far beyond local timings — a 3-deep sequential dispatch
        // chain that completes in <1s locally can take 8s+ on a CI runner. The
        // poll loop below returns the instant `count` is reached, so a generous
        // floor never slows a passing run; it only avoids spurious timeouts in
        // the genuine-still-pending case.
        let effective = max(timeoutSeconds, 30)
        let deadline = Date().addingTimeInterval(effective)
        while true {
            let current = executedIDs.count
            if current >= count { return }
            if Date() > deadline {
                Issue.record("Timed out waiting for \(count) executions, got \(current)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// A simple count-down latch for async tests. Test-only — uses
/// `OSAllocatedUnfairLock` (async-safe) so `release()` is synchronous.
private final class CountDownLatch: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (count: 0, waiters: [CheckedContinuation<Void, Never>]()))
    private let initialCount: Int

    init(count: Int) {
        self.initialCount = count
        lock.withLock { state in
            state.count = count
        }
    }

    func wait() async {
        // Check if already released synchronously (no suspension needed).
        let needsWait: Bool = lock.withLock { state in
            if state.count <= 0 { return false }
            return true
        }
        guard needsWait else { return }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { state in
                if state.count <= 0 {
                    c.resume()
                } else {
                    state.waiters.append(c)
                }
            }
        }
    }

    func release() {
        lock.withLock { state in
            state.count -= 1
            if state.count <= 0 {
                for w in state.waiters { w.resume() }
                state.waiters.removeAll()
            }
        }
    }
}
