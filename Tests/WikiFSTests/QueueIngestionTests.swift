import Testing
import Foundation
@testable import WikiFSEngine
@testable import WikiFS
import WikiFSCore

// MARK: - CompositeWorkerFactoryTests

@Suite("CompositeWorkerFactory")
struct CompositeWorkerFactoryTests {

    // A fake factory that always returns the same provider ID + a no-op worker.
    private struct FakeFactory: QueueWorkerFactory {
        let providerIDValue: String?
        func providerID(for item: QueueItem) async -> String? { providerIDValue }
        func worker(for item: QueueItem) async throws -> any QueueWorker {
            NoopWorker()
        }
    }

    private struct NoopWorker: QueueWorker {
        func execute(_ item: QueueItem) async throws {}
    }

    @Test("Routes extraction items to extraction factory")
    func routesExtractionItems() async throws {
        let extractionFactory = FakeFactory(providerIDValue: "local-pdf2md")
        let ingestionFactory = FakeFactory(providerIDValue: "default-ingest")
        let composite = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory,
            .ingestion: ingestionFactory
        ])

        let item = QueueItem(
            id: "123", queue: .extraction, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0)

        let providerID = await composite.providerID(for: item)
        #expect(providerID == "local-pdf2md")
    }

    @Test("Routes ingestion items to ingestion factory")
    func routesIngestionItems() async throws {
        let extractionFactory = FakeFactory(providerIDValue: "local-pdf2md")
        let ingestionFactory = FakeFactory(providerIDValue: "default-ingest")
        let composite = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory,
            .ingestion: ingestionFactory
        ])

        let item = QueueItem(
            id: "456", queue: .ingestion, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src2")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0)

        let providerID = await composite.providerID(for: item)
        #expect(providerID == "default-ingest")
    }

    @Test("Missing factory returns nil provider ID")
    func missingFactoryReturnsNil() async throws {
        let extractionFactory = FakeFactory(providerIDValue: "local-pdf2md")
        let composite = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory
        ])

        let item = QueueItem(
            id: "789", queue: .ingestion, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src3")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0)

        let providerID = await composite.providerID(for: item)
        #expect(providerID == nil)
    }
}

// MARK: - QueueIngestionWorkerTests

@Suite("QueueIngestionWorker")
struct QueueIngestionWorkerTests {

    // A fake ingestion provider that records what it was called with.
    actor FakeIngestionProvider: QueueIngestionProvider {
        var calledWikiID: String?
        var calledSourceIDs: [PageID] = []
        var progressLines: [String] = []
        var shouldThrow = false

        func setShouldThrow(_ val: Bool) { shouldThrow = val }

        func runIngestion(
            wikiID: String,
            sourceIDs: [PageID],
            onProgress: @escaping @Sendable (String) -> Void
        ) async throws {
            calledWikiID = wikiID
            calledSourceIDs = sourceIDs
            if shouldThrow { throw QueueIngestionError.spawnFailed("test error") }
            onProgress("starting ingest")
            onProgress("ingest done")
        }

        func getCalledWikiID() -> String? { calledWikiID }
        func getCalledSourceIDs() -> [PageID] { calledSourceIDs }
    }

    @Test("Worker calls provider with correct parameters")
    func workerCallsProvider() async throws {
        let provider = FakeIngestionProvider()
        let factory = QueueIngestionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in })
        let worker = try await factory.worker(for: QueueItem(
            id: "test1", queue: .ingestion, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0))

        try await worker.execute(QueueItem(
            id: "test1", queue: .ingestion, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0))

        let wikiID = await provider.getCalledWikiID()
        let sourceIDs = await provider.getCalledSourceIDs()
        #expect(wikiID == "wiki1")
        #expect(sourceIDs == [PageID(rawValue: "src1")])
    }

    @Test("Worker with empty source IDs throws")
    func workerThrowsOnEmpty() async throws {
        let provider = FakeIngestionProvider()
        let worker = QueueIngestionWorker(
            provider: provider,
            emitProgress: { _, _ in })

        await #expect(throws: QueueIngestionError.self) {
            try await worker.execute(QueueItem(
                id: "test2", queue: .ingestion, wikiID: "wiki1",
                payload: QueueItemPayload(sourceIDs: []),
                state: .queued, orderingKey: 1000, attempt: 0,
                createdAt: 0))
        }
    }

    @Test("Worker propagates provider errors")
    func workerPropagatesErrors() async throws {
        let provider = FakeIngestionProvider()
        await provider.setShouldThrow(true)
        let worker = QueueIngestionWorker(
            provider: provider,
            emitProgress: { _, _ in })

        await #expect(throws: QueueIngestionError.self) {
            try await worker.execute(QueueItem(
                id: "test3", queue: .ingestion, wikiID: "wiki1",
                payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
                state: .queued, orderingKey: 1000, attempt: 0,
                createdAt: 0))
        }
    }
}

// MARK: - QueueActivityTracker Ingestion Tests

@Suite("QueueActivityTracker ingestion tracking")
struct QueueActivityTrackerIngestionTests {

    private func makeItem(
        id: String = "test-item-id",
        queue: QueueKind,
        sourceIDs: [PageID],
        state: QueueItemState = .running
    ) -> QueueItem {
        QueueItem(
            id: id, queue: queue, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: sourceIDs),
            state: state, orderingKey: 1000, attempt: 0,
            createdAt: 0)
    }

    @MainActor
    @Test("Tracker tracks ingestion source IDs on started")
    func ingestionStartedAddsSourceIDs() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        await tracker.start(events: AsyncStream { _ in })

        // Simulate the events the engine would emit.
        tracker.attachForTesting(events: AsyncStream { _ in })
        tracker.handleForTesting(.started(item))

        #expect(tracker.ingestingSourceIDs == Set([PageID(rawValue: "src1")]))
        #expect(tracker.isIngesting == true)
    }

    @MainActor
    @Test("Tracker clears ingestion source IDs on completed")
    func ingestionCompletedClearsSourceIDs() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(queue: .ingestion, sourceIDs: [PageID(rawValue: "src1"), PageID(rawValue: "src2")])
        tracker.handleForTesting(.started(item))
        #expect(tracker.ingestingSourceIDs == Set([PageID(rawValue: "src1"), PageID(rawValue: "src2")]))

        let completed = makeItem(id: item.id, queue: .ingestion, sourceIDs: [PageID(rawValue: "src1"), PageID(rawValue: "src2")])
        tracker.handleForTesting(.completed(completed))
        #expect(tracker.ingestingSourceIDs.isEmpty)
        #expect(tracker.isIngesting == false)
    }

    @MainActor
    @Test("Tracker does not conflate extraction and ingestion")
    func noConflation() async {
        let tracker = QueueActivityTracker()
        let extractionItem = makeItem(id: "ext1", queue: .extraction, sourceIDs: [PageID(rawValue: "src1")])
        let ingestionItem = makeItem(id: "ing1", queue: .ingestion, sourceIDs: [PageID(rawValue: "src2")])

        tracker.handleForTesting(.started(extractionItem))
        tracker.handleForTesting(.started(ingestionItem))

        #expect(tracker.extractingSourceIDs == Set([PageID(rawValue: "src1")]))
        #expect(tracker.ingestingSourceIDs == Set([PageID(rawValue: "src2")]))

        // Complete extraction → only extraction clears
        tracker.handleForTesting(.completed(extractionItem))
        #expect(tracker.extractingSourceIDs.isEmpty)
        #expect(tracker.ingestingSourceIDs == Set([PageID(rawValue: "src2")]))

        // Complete ingestion → both clear
        tracker.handleForTesting(.completed(ingestionItem))
        #expect(tracker.ingestingSourceIDs.isEmpty)
    }
}

// MARK: - QueueEngine hasActiveWork Tests

@Suite("QueueEngine hasActiveWork")
struct QueueEngineHasActiveWorkTests {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-ingest-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    @Test("No active work returns false")
    func noActiveWork() async throws {
        let store = try QueueStore(databaseURL: tempDB())
        let factory = StubWorkerFactory()
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        let hasWork = await engine.hasActiveWork(for: "wiki1")
        #expect(hasWork == false)
    }

    @Test("Active work for wiki returns true")
    func activeWorkReturnsTrue() async throws {
        let store = try QueueStore(databaseURL: tempDB())
        let factory = StubWorkerFactory()
        let engine = QueueEngine(store: store, workerFactory: factory)

        // Enqueue an item
        _ = try store.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")])))

        let hasWork = await engine.hasActiveWork(for: "wiki1")
        #expect(hasWork == true)
    }

    @Test("Active work for different wiki returns false")
    func activeWorkDifferentWiki() async throws {
        let store = try QueueStore(databaseURL: tempDB())
        _ = try store.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")])))

        let factory = StubWorkerFactory()
        let engine = QueueEngine(store: store, workerFactory: factory)

        let hasWork = await engine.hasActiveWork(for: "wiki2")
        #expect(hasWork == false)
    }
}

// MARK: - Helpers

/// Test-only access to QueueActivityTracker's event handler.
extension QueueActivityTracker {
    @MainActor
    func handleForTesting(_ event: QueueEvent) {
        handle(event)
    }
    func attachForTesting(events: AsyncStream<QueueEvent>) {
        start(events: events)
    }
}

/// A stub factory that never dispatches (providerID returns nil).
struct StubWorkerFactory: QueueWorkerFactory {
    func providerID(for item: QueueItem) async -> String? { nil }
    func worker(for item: QueueItem) async throws -> any QueueWorker {
        struct W: QueueWorker { func execute(_ item: QueueItem) async throws {} }
        return W()
    }
}
