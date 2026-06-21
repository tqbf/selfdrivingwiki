import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for the serialized claude spawn slot on `AgentLauncher` (option C): two
/// claude spawns never overlap; a cancelled waiter self-removes; `releaseSpawnSlot`
/// wakes the next live waiter FIFO. Also covers the query-page debug-cluster
/// predicate and the extraction-vs-agent edit-lock phase.
///
/// These exercise the slot seam (`awaitSpawnSlot` / `releaseSpawnSlot` /
/// `spawnSlotWaiterCount`) directly, without spawning a real `claude -p` process —
/// so they are fast and deterministic.
@MainActor
struct AgentSpawnSlotTests {

    private func makeLauncher() -> AgentLauncher {
        // Stub the PATH preflight so `run`/`startInteractiveQuery` (if ever used
        // here) never touch the login shell.
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - Slot serialization

    @Test func fastPathAcquiresWithoutSuspending() async {
        let launcher = makeLauncher()
        #expect(!launcher.isRunning)
        let acquired = await launcher.awaitSpawnSlot()
        #expect(acquired)
        #expect(launcher.isRunning)
        #expect(launcher.spawnSlotWaiterCount == 0)
        launcher.releaseSpawnSlot()
        #expect(!launcher.isRunning)
    }

    @Test func secondRequestWaitsUntilFirstReleases() async {
        let launcher = makeLauncher()
        // First acquires the slot.
        let first = await launcher.awaitSpawnSlot()
        #expect(first)
        #expect(launcher.isRunning)

        // Second must suspend behind the first.
        let secondTask = Task { await launcher.awaitSpawnSlot() }
        // Yield so the second task can enqueue its continuation.
        await Task.yield()
        await Task.yield()
        #expect(launcher.spawnSlotWaiterCount == 1)
        #expect(launcher.isRunning)

        // Releasing hands the slot to the waiter; isRunning stays true (atomic
        // handoff) and the waiter reports it acquired the slot.
        launcher.releaseSpawnSlot()
        let secondAcquired = await secondTask.value
        #expect(secondAcquired)
        #expect(launcher.isRunning)
        #expect(launcher.spawnSlotWaiterCount == 0)

        launcher.releaseSpawnSlot()
        #expect(!launcher.isRunning)
    }

    // MARK: - Cancelled waiter self-removes

    @Test func cancelledWaiterSelfRemovesAndDoesNotStealSlot() async {
        let launcher = makeLauncher()
        let first = await launcher.awaitSpawnSlot()
        #expect(first)

        // A waiter that gets cancelled while queued must self-remove from
        // spawnWaiters and return false (it never acquired the slot).
        let waiterTask = Task<Void, Never> {
            // This will suspend behind the first holder.
            _ = await launcher.awaitSpawnSlot()
        }
        await Task.yield()
        await Task.yield()
        #expect(launcher.spawnSlotWaiterCount == 1)

        waiterTask.cancel()
        await waiterTask.value
        // The cancelled waiter removed itself.
        #expect(launcher.spawnSlotWaiterCount == 0)

        // The slot is still held by the first; releasing frees it (no stale handoff
        // to the dead task).
        launcher.releaseSpawnSlot()
        #expect(!launcher.isRunning)
    }

    @Test func releaseWakesNextLiveWaiterAfterACancelledOne() async {
        let launcher = makeLauncher()
        _ = await launcher.awaitSpawnSlot()

        // Enqueue a waiter that will be cancelled, then a live waiter behind it.
        let doomed = Task<Void, Never> { _ = await launcher.awaitSpawnSlot() }
        await Task.yield()
        await Task.yield()
        let live = Task { await launcher.awaitSpawnSlot() }
        await Task.yield()
        await Task.yield()
        #expect(launcher.spawnSlotWaiterCount == 2)

        doomed.cancel()
        await doomed.value
        // The cancelled one is gone; the live one is still queued.
        #expect(launcher.spawnSlotWaiterCount == 1)

        // Releasing must hand the slot to the LIVE waiter, skipping the dead one.
        launcher.releaseSpawnSlot()
        let liveAcquired = await live.value
        #expect(liveAcquired)
        #expect(launcher.isRunning)
        launcher.releaseSpawnSlot()
    }

    // MARK: - Query-page debug-cluster predicate

    /// `AgentLauncher.showsQueryDebugControls` is the pure predicate backing
    /// `QueryConversationView.showsDebugControls`. The cluster is visible only
    /// while a QUERY run is in flight (AC.1). Assert it across the state matrix.
    @Test func debugClusterPredicateOnlyTrueForActiveQueryRun() {
        func p(_ isRunning: Bool, _ kind: WikiOperation.Kind?) -> Bool {
            AgentLauncher.showsQueryDebugControls(isRunning: isRunning, runningKind: kind)
        }
        // Idle: no cluster.
        #expect(!p(false, nil))
        // Ingest run active: no cluster on the query page.
        #expect(!p(true, .ingest))
        // Lint run active: no cluster.
        #expect(!p(true, .lint))
        // Query run active: cluster shows.
        #expect(p(true, .query))
        // Run ended (isRunning false): cluster hides even if runningKind is stale.
        #expect(!p(false, .query))
        #expect(!p(false, nil))
    }

    // MARK: - Edit-lock phase: extraction does not lock, agent spawn does

    /// `store.isAgentRunning` is the edit lock. It is `true` only while a claude
    /// process is running (driven by `onLock`/`onUnlock`). Extraction
    /// (`isExtracting`) does NOT lock editing. This mirrors the
    /// `IngestedFileDetailView`/`PageDetailView` banner binding
    /// (`store.isAgentRunning`), so the query page shows the orange banner during an
    /// agent run but NOT during extraction (AC.2 vs AC.3). Drives `isRunning` via the
    /// slot seam so the test exercises the real flag, not a mock.
    @Test func extractionPhaseDoesNotLockEditing() async throws {
        let launcher = makeLauncher()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WikiStoreModel(
            store: try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite")))

        // Extraction phase: isExtracting true, no claude running. Editing is free.
        launcher.isExtracting = true
        #expect(!launcher.isRunning)
        #expect(!store.isAgentRunning)

        // Agent spawn reservation: acquire the slot (sets isRunning true) and fire
        // onLock (store.beginAgentRun). Editing is now locked.
        launcher.isExtracting = false
        _ = await launcher.awaitSpawnSlot()
        store.beginAgentRun()
        #expect(launcher.isRunning)
        #expect(store.isAgentRunning)

        // Agent finishes: slot released (isRunning false), onUnlock fires. Editing
        // free again.
        launcher.releaseSpawnSlot()
        store.endAgentRun()
        #expect(!launcher.isRunning)
        #expect(!store.isAgentRunning)
    }
}
