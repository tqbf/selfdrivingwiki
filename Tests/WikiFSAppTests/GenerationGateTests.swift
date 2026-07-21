#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for the shared `GenerationGate` guarantee: two `AgentLauncher` instances
/// that share a single `GenerationGate` serialize their ACTIVE GENERATIONS globally.
///
/// This is the core Step-3 / Step-6 property — Ask + Edit + ingest never generate
/// at the same time even though they run on different launchers. Interactive
/// sessions' PROCESSES can coexist; only one GENERATES at a time (per-turn gate).
///
/// Tests:
///
/// Primitives (cross-instance serialization and cancellation):
/// - `sharedGateSerializesAcrossLaunchers` — the KEY invariant: A holds the slot,
///   B (on a different launcher but the SAME gate) must wait; A's release hands the
///   slot to B atomically.
/// - `independentGatesDoNotSerialize` — isolation/contrast: launchers with SEPARATE
///   default gates contend on independent queues and can both acquire concurrently.
/// - `sharedGateIsFIFOAcrossLaunchers` — FIFO ordering: three launchers on one
///   gate enqueue in order and receive the slot in that order.
/// - `sharedGateSkipsCancelledWaiterAndWakesNext` — release skips a dead waiter.
/// - `cancelledWaiterOnSharedGateSelfRemoves` — safety: a waiter that is cancelled
///   while queued on a shared gate self-removes cleanly; the holder's subsequent
///   release finds no live waiters and frees the slot without a stale handoff.
///
/// Generation-scoped model (Step 6 behavioral guarantees):
/// - `idleHolderDoesNotBlockPeer_modelsIngestBetweenTurns` — THE key regression
///   guard: an idle interactive session (not mid-turn) holds nothing, so ingest /
///   another session acquires immediately. Contrasts with the OLD spawn-gate model.
/// - `turnsInterleaveAcrossTwoSessions` — "only one generates at a time" across two
///   live sessions; turn 1/turn 2 interleaving is strictly serialized.
/// - `releaseGenerationSlotIsIdempotent` — double-release is a no-op; guarded by
///   `holdsGenerationSlot`, so a spurious second release does NOT hand the slot to a
///   waiting peer. Proven observable: a third waiter is NOT woken by the double call.
///
/// NOTE: `awaitGenerationSlot()` does NOT set `isRunning` (process lifetime is
/// decoupled from gate ownership in Step 6). Tests verify slot behavior via the
/// return value and `generationSlotWaiterCount`, not via `isRunning`.
///
/// The single-launcher generation slot tests remain in `AgentGenerationSlotTests.swift`.
@MainActor
struct GenerationGateTests {

    private func makeLauncher(gate: GenerationGate) -> AgentLauncher {
        let launcher = AgentLauncher(generationGate: gate)
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    private func makeLauncher() -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - Shared gate serializes across launcher instances

    /// The KEY Step-3 / Step-6 property: two launchers sharing one `GenerationGate`
    /// contend on the same FIFO queue.
    ///
    /// - A acquires the slot fast-path; `aAcquired` is true.
    /// - B (on a separate launcher, same gate) enqueues as a waiter;
    ///   `b.generationSlotWaiterCount` (which delegates to the shared gate) is 1,
    ///   `bAcquired` is pending — B has NOT generated yet.
    /// - A releases: the slot transfers atomically to B.
    /// - `bAcquired` is now true.
    ///
    /// NOTE: `isRunning` is NOT set by `awaitGenerationSlot()` — gate ownership and
    /// process lifetime are decoupled in Step 6. Only spawn commit sets `isRunning`.
    ///
    /// This locks in the AC "only one generates at a time" across DIFFERENT
    /// launchers — the guarantee that Ask / Edit / ingest serialize globally.
    @Test func sharedGateSerializesAcrossLaunchers() async {
        let gate = GenerationGate()
        let a = makeLauncher(gate: gate)
        let b = makeLauncher(gate: gate)

        // A acquires the shared slot (fast path — no contention yet).
        let aAcquired = await a.awaitGenerationSlot()
        #expect(aAcquired)
        // isRunning is NOT set by gate acquire (decoupled in Step 6).
        #expect(!a.isRunning)

        // B races for the slot — gate is held, so B suspends as a waiter.
        let bTask = Task { await b.awaitGenerationSlot() }
        // Yield twice: first to let bTask start, second to let it register its
        // continuation in the gate's waiter queue.
        await Task.yield()
        await Task.yield()

        // B is queued. `b.generationSlotWaiterCount` delegates to `gate.waiterCount`;
        // since A and B share the same gate instance, both see count == 1.
        #expect(b.generationSlotWaiterCount == 1)
        #expect(!b.isRunning)

        // A releases: atomic handoff — gate hands the slot to B without a window
        // where the fast path could sneak in a third launcher.
        a.releaseGenerationSlot()
        let bAcquired = await bTask.value
        #expect(bAcquired)
        // Neither launcher sets isRunning via gate acquire — that's set at spawn commit.
        #expect(!a.isRunning)
        #expect(!b.isRunning)

        b.releaseGenerationSlot()
    }

    // MARK: - Independent gates do not serialize

    /// Isolation / contrast proof: two launchers with SEPARATE default gates (each
    /// constructed via `AgentLauncher()`) contend on INDEPENDENT queues and can both
    /// hold the slot concurrently. Neither waits for the other.
    ///
    /// This ensures the shared-gate serialization is opt-in (via `init(generationGate:)`)
    /// and that adding a second launcher with its own gate does not accidentally
    /// block an unrelated launcher.
    @Test func independentGatesDoNotSerialize() async {
        let a = makeLauncher()  // owns its own GenerationGate()
        let b = makeLauncher()  // owns a different, independent GenerationGate()

        // Both acquire their respective gates with no contention.
        let aAcquired = await a.awaitGenerationSlot()
        let bAcquired = await b.awaitGenerationSlot()

        #expect(aAcquired)
        #expect(bAcquired)
        // Neither waited for the other.
        #expect(a.generationSlotWaiterCount == 0)
        #expect(b.generationSlotWaiterCount == 0)

        a.releaseGenerationSlot()
        b.releaseGenerationSlot()
    }

    // MARK: - Shared gate is FIFO across three launchers

    /// Three launchers A, B, C share one gate. A acquires first; B and C enqueue
    /// in that order. When A releases, B (the FIFO head) acquires — not C. When B
    /// releases, C acquires. The waiter count decrements correctly at each step.
    @Test func sharedGateIsFIFOAcrossLaunchers() async {
        let gate = GenerationGate()
        let a = makeLauncher(gate: gate)
        let b = makeLauncher(gate: gate)
        let c = makeLauncher(gate: gate)

        // A acquires the shared slot fast-path.
        let aAcquired = await a.awaitGenerationSlot()
        #expect(aAcquired)

        // B enqueues behind A.
        let bTask = Task { await b.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()

        // C enqueues behind B (yield again so B's continuation is registered first).
        let cTask = Task { await c.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()

        // Both B and C are waiting; order is B then C.
        #expect(a.generationSlotWaiterCount == 2)

        // A releases: FIFO hands the slot to B, not C.
        a.releaseGenerationSlot()
        let bAcquired = await bTask.value
        #expect(bAcquired)
        // C is still waiting.
        #expect(b.generationSlotWaiterCount == 1)

        // B releases: slot goes to C.
        b.releaseGenerationSlot()
        let cAcquired = await cTask.value
        #expect(cAcquired)
        #expect(c.generationSlotWaiterCount == 0)

        c.releaseGenerationSlot()
    }

    // MARK: - Shared gate skips a cancelled waiter and wakes the next

    /// With three launchers on one gate: A holds, B enqueues, C enqueues (count 2).
    /// Cancelling B's task causes it to self-remove (count 1). When A releases, the
    /// slot skips the dead B and goes directly to C.
    @Test func sharedGateSkipsCancelledWaiterAndWakesNext() async {
        let gate = GenerationGate()
        let a = makeLauncher(gate: gate)
        let b = makeLauncher(gate: gate)
        let c = makeLauncher(gate: gate)

        // A holds the slot.
        _ = await a.awaitGenerationSlot()

        // B enqueues behind A.
        let bTask = Task<Bool, Never> { await b.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()

        // C enqueues behind B.
        let cTask = Task { await c.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(a.generationSlotWaiterCount == 2)

        // Cancel B — it self-removes from the queue.
        bTask.cancel()
        let bAcquired = await bTask.value
        #expect(!bAcquired)
        #expect(a.generationSlotWaiterCount == 1)  // only C remains

        // A releases: slot must skip the dead B and go to C.
        a.releaseGenerationSlot()
        let cAcquired = await cTask.value
        #expect(cAcquired)
        #expect(c.generationSlotWaiterCount == 0)

        c.releaseGenerationSlot()
    }

    // MARK: - Cancelled waiter on shared gate self-removes

    /// A second launcher's `awaitGenerationSlot()` Task that is cancelled while
    /// queued behind the first launcher's held slot must:
    ///   - self-remove from the gate's waiter queue (count returns to 0),
    ///   - return false (B never acquired the slot),
    ///   - leave A's subsequent `releaseGenerationSlot` clean — no stale handoff.
    ///
    /// This mirrors `cancelledWaiterSelfRemovesAndDoesNotStealSlot` in
    /// `AgentGenerationSlotTests` but across two launchers on a shared gate.
    @Test func cancelledWaiterOnSharedGateSelfRemoves() async {
        let gate = GenerationGate()
        let a = makeLauncher(gate: gate)
        let b = makeLauncher(gate: gate)

        // A holds the slot.
        _ = await a.awaitGenerationSlot()

        // B waits behind A on the shared gate.
        let bTask = Task<Bool, Never> { await b.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(b.generationSlotWaiterCount == 1)

        // Cancel B's wait — the `onCancel` handler hops to the main actor,
        // removes B's waiter from the shared gate's queue, and resumes B's
        // continuation so `awaitGenerationSlot` returns false.
        bTask.cancel()
        let bAcquired = await bTask.value
        #expect(!bAcquired)          // cancelled before slot was granted
        #expect(!b.isRunning)        // B never set its own isRunning flag
        #expect(b.generationSlotWaiterCount == 0)  // B removed itself from the shared queue

        // A releases cleanly: no live waiters, gate's `held` flag cleared.
        a.releaseGenerationSlot()
        // Direct gate check confirms the shared queue is empty after the release.
        #expect(gate.waiterCount == 0)
    }

    // MARK: - Generation-scoped model: idle holder does not block peers

    /// THE key regression guard for the Step 6 semantic shift.
    ///
    /// In the OLD spawn-gate model an interactive session held the gate for its
    /// entire lifetime — so ingest (or a second session) was blocked even when the
    /// first session was sitting idle between turns.
    ///
    /// In the NEW generation-scoped model the gate is per-TURN: releasing at the
    /// turn boundary (`ingestStdout` endsGeneration / `finish()`) leaves the gate
    /// free even though the process is still alive. This test proves that guarantee:
    ///
    /// - `session` acquires (simulates a turn generating).
    /// - `session` releases at the turn boundary (session now idle — no process
    ///   lifecycle change, gate is free).
    /// - `ingest` acquires IMMEDIATELY via the fast path (zero suspension); the
    ///   waiter count stays 0, proving no queuing occurred.
    @Test func idleHolderDoesNotBlockPeer_modelsIngestBetweenTurns() async {
        let gate = GenerationGate()
        let session = makeLauncher(gate: gate)
        let ingest = makeLauncher(gate: gate)

        // Session acquires the slot for its turn (simulates the send → endsGeneration arc).
        let sessionAcquired = await session.awaitGenerationSlot()
        #expect(sessionAcquired)

        // Turn boundary: session releases. Process stays "alive" (isRunning would be
        // true in production) but the gate is free — this is the key Step 6 property.
        session.releaseGenerationSlot()

        // With the old spawn-gate model the gate would still be held here and ingest
        // would suspend. With the generation-scoped model the fast path runs.
        let ingestAcquired = await ingest.awaitGenerationSlot()
        #expect(ingestAcquired)
        // No queuing: fast path. Proves idle session does NOT block peer.
        #expect(ingest.generationSlotWaiterCount == 0)

        ingest.releaseGenerationSlot()
    }

    // MARK: - Generation-scoped model: turn interleaving across two live sessions

    /// Models "only one generates at a time" with both sessions persisting across
    /// multiple turns. Each turn is serialized through the shared gate; between turns
    /// the gate is free and the next turn (from either session) can run immediately.
    ///
    /// Sequence:
    ///   ask turn 1 → edit queues → ask releases → edit acquires → edit releases
    ///   → ask turn 2 acquires immediately (fast path, no queuing).
    @Test func turnsInterleaveAcrossTwoSessions() async {
        let gate = GenerationGate()
        let ask = makeLauncher(gate: gate)
        let edit = makeLauncher(gate: gate)

        // ask starts turn 1.
        let askTurn1 = await ask.awaitGenerationSlot()
        #expect(askTurn1)

        // edit tries to generate concurrently — must queue (only one generates at a time).
        let editTask = Task { await edit.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(ask.generationSlotWaiterCount == 1)

        // ask turn 1 ends → slot transfers atomically to edit.
        ask.releaseGenerationSlot()
        let editAcquired = await editTask.value
        #expect(editAcquired)
        #expect(edit.generationSlotWaiterCount == 0)

        // edit turn ends → gate is free. ask starts turn 2 on the fast path.
        edit.releaseGenerationSlot()
        let askTurn2 = await ask.awaitGenerationSlot()
        #expect(askTurn2)
        // Fast path: no queuing for ask's next turn (gate was free).
        #expect(ask.generationSlotWaiterCount == 0)

        ask.releaseGenerationSlot()
    }

    // MARK: - Idempotent release: double-call is a no-op

    /// `releaseGenerationSlot()` is guarded by the private `holdsGenerationSlot`
    /// flag so a double-call is a no-op — it does NOT hand the slot to the next
    /// waiter a second time.
    ///
    /// The test makes the bug observable: with A, B, C queued in that order,
    ///   A.release() → B acquires (C still waiting, count == 1).
    ///   A.release() AGAIN → no-op; C must NOT be woken prematurely (count still 1).
    ///   B.release() → C acquires normally.
    ///
    /// A buggy implementation (no `holdsGenerationSlot` guard) would call
    /// `gate.release()` on the spurious second call, waking C early and leaving B
    /// holding the slot while C also thinks it holds the slot — a double-generation.
    @Test func releaseGenerationSlotIsIdempotent() async {
        let gate = GenerationGate()
        let a = makeLauncher(gate: gate)
        let b = makeLauncher(gate: gate)
        let c = makeLauncher(gate: gate)

        // A holds the slot.
        _ = await a.awaitGenerationSlot()

        // B enqueues behind A.
        let bTask = Task { await b.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()

        // C enqueues behind B.
        let cTask = Task { await c.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(a.generationSlotWaiterCount == 2)

        // A's first release hands the slot to B (FIFO).
        a.releaseGenerationSlot()
        let bAcquired = await bTask.value
        #expect(bAcquired)
        // C is still waiting.
        #expect(b.generationSlotWaiterCount == 1)

        // A's spurious second release must be a no-op — `holdsGenerationSlot` is
        // false so the guard exits immediately and `gate.release()` is never called.
        a.releaseGenerationSlot()
        // C must still be waiting — it was NOT woken by the spurious release.
        #expect(b.generationSlotWaiterCount == 1)

        // B releases properly: C acquires.
        b.releaseGenerationSlot()
        let cAcquired = await cTask.value
        #expect(cAcquired)
        #expect(c.generationSlotWaiterCount == 0)

        c.releaseGenerationSlot()
    }
}
#endif
