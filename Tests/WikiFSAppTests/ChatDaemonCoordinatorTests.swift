#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

@MainActor
struct ChatDaemonCoordinatorTests {
    @Test func sessionRegistryUsesStableInstances() {
        let coordinator = makeCoordinator()

        let first = coordinator.session(for: ChatID(rawValue: "chat-1"))
        let second = coordinator.session(for: ChatID(rawValue: "chat-1"))
        let draft = coordinator.session(for: nil)

        #expect(first === second)
        #expect(draft.chatID == .draft)
    }

    @Test func resetDraftReplacesDraftSession() {
        let coordinator = makeCoordinator()
        let first = coordinator.session(for: nil)

        coordinator.resetDraft()

        #expect(coordinator.session(for: nil) !== first)
    }

    @Test func ingestForTestingDeliversSyncUpdateToOpenSession() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 0)
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        let session = coordinator.session(for: ChatID(rawValue: "chat-1"))
        await coordinator.rehydrate(chatID: ChatID(rawValue: "chat-1"))

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(
                    sequence: 1,
                    activeTurn: makeActiveTurn(state: .responding),
                    overlay: [makeMessage(role: .assistant, text: "hello")]
                )
            )
        )

        #expect(session.events == [.assistantText("hello")])
        #expect(session.isGenerating)
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
        #expect(coordinator.anyChatGenerating)
    }

    @Test func runningStateTokenBumpsOnlyOnGeneratingMembershipChanges() {
        let coordinator = makeCoordinator()
        let before = coordinator.runningStateToken

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 1, activeTurn: makeActiveTurn(state: .responding))
            )
        )
        let afterStart = coordinator.runningStateToken
        #expect(afterStart == before + 1)

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 2, activeTurn: makeActiveTurn(state: .responding))
            )
        )
        #expect(coordinator.runningStateToken == afterStart)

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 3, activeTurn: nil)
            )
        )
        #expect(coordinator.runningStateToken == afterStart + 1)
        #expect(!coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func commandMethodsForwardTypedRequests() async throws {
        let stub = StubChatDaemonCommands()
        stub.nextStartChatID = ChatID(rawValue: "start-id")
        stub.nextSubmitChatID = ChatID(rawValue: "submit-id")
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())

        let startID = try await coordinator.startChat(
            wikiID: WikiID(rawValue: "wiki-1"),
            firstMessage: "hello"
        )
        let submitID = try await coordinator.submitTurn(
            ChatSubmitRequest(
                wikiID: WikiID(rawValue: "wiki-1"),
                chatID: nil,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: "command-1"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    userText: "question",
                    contextReferences: [],
                    submittedAt: Date(timeIntervalSince1970: 10)
                )
            )
        )
        try await coordinator.continueChat(
            wikiID: WikiID(rawValue: "wiki-1"),
            chatID: ChatID(rawValue: "chat-1"),
            message: "continue"
        )
        try await coordinator.sendMessage(chatID: ChatID(rawValue: "chat-1"), message: "follow up")
        await coordinator.resolvePermission(chatID: ChatID(rawValue: "chat-1"), optionId: "allow", approve: true)
        await coordinator.setThinkingEffort(chatID: ChatID(rawValue: "chat-1"), value: "high")
        await coordinator.stop(chatID: ChatID(rawValue: "chat-1"))

        #expect(startID == ChatID(rawValue: "start-id"))
        #expect(submitID == ChatID(rawValue: "submit-id"))
        #expect(stub.startChatCalls.count == 1)
        #expect(stub.submitTurnCalls.count == 1)
        #expect(stub.continueChatCalls.first?.message == "continue")
        #expect(stub.sendCalls.first?.1 == "follow up")
        #expect(stub.resolveCalls.first?.optionId == "allow")
        #expect(stub.configOptionCalls.first?.value == "high")
        #expect(stub.stopCalls == [ChatID(rawValue: "chat-1")])
    }

    @Test func rehydrateUsesAuthoritativeSnapshot() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(
            sequence: 4,
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [makeMessage(role: .assistant, text: "seed")]
        )
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())

        await coordinator.rehydrate(chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(for: ChatID(rawValue: "chat-1"))
        #expect(session.events == [.assistantText("seed")])
        #expect(session.isGenerating)
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func rehydrateFailureClearsLivenessClaim() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 1, activeTurn: makeActiveTurn(state: .responding))
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coordinator.rehydrate(chatID: ChatID(rawValue: "chat-1"))
        #expect(coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))

        stub.shouldThrow = true
        await coordinator.rehydrate(chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(for: ChatID(rawValue: "chat-1"))
        #expect(session.activeChatID == nil)
        #expect(!coordinator.isChatGenerating(ChatID(rawValue: "chat-1")))
    }

    @Test func sessionWiresAuthoritativeSnapshotLoaderForGapRecovery() async {
        let stub = StubChatDaemonCommands()
        stub.sessionState = makeSnapshot(sequence: 1)
        let coordinator = ChatDaemonCoordinator(client: stub, eventSink: DaemonQueueEventSink())
        await coordinator.rehydrate(chatID: ChatID(rawValue: "chat-1"))

        let session = coordinator.session(for: ChatID(rawValue: "chat-1"))
        stub.sessionState = makeSnapshot(
            sequence: 4,
            runMetadata: ChatRunMetadata(preflightError: "resynced")
        )

        coordinator.ingestForTesting(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 4)
            )
        )

        await expectEventually(session.preflightError == "resynced")
        #expect(stub.sessionStateRequests.count >= 2)
    }

    @Test func draftSessionDoesNotWireConfigCallback() {
        let coordinator = makeCoordinator()
        #expect(coordinator.session(for: nil).onSetChatConfigOption == nil)
    }

    private func makeCoordinator() -> ChatDaemonCoordinator {
        ChatDaemonCoordinator(client: StubChatDaemonCommands(), eventSink: DaemonQueueEventSink())
    }

    private func makeSnapshot(
        sequence: Int64,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: "generation-1"),
                lifecycle: activeTurn == nil ? .closed : .ready,
                activeTurn: activeTurn,
                queuedTurns: [],
                attention: .none,
                capabilities: .unavailable,
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider-1"),
                    modelID: ModelID(rawValue: "model-1"),
                    providerSessionID: nil
                ),
                usage: nil,
                diagnostics: ChatDiagnosticsState(),
                transcriptOverlay: overlay,
                committedCursor: .zero,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: nil,
                runMetadata: runMetadata
            )
        )
    }

    private func makeUpdate(
        sequence: Int64,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = []
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1"))),
            projection: makeSnapshot(
                sequence: sequence,
                activeTurn: activeTurn,
                overlay: overlay
            ).projection
        )
    }

    private func makeActiveTurn(state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-1"),
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "visible",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeMessage(
        role: ChatTranscriptMessageRole,
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "\(role.rawValue)-\(text)"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: role,
                text: text,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
    }

    private func expectEventually(
        _ condition: @autoclosure @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition was not met before timeout.")
    }
}

@MainActor
final class StubChatDaemonCommands: ChatDaemonCommands, @unchecked Sendable {
    var startChatCalls: [ChatStartRequest] = []
    var submitTurnCalls: [ChatSubmitRequest] = []
    var continueChatCalls: [ChatContinueRequest] = []
    var sendCalls: [(ChatID, String)] = []
    var stopCalls: [ChatID] = []
    var resolveCalls: [ChatPermissionResolveRequest] = []
    var sessionStateRequests: [ChatID] = []
    var configOptionCalls: [ChatConfigOptionRequest] = []

    var nextStartChatID = ChatID(rawValue: "stub-chat-id")
    var nextSubmitChatID = ChatID(rawValue: "stub-submit-chat-id")
    var sessionState: ChatSyncSnapshot?
    var shouldThrow = false

    func startChat(_ request: ChatStartRequest) async throws -> ChatID {
        startChatCalls.append(request)
        if shouldThrow { throw StubError.throwing }
        return nextStartChatID
    }

    func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        submitTurnCalls.append(request)
        if shouldThrow { throw StubError.throwing }
        return nextSubmitChatID
    }

    func continueChat(_ request: ChatContinueRequest) async throws {
        continueChatCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }

    func sendChatMessage(chatID: ChatID, message: String) async throws {
        sendCalls.append((chatID, message))
        if shouldThrow { throw StubError.throwing }
    }

    func stopChat(_ chatID: ChatID) async throws {
        stopCalls.append(chatID)
        if shouldThrow { throw StubError.throwing }
    }

    func chatSessionState(_ chatID: ChatID) async throws -> ChatSyncSnapshot {
        sessionStateRequests.append(chatID)
        if shouldThrow { throw StubError.throwing }
        return sessionState ?? ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: chatID,
                generation: ChatSessionGenerationID(rawValue: "generation-default"),
                lifecycle: .closed,
                activeTurn: nil,
                queuedTurns: [],
                attention: .none,
                capabilities: .unavailable,
                providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
                usage: nil,
                diagnostics: ChatDiagnosticsState(),
                transcriptOverlay: [],
                committedCursor: .zero,
                lastIncludedSequence: .initial,
                pendingPermission: nil,
                runMetadata: .empty
            )
        )
    }

    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        resolveCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }

    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        configOptionCalls.append(request)
        if shouldThrow { throw StubError.throwing }
    }
}

private enum StubError: Error {
    case throwing
}
#endif
