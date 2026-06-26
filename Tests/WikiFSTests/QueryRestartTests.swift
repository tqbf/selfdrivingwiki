import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for `AgentOperationRunner.transcriptContextMessage` — the opening context
/// built when a query session is restarted in a different edit mode, so the new
/// claude process keeps conversational context (a new process has no memory of the
/// old one). Pure formatting; no process spawned.
struct QueryRestartTests {

    @Test func emptyTranscriptProducesModeNoteOnly() {
        let msg = AgentOperationRunner.transcriptContextMessage(from: [], allowWikiEdits: true)
        #expect(msg.contains("wiki edits are now ALLOWED"))
        // No turns → no "prior conversation" body.
        #expect(!msg.contains("prior conversation"))
    }

    @Test func carriesUserAndAssistantProse() {
        let events: [AgentEvent] = [
            .userText("What is photosynthesis?"),
            .assistantText("It is how plants make food."),
        ]
        let msg = AgentOperationRunner.transcriptContextMessage(from: events, allowWikiEdits: false)
        #expect(msg.contains("User: What is photosynthesis?"))
        #expect(msg.contains("Assistant: It is how plants make food."))
        #expect(msg.contains("read-only"))
        #expect(msg.contains("do not re-answer it"))
    }

    @Test func carriesResultTextAsAssistant() {
        let msg = AgentOperationRunner.transcriptContextMessage(
            from: [.result(isError: false, text: "Final answer.")], allowWikiEdits: true)
        #expect(msg.contains("Assistant: Final answer."))
    }

    @Test func dropsToolCallsSystemBookkeepingAndEmptyResult() {
        let events: [AgentEvent] = [
            .systemInit(model: "claude"),
            .userText("hi"),
            .toolUse(name: "Bash", inputSummary: "ZZTOOLINPUT"),
            .toolResult(isError: false, summary: "ZZTOOLRESULT"),
            .result(isError: false, text: ""),   // empty result is dropped
            .messageStop,
            .raw("ZZRAWLINE"),
            .assistantText("hello"),
        ]
        let msg = AgentOperationRunner.transcriptContextMessage(from: events, allowWikiEdits: true)
        // Carried.
        #expect(msg.contains("User: hi"))
        #expect(msg.contains("Assistant: hello"))
        // Dropped (unique markers so the substring checks can't false-positive).
        #expect(!msg.contains("Bash"))
        #expect(!msg.contains("ZZTOOLINPUT"))
        #expect(!msg.contains("ZZTOOLRESULT"))
        #expect(!msg.contains("claude"))   // systemInit model
        #expect(!msg.contains("ZZRAWLINE"))
    }

    @Test func modeStringReflectsEditFlag() {
        let on = AgentOperationRunner.transcriptContextMessage(from: [.userText("x")], allowWikiEdits: true)
        let off = AgentOperationRunner.transcriptContextMessage(from: [.userText("x")], allowWikiEdits: false)
        #expect(on.contains("ALLOWED"))
        #expect(off.contains("read-only"))
    }
}
