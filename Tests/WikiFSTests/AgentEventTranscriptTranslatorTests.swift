#if canImport(WikiFSEngine)
import Testing
import WikiFSCore
import WikiFSEngine

struct AgentEventTranscriptTranslatorTests {
    @Test func assistantStreamUpdatesOneStableMessage() {
        let turnID = ChatTurnID(rawValue: "turn-assistant-stream")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([.assistantTextDelta("Hello")], turnID: turnID)
            + translator.translate([.assistantTextDelta(" world")], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)

        guard items.count == 1, case .message(let message)? = items.first else {
            Issue.record("expected one assistant message")
            return
        }
        #expect(message.messageID == ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-0"))
        #expect(message.role == .assistant)
        #expect(message.text == "Hello world")
        #expect(translator.activeContentBlock?.messageID == message.messageID)
    }

    @Test func reasoningStreamUpdatesOneStableMessage() {
        let turnID = ChatTurnID(rawValue: "turn-reasoning-stream")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([.thinkingDelta("Need")], turnID: turnID)
            + translator.translate([.thinkingDelta(" context")], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)

        guard items.count == 1, case .message(let message)? = items.first else {
            Issue.record("expected one reasoning message")
            return
        }
        #expect(message.messageID == ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)-block-0"))
        #expect(message.role == .reasoning)
        #expect(message.text == "Need context")
        #expect(translator.activeContentBlock?.messageID == message.messageID)
    }

    @Test func fullReplacementPreservesMessageIdentity() {
        let turnID = ChatTurnID(rawValue: "turn-replacement")
        var translator = AgentEventTranscriptTranslator()
        let initial = translator.translate([.assistantTextDelta("Partial")], turnID: turnID)
        let replacement = translator.translate([.assistantText("Final")], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: initial + replacement)

        guard items.count == 1, case .message(let message)? = items.first else {
            Issue.record("expected one replaced assistant message")
            return
        }
        #expect(message.messageID == ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-0"))
        #expect(message.text == "Final")
        #expect(translator.activeContentBlock == nil)
    }

    @Test func toolResultUpdatesTheMatchingFIFOCall() {
        let turnID = ChatTurnID(rawValue: "turn-tool-fifo")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([
            .toolUse(name: "Read", inputSummary: "first.md"),
            .toolUse(name: "Edit", inputSummary: "second.md"),
            .toolResult(isError: false, summary: "first result"),
            .toolResult(isError: true, summary: "second result"),
        ], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)
        let toolCalls = items.compactMap { item -> ChatTranscriptToolCallItem? in
            guard case .toolCall(let toolCall) = item else { return nil }
            return toolCall
        }

        #expect(toolCalls.map(\.toolCallID) == [
            ToolCallID(rawValue: "\(turnID.rawValue)-tool-0"),
            ToolCallID(rawValue: "\(turnID.rawValue)-tool-1"),
        ])
        #expect(toolCalls.map(\.toolName) == ["Read", "Edit"])
        #expect(toolCalls.map(\.detail) == ["first.md", "second.md"])
        #expect(toolCalls.map(\.output) == ["first result", "second result"])
        #expect(toolCalls.map(\.status) == [.completed, .failed])
    }

    @Test func unmatchedToolResultPreservesTheLegacyFallbackIdentity() {
        let turnID = ChatTurnID(rawValue: "turn-tool-fallback")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([
            .toolResult(isError: false, summary: "orphaned result"),
            .toolUse(name: "Read", inputSummary: "later.md"),
        ], turnID: turnID)

        guard deltas.count == 2,
              case .toolCallUpsert(let fallback) = deltas[0],
              case .toolCallUpsert(let nextUse) = deltas[1] else {
            Issue.record("expected fallback and later tool upserts")
            return
        }
        #expect(fallback.toolCallID == ToolCallID(rawValue: "\(turnID.rawValue)-tool-0"))
        #expect(fallback.toolName == "Tool")
        #expect(fallback.status == .completed)
        #expect(nextUse.toolCallID == fallback.toolCallID)
        #expect(nextUse.toolName == "Read")
        #expect(nextUse.status == .running)
    }

    @Test func userTextAppendsATypedUserMessage() {
        let turnID = ChatTurnID(rawValue: "turn-user")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([.userText("Hello")], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)

        guard items.count == 1, case .message(let message)? = items.first else {
            Issue.record("expected one user message")
            return
        }
        #expect(message.turnID == turnID)
        #expect(message.role == .user)
        #expect(message.text == "Hello")
        #expect(translator.activeContentBlock == nil)
    }

    @Test func turnFailureProducesTypedFailure() {
        let turnID = ChatTurnID(rawValue: "turn-failure")
        var translator = AgentEventTranscriptTranslator()
        let reason = TurnFailureReason.quotaExhausted(
            provider: ProviderID(rawValue: "provider-failure"),
            resetTime: nil
        )
        let deltas = translator.translate([.turnFailed(reason: reason)], turnID: turnID)
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)

        guard items.count == 1, case .turnFailure(let failure)? = items.first else {
            Issue.record("expected one turn failure")
            return
        }
        #expect(failure.turnID == turnID)
        #expect(failure.category == .transportError)
        #expect(failure.message == reason.description)
        #expect(translator.activeContentBlock == nil)
    }

    @Test func failureCategoriesPreserveExistingMappings() {
        #expect(AgentEventTranscriptTranslator.failureCategory(for: .stalled(idleSeconds: 1)) == .interrupted)
        #expect(AgentEventTranscriptTranslator.failureCategory(for: .ceilingExceeded(totalSeconds: 1)) == .interrupted)
        #expect(AgentEventTranscriptTranslator.failureCategory(for: .agentError("failure")) == .runtimeError)
        #expect(AgentEventTranscriptTranslator.failureCategory(for: .quotaExhausted(
            provider: ProviderID(rawValue: "provider-failure"),
            resetTime: nil
        )) == .transportError)
    }

    @Test func ignoredEventsProduceNoDelta() {
        let turnID = ChatTurnID(rawValue: "turn-ignored")
        var translator = AgentEventTranscriptTranslator()
        _ = translator.translate([.assistantTextDelta("partial")], turnID: turnID)
        let deltas = translator.translate([
            .systemInit(model: "model"),
            .subagent(subagentType: "worker", description: "work", isCompletion: false),
            .result(isError: false, text: "complete"),
            .messageStop,
            .raw("wire"),
        ], turnID: turnID)

        #expect(deltas.isEmpty)
        #expect(translator.activeContentBlock == nil)
    }

    @Test func queueAttemptCreatesDeterministicDistinctIdentities() {
        let firstAttempt = ChatTurnID(rawValue: "queue:item-1:attempt:1")
        let secondAttempt = ChatTurnID(rawValue: "queue:item-1:attempt:2")
        var firstTranslator = AgentEventTranscriptTranslator()
        var secondTranslator = AgentEventTranscriptTranslator()
        let first = firstTranslator.translate([.assistantTextDelta("first")], turnID: firstAttempt)
        let second = secondTranslator.translate([.assistantTextDelta("second")], turnID: secondAttempt)

        guard first.count == 1,
              second.count == 1,
              case .messageReplacement(let firstID, _, _, _, _)? = first.first,
              case .messageReplacement(let secondID, _, _, _, _)? = second.first else {
            Issue.record("expected deterministic message replacements")
            return
        }
        #expect(firstID == ChatMessageID(rawValue: "assistant-\(firstAttempt.rawValue)-block-0"))
        #expect(secondID == ChatMessageID(rawValue: "assistant-\(secondAttempt.rawValue)-block-0"))
        #expect(firstID != secondID)
    }

    @Test func terminalEventsStartNewContentBlocks() {
        let turnID = ChatTurnID(rawValue: "turn-content-boundary")
        var translator = AgentEventTranscriptTranslator()
        let deltas = translator.translate([
            .assistantTextDelta("Partial"),
            .assistantText("First block"),
            .assistantTextDelta("Second block"),
        ], turnID: turnID)
        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.map(\.text) == ["First block", "Second block"])
        #expect(messages.map(\.messageID) == [
            ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-0"),
            ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-1"),
        ])
    }
}
#endif
