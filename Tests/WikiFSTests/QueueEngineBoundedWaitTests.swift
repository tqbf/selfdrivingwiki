import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore
import WikiFSTypes

/// Bounded-wait tests (Tier 0 Phase 3): `waitForCompletion` resolves within
/// the completion-wait deadline even when the worker never settles, and the
/// deadline constant cannot silently drift below the extractor host ceiling.
///
/// Reuses the fake worker infrastructure from `QueueEngineTests` — do not
/// duplicate those seams here.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct QueueEngineBoundedWaitTests {

    // MARK: - Test helpers

    /// A fresh on-disk `queue.sqlite` URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-bounded-wait-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    /// A trivial payload for tests that don't care about payload specifics.
    private func makePayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [SourceID(rawValue: "BOUNDSRC0001")])
    }

    // MARK: - Completion-wait deadline (AC.5)

    @Test func waitForCompletionTimesOutAndLeavesTheItemRunning() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        // A single-worker hold gate: the worker never settles until released.
        let gate = AsyncStream<Void>.makeStream()
        let recorder = FakeWorkerRecorder()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "p1") },
            worker: { item in
                recorder.record(item.id)
                for await _ in gate.stream { break }
            })
        let deadline = ManualQueueEngineDeadlineSource()
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig(ingestionLimits: ["p1": 1]),
            workerFactory: factory,
            deadlineSource: deadline)
        await engine.start()

        let itemID = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        try await recorder.waitForCount(1, timeoutSeconds: 5)

        let waiterTask = Task { await engine.waitForCompletion(of: itemID) }
        // The manual deadline registers its stream the moment the engine
        // races the wait; firing then exercises the timeout path.
        await deadline.awaitWaiting()
        deadline.fire()

        let result = await waiterTask.value
        guard case .failure(let error) = result else {
            Issue.record("wait should time out with a failure, got success")
            return
        }
        guard case QueueEngineCompletionWaitError.timeout(let timedOutID) = error else {
            Issue.record("expected QueueEngineCompletionWaitError.timeout, got \(error)")
            return
        }
        #expect(timedOutID == itemID)

        // The WAIT is bounded, not the work: the item is untouched.
        let item = try #require(try store.getItem(itemID))
        #expect(item.state == .running)

        // The eventual settlement must not resume the consumed waiter a
        // second time (a crash here fails the whole run) and must leave the
        // item completable.
        gate.continuation.finish()
        let settled = await engine.waitForCompletion(of: itemID)
        if case .failure(let error) = settled {
            Issue.record("released worker should complete the item, got \(error)")
        }
        let final = try #require(try store.getItem(itemID))
        #expect(final.state == .completed)

        store.close()
    }

    @Test func completionWaitDeadlineSitsAboveTheHostCeiling() {
        // The schema caps manifest maximumDurationMilliseconds at 30 minutes
        // and Pdf2md/DoclingServe declare the full amount; the completion-wait
        // bound must stay strictly above it so a legitimate full-length run
        // can never time out its waiters.
        let ceilingMillis = ExtractorHostLimits.maximumDurationMilliseconds
        let components = QueueEngineWaitPolicy.completionWaitDeadline.components
        let deadlineMillis = Int(components.seconds) * 1_000
            + Int(components.attoseconds / 1_000_000_000)
        #expect(deadlineMillis > ceilingMillis)
    }
}
