#if os(macOS)
import AppKit
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Regression coverage for #1222 — lint operations must drive the menu-bar
/// activity blinker:
///
/// 1. A newly enqueued lint job starts the working state immediately, on the
///    `.enqueued` event itself — not on an async snapshot RPC that can return
///    stale (pre-enqueue) data after the user already saw the "Lint queued"
///    hint.
/// 2. The working state persists while the lint is queued or running.
/// 3. Completion, cancellation, and failure clear it.
/// 4. A stale empty snapshot landing AFTER an enqueue must not clear the
///    blinker (the #1222 snapshot/event timing race).
/// 5. Ingestion/extraction indication keeps working through the same
///    event-driven path (queue-agnostic membership).
///
/// State is observed via `MenuBarItemController.lastDerivedIconState` — the
/// value `updateIcon()` derived on its last pass. AppKit offers no way to
/// read a status item's animation back.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MenuBarItemLintBlinkerTests {

    private let wikiID = WikiID(rawValue: "01992222-lint-wiki")

    // MARK: - Real-engine end-to-end transitions

    @Test("A newly enqueued page-level lint starts the blinker; cancelling stops it")
    func enqueuedPageLintStartsBlinkerAndCancelStopsIt() async throws {
        let harness = try makeRealEngineHarness()
        let controller = harness.controller
        controller.start()
        defer { controller.stop() }

        let settledIdle = await waitUntil { controller.lastDerivedIconState == .idle }
        #expect(settledIdle, "fresh controller over an empty queue should settle idle")

        let itemID = try await harness.engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [PageID(rawValue: "lint-page-1")])))
        _ = itemID

        // The engine never started (no dispatch in this fixture), so the item
        // stays `.queued` — the blinker must still start (#1222: "remains
        // active for queued and running lint jobs").
        let started = await waitUntil { controller.lastDerivedIconState == .working }
        #expect(started, "lint enqueue must start the menu-bar blinker (#1222)")

        await harness.engine.cancelItem(itemID)
        let stopped = await waitUntil { controller.lastDerivedIconState == .idle }
        #expect(stopped, "lint cancellation must stop the blinker (#1222)")
    }

    @Test("A whole-wiki lint (empty lintPageIDs) starts the blinker too")
    func enqueuedWholeWikiLintStartsBlinker() async throws {
        let harness = try makeRealEngineHarness()
        let controller = harness.controller
        controller.start()
        defer { controller.stop() }

        _ = await waitUntil { controller.lastDerivedIconState == .idle }

        _ = try await harness.engine.enqueue(QueueItemRequest(
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [])))

        let started = await waitUntil { controller.lastDerivedIconState == .working }
        #expect(started, "whole-wiki lint enqueue must start the blinker (#1222)")
    }

    @Test("Extraction enqueue still drives the blinker (queue-agnostic membership)")
    func extractionEnqueueStillStartsBlinker() async throws {
        let harness = try makeRealEngineHarness()
        let controller = harness.controller
        controller.start()
        defer { controller.stop() }

        _ = await waitUntil { controller.lastDerivedIconState == .idle }

        let itemID = try await harness.engine.enqueue(QueueItemRequest(
            queue: .extraction,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "source-1")])))

        let started = await waitUntil { controller.lastDerivedIconState == .working }
        #expect(started, "extraction enqueue must keep starting the blinker")

        await harness.engine.cancelItem(itemID)
        let stopped = await waitUntil { controller.lastDerivedIconState == .idle }
        #expect(stopped, "extraction cancellation must stop the blinker")
    }

    // MARK: - Snapshot/event timing (#1222 race)

    @Test("A stale empty snapshot landing after a lint enqueue cannot clear the blinker")
    func staleSnapshotCannotClearLintBlinker() async throws {
        let engine = GatedSnapshotEngine()
        let controller = makeController(engine: engine)
        controller.start()
        // Safety net: resume any fetches still parked at the gate so the test
        // process never exits with a leaked continuation.
        defer {
            engine.releaseAll(with: QueueSnapshot())
            controller.stop()
        }

        // The initial fetch parks at the gate; release it empty → idle.
        let initial = await waitUntil { engine.parkedCount == 1 }
        #expect(initial, "the initial snapshot fetch should be parked at the gate")
        engine.releaseOldest(with: QueueSnapshot())
        let idle = await waitUntil { controller.lastDerivedIconState == .idle }
        #expect(idle)

        // A snapshot fetch is now in flight that started BEFORE the lint
        // enqueue (progress events spawn these continuously during runs).
        let lintItem = makeLintItem(state: .queued)
        engine.yield(.progress(lintItem.id, line: "lint agent started"))
        let parked = await waitUntil { engine.parkedCount == 1 }
        #expect(parked, "the pre-enqueue snapshot fetch should be parked at the gate")

        // The enqueue event arrives — the blinker must start on the EVENT,
        // while its own snapshot fetch is still parked at the gate.
        engine.yield(.enqueued(lintItem))
        let started = await waitUntil { controller.lastDerivedIconState == .working }
        #expect(started, "lint enqueue must start the blinker without waiting on a snapshot")

        // Now the PRE-ENQUEUE snapshot returns: empty activeItems. The
        // pre-#1222 code applied it and flipped the icon idle — the exact
        // reported bug. The epoch guard must discard it. Release ONLY the
        // pre-enqueue fetch (FIFO); the enqueue's own fetch stays parked.
        engine.releaseOldest(with: QueueSnapshot())
        await settle()
        #expect(
            controller.lastDerivedIconState == .working,
            "a stale pre-enqueue snapshot must not clear the blinker (#1222)")

        // Started keeps it working; completed stops it and releases cleanly.
        engine.yield(.started(makeLintItem(state: .running, id: lintItem.id.rawValue)))
        await settle()
        #expect(controller.lastDerivedIconState == .working, "a running lint keeps the blinker on")

        engine.yield(.completed(makeLintItem(state: .completed, id: lintItem.id.rawValue)))
        let idleAgain = await waitUntil { controller.lastDerivedIconState == .idle }
        #expect(idleAgain, "lint completion must stop the blinker (#1222)")
    }

    // MARK: - Fixtures

    private struct RealEngineHarness {
        let controller: MenuBarItemController
        let engine: QueueEngine
    }

    /// Real in-memory `QueueEngine` (never started → no dispatch, items stay
    /// `.queued`) wired to a real `MenuBarItemController`, mirroring
    /// `MenuBarItemMaintenanceMenuTests`.
    private func makeRealEngineHarness() throws -> RealEngineHarness {
        let engine = try makeTestQueueEngine()
        let controller = makeController(engine: engine)
        return RealEngineHarness(controller: controller, engine: engine)
    }

    private func makeController(engine: any QueueEngineClient) -> MenuBarItemController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-blinker-\(UUID().uuidString)", isDirectory: true)
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { StubExtractor() })
        let sessionManager = SessionManager(
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: engine,
            extractionProvider: StubExtractionProvider(),
            pdf2mdScriptPathResolver: { nil })
        let registry = WikiRegistryClient(containerDirectory: dir)
        return MenuBarItemController(
            queueEngine: engine,
            activityTracker: QueueActivityTracker(),
            sessionManager: sessionManager,
            registry: registry,
            openWindowBridge: OpenWindowBridge())
    }

    private func makeTestQueueEngine() throws -> QueueEngine {
        // A UNIQUE per-test database FILE. `URL(fileURLWithPath: ":memory:")`
        // does NOT produce SQLite's private in-memory database — the colon is
        // not preserved through URL path conversion, so GRDB opens a literal
        // `:memory:` file in the process CWD that persists and accumulates
        // items across every test run (which made the "fresh queue" fixture
        // start with a pile of stale queued items and the controller sit in
        // the working state forever).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-blinker-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try QueueStore(databaseURL: dir.appendingPathComponent("queue.sqlite"))
        let factory = QueueExtractionWorkerFactory(
            provider: StubExtractionProvider(),
            emitProgress: { _, _ in })
        return QueueEngine(store: store, workerFactory: factory)
    }

    private func makeLintItem(
        state: QueueItemState,
        id: String = "01992222-lint-item",
        lintPageIDs: [PageID] = [PageID(rawValue: "lint-page-1")]
    ) -> QueueItem {
        QueueItem(
            id: QueueItemID(rawValue: id),
            queue: .ingestion,
            wikiID: wikiID,
            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: lintPageIDs),
            state: state,
            orderingKey: 1000,
            attempt: 0,
            createdAt: 0)
    }

    /// Poll a main-actor condition until it holds or the timeout elapses.
    /// Task.sleep is non-blocking — the cooperative pool is never parked
    /// (repo concurrency rule).
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Let already-scheduled main-actor tasks (event loop, snapshot tasks)
    /// run a few hops before asserting.
    private func settle(hops: Int = 5) async {
        for _ in 0..<hops {
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Gated snapshot engine (event-timing race fixture)

/// A `QueueEngineClient` whose `snapshot()` calls park at a gate until
/// `releaseParked(with:)` resumes them, and whose events the test injects
/// directly. This makes the snapshot/event interleaving of the #1222 race
/// deterministic: the test controls exactly when a fetch started relative to
/// each event, and what data it returns.
private final class GatedSnapshotEngine: QueueEngineClient, @unchecked Sendable {
    private enum GateError: Error { case unimplemented }

    private let broadcaster = QueueEventBroadcaster()
    private let lock = NSLock()
    private var parked: [CheckedContinuation<QueueSnapshot, Never>] = []

    var events: AsyncStream<QueueEvent> { broadcaster.subscribe() }

    /// How many snapshot fetches are currently parked at the gate.
    var parkedCount: Int {
        lock.withLock { parked.count }
    }

    func snapshot() async throws -> QueueSnapshot {
        await withCheckedContinuation { (cont: CheckedContinuation<QueueSnapshot, Never>) in
            lock.withLock { parked.append(cont) }
        }
    }

    /// Resume the OLDEST parked fetch with `snapshot`. Returns false when
    /// nothing is parked. FIFO matters for the race test: the pre-enqueue
    /// fetch parks before the enqueue's own fetch, so releasing one fetch
    /// deterministically targets the stale one.
    @discardableResult
    func releaseOldest(with snapshot: QueueSnapshot) -> Bool {
        let cont: CheckedContinuation<QueueSnapshot, Never>? = lock.withLock {
            parked.isEmpty ? nil : parked.removeFirst()
        }
        guard let cont else { return false }
        cont.resume(returning: snapshot)
        return true
    }

    /// Resume every parked fetch with `snapshot` (no-op when none parked).
    func releaseAll(with snapshot: QueueSnapshot) {
        let toResume = lock.withLock { () -> [CheckedContinuation<QueueSnapshot, Never>] in
            let pending = parked
            parked.removeAll()
            return pending
        }
        for cont in toResume { cont.resume(returning: snapshot) }
    }

    func yield(_ event: QueueEvent) {
        broadcaster.yield(event)
    }

    // Unused client surface — throw loudly if the controller ever calls it.
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { throw GateError.unimplemented }
    func cancelItem(_ id: QueueItem.ID) async throws { throw GateError.unimplemented }
    func cancelAllInFlight() async throws -> Int { throw GateError.unimplemented }
    func retryItem(_ id: QueueItem.ID) async throws { throw GateError.unimplemented }
    func pause(_ queue: QueueKind) async throws { throw GateError.unimplemented }
    func resume(_ queue: QueueKind) async throws { throw GateError.unimplemented }
    func halt(_ queue: QueueKind) async throws { throw GateError.unimplemented }
    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws { throw GateError.unimplemented }
    func hasActiveWork(for wikiID: WikiID) async throws -> Bool { throw GateError.unimplemented }
    func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> { throw GateError.unimplemented }
    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { throw GateError.unimplemented }
    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { throw GateError.unimplemented }
}

// MARK: - Minimal stubs (mirror MenuBarItemMaintenanceMenuTests)

@MainActor
private final class StubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(pdfData: Data, filename: String, onProgress: (@Sendable (String) -> Void)?) async throws -> String { "" }
}

private struct StubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(wikiID: WikiID, sourceID: SourceID, backendOverride: ExtractionBackend?) async throws -> ExtractionResolution? { nil }
    func persistBytesExtraction(wikiID: WikiID, sourceID: SourceID, resolution: BytesExtractionResolution, markdown: String) async throws {}
    func persistTranscriptExtraction(wikiID: WikiID, sourceID: SourceID, resolution: TranscriptExtractionResolution, outcome: TranscriptFetchOutcome) async throws {}
}
#endif
