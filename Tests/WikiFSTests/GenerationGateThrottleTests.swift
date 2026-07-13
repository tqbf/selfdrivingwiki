import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for W4 — configurable N-throttle on GenerationGate (PR #312).
///
/// Updated for Phase 2: `acquire`/`release` now require a lane argument.
/// These tests use the `.interactive` lane (the `init(maxConcurrent:)`
/// convenience seeds it as the sole lane).
@MainActor
struct GenerationGateThrottleTests {

    @Test func singleSlotBlocksSecondAcquirer() async {
        let gate = GenerationGate(maxConcurrent: 1)
        let first = await gate.acquire(.interactive)
        #expect(first)

        // Second acquire should not get a slot immediately (it would suspend).
        // Use a short timeout to test: start the acquire, then release the
        // first slot, and verify the second gets it.
        let task = Task { await gate.acquire(.interactive) }
        // Give the task a moment to queue.
        try? await Task.sleep(for: .milliseconds(50))
        gate.release(.interactive)
        let second = await task.value
        #expect(second)
    }

    @Test func twoSlotGateAllowsTwoConcurrentAquires() async {
        let gate = GenerationGate(maxConcurrent: 2)
        let first = await gate.acquire(.interactive)
        #expect(first)
        let second = await gate.acquire(.interactive)
        #expect(second)
        gate.release(.interactive)
        gate.release(.interactive)
    }

    @Test func releaseFreesSlotForWaiter() async {
        let gate = GenerationGate(maxConcurrent: 1)
        _ = await gate.acquire(.interactive)
        let task = Task { await gate.acquire(.interactive) }
        try? await Task.sleep(for: .milliseconds(50))
        gate.release(.interactive)
        let result = await task.value
        #expect(result)
        gate.release(.interactive)
    }
}
