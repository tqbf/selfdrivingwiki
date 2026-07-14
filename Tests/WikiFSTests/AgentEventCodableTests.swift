import Testing
import Foundation
@testable import WikiFSCore

/// `AgentEvent` is `Codable` (synthesized) so persisted chat history can store
/// each event verbatim as JSON (`chat_messages.event_json`) and re-render it
/// through the exact same typed pipeline as the live transcript. This proves
/// every case — including the non-persistable stream-bookkeeping ones, which
/// still need to round-trip correctly even though the store never writes them
/// — survives an encode→decode round trip with its associated values intact.
@Suite struct AgentEventCodableTests {

    private func roundTrip(_ event: AgentEvent) throws -> AgentEvent {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(AgentEvent.self, from: data)
    }

    @Test func userTextRoundTrips() throws {
        let event = AgentEvent.userText("What does this page say?")
        #expect(try roundTrip(event) == event)
    }

    @Test func systemInitRoundTrips() throws {
        let event = AgentEvent.systemInit(model: "claude-opus-4")
        #expect(try roundTrip(event) == event)
    }

    @Test func assistantTextRoundTrips() throws {
        let event = AgentEvent.assistantText("Here's the answer.")
        #expect(try roundTrip(event) == event)
    }

    @Test func assistantTextDeltaRoundTrips() throws {
        let event = AgentEvent.assistantTextDelta("Here")
        #expect(try roundTrip(event) == event)
    }

    @Test func toolUseRoundTrips() throws {
        let event = AgentEvent.toolUse(name: "Bash", inputSummary: "wikictl page upsert --title \"X\"")
        #expect(try roundTrip(event) == event)
    }

    @Test func toolResultRoundTrips() throws {
        let event = AgentEvent.toolResult(isError: true, summary: "command not found")
        #expect(try roundTrip(event) == event)
    }

    @Test func subagentRoundTrips() throws {
        let event = AgentEvent.subagent(
            subagentType: "source-reader", description: "Digest pages 1-20", isCompletion: false)
        #expect(try roundTrip(event) == event)
    }

    @Test func resultRoundTrips() throws {
        let event = AgentEvent.result(isError: false, text: "Done.")
        #expect(try roundTrip(event) == event)
    }

    @Test func messageStopRoundTrips() throws {
        let event = AgentEvent.messageStop
        #expect(try roundTrip(event) == event)
    }

    @Test func rawRoundTrips() throws {
        let event = AgentEvent.raw("{\"type\":\"unknown\"}")
        #expect(try roundTrip(event) == event)
    }

    @Test func turnFailedStalledRoundTrips() throws {
        let event = AgentEvent.turnFailed(reason: .stalled(idleSeconds: 130))
        #expect(try roundTrip(event) == event)
    }

    @Test func turnFailedCeilingRoundTrips() throws {
        let event = AgentEvent.turnFailed(reason: .ceilingExceeded(totalSeconds: 1800))
        #expect(try roundTrip(event) == event)
    }

    @Test func turnFailedAgentErrorRoundTrips() throws {
        let event = AgentEvent.turnFailed(reason: .agentError("connection refused"))
        #expect(try roundTrip(event) == event)
    }
}
