import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSCore

/// Regression coverage for the synchronous provider-callback seam. The store
/// is real in the durability cases so these tests cover translation, ordering,
/// SQLite persistence, and the live event value together.
@Suite(.serialized)
struct QueueTranscriptConcurrencyTests {
    @Test func sameAttemptCallbacksCommitInAcceptedOrder() throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let state = QueueTranscriptStateStore()
        let updates = UpdateRecorder()
        state.begin(attempt)

        state.accept(event: .assistantText("first"), for: attempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { updates.append($0) })
        state.accept(event: .assistantText("second"), for: attempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { updates.append($0) })

        #expect(updates.batchNumbers == [0, 1])
        #expect(messageTexts(try store.loadTranscriptItems(itemID: item.id)) == ["first", "second"])
    }

    @Test func differentAttemptsDoNotShareTranslatorState() throws {
        let store = try makeStore()
        let first = try enqueueItem(in: store)
        let second = try enqueueItem(in: store)
        let firstAttempt = QueueAttemptID(itemID: first.id, attempt: first.attempt)
        let secondAttempt = QueueAttemptID(itemID: second.id, attempt: second.attempt)
        let state = QueueTranscriptStateStore()
        state.begin(firstAttempt)
        state.begin(secondAttempt)

        state.accept(event: .assistantTextDelta("one"), for: firstAttempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { _ in })
        state.accept(event: .assistantTextDelta("two"), for: secondAttempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { _ in })

        let firstItem = try #require(try store.loadTranscriptItems(itemID: first.id).first)
        let secondItem = try #require(try store.loadTranscriptItems(itemID: second.id).first)
        #expect(firstItem != secondItem)
        #expect(messageTexts([firstItem]) == ["one"])
        #expect(messageTexts([secondItem]) == ["two"])
    }

    @Test func delayedFirstBatchCannotBeOvertakenBySecondBatch() async throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let state = QueueTranscriptStateStore()
        let updates = UpdateRecorder()
        let firstPersistEntered = AsyncSignal()
        let releaseFirstPersist = DispatchSemaphore(value: 0)
        let secondReturned = AsyncSignal()
        state.begin(attempt)

        let persist: @Sendable (QueueTranscriptUpdate) throws -> Void = { update in
            if update.batchNumber == 0 {
                firstPersistEntered.signal()
                _ = releaseFirstPersist.wait(timeout: .now() + 5)
            }
            try store.upsertTranscriptItems(attemptID: update.attemptID, items: update.changedItems)
        }
        let first = Task.detached {
            state.accept(event: .assistantText("A"), for: attempt, persist: persist, broadcast: { updates.append($0) })
        }
        await firstPersistEntered.wait()

        let second = Task.detached {
            state.accept(event: .assistantText("B"), for: attempt, persist: persist, broadcast: { updates.append($0) })
            secondReturned.signal()
        }
        await secondReturned.wait()
        releaseFirstPersist.signal()
        await first.value
        await second.value

        #expect(updates.batchNumbers == [0, 1])
        #expect(messageTexts(try store.loadTranscriptItems(itemID: item.id)) == ["A", "B"])
    }

    @Test func sqliteRunsAfterTranslationLockIsReleased() async throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let state = QueueTranscriptStateStore()
        let firstPersistEntered = AsyncSignal()
        let releaseFirstPersist = DispatchSemaphore(value: 0)
        let secondCallbackReturned = AsyncSignal()
        state.begin(attempt)

        let persist: @Sendable (QueueTranscriptUpdate) throws -> Void = { update in
            if update.batchNumber == 0 {
                firstPersistEntered.signal()
                _ = releaseFirstPersist.wait(timeout: .now() + 5)
            }
            try store.upsertTranscriptItems(attemptID: update.attemptID, items: update.changedItems)
        }
        let first = Task.detached {
            state.accept(event: .assistantText("locked only for reduction"), for: attempt, persist: persist, broadcast: { _ in })
        }
        await firstPersistEntered.wait()
        let second = Task.detached {
            state.accept(event: .assistantText("second callback"), for: attempt, persist: persist, broadcast: { _ in })
            secondCallbackReturned.signal()
        }

        // Batch B can translate and enqueue while A is blocked in SQLite. If
        // the callback lock covered persistence, this timeout would fire.
        await secondCallbackReturned.wait()
        releaseFirstPersist.signal()
        await first.value
        await second.value
    }

    @Test func oldWorkerCallbackAfterRetryIsRejected() throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let oldAttempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let state = QueueTranscriptStateStore()
        let updates = UpdateRecorder()
        state.begin(oldAttempt)
        state.accept(event: .assistantText("old accepted"), for: oldAttempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { updates.append($0) })
        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "test"))
        try store.markFailed(id: item.id, error: "retry")
        state.invalidate(itemID: item.id)
        try store.retryItem(id: item.id)
        let retried = try #require(try store.getItem(item.id))
        let currentAttempt = QueueAttemptID(itemID: retried.id, attempt: retried.attempt)
        state.begin(currentAttempt)

        state.accept(event: .assistantText("late old"), for: oldAttempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { updates.append($0) })
        state.accept(event: .assistantText("new"), for: currentAttempt,
                     persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                     broadcast: { updates.append($0) })

        #expect(updates.batchNumbers == [0, 0])
        #expect(messageTexts(try store.loadTranscriptItems(itemID: item.id)) == ["new"])
    }

    @Test func oldWorkerCallbackAfterNewOutputIsRejected() throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let oldAttempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let newAttempt = QueueAttemptID(itemID: item.id, attempt: item.attempt + 1)
        let state = QueueTranscriptStateStore()
        let updates = UpdateRecorder()
        state.begin(oldAttempt)
        state.begin(newAttempt)

        state.accept(event: .assistantText("new output"), for: newAttempt,
                     persist: { _ in }, broadcast: { updates.append($0) })
        state.accept(event: .assistantText("old output"), for: oldAttempt,
                     persist: { _ in }, broadcast: { updates.append($0) })

        #expect(updates.updates.map(\.attemptID) == [newAttempt])
        #expect(messageTexts(updates.updates.flatMap(\.changedItems)) == ["new output"])
    }

    @Test func oldWorkerCallbackAfterStateCleanupIsRejected() throws {
        let store = try makeStore()
        let item = try enqueueItem(in: store)
        let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let state = QueueTranscriptStateStore()
        let updates = UpdateRecorder()
        state.begin(attempt)
        state.finish(attempt)

        state.accept(event: .assistantText("late"), for: attempt,
                     persist: { _ in Issue.record("Late callback reached persistence") },
                     broadcast: { updates.append($0) })

        #expect(updates.updates.isEmpty)
    }

    @Test func reopenedTranscriptPreservesAcceptedEventOrder() throws {
        let url = try temporaryDatabaseURL()
        let itemID: QueueItem.ID
        do {
            let store = try QueueStore(databaseURL: url)
            let item = try enqueueItem(in: store)
            itemID = item.id
            let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
            let state = QueueTranscriptStateStore()
            state.begin(attempt)
            state.accept(event: .assistantText("first"), for: attempt,
                         persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                         broadcast: { _ in })
            state.accept(event: .assistantText("second"), for: attempt,
                         persist: { try store.upsertTranscriptItems(attemptID: $0.attemptID, items: $0.changedItems) },
                         broadcast: { _ in })
            store.close()
        }

        let reopened = try QueueStore(databaseURL: url)
        #expect(messageTexts(try reopened.loadTranscriptItems(itemID: itemID)) == ["first", "second"])
    }

    private func makeStore() throws -> QueueStore {
        try QueueStore(databaseURL: temporaryDatabaseURL())
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-transcript-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("queue.sqlite")
    }

    private func enqueueItem(in store: QueueStore) throws -> QueueItem {
        try store.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: WikiID(rawValue: "queue-transcript-concurrency"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "source")])
        ))
    }

    private func messageTexts(_ items: [ChatTranscriptItem]) -> [String] {
        items.compactMap { item in
            guard case .message(let message) = item else { return nil }
            return message.text
        }
    }
}

private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [QueueTranscriptUpdate] = []

    var updates: [QueueTranscriptUpdate] {
        lock.withLock { storage }
    }

    var batchNumbers: [Int] {
        lock.withLock { storage.map(\.batchNumber) }
    }

    func append(_ update: QueueTranscriptUpdate) {
        lock.withLock { storage.append(update) }
    }
}

/// A one-shot, non-blocking test barrier. Its continuation is resumed outside
/// the lock, so it is safe to signal from the synchronous persistence seam.
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isSignaled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isSignaled = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }
}
