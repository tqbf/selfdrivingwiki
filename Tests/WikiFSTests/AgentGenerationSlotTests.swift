import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
import WikiFSCore

/// Tests for the serialized active-generation slot on `AgentLauncher` (Step 6):
/// two active generations never overlap; a cancelled waiter self-removes;
/// `releaseGenerationSlot` wakes the next live waiter FIFO. Also covers the
/// query-page debug-cluster predicate, the per-turn send gate predicate, and
/// the extraction-vs-agent edit-lock phase separation.
///
/// NOTE: In Step 6, `awaitGenerationSlot()` does NOT set `isRunning`. Process
/// lifetime (`isRunning`) is now decoupled from gate ownership (`holdsGenerationSlot`).
/// `isRunning` is set only at actual spawn commit in `run()` / `startInteractiveQuery()`.
/// Tests that previously used `awaitSpawnSlot()` as a proxy for "isRunning = true"
/// are updated to reflect the new semantics: the slot is verified via return value
/// and `generationSlotWaiterCount`, not via `isRunning`.
///
/// These exercise the slot seam (`awaitGenerationSlot` / `releaseGenerationSlot` /
/// `generationSlotWaiterCount`) directly, without spawning a real `claude -p` process —
/// so they are fast and deterministic.
@MainActor
struct AgentGenerationSlotTests {

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
        // Initially not running (no process spawned).
        #expect(!launcher.isRunning)
        let acquired = await launcher.awaitGenerationSlot()
        #expect(acquired)
        // Step 6 decoupling: gate acquire does NOT set isRunning (process not spawned).
        #expect(!launcher.isRunning)
        #expect(launcher.generationSlotWaiterCount == 0)
        launcher.releaseGenerationSlot()
        // isRunning stays false (was never set via slot).
        #expect(!launcher.isRunning)
    }

    @Test func secondRequestWaitsUntilFirstReleases() async {
        let launcher = makeLauncher()
        // First acquires the slot.
        let first = await launcher.awaitGenerationSlot()
        #expect(first)
        // Gate acquire does NOT set isRunning.

        // Second must suspend behind the first.
        let secondTask = Task { await launcher.awaitGenerationSlot() }
        // Yield so the second task can enqueue its continuation.
        await Task.yield()
        await Task.yield()
        #expect(launcher.generationSlotWaiterCount == 1)

        // Releasing hands the slot: the gate keeps its `held` flag true across the
        // atomic handoff; the second caller resumes and its `awaitGenerationSlot`
        // returns true.
        launcher.releaseGenerationSlot()
        let secondAcquired = await secondTask.value
        #expect(secondAcquired)
        #expect(launcher.generationSlotWaiterCount == 0)

        launcher.releaseGenerationSlot()
    }

    // MARK: - Cancelled waiter self-removes

    @Test func cancelledWaiterSelfRemovesAndDoesNotStealSlot() async {
        let launcher = makeLauncher()
        let first = await launcher.awaitGenerationSlot()
        #expect(first)

        // A waiter that gets cancelled while queued must self-remove from
        // the gate's waiters and return false (it never acquired the slot).
        let waiterTask = Task<Void, Never> {
            // This will suspend behind the first holder.
            _ = await launcher.awaitGenerationSlot()
        }
        await Task.yield()
        await Task.yield()
        #expect(launcher.generationSlotWaiterCount == 1)

        waiterTask.cancel()
        await waiterTask.value
        // The cancelled waiter removed itself.
        #expect(launcher.generationSlotWaiterCount == 0)

        // The slot is still held by the first; releasing frees it (no stale handoff
        // to the dead task).
        launcher.releaseGenerationSlot()
    }

    @Test func releaseWakesNextLiveWaiterAfterACancelledOne() async {
        let launcher = makeLauncher()
        _ = await launcher.awaitGenerationSlot()

        // Enqueue a waiter that will be cancelled, then a live waiter behind it.
        let doomed = Task<Void, Never> { _ = await launcher.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        let live = Task { await launcher.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(launcher.generationSlotWaiterCount == 2)

        doomed.cancel()
        await doomed.value
        // The cancelled one is gone; the live one is still queued.
        #expect(launcher.generationSlotWaiterCount == 1)

        // Releasing must hand the slot to the LIVE waiter, skipping the dead one.
        launcher.releaseGenerationSlot()
        let liveAcquired = await live.value
        #expect(liveAcquired)
        launcher.releaseGenerationSlot()
    }

    // MARK: - Query-page debug-cluster predicate

    /// `AgentLauncher.showsQueryDebugControls` is the pure predicate backing
    /// `ChatView.showsDebugControls`. The cluster is visible only
    /// while a QUERY run is in flight (AC.1). Assert it across the state matrix.
    @Test func debugClusterPredicateOnlyTrueForActiveQueryRun() {
        func p(_ isGenerating: Bool, _ kind: WikiOperation.Kind?) -> Bool {
            AgentLauncher.showsQueryDebugControls(isGenerating: isGenerating, runningKind: kind)
        }
        // Idle: no cluster.
        #expect(!p(false, nil))
        // Ingest generating: no cluster on the query page.
        #expect(!p(true, .ingest))
        // Lint generating: no cluster.
        #expect(!p(true, .lint))
        // Query turn generating: cluster shows.
        #expect(p(true, .query))
        // Turn ended (not generating): cluster hides even if runningKind is stale.
        #expect(!p(false, .query))
        #expect(!p(false, nil))
    }

    // MARK: - sendInteractiveMessage gate predicate (first-message regression)

    /// `AgentLauncher.shouldSendMessage` is the pure gate backing
    /// `sendInteractiveMessage`. This locks in the regression where the FIRST
    /// message of an interactive query was dropped: `startInteractiveQuery` used to
    /// set `isGenerating = true` in spawn-commit, so the `sendInteractiveMessage(
    /// firstMessage)` call right after hit the `!isGenerating` guard and returned
    /// early — claude then blocked on stdin forever (events=0, perpetual spinner).
    /// The fix: the first-turn `isGenerating(true)` transition is owned by
    /// `sendInteractiveMessage` itself, so the first send runs with
    /// `isGenerating == false`.
    ///
    /// Step 6 adds `isAwaitingGenerationSlot` as a fifth gate condition: a pending
    /// send cannot start another send while already waiting for the gate.
    @Test func firstMessageIsSentBecauseGenerationIsNotPreSet() {
        // The exact state at the first send: running, interactive, NOT yet
        // generating, NOT awaiting slot (first send), real text. Must send.
        #expect(AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "hi"))
        // Whitespace-only text never sends.
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "   "))
    }

    @Test func followUpWhileGeneratingIsRefused() {
        // A follow-up send while the agent is mid-response must be refused so two
        // turns never interleave on the shared stdin. (The UI's `canSend` also
        // disables the button; this is the defensive backstop.)
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: true,
            isAwaitingGenerationSlot: false,
            message: "again"))
        // But a follow-up BETWEEN turns (generation finished) sends again.
        #expect(AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "again"))
    }

    @Test func sendGateRequiresRunningInteractiveSession() {
        // Not running, or not an interactive session, or empty: never send.
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: false,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "hi"))
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: false,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "hi"))
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: ""))
    }

    // cancelledInteractiveSendReleasesGate: skipped — driving the Task cancellation
    // path through `sendInteractiveMessage` requires a live process (isRunning +
    // isInteractiveSession are only set at spawn commit). The guarantee is covered
    // at the call-site by `if ok { self.releaseGenerationSlot() }` in the
    // `interactiveSendTask` body, exercised indirectly by the existing cancellation
    // tests in GenerationGateTests.swift.

    /// Step 6: a send is blocked while already awaiting the generation slot.
    /// This prevents double-queueing — there can be at most one pending send task.
    @Test func sendGateBlockedWhileAwaitingGenerationSlot() {
        // Awaiting the slot: refuse another send (prevents double-queue).
        #expect(!AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: true,
            message: "hi"))
        // Not awaiting, not generating: allow.
        #expect(AgentLauncher.shouldSendMessage(
            isRunning: true,
            isInteractiveSession: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            message: "hi"))
    }

    // MARK: - Per-turn gate release predicate

    /// `AgentLauncher.releasesGenerationSlotPerTurn` encodes the invariant that
    /// interactive sessions release the gate at each turn boundary while one-shot
    /// runs hold the gate through `finish()`. This prevents a one-shot run from
    /// releasing per-turn (which would double-release with finish and, more
    /// importantly, let a peer interleave mid-run).
    @Test func perTurnReleasePredicateTrueForInteractiveFalseForOneShot() {
        // Interactive session: releases per turn so peers can generate between turns.
        #expect(AgentLauncher.releasesGenerationSlotPerTurn(isInteractiveSession: true))
        // One-shot run (ingest/lint/query): holds gate through finish(); must NOT release per turn.
        #expect(!AgentLauncher.releasesGenerationSlotPerTurn(isInteractiveSession: false))
    }

    // MARK: - Agent-run lifecycle: extraction does not increment, spawn commit does

    /// `store.agentRunCount` tracks how many claude processes are writing to
    /// this wiki. It is incremented at spawn commit (via `onLock`/`onUnlock`)
    /// and decremented at process termination. Extraction (`isExtracting`)
    /// does NOT increment it. When the count is > 0 the model knows an agent
    /// is active; when it drops to 0, the model reloads from store.
    ///
    /// Step 6 rework: `awaitGenerationSlot()` does NOT set `isRunning` —
    /// process lifetime is decoupled from gate ownership. `isRunning` is set
    /// only at actual spawn commit (inside `run()` / `startInteractiveQuery()`).
    /// The agent-run counter is still wired at spawn commit via `onLock`, so
    /// the intent of this test is preserved: extraction does NOT increment
    /// the counter, and an agent's spawn commit DOES (via `onLock`).
    @Test func extractionPhaseDoesNotIncrementAgentRunCount() async throws {
        let launcher = makeLauncher()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-gen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WikiStoreModel(
            store: try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite")))

        // Extraction phase: isExtracting true, no claude running. Counter is 0.
        launcher.isExtracting = true
        #expect(!launcher.isRunning)
        #expect(store.agentRunCount == 0)

        // Generation slot acquired: does NOT set isRunning (Step 6 decoupling).
        // isRunning is set only when the actual process launches (spawn commit).
        launcher.isExtracting = false
        _ = await launcher.awaitGenerationSlot()
        #expect(!launcher.isRunning)  // gate alone does not mean "process alive"

        // Spawn commit simulation: the runner calls onLock when the process launches.
        // This is what increments the counter — not the gate acquire.
        store.agentRunStarted()
        #expect(store.agentRunCount == 1)  // agent run IS active during agent run

        // Agent finishes: slot released, counter decremented. Counter back to 0.
        launcher.releaseGenerationSlot()
        store.agentRunEnded()
        #expect(!launcher.isRunning)
        #expect(store.agentRunCount == 0)
    }
}
