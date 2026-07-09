import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFS

/// Tests for `[AgentEvent].transcriptVisible`, the filter shared by the live
/// Query page (`ChatTranscriptView`) and the read-only chat-history view
/// (`ChatHistoryDetailView`) so a persisted chat re-renders exactly
/// like it looked live.
struct ChatTranscriptFilterTests {

    @Test func userTextPasses() {
        let events: [AgentEvent] = [.userText("hello")]
        #expect(events.transcriptVisible == events)
    }

    @Test func assistantTextPasses() {
        let events: [AgentEvent] = [.assistantText("hi there")]
        #expect(events.transcriptVisible == events)
    }

    @Test func toolUsePasses() {
        let events: [AgentEvent] = [.toolUse(name: "Bash", inputSummary: "ls")]
        #expect(events.transcriptVisible == events)
    }

    @Test func nonErrorToolResultIsDropped() {
        let events: [AgentEvent] = [.toolResult(isError: false, summary: "ok")]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func errorToolResultIsKept() {
        let events: [AgentEvent] = [.toolResult(isError: true, summary: "boom")]
        #expect(events.transcriptVisible == events)
    }

    @Test func resultDuplicatingAssistantTextIsDropped() {
        let events: [AgentEvent] = [
            .assistantText("The final answer."),
            .result(isError: false, text: "The final answer."),
        ]
        #expect(events.transcriptVisible == [.assistantText("The final answer.")])
    }

    @Test func resultDuplicatingAssistantTextIgnoresSurroundingWhitespace() {
        let events: [AgentEvent] = [
            .assistantText("The final answer."),
            .result(isError: false, text: "  The final answer.  \n"),
        ]
        #expect(events.transcriptVisible == [.assistantText("The final answer.")])
    }

    @Test func resultWithNovelTextIsKept() {
        let events: [AgentEvent] = [
            .assistantText("Some other prose."),
            .result(isError: false, text: "A different final report."),
        ]
        #expect(events.transcriptVisible == events)
    }

    @Test func messageStopIsDropped() {
        let events: [AgentEvent] = [.messageStop]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func assistantTextDeltaIsDropped() {
        let events: [AgentEvent] = [.assistantTextDelta("partial")]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func rawIsDropped() {
        let events: [AgentEvent] = [.raw("{\"type\":\"unknown\"}")]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func systemInitIsDropped() {
        // isInternalTranscriptEvent: true — pinned so a future change to that
        // predicate is caught here too, not just in AgentActivityView.
        let events: [AgentEvent] = [.systemInit(model: "claude-opus")]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func subagentIsDropped() {
        let events: [AgentEvent] = [
            .subagent(subagentType: "source-reader", description: "digest.pdf", isCompletion: false)
        ]
        #expect(events.transcriptVisible.isEmpty)
    }

    @Test func fullTurnFiltersToUserAssistantAndToolUse() {
        let events: [AgentEvent] = [
            .systemInit(model: "claude-opus"),
            .userText("What's in the wiki?"),
            .toolUse(name: "Read", inputSummary: "page.md"),
            .toolResult(isError: false, summary: "contents"),
            .assistantText("Here's what's in the wiki."),
            .messageStop,
            .result(isError: false, text: "Here's what's in the wiki."),
        ]
        #expect(events.transcriptVisible == [
            .userText("What's in the wiki?"),
            .toolUse(name: "Read", inputSummary: "page.md"),
            .assistantText("Here's what's in the wiki."),
        ])
    }
}
