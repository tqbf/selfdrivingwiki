#if os(macOS)
import Foundation
import Testing
import os
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the `.transcription` queue kind: `QueueTranscriptionWorker`,
/// `QueueTranscriptionWorkerFactory`, engine enqueue/waitForCompletion, and
/// capacity limits. Mirrors `QueueExtractionTests`. Uses fake providers (no
/// real network/subprocess fetches).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueueTranscriptionTests {

    // MARK: - Helpers

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-transcription-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    private func makePayload(sourceID: String = "TESTSRC001") -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [PageID(rawValue: sourceID)])
    }

    // MARK: - Enqueue returns immediately

    @Test func testEnqueueReturnsBeforeTranscription() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: { await gate.wait() }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in }
        )
        let config = QueueEngineConfig(transcriptionLimit: 2)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)
        await engine.start()

        let start = Date()
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.0) // Immediate — not waiting for the worker.
        gate.release()
        store.close()
    }

    // MARK: - Enqueue rejects empty wikiID

    @Test func testEnqueueRejectsEmptyWikiID() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let provider = FakeTranscriptionProvider(resolveResult: .resolved)
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        do {
            _ = try await engine.enqueue(
                QueueItemRequest(queue: .transcription, wikiID: "", payload: makePayload()))
            Issue.record("Should have thrown")
        } catch is QueueStoreError { /* expected */ }
        store.close()
    }

    // MARK: - Nil resolution: item stays queued

    @Test func testUnconfiguredProviderStaysQueued() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeTranscriptionProvider(resolveResult: .nilResolution)
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(id)
        #expect(item?.state == .queued) // Never dispatched.
        store.close()
    }

    // MARK: - Worker calls provider in order (resolve → fetch → persist)

    @Test func testTranscriptionWorkerCallsProviderInOrder() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: { }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(transcriptionLimit: 2),
                                 workerFactory: factory)
        await engine.start()

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let calls = provider.callLog
        // Factory calls resolve during providerID(for:), worker calls it
        // again before fetch, then persist. Expect at least 2 resolve + 1 persist.
        #expect(calls.count >= 2)
        #expect(calls.contains(where: { $0.contains("persist") }))
        #expect(calls[0].contains("resolve"))
        // The technique should be the one from the resolution.
        #expect(provider.lastTechnique == "youtube-captions")
        store.close()
    }

    // MARK: - Fetch throws → item .failed

    @Test func testTranscriptionFetchThrowMarksFailed() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        struct TestError: Error {}
        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: { throw TestError() }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(transcriptionLimit: 2),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        let result = await engine.waitForCompletion(of: id)

        switch result {
        case .success: Issue.record("Expected failure, got success")
        case .failure: break // Expected.
        }

        let item = try store.getItem(id)
        #expect(item?.state == .failed)
        store.close()
    }

    // MARK: - waitForCompletion success

    @Test func testWaitForCompletionReturnsSuccess() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: { }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(transcriptionLimit: 2),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        let result = await engine.waitForCompletion(of: id)

        if case .success = result { /* expected */ } else {
            Issue.record("Expected .success")
        }

        let item = try store.getItem(id)
        #expect(item?.state == .completed)
        store.close()
    }

    // MARK: - Capacity: two concurrent, a third waits

    @Test func testTwoConcurrentTranscriptionThirdWaits() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate1 = CountDownLatch(count: 1)
        let gate2 = CountDownLatch(count: 1)
        let counter = AsyncCounter()
        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: {
                let n = await counter.increment()
                if n == 1 { await gate1.wait() }
                if n == 2 { await gate2.wait() }
            }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(transcriptionLimit: 2),
                                 workerFactory: factory)
        await engine.start()

        let id1 = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1",
                             payload: makePayload(sourceID: "SRC1")))
        let id2 = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1",
                             payload: makePayload(sourceID: "SRC2")))
        let id3 = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1",
                             payload: makePayload(sourceID: "SRC3")))

        // Give the engine time to dispatch.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Item 1 and 2 should be running; item 3 should be queued.
        let item1 = try store.getItem(id1)
        let item2 = try store.getItem(id2)
        let item3 = try store.getItem(id3)
        #expect(item1?.state == .running)
        #expect(item2?.state == .running)
        #expect(item3?.state == .queued) // Third waits — capacity is 2.

        // Release the gates so the engine cleans up.
        gate1.release()
        gate2.release()
        try await Task.sleep(nanoseconds: 500_000_000)
        store.close()
    }

    // MARK: - Factory providerID

    @Test func testFactoryProviderIDReturnsTranscriptionWhenResolvable() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let provider = FakeTranscriptionProvider(resolveResult: .resolved)
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(id)
        // When dispatched, the providerID should be "transcription".
        #expect(item?.providerID == "transcription")
        store.close()
    }

    @Test func testFactoryProviderIDReturnsNilWhenNotResolvable() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let provider = FakeTranscriptionProvider(resolveResult: .nilResolution)
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(id)
        // Never dispatched — no provider ID assigned.
        #expect(item?.providerID == nil)
        #expect(item?.state == .queued)
        store.close()
    }

    // MARK: - Progress event emitted

    @Test func testProgressEventEmitted() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let progressHolder = ProgressCollector()
        let provider = FakeTranscriptionProvider(
            resolveResult: .resolved,
            fetchBehavior: { }
        )
        let factory = QueueTranscriptionWorkerFactory(
            provider: provider,
            emitProgress: { id, line in progressHolder.record(id: id, line: line) })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(transcriptionLimit: 2),
                                 workerFactory: factory)
        await engine.start()

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .transcription, wikiID: "wiki1", payload: makePayload()))

        try await progressHolder.waitForCount(1, timeoutSeconds: 5)

        #expect(progressHolder.lines.count >= 1)
        #expect(progressHolder.lines[0].line == "Fetching transcript…")
        store.close()
    }

    // MARK: - Headless isolation

    @Test func testHeadlessIsolation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let files = [
            root.appendingPathComponent("Sources/WikiFSEngine/QueueTranscriptionProvider.swift"),
            root.appendingPathComponent("Sources/WikiFSEngine/QueueTranscriptionWorker.swift"),
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!source.contains("import AppKit"),
                   "\(fileURL.lastPathComponent) must not import AppKit")
            #expect(!source.contains("import SwiftUI"),
                   "\(fileURL.lastPathComponent) must not import SwiftUI")
        }
    }
}

// MARK: - Fake transcription provider

private final class FakeTranscriptionProvider: QueueTranscriptionProvider, @unchecked Sendable {
    enum ResolveResult {
        case resolved
        case nilResolution
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let resolveResult: ResolveResult
    private let fetchBehavior: @Sendable () async throws -> Void

    private struct State {
        var callLog: [String] = []
        var lastTechnique: String? = nil
    }

    var callLog: [String] { lock.withLock { $0.callLog } }
    var lastTechnique: String? { lock.withLock { $0.lastTechnique } }

    init(
        resolveResult: ResolveResult,
        fetchBehavior: @escaping @Sendable () async throws -> Void = { }
    ) {
        self.resolveResult = resolveResult
        self.fetchBehavior = fetchBehavior
    }

    func resolveTranscription(
        wikiID: String, sourceID: PageID
    ) async throws -> TranscriptionResolution? {
        lock.withLock { state in
            state.callLog.append("resolve(wikiID:\(wikiID), sourceID:\(sourceID.rawValue))")
            state.lastTechnique = "youtube-captions"
        }

        switch resolveResult {
        case .resolved:
            return TranscriptionResolution(
                fetch: { @Sendable in
                    try await self.fetchBehavior()
                    return "# Transcript markdown"
                },
                technique: "youtube-captions")
        case .nilResolution:
            return nil
        }
    }

    func persistTranscription(
        wikiID: String, sourceID: PageID,
        markdown: String, technique: String
    ) async throws {
        lock.withLock { state in
            state.callLog.append("persist(wikiID:\(wikiID), sourceID:\(sourceID.rawValue), technique:\(technique))")
        }
    }
}

// MARK: - Progress collector + CountDownLatch (same as QueueExtractionTests)

private final class ProgressCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(id: QueueItem.ID, line: String)]())

    var lines: [(id: QueueItem.ID, line: String)] {
        lock.withLock { $0 }
    }

    func record(id: QueueItem.ID, line: String) {
        lock.withLock { $0.append((id, line)) }
    }

    func waitForCount(_ count: Int, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let current = lines.count
            if current >= count { return }
            if Date() > deadline {
                Issue.record("Timed out waiting for \(count) progress lines, got \(current)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private final class CountDownLatch: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (count: 0, waiters: [CheckedContinuation<Void, Never>]()))

    init(count: Int) {
        lock.withLock { state in state.count = count }
    }

    func wait() async {
        let needsWait: Bool = lock.withLock { state in
            state.count > 0
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

private actor AsyncCounter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
#endif // os(macOS)
