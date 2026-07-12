import Foundation
import Testing
@testable import WikiFS

/// Tests for Phase 2: lane-aware generation gate (`#multi-writer-hardening`).
///
/// The gate is split into two independent lanes (`.ingest`, `.interactive`),
/// each with its own concurrency limit and FIFO queue. Acquiring on one lane
/// never blocks the other. Cancellation safety is preserved per-lane: a
/// cancelled waiter self-removes and is never handed a slot.
@MainActor
@Suite(.tags(.integration))
struct GenerationGateLaneTests {

    // MARK: - AC2.1: interactive acquires during ingest

    @Test func interactiveAcquiresDuringIngest() async {
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])

        // Hold the ingest lane.
        let ingestAcquired = await gate.acquire(.ingest)
        #expect(ingestAcquired)

        // An interactive turn should acquire immediately (different lane).
        let interactiveAcquired = await gate.acquire(.interactive)
        #expect(interactiveAcquired)

        // Both lanes have one active.
        #expect(gate.activeCount(for: .ingest) == 1)
        #expect(gate.activeCount(for: .interactive) == 1)

        gate.release(.ingest)
        gate.release(.interactive)
    }

    // MARK: - AC2.2: second ingest queues until first releases (FIFO)

    @Test func secondIngestQueuesFIFO() async {
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])

        // First ingest acquires immediately.
        let first = await gate.acquire(.ingest)
        #expect(first)
        #expect(gate.activeCount(for: .ingest) == 1)

        // Second ingest should queue (limit 1).
        async let secondResult: Bool = gate.acquire(.ingest)
        // Give the waiter time to enqueue.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(gate.waiterCount(for: .ingest) == 1)

        // Release the first — the second should acquire.
        gate.release(.ingest)
        let second = await secondResult
        #expect(second)

        gate.release(.ingest)
    }

    // MARK: - AC2.3: cancelled waiter never receives or leaks a slot

    @Test func cancelledWaiterNeverLeaksSlot() async {
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 1])

        // Hold both lanes.
        let ingestHeld = await gate.acquire(.ingest)
        #expect(ingestHeld)
        let interactiveHeld = await gate.acquire(.interactive)
        #expect(interactiveHeld)

        // Queue a cancelled waiter on each lane.
        let cancelledIngest = Task<Bool, Never> {
            await gate.acquire(.ingest)
        }
        let cancelledInteractive = Task<Bool, Never> {
            await gate.acquire(.interactive)
        }
        // Let them enqueue.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(gate.waiterCount(for: .ingest) == 1)
        #expect(gate.waiterCount(for: .interactive) == 1)

        cancelledIngest.cancel()
        cancelledInteractive.cancel()

        // Wait for cancellation to propagate.
        let ingestResult = await cancelledIngest.value
        let interactiveResult = await cancelledInteractive.value
        #expect(ingestResult == false)
        #expect(interactiveResult == false)

        // The waiters should have self-removed.
        #expect(gate.waiterCount(for: .ingest) == 0)
        #expect(gate.waiterCount(for: .interactive) == 0)

        // Slots are still held by the originals — releasing should free them
        // (not hand to the cancelled waiters).
        gate.release(.ingest)
        gate.release(.interactive)
        #expect(gate.activeCount(for: .ingest) == 0)
        #expect(gate.activeCount(for: .interactive) == 0)
    }

    // MARK: - AC2.4: lane limits are constructor-configurable

    @Test func laneLimitsConfigurable() async {
        let gate = GenerationGate(laneLimits: [.ingest: 2, .interactive: 5])

        // Should allow 2 concurrent ingests.
        let i1 = await gate.acquire(.ingest)
        let i2 = await gate.acquire(.ingest)
        #expect(i1 && i2)
        #expect(gate.activeCount(for: .ingest) == 2)

        // Should allow 5 concurrent interactive.
        for _ in 0..<5 {
            let acquired = await gate.acquire(.interactive)
            #expect(acquired)
        }
        #expect(gate.activeCount(for: .interactive) == 5)

        // A sixth interactive should queue.
        let sixth = Task<Bool, Never> { await gate.acquire(.interactive) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(gate.waiterCount(for: .interactive) == 1)

        // But a third ingest should also queue (limit 2).
        let third = Task<Bool, Never> { await gate.acquire(.ingest) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(gate.waiterCount(for: .ingest) == 1)

        // Cross-lane: releasing an interactive slot doesn't help the ingest waiter.
        gate.release(.interactive)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(gate.waiterCount(for: .ingest) == 1)

        // Clean up: cancel the pending waiters.
        sixth.cancel()
        third.cancel()
        _ = await sixth.value
        _ = await third.value

        // Release remaining slots.
        gate.release(.ingest)
        gate.release(.ingest)
        for _ in 0..<4 { gate.release(.interactive) }
    }

    // MARK: - waiterCount sums across lanes

    @Test func waiterCountSumsAcrossLanes() async {
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 1])

        // Hold both lanes.
        _ = await gate.acquire(.ingest)
        _ = await gate.acquire(.interactive)

        // Queue one waiter on each lane.
        let w1 = Task<Bool, Never> { await gate.acquire(.ingest) }
        let w2 = Task<Bool, Never> { await gate.acquire(.interactive) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(gate.waiterCount == 2)

        // Clean up.
        w1.cancel()
        w2.cancel()
        _ = await w1.value
        _ = await w2.value
        gate.release(.ingest)
        gate.release(.interactive)
    }
}
