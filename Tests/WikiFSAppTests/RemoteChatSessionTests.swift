#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFS

/// Tests for `RemoteChatSession` — the app-side `@Observable` mirror of a
/// daemon-hosted chat session. These are pure (no XPC, no backend) — they
/// feed canned `QueueEventEnvelope` chat envelopes and assert the session's
/// state updates correctly.
struct RemoteChatSessionTests {

    // MARK: - chatEvent ingestion

    @Test @MainActor func chatEventAppendsNewEvent() {
        let session = RemoteChatSession(chatID: "chat-1")
        let envelope = QueueEventEnvelope.chatEvent(
            chatID: "chat-1", event: .assistantText("hello"))
        session.ingest(envelope)
        #expect(session.events.count == 1)
        #expect(session.events[0] == .assistantText("hello"))
    }

    @Test @MainActor func chatEventReplacesDeltaContinuation() {
        let session = RemoteChatSession(chatID: "chat-1")
        // First event: partial assistant text
        session.ingest(.chatEvent(chatID: "chat-1", event: .assistantText("Hello")))
        #expect(session.events.count == 1)

        // Delta continuation: text starts with the previous text → replace
        session.ingest(.chatEvent(chatID: "chat-1", event: .assistantText("Hello world")))
        #expect(session.events.count == 1) // not appended
        #expect(session.events[0] == .assistantText("Hello world"))
    }

    @Test @MainActor func chatEventAppendsDifferentEvent() {
        let session = RemoteChatSession(chatID: "chat-1")
        session.ingest(.chatEvent(chatID: "chat-1", event: .userText("question")))
        session.ingest(.chatEvent(chatID: "chat-1", event: .assistantText("answer")))
        #expect(session.events.count == 2)
        #expect(session.events[0] == .userText("question"))
        #expect(session.events[1] == .assistantText("answer"))
    }

    @Test @MainActor func chatEventIgnoresWrongChatID() {
        let session = RemoteChatSession(chatID: "chat-1")
        session.ingest(.chatEvent(chatID: "chat-2", event: .assistantText("other")))
        #expect(session.events.isEmpty)
    }

    @Test @MainActor func chatEventHandlesToolUseAndResult() {
        let session = RemoteChatSession(chatID: "chat-1")
        session.ingest(.chatEvent(chatID: "chat-1", event: .toolUse(
            name: "wikictl", inputSummary: "page list")))
        session.ingest(.chatEvent(chatID: "chat-1", event: .toolResult(
            isError: false, summary: "pages...")))
        #expect(session.events.count == 2)
    }

    // MARK: - chatState ingestion

    @Test @MainActor func chatStateUpdatesRunFlags() {
        let session = RemoteChatSession(chatID: "chat-1")
        let update = ChatStateUpdate(
            isRunning: true,
            isGenerating: true,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: "queryChat",
            runStartedAt: Date(timeIntervalSince1970: 1000))
        session.ingest(.chatState(chatID: "chat-1", update: update))

        #expect(session.isRunning == true)
        #expect(session.isGenerating == true)
        #expect(session.isAwaitingGenerationSlot == false)
        #expect(session.preflightError == nil)
        #expect(session.runStartedAt?.timeIntervalSince1970 == 1000)
    }

    @Test @MainActor func chatStateUpdatesPreflightError() {
        let session = RemoteChatSession(chatID: "chat-1")
        let update = ChatStateUpdate(
            isRunning: false,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: "claude not found",
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil)
        session.ingest(.chatState(chatID: "chat-1", update: update))
        #expect(session.preflightError == "claude not found")
    }

    @Test @MainActor func chatStateUpdatesThinkingOption() {
        let session = RemoteChatSession(chatID: "chat-1")
        let option = ThinkingEffortOption(
            configId: "thought_level",
            currentValue: "high",
            choices: [
                ThinkingEffortOption.Choice(value: "high", label: "High"),
                ThinkingEffortOption.Choice(value: "low", label: "Low"),
            ])
        let update = ChatStateUpdate(
            isRunning: true, isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: option,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil)
        session.ingest(.chatState(chatID: "chat-1", update: update))

        #expect(session.thinkingOption?.currentValue == "high")
        #expect(session.availableThinkingOptions.count == 2)
        #expect(session.availableThinkingOptions[0].value == "high")
    }

    @Test @MainActor func chatStateUpdatesUsage() throws {
        let session = RemoteChatSession(chatID: "chat-1")
        let usage = SessionUsage(
            inputTokens: 1000, outputTokens: 500,
            totalTokens: 1500,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.05, currency: "USD",
            contextUsed: 8000, contextSize: 200000,
            modelId: "claude-sonnet")
        let usageData = try JSONEncoder().encode(usage)
        let update = ChatStateUpdate(
            isRunning: true, isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: usageData,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil)
        session.ingest(.chatState(chatID: "chat-1", update: update))

        #expect(session.runTotalUsage?.inputTokens == 1000)
        #expect(session.runTotalUsage?.outputTokens == 500)
    }

    // MARK: - Hydration from ChatSessionState

    @Test @MainActor func hydrateFromStateSetsAllFields() {
        let session = RemoteChatSession(chatID: "chat-1")
        let state = ChatSessionState(
            chatID: "chat-1",
            events: [.userText("hi"), .assistantText("hello")],
            isRunning: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: "queryChat",
            runStartedAt: Date(timeIntervalSince1970: 2000))
        session.hydrate(from: state)

        #expect(session.events.count == 2)
        #expect(session.isRunning == true)
        #expect(session.isInteractiveSession == true)
        #expect(session.runStartedAt?.timeIntervalSince1970 == 2000)
    }

    // MARK: - Phase C4 follow-up: state envelope fields (stderr, lastActivityAt, currentProcessID)

    @Test @MainActor func hydrateFromStateSetsStderrLastActivityAndPID() {
        let session = RemoteChatSession(chatID: "chat-1")
        let state = ChatSessionState(
            chatID: "chat-1",
            events: [],
            isRunning: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil,
            stderr: "some diagnostic output",
            lastActivityAt: Date(timeIntervalSince1970: 5000),
            currentProcessID: 12345)
        session.hydrate(from: state)

        #expect(session.stderr == "some diagnostic output")
        #expect(session.lastActivityAt?.timeIntervalSince1970 == 5000)
        #expect(session.currentProcessID == 12345)
    }

    @Test @MainActor func hydrateFromStateNilFieldsDefaultGracefully() {
        let session = RemoteChatSession(chatID: "chat-1")
        let state = ChatSessionState(
            chatID: "chat-1",
            events: [],
            isRunning: false,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil)
        session.hydrate(from: state)

        #expect(session.stderr == "")
        #expect(session.lastActivityAt == nil)
        #expect(session.currentProcessID == nil)
    }

    @Test @MainActor func chatStateUpdateCarriesStderrLastActivityAndPID() {
        let session = RemoteChatSession(chatID: "chat-1")
        let update = ChatStateUpdate(
            isRunning: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil,
            stderr: "stderr line",
            lastActivityAt: Date(timeIntervalSince1970: 9000),
            currentProcessID: 999)
        session.ingest(.chatState(chatID: "chat-1", update: update))

        #expect(session.stderr == "stderr line")
        #expect(session.lastActivityAt?.timeIntervalSince1970 == 9000)
        #expect(session.currentProcessID == 999)
    }

    @Test @MainActor func stateEnvelopeFieldsRoundTrip() throws {
        // Verify the new fields survive JSON encode/decode.
        let state = ChatSessionState(
            chatID: "chat-rt",
            events: [],
            isRunning: true,
            isGenerating: false,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: nil,
            runStartedAt: nil,
            stderr: "captured stderr",
            lastActivityAt: Date(timeIntervalSince1970: 7777),
            currentProcessID: 4242)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ChatSessionState.self, from: data)

        #expect(decoded.stderr == "captured stderr")
        #expect(decoded.lastActivityAt?.timeIntervalSince1970 == 7777)
        #expect(decoded.currentProcessID == 4242)
    }

    // MARK: - Reset

    @Test @MainActor func resetClearsAllState() {
        let session = RemoteChatSession(chatID: "chat-1")
        session.ingest(.chatEvent(chatID: "chat-1", event: .assistantText("test")))
        // Set isRunning via a state update
        session.ingest(.chatState(chatID: "chat-1", update: ChatStateUpdate(
            isRunning: true, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: "error", thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(session.events.count == 1)
        #expect(session.isRunning == true)

        session.reset()

        #expect(session.events.isEmpty)
        #expect(session.isRunning == false)
        #expect(session.preflightError == nil)
    }

    // MARK: - chatPendingPermission ingestion

    @Test @MainActor func chatPendingPermissionSetsPendingList() {
        let session = RemoteChatSession(chatID: "chat-1")
        let envelope = QueueEventEnvelope.chatPendingPermission(
            chatID: "chat-1",
            permission: PendingPermission(
                toolCallId: "tc-1",
                title: "Edit file",
                toolName: "Edit",
                inputSummary: "/path/to/file",
                options: []))
        session.ingest(envelope)
        #expect(session.pendingPermissions.count == 1)
        #expect(session.pendingPermissions[0].toolCallId == "tc-1")
        #expect(session.pendingPermissions[0].title == "Edit file")
    }

    // MARK: - QueueEventEnvelope encoding round-trip

    @Test @MainActor func chatEventEnvelopeRoundTrip() throws {
        let event = AgentEvent.assistantText("test content")
        let envelope = QueueEventEnvelope.chatEvent(chatID: "chat-1", event: event)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)

        #expect(decoded.kind == .chatEvent)
        #expect(decoded.chatID == "chat-1")
        #expect(decoded.chatAgentEvent == .assistantText("test content"))
        #expect(decoded.isChatEnvelope)
    }

    @Test @MainActor func chatStateEnvelopeRoundTrip() throws {
        let update = ChatStateUpdate(
            isRunning: true, isGenerating: false,
            isAwaitingGenerationSlot: true,
            preflightError: "test error",
            thinkingOption: nil,
            usageData: nil,
            logFileURL: URL(string: "file:///tmp/log.jsonl"),
            debugFolderURL: nil,
            runKindRaw: "queryChat",
            runStartedAt: Date(timeIntervalSince1970: 1234))
        let envelope = QueueEventEnvelope.chatState(chatID: "chat-2", update: update)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)

        #expect(decoded.kind == .chatState)
        #expect(decoded.chatID == "chat-2")
        #expect(decoded.chatStateUpdate?.isRunning == true)
        #expect(decoded.chatStateUpdate?.isAwaitingGenerationSlot == true)
        #expect(decoded.chatStateUpdate?.preflightError == "test error")
        #expect(decoded.chatStateUpdate?.runStartedAt?.timeIntervalSince1970 == 1234)
    }

    @Test @MainActor func chatAcpSessionIdEnvelopeRoundTrip() throws {
        let envelope = QueueEventEnvelope.chatAcpSessionId(
            chatID: "chat-3", sessionId: "session-xyz")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)

        #expect(decoded.kind == .chatAcpSessionId)
        #expect(decoded.chatID == "chat-3")
        #expect(decoded.acpSessionId == "session-xyz")
    }

    @Test @MainActor func queueEventsStillDecodeAfterChatKindsAdded() throws {
        // Verify that adding chat kinds didn't break existing queue envelope
        // encoding/decoding.
        let envelope = QueueEventEnvelope(
            kind: .transcript,
            itemID: "item-1",
            agentEventData: try JSONEncoder().encode(AgentEvent.assistantText("test")))
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)

        #expect(decoded.kind == .transcript)
        #expect(decoded.itemID == "item-1")
        #expect(!decoded.isChatEnvelope)
        #expect(decoded.toQueueEvent() != nil)
    }

    // MARK: - Phase C4: source-of-truth activeChatID tracking

    @Test @MainActor func activeChatIDSetToChatIDWhenHydratedRunning() {
        // Hydrating with isRunning=true marks this mirror as the live session
        // (activeChatID == chatID) so ChatDetailView's source-of-truth rule
        // renders the streaming path.
        let session = RemoteChatSession(chatID: "chat-live")
        let state = ChatSessionState(
            chatID: "chat-live", events: [],
            isRunning: true, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        session.hydrate(from: state)
        #expect(session.activeChatID == "chat-live")
        #expect(session.isInteractiveSession == true)
    }

    @Test @MainActor func activeChatIDNilWhenHydratedIdle() {
        // An idle persisted chat is NOT live — activeChatID clears so the view
        // renders the persisted rows instead of an empty live stream.
        let session = RemoteChatSession(chatID: "chat-idle")
        let state = ChatSessionState(
            chatID: "chat-idle", events: [.userText("old")],
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)
        session.hydrate(from: state)
        #expect(session.activeChatID == nil)
        #expect(session.isInteractiveSession == false)
    }

    @Test @MainActor func chatStateEnvelopeFlipsActiveChatIDWithRunFlag() {
        // A chatState envelope with isGenerating=true flips the mirror live;
        // a later one with both flags false flips it back to persisted.
        let session = RemoteChatSession(chatID: "chat-flip")
        session.ingest(.chatState(chatID: "chat-flip", update: ChatStateUpdate(
            isRunning: true, isGenerating: true, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(session.activeChatID == "chat-flip")

        session.ingest(.chatState(chatID: "chat-flip", update: ChatStateUpdate(
            isRunning: false, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(session.activeChatID == nil)
    }

    // MARK: - Phase C4: mid-session thinking + reset

    @Test @MainActor func setThinkingEffortOptimisticallyFlipsCurrentValue() {
        let session = RemoteChatSession(chatID: "chat-think")
        session.thinkingOption = ThinkingEffortOption(
            configId: "thought_level", currentValue: "low",
            choices: [
                ThinkingEffortOption.Choice(value: "low", label: "Low"),
                ThinkingEffortOption.Choice(value: "high", label: "High"),
            ])
        session.setThinkingEffort("high")
        #expect(session.thinkingOption?.currentValue == "high")
    }

    @Test @MainActor func setThinkingEffortNoOpWhenNoOptionAdvertised() {
        let session = RemoteChatSession(chatID: "chat-think")
        // thinkingOption is nil by default (agent advertises no thought_level).
        session.setThinkingEffort("high")
        #expect(session.thinkingOption == nil)
    }

    @Test @MainActor func startNewChatClearsStateAndActiveChatID() {
        let session = RemoteChatSession(chatID: "chat-reset")
        session.ingest(.chatEvent(chatID: "chat-reset", event: .assistantText("hi")))
        session.ingest(.chatState(chatID: "chat-reset", update: ChatStateUpdate(
            isRunning: true, isGenerating: false, isAwaitingGenerationSlot: false,
            preflightError: nil, thinkingOption: nil, usageData: nil,
            logFileURL: nil, debugFolderURL: nil, runKindRaw: nil, runStartedAt: nil)))
        #expect(session.activeChatID == "chat-reset")
        #expect(session.events.count == 1)

        session.startNewChat()
        #expect(session.events.isEmpty)
        #expect(session.activeChatID == nil)
        #expect(session.isRunning == false)
    }
}
#endif
