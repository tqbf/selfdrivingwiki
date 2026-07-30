#if os(macOS)
import ACPModel
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

@MainActor
struct RemoteChatSessionTests {
    @Test func hydrateSnapshotProjectsTranscriptAndRunMetadata() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [
                makeMessage(role: .user, text: "question"),
                makeMessage(role: .assistant, text: "answer")
            ],
            usage: SessionUsage(
                inputTokens: 10,
                outputTokens: 4,
                totalTokens: 14,
                cachedReadTokens: nil,
                thoughtTokens: nil,
                cost: 0.02,
                currency: "USD",
                contextUsed: 100,
                contextSize: 1000
            ),
            diagnostics: ChatDiagnosticsState(
                stderr: "stderr line",
                lastActivityAt: Date(timeIntervalSince1970: 90),
                currentProcessID: 321
            ),
            runMetadata: ChatRunMetadata(
                preflightError: "preflight",
                thinkingOption: ThinkingEffortOption(
                    configId: "thought_level",
                    currentValue: "high",
                    choices: [ThinkingEffortOption.Choice(value: "high", label: "High")]
                ),
                logFileURL: URL(string: "file:///tmp/log")!,
                debugFolderURL: URL(string: "file:///tmp/debug")!,
                runKindRaw: "query",
                runStartedAt: Date(timeIntervalSince1970: 50)
            )
        ))

        #expect(session.events == [.userText("question"), .assistantText("answer")])
        #expect(session.isRunning)
        #expect(session.isGenerating)
        #expect(session.activeChatID == ChatID(rawValue: "chat-1"))
        #expect(session.runStartedAt?.timeIntervalSince1970 == 50)
        #expect(session.preflightError == "preflight")
        #expect(session.thinkingOption?.currentValue == "high")
        #expect(session.stderr == "stderr line")
        #expect(session.currentProcessID == 321)
        #expect(session.runTotalUsage?.totalTokens == 14)
        #expect(session.logFileURL?.absoluteString == "file:///tmp/log")
        #expect(session.debugFolderURL?.absoluteString == "file:///tmp/debug")
    }

    @Test func sameSequenceCompatibilityRefreshUpdatesProjection() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(sequence: 5))

        session.ingest(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(
                    sequence: 5,
                    reason: .compatibilityRefreshed,
                    diagnostics: ChatDiagnosticsState(stderr: "refreshed stderr"),
                    runMetadata: ChatRunMetadata(preflightError: "refresh")
                )
            )
        )

        #expect(session.stderr == "refreshed stderr")
        #expect(session.preflightError == "refresh")
    }

    @Test func optimisticSubmitAddsVisibleQueuedTurn() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(lifecycle: .ready))

        let submission = ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "hello",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        session.optimisticSubmit(submission)

        #expect(session.events == [.userText("hello")])
        #expect(session.runState == .queued)
        #expect(session.activeChatID == ChatID(rawValue: "chat-1"))
    }

    @Test func optimisticSubmitFailedRollsBackOptimisticState() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(lifecycle: .ready))

        let turnID = ChatTurnID(rawValue: "turn-1")
        session.optimisticSubmit(
            ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "command-1"),
                turnID: turnID,
                userText: "hello",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 10)
            )
        )
        session.optimisticSubmitFailed(turnID: turnID)

        #expect(session.events.isEmpty)
        #expect(session.runState == .idle)
        #expect(session.activeChatID == nil)
    }

    @Test func pendingPermissionMapsToCompatibilitySurface() throws {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(
            pendingPermission: ChatPendingPermissionRequest(
                requestID: PermissionRequestID(rawValue: "request-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                toolCallID: ToolCallID(rawValue: "tool-1"),
                title: "Edit file",
                message: "/tmp/file.swift",
                options: [
                    ChatPermissionOption(
                        id: PermissionOptionID(rawValue: "allow"),
                        label: "Allow",
                        behavior: .allow
                    ),
                    ChatPermissionOption(
                        id: PermissionOptionID(rawValue: "deny"),
                        label: "Deny",
                        behavior: .deny
                    )
                ]
            )
        ))

        let pending = try #require(session.pendingPermissions.first)
        #expect(pending.toolCallId == ToolCallID(rawValue: "tool-1"))
        #expect(pending.title == "Edit file")
        #expect(pending.inputSummary == "/tmp/file.swift")
        #expect(pending.options.map(\.optionId) == ["allow", "deny"])
    }

    @Test func gapUpdateRequestsAuthoritativeSnapshot() async {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(sequence: 1))
        let authoritative = makeSnapshot(
            sequence: 3,
            runMetadata: ChatRunMetadata(preflightError: "authoritative")
        )
        session.onRequestAuthoritativeSnapshot = {
            authoritative
        }

        session.ingest(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 3)
            )
        )

        await expectEventually(session.preflightError == "authoritative")
    }

    @Test func hydrateLoadsCommittedHistoryAndReconcilesOptimisticOverlay() async throws {
        let session = makeSession()
        let turnID = ChatTurnID(rawValue: "turn-1")
        session.installHistoryLoader { after in
            #expect(after == nil)
            return ChatTranscriptPage(
                items: [
                    PersistedChatTranscriptItem(
                        cursor: ChatTranscriptCursor(rawValue: 1),
                        item: makeMessage(role: .user, turnID: turnID, text: "hello"),
                        projectedEventJSON: nil,
                        projectedPlainText: "hello",
                        createdAt: Date(timeIntervalSince1970: 20)
                    )
                ],
                checkpoint: ChatTranscriptCursor(rawValue: 1),
                nextCursor: nil
            )
        }

        session.hydrate(from: makeSnapshot(
            sequence: 1,
            overlay: [makeMessage(role: .user, turnID: turnID, text: "hello")],
            committedCursor: ChatTranscriptCursor(rawValue: 1)
        ))

        await expectEventually((session.syncState?.committedItems.count ?? 0) == 1)
        let syncState = try #require(session.syncState)
        #expect(session.events == [.userText("hello")])
        #expect(syncState.committedItems.count == 1)
        #expect(syncState.projection?.transcriptOverlay.isEmpty == true)
    }

    @Test func markNotLiveRelinquishesLivenessClaim() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(lifecycle: .ready))
        #expect(session.activeChatID == ChatID(rawValue: "chat-1"))

        session.markNotLive()

        #expect(session.activeChatID == nil)
        #expect(session.runState == .idle)
        #expect(!session.isRunning)
    }

    @Test func resetClearsAllProjectedState() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [makeMessage(role: .assistant, text: "answer")],
            runMetadata: ChatRunMetadata(preflightError: "error")
        ))

        session.reset()

        #expect(session.events.isEmpty)
        #expect(session.preflightError == nil)
        #expect(session.runState == .idle)
        #expect(session.activeChatID == nil)
    }

    @Test func chatSyncUpdateEnvelopeRoundTrips() throws {
        let envelope = QueueEventEnvelope.chatSyncUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            update: makeUpdate(sequence: 2)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)

        #expect(decoded.kind == .chatSyncUpdate)
        #expect(decoded.chatID == ChatID(rawValue: "chat-1"))
        #expect(try decoded.decodedChatSyncUpdate().projection.lastIncludedSequence == ChatUpdateSequence(rawValue: 2))
    }

    private func makeSession() -> RemoteChatSession {
        RemoteChatSession(chatID: .chat(ChatID(rawValue: "chat-1")))
    }

    private func makeSnapshot(
        lifecycle: ChatSessionLifecycle = .ready,
        sequence: Int64 = 1,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero,
        pendingPermission: ChatPendingPermissionRequest? = nil,
        usage: SessionUsage? = nil,
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: "generation-1"),
                lifecycle: lifecycle,
                activeTurn: activeTurn,
                queuedTurns: [],
                attention: .none,
                capabilities: .unavailable,
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider-1"),
                    modelID: ModelID(rawValue: "model-1"),
                    providerSessionID: nil
                ),
                usage: usage,
                diagnostics: diagnostics,
                transcriptOverlay: overlay,
                committedCursor: committedCursor,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: pendingPermission,
                runMetadata: runMetadata
            )
        )
    }

    private func makeUpdate(
        sequence: Int64,
        reason: ChatSyncUpdateReason = .sessionEvent(.sessionReady(
            capabilities: .unavailable,
            providerState: ChatProviderState(
                providerID: ProviderID(rawValue: "provider-1"),
                modelID: ModelID(rawValue: "model-1"),
                providerSessionID: nil
            )
        )),
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        runMetadata: ChatRunMetadata = .empty
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: reason,
            projection: makeSnapshot(
                sequence: sequence,
                diagnostics: diagnostics,
                runMetadata: runMetadata
            ).projection
        )
    }

    private func makeActiveTurn(
        turnID: ChatTurnID = ChatTurnID(rawValue: "turn-1"),
        state: ChatTurnState
    ) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: turnID,
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "visible",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeMessage(
        role: ChatTranscriptMessageRole,
        turnID: ChatTurnID = ChatTurnID(rawValue: "turn-1"),
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "\(role.rawValue)-\(turnID.rawValue)-\(text)"),
                turnID: turnID,
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
#endif
