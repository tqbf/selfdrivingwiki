import Testing
import Foundation
@testable import WikiFS
@testable import WikiFSCore

/// Stop-path audit + stall recovery (1c from `plans/acp-stall-recovery.md`).
///
/// Tests the recovery mechanisms that fire when an ACP turn stalls:
/// - `ACPBackendError` messages are user-readable
/// - `turnEndEvents` with a stall error synthesizes `.messageStop` (the
///   generation-ending event the launcher keys off)
/// - `FakeAgentBackend` with `neverFinish` simulates the stall correctly
@Suite struct ACPStallRecoveryTests {

    /// A stalled `send` (never finishes) yields events but the stream stays
    /// open — simulating a `sendPrompt` that never returns (#334 symptom).
    @Test func neverFinishYieldsEventsWithoutEndingTurn() async throws {
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.assistantTextDelta("partial…")], neverFinish: true)
        ])

        let session = try await backend.start(
            profile: BackendProfile(model: ""),
            systemPrompt: "",
            onExit: { _ in }
        )

        let stream = await backend.send(
            TurnInput(userText: "hello"), into: session)

        // Collect events — since the stream never finishes, we must break
        // manually after receiving the expected events (like the launcher's
        // consumer loop would on `.messageStop`, except here there is none).
        var received: [AgentEvent] = []
        let collectTask = Task<[AgentEvent], Never> {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
                if events.count >= 1 { break } // got the partial event
            }
            return events
        }
        let events = await collectTask.value
        received = events

        // The partial event was received.
        #expect(received.count == 1)

        // No `.messageStop` was emitted — the turn didn't end naturally.
        // (In the real ACPBackend, the watchdog would synthesize one.)
        #expect(received.contains(.messageStop) == false)

        // The backend's cancel is called (like stopAgent → backend.cancel).
        await backend.cancel(session)
        #expect(await backend.cancelCount == 1)
    }

    /// A normal (finishing) `send` is unaffected — the consumer exits on its
    /// own when the stream finishes, no cancellation needed.
    @Test func normalTurnIsUnaffectedByStallInfrastructure() async throws {
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.assistantTextDelta("done"), .messageStop])
        ])

        let session = try await backend.start(
            profile: BackendProfile(model: ""),
            systemPrompt: "",
            onExit: { _ in }
        )

        let stream = await backend.send(
            TurnInput(userText: "hello"), into: session)

        var received: [AgentEvent] = []
        for await event in stream {
            received.append(event)
        }

        // Normal turn: all events received, loop exited naturally.
        #expect(received.count == 2)
        #expect(received.last == .messageStop)
        #expect(AgentEvent.endsGeneration(.messageStop) == true)
    }

    /// `ACPBackendError.turnStalled` produces a user-readable error message.
    @Test func turnStalledErrorIsDescriptive() {
        let error = ACPBackendError.turnStalled(idleSeconds: 137)
        let message = error.errorDescription ?? ""
        #expect(message.contains("stalled"))
        #expect(message.contains("137"))
        #expect(message.contains("cancelled"))
    }

    /// `ACPBackendError.turnCeilingExceeded` produces a user-readable error
    /// message.
    @Test func turnCeilingErrorIsDescriptive() {
        let error = ACPBackendError.turnCeilingExceeded(totalSeconds: 1800)
        let message = error.errorDescription ?? ""
        #expect(message.contains("maximum"))
        #expect(message.contains("1800"))
    }

    /// `turnEndEvents` with a stall error produces the expected sequence:
    /// a `.raw` line carrying the message, then `.messageStop` — the exact
    /// sequence the watchdog yields to end a stalled turn. This reuses the
    /// existing synthesis path, so the consumer's `for await` exits, the
    /// generation gate releases, and the user sees an error line.
    @Test func turnEndEventsForStallSynthesizeMessageStop() {
        let error = ACPBackendError.turnStalled(idleSeconds: 120)
        let events = ACPBackend.turnEndEvents(error: error)

        #expect(events.count == 2)
        // First: a raw line carrying the error message.
        if case .raw(let text) = events[0] {
            #expect(text.contains("stalled"))
        } else {
            Issue.record("expected .raw event, got \(events[0])")
        }
        // Second: .messageStop (the generation-ending event).
        #expect(events[1] == .messageStop)
        #expect(AgentEvent.endsGeneration(events[1]) == true)
    }

    /// `turnEndEvents` with a ceiling error also synthesizes `.messageStop`.
    @Test func turnEndEventsForCeilingSynthesizeMessageStop() {
        let error = ACPBackendError.turnCeilingExceeded(totalSeconds: 1800)
        let events = ACPBackend.turnEndEvents(error: error)

        #expect(events.count == 2)
        if case .raw(let text) = events[0] {
            #expect(text.contains("maximum"))
        } else {
            Issue.record("expected .raw event, got \(events[0])")
        }
        #expect(events[1] == .messageStop)
        #expect(AgentEvent.endsGeneration(events[1]) == true)
    }
}
