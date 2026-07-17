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

// A fake ingestion provider that records what it was called with.
actor FakeIngestionProvider: QueueIngestionProvider {
    var calledWikiID: String?
    var calledSourceIDs: [PageID] = []
    var progressLines: [String] = []
    var shouldThrow = false
    var calledLintWikiID: String?
    var calledLintPageIDs: [PageID] = []
    var transcriptEvents: [AgentEvent] = []

    func setShouldThrow(_ val: Bool) { shouldThrow = val }

    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?
    ) async throws {
        calledWikiID = wikiID
        calledSourceIDs = sourceIDs
        if shouldThrow { throw QueueIngestionError.spawnFailed("test error") }
        onProgress("starting ingest")
        onProgress("ingest done")
    }

    func runLint(
        wikiID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?
    ) async throws {
        calledLintWikiID = wikiID
        calledLintPageIDs = []
        if shouldThrow { throw QueueIngestionError.spawnFailed("test lint error") }
        onProgress("starting whole-wiki lint")
        onProgress("lint done")
    }

    func runLintPages(
        wikiID: String,
        pageIDs: [PageID],
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?
    ) async throws {
        calledLintWikiID = wikiID
        calledLintPageIDs = pageIDs
        if shouldThrow { throw QueueIngestionError.spawnFailed("test lint error") }
        onProgress("starting page lint")
        onProgress("lint done")
    }

    func getCalledWikiID() -> String? { calledWikiID }
    func getCalledSourceIDs() -> [PageID] { calledSourceIDs }
    func getCalledLintWikiID() -> String? { calledLintWikiID }
    func getCalledLintPageIDs() -> [PageID] { calledLintPageIDs }
}

@Suite("QueueIngestionWorker")
struct QueueIngestionWorkerTests {

    @Test("Worker calls provider with correct parameters")
    func workerCallsProvider() async throws {
        let provider = FakeIngestionProvider()
        let factory = QueueIngestionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })
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
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })

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
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })

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
        tracker.start(events: AsyncStream { _ in })

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

// MARK: - Lint-as-ingestion dispatch tests

@Suite("Lint dispatch via .ingestion queue")
struct LintIngestionDispatchTests {

    // AC.1: lintPageIDs in payload → runLintPages called (not runIngestion)
    @MainActor
    @Test("Page-level lint dispatches runLintPages")
    func pageLintDispatchesRunLintPages() async throws {
        let provider = FakeIngestionProvider()
        let factory = QueueIngestionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })
        let worker = try await factory.worker(for: QueueItem(
            id: "lint1", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [PageID(rawValue: "p1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        try await worker.execute(QueueItem(
            id: "lint1", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [PageID(rawValue: "p1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        let lintWikiID = await provider.getCalledLintWikiID()
        let lintPageIDs = await provider.getCalledLintPageIDs()
        #expect(lintWikiID == "w1")
        #expect(lintPageIDs == [PageID(rawValue: "p1")])
    }

    // AC.1: lintPageIDs empty → runLint called (whole-wiki)
    @MainActor
    @Test("Whole-wiki lint dispatches runLint")
    func wholeWikiLintDispatchesRunLint() async throws {
        let provider = FakeIngestionProvider()
        let factory = QueueIngestionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })
        let worker = try await factory.worker(for: QueueItem(
            id: "lint2", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: []),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        try await worker.execute(QueueItem(
            id: "lint2", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: []),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        let lintWikiID = await provider.getCalledLintWikiID()
        #expect(lintWikiID == "w1")
    }

    // AC.1: nil lintPageIDs → runIngestion called (not lint)
    @MainActor
    @Test("Nil lintPageIDs dispatches runIngestion")
    func nilLintPageIDsDispatchesIngestion() async throws {
        let provider = FakeIngestionProvider()
        let factory = QueueIngestionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in })
        let worker = try await factory.worker(for: QueueItem(
            id: "ing1", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "s1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        try await worker.execute(QueueItem(
            id: "ing1", queue: .ingestion, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "s1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0))

        let wikiID = await provider.getCalledWikiID()
        #expect(wikiID == "w1")
    }
}

// MARK: - Transcript forwarding tests

@Suite("QueueActivityTracker transcript forwarding")
struct QueueActivityTrackerTranscriptTests {

    private func makeItem(
        id: String = "test-item-id",
        queue: QueueKind,
        sourceIDs: [PageID],
        lintPageIDs: [PageID]? = nil,
        state: QueueItemState = .running
    ) -> QueueItem {
        QueueItem(
            id: id, queue: queue, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: sourceIDs, lintPageIDs: lintPageIDs),
            state: state, orderingKey: 1000, attempt: 0,
            createdAt: 0)
    }

    // AC.9: transcript events forwarded to tracker
    @MainActor
    @Test("Transcript events are forwarded to tracker")
    func transcriptEventsForwarded() async {
        let tracker = QueueActivityTracker()
        let itemID = "lint-transcript-1"
        let item = makeItem(id: itemID, queue: .ingestion, sourceIDs: [], lintPageIDs: [])

        tracker.handleForTesting(.started(item))
        #expect(tracker.lintingItemIDs.contains(itemID))
        #expect(tracker.isIngesting == true)

        // Simulate transcript events.
        let event1 = AgentEvent.assistantText("Linting page 1…")
        let event2 = AgentEvent.assistantText("Found 3 issues.")
        tracker.handleForTesting(.transcript(itemID, event1))
        tracker.handleForTesting(.transcript(itemID, event2))

        let transcript = tracker.transcript(for: itemID)
        #expect(transcript.count == 2)
        #expect(transcript[0] == event1)
        #expect(transcript[1] == event2)

        // Terminal state should NOT clear the transcript.
        let completed = makeItem(id: itemID, queue: .ingestion, sourceIDs: [], lintPageIDs: [], state: .completed)
        tracker.handleForTesting(.completed(completed))

        #expect(!tracker.lintingItemIDs.contains(itemID))
        #expect(tracker.isIngesting == false)
        // Transcript still available after completion.
        #expect(tracker.transcript(for: itemID).count == 2)
    }

    // AC.10: lint-only runs show isIngesting = true
    @MainActor
    @Test("Lint-only run triggers isIngesting")
    func lintOnlyRunTriggersIsIngesting() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "lint-only", queue: .ingestion, sourceIDs: [], lintPageIDs: [])

        tracker.handleForTesting(.started(item))
        #expect(tracker.isIngesting == true)
        #expect(tracker.lintingItemIDs.contains("lint-only"))
        #expect(tracker.ingestingSourceIDs.isEmpty)  // no sources for lint
    }

    // Per-item progress accumulation
    @MainActor
    @Test("Progress accumulated per-item")
    func progressAccumulatedPerItem() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "prog-1", queue: .extraction, sourceIDs: [PageID(rawValue: "src1")])

        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.progress("prog-1", line: "line 1"))
        tracker.handleForTesting(.progress("prog-1", line: "line 2"))

        let log = tracker.progressLog(for: "prog-1")
        #expect(log.contains("line 1"))
        #expect(log.contains("line 2"))
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
