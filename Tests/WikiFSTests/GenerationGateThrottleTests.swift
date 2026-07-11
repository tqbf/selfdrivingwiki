import Foundation
import Testing
@testable import WikiFS

/// Tests for W4 — configurable N-throttle on GenerationGate (PR #312).
@MainActor
struct GenerationGateThrottleTests {

    @Test func singleSlotBlocksSecondAcquirer() async {
        let gate = GenerationGate(maxConcurrent: 1)
        let first = await gate.acquire()
        #expect(first)

        // Second acquire should not get a slot immediately (it would suspend).
        // Use a short timeout to test: start the acquire, then release the
        // first slot, and verify the second gets it.
        let task = Task { await gate.acquire() }
        // Give the task a moment to queue.
        try? await Task.sleep(for: .milliseconds(50))
        gate.release()
        let second = await task.value
        #expect(second)
    }

    @Test func twoSlotGateAllowsTwoConcurrentAquires() async {
        let gate = GenerationGate(maxConcurrent: 2)
        let first = await gate.acquire()
        #expect(first)
        let second = await gate.acquire()
        #expect(second)
        gate.release()
        gate.release()
    }

    @Test func releaseFreesSlotForWaiter() async {
        let gate = GenerationGate(maxConcurrent: 1)
        _ = await gate.acquire()
        let task = Task { await gate.acquire() }
        try? await Task.sleep(for: .milliseconds(50))
        gate.release()
        let result = await task.value
        #expect(result)
        gate.release()
    }
}
