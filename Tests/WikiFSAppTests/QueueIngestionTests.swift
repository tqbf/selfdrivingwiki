#if os(macOS)
import Testing
import Foundation
import ACPModel
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

    @Test("Routes transcription items to transcription factory")
    func routesTranscriptionItems() async throws {
        let extractionFactory = FakeFactory(providerIDValue: "local-pdf2md")
        let ingestionFactory = FakeFactory(providerIDValue: "default-ingest")
        let transcriptionFactory = FakeFactory(providerIDValue: "transcription")
        let composite = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory,
            .ingestion: ingestionFactory,
            .transcription: transcriptionFactory
        ])

        let item = QueueItem(
            id: "tr1", queue: .transcription, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src2")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0)

        let providerID = await composite.providerID(for: item)
        #expect(providerID == "transcription")
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
    /// When non-nil, `readiness()` returns this message (simulating a
    /// not-ready provider). When nil, `readiness()` returns nil (ready).
    var readinessMessage: String?

    func setShouldThrow(_ val: Bool) { shouldThrow = val }

    func readiness() async -> String? { readinessMessage }

    func setReadinessMessage(_ val: String?) { readinessMessage = val }

    func runIngestion(
        wikiID: String,
        sourceIDs: [PageID],
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {
        calledWikiID = wikiID
        calledSourceIDs = sourceIDs
        if shouldThrow { throw QueueIngestionError.spawnFailed("test error") }
        onProgress("starting ingest")
        onProgress("ingest done")
    }

    func runLint(
        wikiID: String,
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
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
        queueItemID: String,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in },
            emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })
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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in }, emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })

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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in }, emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })

        await #expect(throws: QueueIngestionError.self) {
            try await worker.execute(QueueItem(
                id: "test3", queue: .ingestion, wikiID: "wiki1",
                payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
                state: .queued, orderingKey: 1000, attempt: 0,
                createdAt: 0))
        }
    }

    @Test("Worker fails with notReady when provider is not ready (#440)")
    func workerFailsWhenNotReady() async throws {
        let provider = FakeIngestionProvider()
        let notReadyMsg = "‘bun’ was not found on your PATH. Install bun (bun.sh) or configure a different agent provider. Open Settings → Providers to configure one."
        await provider.setReadinessMessage(notReadyMsg)
        let worker = QueueIngestionWorker(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in }, emitUsage: { _, _ in }, emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })

        do {
            try await worker.execute(QueueItem(
                id: "test-ready", queue: .ingestion, wikiID: "wiki1",
                payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
                state: .queued, orderingKey: 1000, attempt: 0,
                createdAt: 0))
            Issue.record("Expected notReady error was not thrown")
        } catch let err as QueueIngestionError {
            // The readiness gate should throw .notReady (not .spawnFailed),
            // carrying the readiness message verbatim.
            guard case .notReady(let msg) = err else {
                Issue.record("Expected .notReady, got \(err)")
                return
            }
            #expect(msg == notReadyMsg)
            // The provider should NOT have been called (fast-fail).
            let wikiID = await provider.getCalledWikiID()
            #expect(wikiID == nil)
        } catch {
            Issue.record("Expected QueueIngestionError.notReady, got \(error)")
        }
    }

    @Test("Worker proceeds when provider is ready (#440)")
    func workerProceedsWhenReady() async throws {
        let provider = FakeIngestionProvider()
        // readinessMessage is nil by default → ready.
        let worker = QueueIngestionWorker(
            provider: provider,
            emitProgress: { _, _ in },
            emitTranscript: { _, _ in }, emitUsage: { _, _ in }, emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })

        try await worker.execute(QueueItem(
            id: "test-ready-ok", queue: .ingestion, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0,
            createdAt: 0))

        let wikiID = await provider.getCalledWikiID()
        #expect(wikiID == "wiki1")
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

    // MARK: - Transcription source-ID tracking (#842)

    @MainActor
    @Test("Tracker tracks transcription source IDs on started")
    func transcriptionStartedAddsSourceIDs() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "tr1", queue: .transcription, sourceIDs: [PageID(rawValue: "src1"), PageID(rawValue: "src2")])
        tracker.start(events: AsyncStream { _ in })
        tracker.attachForTesting(events: AsyncStream { _ in })
        tracker.handleForTesting(.started(item))

        #expect(tracker.transcribingSourceIDs == Set([PageID(rawValue: "src1"), PageID(rawValue: "src2")]))
        #expect(tracker.isTranscribing(sourceID: PageID(rawValue: "src1")) == true)
        #expect(tracker.isTranscribing(sourceID: PageID(rawValue: "src2")) == true)
        #expect(tracker.isTranscribing(sourceID: PageID(rawValue: "other")) == false)
        #expect(tracker.isTranscribingAny == true)
    }

    @MainActor
    @Test("Tracker clears transcription source IDs on completed")
    func transcriptionCompletedClearsSourceIDs() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "tr1", queue: .transcription, sourceIDs: [PageID(rawValue: "src1")])
        tracker.start(events: AsyncStream { _ in })
        tracker.attachForTesting(events: AsyncStream { _ in })
        tracker.handleForTesting(.started(item))
        #expect(tracker.isTranscribing(sourceID: PageID(rawValue: "src1")))

        let completed = makeItem(id: item.id, queue: .transcription, sourceIDs: [PageID(rawValue: "src1")], state: .completed)
        tracker.handleForTesting(.completed(completed))
        #expect(tracker.transcribingSourceIDs.isEmpty)
        #expect(tracker.isTranscribing(sourceID: PageID(rawValue: "src1")) == false)
        #expect(tracker.isTranscribingAny == false)
    }

    @MainActor
    @Test("Tracker does not conflate transcription with extraction")
    func noTranscriptionConflation() async {
        let tracker = QueueActivityTracker()
        let extractionItem = makeItem(id: "ext1", queue: .extraction, sourceIDs: [PageID(rawValue: "src1")])
        let transcriptionItem = makeItem(id: "tr1", queue: .transcription, sourceIDs: [PageID(rawValue: "src2")])
        tracker.start(events: AsyncStream { _ in })
        tracker.attachForTesting(events: AsyncStream { _ in })

        tracker.handleForTesting(.started(extractionItem))
        tracker.handleForTesting(.started(transcriptionItem))

        #expect(tracker.extractingSourceIDs == Set([PageID(rawValue: "src1")]))
        #expect(tracker.transcribingSourceIDs == Set([PageID(rawValue: "src2")]))

        // Complete transcription → only transcription clears
        tracker.handleForTesting(.completed(transcriptionItem))
        #expect(tracker.transcribingSourceIDs.isEmpty)
        #expect(tracker.extractingSourceIDs == Set([PageID(rawValue: "src1")]))

        // Complete extraction → both clear
        tracker.handleForTesting(.completed(extractionItem))
        #expect(tracker.extractingSourceIDs.isEmpty)
    }

    // MARK: - #608: pending-permission surfacing

    /// Builds a `PendingPermission` for tests with the same shape `ACPBackend`
    /// hands the launcher: tool name + input summary + a single allow/reject
    /// option pair. ACP agents gate one write at a time, so a single entry is
    /// the realistic shape.
    private func makePermission(
        toolCallId: String = "tc-1",
        toolName: String? = "Edit file",
        inputSummary: String? = "/wiki/page.md"
    ) -> PendingPermission {
        PendingPermission(
            toolCallId: toolCallId,
            title: "Edit file /wiki/page.md",
            toolName: toolName,
            inputSummary: inputSummary,
            options: [
                PermissionOption(kind: "allow_always", name: "Allow", optionId: "opt-allow"),
                PermissionOption(kind: "reject_once", name: "Reject", optionId: "opt-reject")
            ])
    }

    @MainActor
    @Test("Tracker surfaces pending permission via pendingPermission(for:) (#608)")
    func pendingPermissionSurfaced() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        tracker.handleForTesting(.started(item))

        // Before any pending permission event: nil — the row should not render.
        #expect(tracker.pendingPermission(for: item.id) == nil)

        // Surface a pending permission — the launcher's poller does this via
        // the emit closure when `pendingPermissions` goes from [] to [perm].
        let perm = makePermission()
        tracker.handleForTesting(.pendingPermission(item.id, perm))
        #expect(tracker.pendingPermission(for: item.id) == perm)

        // Clear the pending permission — the continuation resolved (approve,
        // reject) or the S1 auto-reject timer fired.
        tracker.handleForTesting(.pendingPermission(item.id, nil))
        #expect(tracker.pendingPermission(for: item.id) == nil)
    }

    @MainActor
    @Test("Tracker replaces prior pending permission when a new one arrives (#608)")
    func pendingPermissionReplaces() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        tracker.handleForTesting(.started(item))

        let firstPerm = makePermission(toolCallId: "tc-1", toolName: "Edit file")
        tracker.handleForTesting(.pendingPermission(item.id, firstPerm))
        #expect(tracker.pendingPermission(for: item.id) == firstPerm)

        // A second pending permission replaces the first — ACP agents gate one
        // write at a time, but successive prompts within a single run are
        // plausible (the agent asks, user approves, agent asks again). The
        // snapshot diff in `refreshPendingPermissions` would clear → set in
        // two events, but a single replace event covers the in-place update
        // path too.
        let secondPerm = makePermission(toolCallId: "tc-2", toolName: "Create directory")
        tracker.handleForTesting(.pendingPermission(item.id, secondPerm))
        #expect(tracker.pendingPermission(for: item.id) == secondPerm)
        #expect(tracker.pendingPermission(for: item.id) != firstPerm)
    }

    @MainActor
    @Test("Tracker clears pending permission on terminal state (#608)")
    func pendingPermissionClearedOnTerminal() async {
        let tracker = QueueActivityTracker()
        let item = makeItem(queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.pendingPermission(item.id, makePermission()))
        #expect(tracker.pendingPermission(for: item.id) != nil)

        // Completed → the yellow row must clear so it doesn't linger on a
        // completed row. The launcher's `finish()` emits `nil` first, but a
        // terminal state arriving first (cancelled mid-prompt, hard process
        // death) needs this safety net too.
        let completed = makeItem(id: item.id, queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        tracker.handleForTesting(.completed(completed))
        #expect(tracker.pendingPermission(for: item.id) == nil)

        // Same for failed.
        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.pendingPermission(item.id, makePermission()))
        #expect(tracker.pendingPermission(for: item.id) != nil)
        let failed = makeItem(id: item.id, queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")], state: .failed)
        tracker.handleForTesting(.failed(failed, error: "boom"))
        #expect(tracker.pendingPermission(for: item.id) == nil)

        // Same for cancelled.
        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.pendingPermission(item.id, makePermission()))
        #expect(tracker.pendingPermission(for: item.id) != nil)
        let cancelled = makeItem(id: item.id, queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")], state: .cancelled)
        tracker.handleForTesting(.cancelled(cancelled))
        #expect(tracker.pendingPermission(for: item.id) == nil)
    }

    @MainActor
    @Test("Tracker isolates pending permissions per item (#608)")
    func pendingPermissionPerItemIsolation() async {
        let tracker = QueueActivityTracker()
        let itemA = makeItem(id: "ing-a", queue: .ingestion, sourceIDs: [PageID(rawValue: "src1")])
        let itemB = makeItem(id: "ing-b", queue: .ingestion, sourceIDs: [PageID(rawValue: "src2")])
        tracker.handleForTesting(.started(itemA))
        tracker.handleForTesting(.started(itemB))

        let permA = makePermission(toolCallId: "tc-a", toolName: "Edit file")
        tracker.handleForTesting(.pendingPermission(itemA.id, permA))

        // Item A is parked on a permission; item B is not.
        #expect(tracker.pendingPermission(for: itemA.id) == permA)
        #expect(tracker.pendingPermission(for: itemB.id) == nil)

        // Completing item A should NOT clear item B's state — but more
        // importantly, completing item B (without ever surfacing a permission
        // for it) should leave item A's pending permission intact.
        let completedB = makeItem(id: itemB.id, queue: .ingestion, sourceIDs: [PageID(rawValue: "src2")])
        tracker.handleForTesting(.completed(completedB))
        #expect(tracker.pendingPermission(for: itemA.id) == permA)
        #expect(tracker.pendingPermission(for: itemB.id) == nil)
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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in },
            emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })
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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in },
            emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })
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
            emitTranscript: { _, _ in }, emitUsage: { _, _ in },
            emitLiveUsage: { _, _ in }, emitLogPaths: { _, _, _ in }, emitPendingPermission: { _, _ in })
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

// MARK: - Run paths (log/debug folder URL) forwarding tests

@Suite("QueueActivityTracker run paths")
struct QueueActivityTrackerRunPathsTests {

    private func makeItem(
        id: String = "paths-item",
        queue: QueueKind = .ingestion,
        sourceIDs: [PageID] = [PageID(rawValue: "src1")],
        state: QueueItemState = .running
    ) -> QueueItem {
        QueueItem(
            id: id, queue: queue, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: sourceIDs),
            state: state, orderingKey: 1000, attempt: 0,
            createdAt: 0)
    }

    @MainActor
    @Test("Run paths stored per-item")
    func runPathsStoredPerItem() {
        let tracker = QueueActivityTracker()
        let itemID = "paths-item"
        let item = makeItem(id: itemID)
        let logURL = URL(fileURLWithPath: "/tmp/scratch/run.jsonl")
        let debugURL = URL(fileURLWithPath: "/tmp/scratch/debug", isDirectory: true)

        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.runPaths(itemID, logURL: logURL, debugURL: debugURL))

        #expect(tracker.logURL(for: itemID) == logURL)
        #expect(tracker.debugURL(for: itemID) == debugURL)
    }

    @MainActor
    @Test("Run paths survive terminal state")
    func runPathsSurviveCompletion() {
        let tracker = QueueActivityTracker()
        let itemID = "paths-item"
        let item = makeItem(id: itemID)
        let logURL = URL(fileURLWithPath: "/tmp/scratch/run.jsonl")

        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.runPaths(itemID, logURL: logURL, debugURL: nil))

        let completed = makeItem(id: itemID, state: .completed)
        tracker.handleForTesting(.completed(completed))

        // Paths persist after completion (same as transcripts) so the user can
        // reveal them for recently-completed items.
        #expect(tracker.logURL(for: itemID) == logURL)
        #expect(tracker.debugURL(for: itemID) == nil)
    }

    @MainActor
    @Test("Run paths cleared on prune")
    func runPathsClearedOnPrune() {
        let tracker = QueueActivityTracker()
        let itemID = "paths-item"
        let item = makeItem(id: itemID)
        let logURL = URL(fileURLWithPath: "/tmp/scratch/run.jsonl")
        let debugURL = URL(fileURLWithPath: "/tmp/scratch/debug", isDirectory: true)

        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.runPaths(itemID, logURL: logURL, debugURL: debugURL))
        tracker.pruneTranscripts(for: itemID)

        #expect(tracker.logURL(for: itemID) == nil)
        #expect(tracker.debugURL(for: itemID) == nil)
    }

    @MainActor
    @Test("Nil paths produce nil accessors")
    func nilPathsProduceNil() {
        let tracker = QueueActivityTracker()
        let itemID = "never-ran"

        tracker.handleForTesting(.runPaths(itemID, logURL: nil, debugURL: nil))

        #expect(tracker.logURL(for: itemID) == nil)
        #expect(tracker.debugURL(for: itemID) == nil)
    }
}

// MARK: - Interactive usage tracking

@Suite("QueueActivityTracker interactive usage")
struct QueueActivityTrackerInteractiveUsageTests {

    /// `recordInteractiveUsage` accumulates the per-turn delta into `todayUsage`
    /// (the menu bar daily total), without creating an `itemUsage` entry —
    /// interactive chat has no queue item. This is the receiving end of the
    /// `AgentLauncher.onInteractiveUsage` → `recordInteractiveUsage` wiring.
    @MainActor
    @Test("Interactive usage accumulates into todayUsage without an itemUsage entry")
    func interactiveUsageAccumulates() async {
        let tracker = QueueActivityTracker()
        // Capture + restore the persisted daily total so this test doesn't
        // pollute the real menu bar count (DailyUsage persists to
        // UserDefaults.standard with a fixed key).
        let savedDaily = tracker.todayUsage
        let baseline = savedDaily.inputTokens

        let firstTurn = SessionUsage(
            inputTokens: 1000, outputTokens: 300, totalTokens: 1300,
            cachedReadTokens: 100, thoughtTokens: 50,
            cost: 0.05, currency: "USD", contextUsed: 4000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4")
        tracker.recordInteractiveUsage(firstTurn)

        let secondTurn = SessionUsage(
            inputTokens: 800, outputTokens: 200, totalTokens: 1000,
            cachedReadTokens: 60, thoughtTokens: 30,
            cost: 0.03, currency: "USD", contextUsed: 5000, contextSize: 10000,
            providerLabel: "Claude", modelId: "sonnet-4")
        tracker.recordInteractiveUsage(secondTurn)

        #expect(tracker.todayUsage.inputTokens == baseline + 1800)
        #expect(tracker.todayUsage.outputTokens == savedDaily.outputTokens + 500)
        #expect(tracker.todayUsage.totalTokens == savedDaily.totalTokens + 2300)
        // No queue item → no per-item usage entry is created.
        #expect(tracker.transcripts["any-interactive"] == nil)

        DailyUsage.save(savedDaily)
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

// MARK: - QueueActivityTracker rehydration (persistence across "restart")

/// Proves that activity data written in one `QueueStore` session is rehydrated
/// into a fresh `QueueActivityTracker` over the same DB — the closest analog to
/// an app restart testable without a running GUI.
@Suite("QueueActivityTracker rehydration")
struct QueueActivityTrackerRehydrateTests {

    private func tempDB() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-rehydrate-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    @MainActor
    @Test("Rehydrate populates usage, paths, and progress from the store")
    func rehydratePopulatesActivity() async throws {
        let db = tempDB()
        let usage = SessionUsage(
            inputTokens: 797, outputTokens: 203, totalTokens: 1000,
            cachedReadTokens: nil, thoughtTokens: 412,
            cost: 0.34, currency: "USD", contextUsed: 100, contextSize: 200,
            providerLabel: "Claude", modelId: "sonnet-4", thinkingLevel: nil)
        let logURL = URL(fileURLWithPath: "/tmp/scratch/run.jsonl")
        let debugURL = URL(fileURLWithPath: "/tmp/scratch/debug", isDirectory: true)

        let itemID: QueueItem.ID
        // Persist activity directly via the store, mirroring the strings the
        // engine's emit closures write (usage JSON + absoluteString URLs).
        do {
            let store = try QueueStore(databaseURL: db)
            let item = try store.enqueue(QueueItemRequest(
                queue: .ingestion, wikiID: "w1",
                payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")])))
            itemID = item.id
            try store.markRunning(id: itemID, providerID: "p1")
            try store.markCompleted(id: itemID)
            let data = try JSONEncoder().encode(usage)
            let usageJSON = String(data: data, encoding: .utf8)!
            try store.upsertItemActivity(itemID: itemID, usageJSON: usageJSON,
                                         logURL: nil, debugURL: nil)
            try store.upsertItemActivity(itemID: itemID, usageJSON: nil,
                                         logURL: logURL.absoluteString,
                                         debugURL: debugURL.absoluteString)
            try store.appendItemProgress(itemID: itemID, line: "extraction output")
            store.close()
        }

        // New "app session": fresh engine + tracker over the SAME database.
        let store = try QueueStore(databaseURL: db)
        let engine = QueueEngine(store: store, workerFactory: StubWorkerFactory())
        await engine.start()
        let tracker = QueueActivityTracker()
        tracker.attachForTesting(events: AsyncStream { _ in })
        await tracker.rehydrate(from: engine)

        // Usage round-trips (JSON → SessionUsage). Compare fields since
        // SessionUsage isn't Equatable.
        let rehydratedUsage = tracker.usage(for: itemID)
        #expect(rehydratedUsage?.inputTokens == 797)
        #expect(rehydratedUsage?.outputTokens == 203)
        #expect(rehydratedUsage?.thoughtTokens == 412)
        #expect(rehydratedUsage?.cost == 0.34)
        #expect(rehydratedUsage?.providerLabel == "Claude")

        // Paths round-trip via absoluteString → URL(string:).
        #expect(tracker.logURL(for: itemID)?.path == "/tmp/scratch/run.jsonl")
        #expect(tracker.debugURL(for: itemID)?.path == "/tmp/scratch/debug")
        // Progress log round-trips verbatim.
        #expect(tracker.progressLog(for: itemID) == "extraction output")
    }

    @MainActor
    @Test("Rehydrate with no persisted activity leaves the tracker empty")
    func rehydrateEmpty() async throws {
        let store = try QueueStore(databaseURL: tempDB())
        let engine = QueueEngine(store: store, workerFactory: StubWorkerFactory())
        await engine.start()
        let tracker = QueueActivityTracker()
        tracker.attachForTesting(events: AsyncStream { _ in })
        await tracker.rehydrate(from: engine)

        #expect(tracker.usage(for: "never-existed") == nil)
        #expect(tracker.logURL(for: "never-existed") == nil)
        #expect(tracker.progressLog(for: "never-existed") == "")
    }
}

// MARK: - Lint item ID resolution (#837)

@Suite("QueueActivityTracker lint item ID resolution")
struct QueueActivityTrackerLintItemIDTests {

    /// Mirrors the helper in the transcript tests but with a configurable wikiID
    /// so cross-wiki scoping can be exercised.
    private func makeLintItem(
        id: String,
        wikiID: String = "w1",
        lintPageIDs: [PageID],
        state: QueueItemState = .running
    ) -> QueueItem {
        QueueItem(
            id: id, queue: .ingestion, wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: lintPageIDs),
            state: state, orderingKey: 1000, attempt: 0,
            createdAt: 0)
    }

    @MainActor
    @Test("Page-level lint resolves to the correct item ID")
    func pageLevelLintResolvesItemID() {
        let tracker = QueueActivityTracker()
        let pageA = PageID(rawValue: "pageA")
        let pageB = PageID(rawValue: "pageB")
        let item = makeLintItem(id: "lint-1", lintPageIDs: [pageA, pageB])

        tracker.handleForTesting(.started(item))

        #expect(tracker.lintItemID(for: pageA, wikiID: "w1") == "lint-1")
        #expect(tracker.lintItemID(for: pageB, wikiID: "w1") == "lint-1")
    }

    @MainActor
    @Test("Whole-wiki lint resolves for any page in that wiki")
    func wholeWikiLintResolvesForAnyPage() {
        let tracker = QueueActivityTracker()
        let anyPage = PageID(rawValue: "any-page")
        let item = makeLintItem(id: "lint-wiki", lintPageIDs: [])

        tracker.handleForTesting(.started(item))

        #expect(tracker.lintItemID(for: anyPage, wikiID: "w1") == "lint-wiki")
    }

    @MainActor
    @Test("Nil when no lint is running for the page")
    func nilWhenNoLintRunning() {
        let tracker = QueueActivityTracker()
        let page = PageID(rawValue: "lonely")

        #expect(tracker.lintItemID(for: page, wikiID: "w1") == nil)
    }

    @MainActor
    @Test("Whole-wiki lint does not cross wiki boundaries")
    func wholeWikiLintWikiScoped() {
        let tracker = QueueActivityTracker()
        let page = PageID(rawValue: "p1")
        let item = makeLintItem(id: "lint-w2", wikiID: "w2", lintPageIDs: [])

        tracker.handleForTesting(.started(item))

        // A whole-wiki lint in w2 should not match a page in w1.
        #expect(tracker.lintItemID(for: page, wikiID: "w1") == nil)
        #expect(tracker.lintItemID(for: page, wikiID: "w2") == "lint-w2")
    }

    @MainActor
    @Test("Page-level lint does not match a page not in its set")
    func pageLevelLintDoesNotMatchUnlistedPage() {
        let tracker = QueueActivityTracker()
        let pageA = PageID(rawValue: "pageA")
        let pageC = PageID(rawValue: "pageC")
        let item = makeLintItem(id: "lint-2", lintPageIDs: [pageA])

        tracker.handleForTesting(.started(item))

        #expect(tracker.lintItemID(for: pageA, wikiID: "w1") == "lint-2")
        #expect(tracker.lintItemID(for: pageC, wikiID: "w1") == nil)
    }

    @MainActor
    @Test("Mapping cleared after completion")
    func mappingClearedOnCompletion() {
        let tracker = QueueActivityTracker()
        let page = PageID(rawValue: "done-page")
        let item = makeLintItem(id: "lint-done", lintPageIDs: [page])

        tracker.handleForTesting(.started(item))
        #expect(tracker.lintItemID(for: page, wikiID: "w1") == "lint-done")

        let completed = makeLintItem(id: "lint-done", lintPageIDs: [page], state: .completed)
        tracker.handleForTesting(.completed(completed))

        #expect(tracker.lintItemID(for: page, wikiID: "w1") == nil)
    }

    @MainActor
    @Test("Mapping cleared after cancellation")
    func mappingClearedOnCancellation() {
        let tracker = QueueActivityTracker()
        let page = PageID(rawValue: "cancelled-page")
        let item = makeLintItem(id: "lint-cancel", lintPageIDs: [page])

        tracker.handleForTesting(.started(item))
        #expect(tracker.lintItemID(for: page, wikiID: "w1") == "lint-cancel")

        let cancelled = makeLintItem(id: "lint-cancel", lintPageIDs: [page], state: .cancelled)
        tracker.handleForTesting(.cancelled(cancelled))

        #expect(tracker.lintItemID(for: page, wikiID: "w1") == nil)
    }

    @MainActor
    @Test("pendingSelectionItemID defaults to nil")
    func pendingSelectionDefaultsNil() {
        let tracker = QueueActivityTracker()
        #expect(tracker.pendingSelectionItemID == nil)
    }

    @MainActor
    @Test("pendingSelectionItemID cleared by stop()")
    func pendingSelectionClearedByStop() {
        let tracker = QueueActivityTracker()
        tracker.pendingSelectionItemID = "some-item"
        tracker.stop()
        #expect(tracker.pendingSelectionItemID == nil)
    }

    // MARK: - #842 PR2: pendingSelectionQueue guard

    @MainActor
    @Test("pendingSelectionQueue defaults to nil")
    func pendingSelectionQueueDefaultsNil() {
        let tracker = QueueActivityTracker()
        #expect(tracker.pendingSelectionQueue == nil)
    }

    @MainActor
    @Test("pendingSelectionQueue cleared by stop()")
    func pendingSelectionQueueClearedByStop() {
        let tracker = QueueActivityTracker()
        tracker.pendingSelectionQueue = .transcription
        tracker.stop()
        #expect(tracker.pendingSelectionQueue == nil)
    }

    // MARK: - #842 PR2: transcriptionItemID resolution

    private func makeTranscriptionItem(
        id: String,
        sourceIDs: [PageID],
        state: QueueItemState = .running
    ) -> QueueItem {
        QueueItem(
            id: id, queue: .transcription, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: sourceIDs),
            state: state, orderingKey: 1000, attempt: 0,
            createdAt: 0)
    }

    @MainActor
    @Test("Transcription item resolves to the correct item ID")
    func transcriptionItemResolvesItemID() {
        let tracker = QueueActivityTracker()
        let srcA = PageID(rawValue: "srcA")
        let srcB = PageID(rawValue: "srcB")
        let item = makeTranscriptionItem(id: "tr-1", sourceIDs: [srcA, srcB])

        tracker.handleForTesting(.started(item))

        #expect(tracker.transcriptionItemID(for: srcA) == "tr-1")
        #expect(tracker.transcriptionItemID(for: srcB) == "tr-1")
    }

    @MainActor
    @Test("Nil when no transcription is running for the source")
    func nilWhenNoTranscriptionRunning() {
        let tracker = QueueActivityTracker()
        let src = PageID(rawValue: "lonely")

        #expect(tracker.transcriptionItemID(for: src) == nil)
    }

    @MainActor
    @Test("Transcription item ID does not resolve via extraction items")
    func transcriptionItemIDDoesNotResolveExtractionItems() {
        let tracker = QueueActivityTracker()
        let src = PageID(rawValue: "src1")
        let extractionItem = QueueItem(
            id: "ext-1", queue: .extraction, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [src]),
            state: .running, orderingKey: 1000, attempt: 0,
            createdAt: 0)

        tracker.handleForTesting(.started(extractionItem))

        // An extraction item tracking the same source should NOT resolve
        // via transcriptionItemID — the mapping is queue-kind-specific.
        #expect(tracker.transcriptionItemID(for: src) == nil)
    }

    @MainActor
    @Test("Transcription item mapping cleared after completion")
    func transcriptionMappingClearedOnCompletion() {
        let tracker = QueueActivityTracker()
        let src = PageID(rawValue: "done-src")
        let item = makeTranscriptionItem(id: "tr-done", sourceIDs: [src])

        tracker.handleForTesting(.started(item))
        #expect(tracker.transcriptionItemID(for: src) == "tr-done")

        let completed = makeTranscriptionItem(id: "tr-done", sourceIDs: [src], state: .completed)
        tracker.handleForTesting(.completed(completed))

        #expect(tracker.transcriptionItemID(for: src) == nil)
    }

    @MainActor
    @Test("Transcription item mapping cleared after cancellation")
    func transcriptionMappingClearedOnCancellation() {
        let tracker = QueueActivityTracker()
        let src = PageID(rawValue: "cancel-src")
        let item = makeTranscriptionItem(id: "tr-cancel", sourceIDs: [src])

        tracker.handleForTesting(.started(item))
        #expect(tracker.transcriptionItemID(for: src) == "tr-cancel")

        let cancelled = makeTranscriptionItem(id: "tr-cancel", sourceIDs: [src], state: .cancelled)
        tracker.handleForTesting(.cancelled(cancelled))

        #expect(tracker.transcriptionItemID(for: src) == nil)
    }

    @MainActor
    @Test("Transcription does not conflate with extraction for item ID resolution")
    func transcriptionItemIDNoCrossKindConflation() {
        let tracker = QueueActivityTracker()
        let src1 = PageID(rawValue: "src1")
        let src2 = PageID(rawValue: "src2")
        let extractionItem = QueueItem(
            id: "ext-1", queue: .extraction, wikiID: "w1",
            payload: QueueItemPayload(sourceIDs: [src1]),
            state: .running, orderingKey: 1000, attempt: 0,
            createdAt: 0)
        let transcriptionItem = makeTranscriptionItem(id: "tr-1", sourceIDs: [src2])

        tracker.handleForTesting(.started(extractionItem))
        tracker.handleForTesting(.started(transcriptionItem))

        #expect(tracker.transcriptionItemID(for: src1) == nil)
        #expect(tracker.transcriptionItemID(for: src2) == "tr-1")

        // Complete transcription → only transcription clears
        tracker.handleForTesting(.completed(transcriptionItem))
        #expect(tracker.transcriptionItemID(for: src2) == nil)
    }
}
#endif
