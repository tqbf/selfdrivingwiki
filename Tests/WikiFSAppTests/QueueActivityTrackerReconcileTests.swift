#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Tests for `QueueActivityTracker.reconcile(with:)` — the app-side #871
/// self-heal. When the daemon → app event stream is broken, a `.completed`
/// event may never arrive, leaving `isExtracting`/`isIngesting` true forever
/// (spinner stuck). Reconciliation clears running-state for any item the
/// daemon's snapshot no longer considers active.
@MainActor
struct QueueActivityTrackerReconcileTests {

    // MARK: - The bug: spinner stuck when the terminal event is dropped

    @Test func reconcileClearsExtractionSpinnerWhenItemFinishedOnDaemon() {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "ext1", queue: .extraction, sourceIDs: ["src1"])

        // .started arrived → spinner on.
        tracker.handle(.started(item))
        #expect(tracker.isExtracting)

        // Daemon finished the item (it's in recent history, not active) but
        // the .completed event was dropped — the exact #871 scenario.
        let snapshot = QueueSnapshot(activeItems: [], recentItems: [item])
        tracker.reconcile(with: snapshot)

        // Reconcile clears the spinner even though no terminal event arrived.
        #expect(!tracker.isExtracting)
    }

    @Test func reconcileClearsIngestionSpinnerWhenItemFinishedOnDaemon() {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "ing1", queue: .ingestion, sourceIDs: ["src9"])

        tracker.handle(.started(item))
        #expect(tracker.isIngesting)

        tracker.reconcile(with: QueueSnapshot(activeItems: [], recentItems: [item]))

        #expect(!tracker.isIngesting)
    }

    // MARK: - Safety: never clears / fabricates activity for still-running items

    @Test func reconcileLeavesStillActiveItemsRunning() {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "ext1", queue: .extraction, sourceIDs: ["src1"])

        tracker.handle(.started(item))
        #expect(tracker.isExtracting)

        // Daemon still has it active → leave the spinner alone.
        tracker.reconcile(with: QueueSnapshot(activeItems: [item], recentItems: []))

        #expect(tracker.isExtracting)
    }

    @Test func reconcileIsRemovalOnlyAndNeverFabricatesActivity() {
        let tracker = QueueActivityTracker()

        // Daemon is running an item the tracker never saw .started for.
        let unknown = makeItem(id: "unknown", queue: .extraction, sourceIDs: ["srcX"])
        tracker.reconcile(with: QueueSnapshot(activeItems: [unknown], recentItems: []))

        // Removal-only: the tracker does not synthesize running-state from a
        // snapshot (that would race with the live event stream). The unknown
        // item is ignored.
        #expect(tracker.extractingSourceIDs.isEmpty)
        #expect(!tracker.isExtracting)
    }

    // MARK: - Queue-kind awareness: shared source ID across two items

    @Test func reconcileClearsOnlyTheFinishedQueueWhenSourceIDShared() {
        let tracker = QueueActivityTracker()
        // Same source ID, different queue kinds — extract then ingest the
        // same file. Both spinners are on; only extraction finished.
        let extraction = makeItem(id: "ext1", queue: .extraction, sourceIDs: ["src1"])
        let ingestion = makeItem(id: "ing1", queue: .ingestion, sourceIDs: ["src1"])

        tracker.handle(.started(extraction))
        tracker.handle(.started(ingestion))
        #expect(tracker.isExtracting)
        #expect(tracker.isIngesting)

        // Daemon: extraction finished (recent), ingestion still active.
        let snapshot = QueueSnapshot(activeItems: [ingestion], recentItems: [extraction])
        tracker.reconcile(with: snapshot)

        // Extraction spinner cleared, ingestion spinner untouched — the
        // per-item queue map prevented subtracting src1 from ingestion.
        #expect(!tracker.isExtracting)
        #expect(tracker.isIngesting)
    }

    // MARK: - Lint self-heal

    @Test func reconcileClearsPageLevelLintWhenItemFinishedOnDaemon() {
        let tracker = QueueActivityTracker()
        let page = PageID(rawValue: "page1")
        let item = makeItem(
            id: "lint1", queue: .ingestion, sourceIDs: [],
            lintPageIDs: [page])

        tracker.handle(.started(item))
        #expect(tracker.isLinting(pageID: page, wikiID: "wiki1"))

        tracker.reconcile(with: QueueSnapshot(activeItems: [], recentItems: [item]))

        #expect(!tracker.isLinting(pageID: page, wikiID: "wiki1"))
    }

    @Test func reconcileClearsWholeWikiLintWhenItemFinishedOnDaemon() {
        let tracker = QueueActivityTracker()
        let item = makeItem(
            id: "lint2", queue: .ingestion, sourceIDs: [],
            lintPageIDs: [])  // empty → whole-wiki lint

        tracker.handle(.started(item))
        #expect(tracker.isLinting(pageID: PageID(rawValue: "anyPage"), wikiID: "wiki1"))

        tracker.reconcile(with: QueueSnapshot(activeItems: [], recentItems: [item]))

        #expect(!tracker.isLinting(pageID: PageID(rawValue: "anyPage"), wikiID: "wiki1"))
    }

    // MARK: - Idempotency

    @Test func reconcileIsIdempotent() {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "ext1", queue: .extraction, sourceIDs: ["src1"])
        tracker.handle(.started(item))

        let snapshot = QueueSnapshot(activeItems: [], recentItems: [item])
        tracker.reconcile(with: snapshot)
        tracker.reconcile(with: snapshot)  // second pass must be a no-op

        #expect(!tracker.isExtracting)
    }

    // MARK: - Watchdog integration: the periodic poll drives reconcile end-to-end

    @Test func snapshotWatchdogClearsSpinnerViaPeriodicPoll() async throws {
        let tracker = QueueActivityTracker()
        let item = makeItem(id: "ext1", queue: .extraction, sourceIDs: ["src1"])
        tracker.handle(.started(item))
        #expect(tracker.isExtracting)

        // Daemon reports the item finished; the watchdog polls this snapshot.
        let engine = FakeQueueEngineClient()
        await engine.setSnapshotValue(QueueSnapshot(activeItems: [], recentItems: [item]))

        tracker.startSnapshotWatchdog(engine: engine, interval: .milliseconds(50))

        // The first iteration reconciles before sleeping, so this should clear
        // well within the polling budget.
        var cleared = false
        for _ in 0..<40 {
            if !tracker.isExtracting {
                cleared = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(cleared)
    }

    // MARK: - Helpers

    private func makeItem(
        id: String,
        queue: QueueKind,
        sourceIDs: [String] = [],
        lintPageIDs: [PageID]? = nil,
        wikiID: String = "wiki1"
    ) -> QueueItem {
        QueueItem(
            id: id, queue: queue, wikiID: wikiID,
            payload: QueueItemPayload(
                sourceIDs: sourceIDs.map { PageID(rawValue: $0) },
                lintPageIDs: lintPageIDs),
            state: .running, orderingKey: 1000, attempt: 0, createdAt: 0)
    }
}

/// Minimal `QueueEngineClient` fake for tracker tests. An `actor` (matching
/// the real `QueueEngine` conformer) so the `Sendable` conformance doesn't
/// cross actor isolation. Only `snapshot()` is meaningful (configurable).
actor FakeQueueEngineClient: QueueEngineClient {
    var snapshotValue: QueueSnapshot = QueueSnapshot()

    /// Cross-isolation setter so tests can configure the snapshot from the
    /// `@MainActor` test function (`await engine.setSnapshotValue(...)`).
    func setSnapshotValue(_ snapshot: QueueSnapshot) {
        snapshotValue = snapshot
    }

    nonisolated var events: AsyncStream<QueueEvent> { AsyncStream { _ in } }
    @discardableResult
    nonisolated func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { "fake" }
    nonisolated func cancelItem(_ id: QueueItem.ID) async {}
    @discardableResult
    nonisolated func cancelAllInFlight() async -> Int { 0 }
    nonisolated func retryItem(_ id: QueueItem.ID) async throws {}
    nonisolated func pause(_ queue: QueueKind) async {}
    nonisolated func resume(_ queue: QueueKind) async {}
    nonisolated func halt(_ queue: QueueKind) async {}
    nonisolated func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {}
    func snapshot() async -> QueueSnapshot { snapshotValue }
    nonisolated func hasActiveWork(for wikiID: String) async -> Bool { false }
    nonisolated func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> { .success(()) }
    nonisolated func loadTranscript(for itemID: QueueItem.ID) async -> [AgentEvent] { [] }
    nonisolated func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
}
#endif
