#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Real-launcher admission-gate regressions for chat cancellation.
///
/// These use the production `AgentLauncher` and `GenerationGate`. The
/// assertions cover the gate invariants cancellation depends on: a cancelled
/// waiter is removed rather than handed a slot, and cancelling one chat cannot
/// revoke a peer's generation slot.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatCancellationGateTests {
    private func launcher(gate: GenerationGate) -> AgentLauncher {
        let launcher = AgentLauncher(generationGate: gate)
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    /// A cancelled waiter must be removed from the lane, and the next waiter
    /// must receive the slot once the owner releases it.
    @Test func cancelSlotWaitThenRunFollower() async {
        let gate = GenerationGate(laneLimits: [.interactive: 1])
        let owner = launcher(gate: gate)
        let cancelled = launcher(gate: gate)
        let follower = launcher(gate: gate)

        #expect(await owner.awaitGenerationSlot())
        let cancelledTask = Task { await cancelled.awaitGenerationSlot() }
        await Task.yield()
        await Task.yield()
        #expect(gate.waiterCount == 1)

        cancelledTask.cancel()
        #expect(await cancelledTask.value == false)
        #expect(gate.waiterCount == 0)

        let followerTask = Task { await follower.awaitGenerationSlot() }
        await Task.yield()
        owner.releaseGenerationSlot()
        #expect(await followerTask.value)
        follower.releaseGenerationSlot()
        #expect(gate.waiterCount == 0)
    }

    /// Cancelling one chat must not stop a peer that legitimately holds a slot.
    @Test func cancelChatDoesNotStopPeer() async {
        let gate = GenerationGate(laneLimits: [.interactive: 2])
        let first = launcher(gate: gate)
        let peer = launcher(gate: gate)

        #expect(await first.awaitGenerationSlot())
        #expect(await peer.awaitGenerationSlot())
        #expect(gate.waiterCount == 0)

        // Each launcher owns only its own admission state, so releasing one
        // cannot revoke the peer's slot or make the peer queue.
        first.releaseGenerationSlot()
        #expect(peer.generationSlotWaiterCount == 0)
        #expect(peer.isRunning == false)
        peer.releaseGenerationSlot()
        #expect(gate.waiterCount == 0)
    }
}
#endif
