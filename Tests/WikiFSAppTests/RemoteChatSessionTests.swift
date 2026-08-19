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

        #expect(session.displayTranscript.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "user-turn-1-question")),
            .message(ChatMessageID(rawValue: "assistant-turn-1-answer")),
        ])
        #expect(session.displayTranscript.rows.map(\.textForSearch) == ["question", "answer"])
        #expect(session.runState.isLive)
        #expect(session.runState.isAnswering)
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

        #expect(session.displayTranscript.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "optimistic-turn-1"))
        ])
        #expect(session.displayTranscript.rows.map(\.textForSearch) == ["hello"])
        #expect(session.runState == .queued)
    }

    @Test func optimisticSubmitFailedPreservesAuthoritativeReadyLifecycle() {
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

        #expect(session.displayTranscript.rows.isEmpty)
        #expect(session.runState == .warm)
        #expect(session.runState.isLive)
    }

    @Test func committedHistoryPagingUsesSuccessiveAfterCursorsUntilTargetReached() async {
        let session = makeSession()
        let turn1 = ChatTurnID(rawValue: "turn-1")
        let turn2 = ChatTurnID(rawValue: "turn-2")
        var afterCursors: [ChatTranscriptCursor?] = []
        session.installHistoryLoader { after in
            afterCursors.append(after)
            switch after?.rawValue {
            case nil:
                return ChatTranscriptPage(
                    items: [
                        PersistedChatTranscriptItem(
                            cursor: ChatTranscriptCursor(rawValue: 1),
                            item: makeMessage(role: .user, turnID: turn1, text: "first"),
                            projectedEventJSON: nil,
                            projectedPlainText: "first",
                            createdAt: Date(timeIntervalSince1970: 21)
                        ),
                        PersistedChatTranscriptItem(
                            cursor: ChatTranscriptCursor(rawValue: 2),
                            item: makeMessage(role: .assistant, turnID: turn1, text: "reply"),
                            projectedEventJSON: nil,
                            projectedPlainText: "reply",
                            createdAt: Date(timeIntervalSince1970: 22)
                        ),
                    ],
                    checkpoint: ChatTranscriptCursor(rawValue: 5),
                    nextCursor: ChatTranscriptCursor(rawValue: 2)
                )
            case 2:
                return ChatTranscriptPage(
                    items: [
                        PersistedChatTranscriptItem(
                            cursor: ChatTranscriptCursor(rawValue: 3),
                            item: makeMessage(role: .user, turnID: turn2, text: "second"),
                            projectedEventJSON: nil,
                            projectedPlainText: "second",
                            createdAt: Date(timeIntervalSince1970: 23)
                        ),
                        PersistedChatTranscriptItem(
                            cursor: ChatTranscriptCursor(rawValue: 4),
                            item: makeMessage(role: .assistant, turnID: turn2, text: "more"),
                            projectedEventJSON: nil,
                            projectedPlainText: "more",
                            createdAt: Date(timeIntervalSince1970: 24)
                        ),
                        PersistedChatTranscriptItem(
                            cursor: ChatTranscriptCursor(rawValue: 5),
                            item: makeMessage(role: .assistant, turnID: turn2, text: "done"),
                            projectedEventJSON: nil,
                            projectedPlainText: "done",
                            createdAt: Date(timeIntervalSince1970: 25)
                        ),
                    ],
                    checkpoint: ChatTranscriptCursor(rawValue: 5),
                    nextCursor: ChatTranscriptCursor(rawValue: 5)
                )
            default:
                Issue.record("unexpected after cursor \(String(describing: after))")
                return ChatTranscriptPage(items: [], checkpoint: .zero, nextCursor: nil)
            }
        }

        session.hydrate(from: makeSnapshot(sequence: 1, committedCursor: ChatTranscriptCursor(rawValue: 5)))

        await expectEventually((session.syncState?.committedItems.count ?? 0) == 5)
        #expect(session.syncState?.loadedCommittedCursor == ChatTranscriptCursor(rawValue: 5))
        #expect(afterCursors.map { $0?.rawValue } == [nil, 2])
    }

    @Test func gapUpdateRetriesAuthoritativeSnapshotAfterFailure() async {
        actor AttemptCounter {
            private var value = 0

            func increment() -> Int {
                value += 1
                return value
            }

            func current() -> Int { value }
        }

        let session = makeSession()
        session.hydrate(from: makeSnapshot(sequence: 1))

        let authoritative = makeSnapshot(
            sequence: 3,
            runMetadata: ChatRunMetadata(preflightError: "authoritative")
        )
        let attempts = AttemptCounter()
        session.onRequestAuthoritativeSnapshot = {
            let nextAttempt = await attempts.increment()
            if nextAttempt == 1 {
                struct RetryError: Error {}
                throw RetryError()
            }
            return authoritative
        }

        session.ingest(
            QueueEventEnvelope.chatSyncUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                update: makeUpdate(sequence: 3)
            )
        )

        await expectEventually(session.preflightError == "authoritative")
        #expect(await attempts.current() == 2)
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
        #expect(session.displayTranscript.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "user-\(turnID.rawValue)-hello"))
        ])
        #expect(session.displayTranscript.rows.map(\.textForSearch) == ["hello"])
        #expect(syncState.committedItems.count == 1)
        #expect(syncState.projection?.transcriptOverlay.isEmpty == true)
    }

    @Test func markNotLiveRelinquishesLivenessClaim() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(lifecycle: .ready))
        session.markNotLive()

        #expect(session.runState == .idle)
        #expect(!session.runState.isLive)
    }

    @Test func resetClearsAllProjectedState() {
        let session = makeSession()
        session.hydrate(from: makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            overlay: [makeMessage(role: .assistant, text: "answer")],
            runMetadata: ChatRunMetadata(preflightError: "error")
        ))

        session.reset()

        #expect(session.displayTranscript.rows.isEmpty)
        #expect(session.preflightError == nil)
        #expect(session.runState == .idle)
        #expect(session.pendingPermissions.isEmpty)
    }

    @Test func resetCancelsPendingHistoryLoadBeforeStalePageApplies() async {
        let session = makeSession()
        var afterCursors: [ChatTranscriptCursor?] = []
        session.installHistoryLoader { after in
            afterCursors.append(after)
            if after == nil {
                session.reset()
            }
            return ChatTranscriptPage(
                items: [
                    PersistedChatTranscriptItem(
                        cursor: ChatTranscriptCursor(rawValue: 1),
                        item: makeMessage(role: .assistant, text: "stale"),
                        projectedEventJSON: nil,
                        projectedPlainText: "stale",
                        createdAt: Date(timeIntervalSince1970: 21)
                    )
                ],
                checkpoint: ChatTranscriptCursor(rawValue: 2),
                nextCursor: ChatTranscriptCursor(rawValue: 1)
            )
        }

        session.hydrate(from: makeSnapshot(sequence: 1, committedCursor: ChatTranscriptCursor(rawValue: 2)))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(afterCursors.map { $0?.rawValue } == [nil])
        #expect(session.syncState?.committedItems.isEmpty == true)
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

    @Test func draftResetClearsPendingModelAndThinkingSelection() {
        let session = RemoteChatSession(chatID: .draft)
        session.pendingModelOverride = (
            ProviderID(rawValue: "provider"), ModelID(rawValue: "model"))
        session.pendingConfiguredThinkingOptionID = ChatConfigurationValueID(rawValue: "high")

        session.reset()

        #expect(session.pendingModelOverride == nil)
        #expect(session.pendingConfiguredThinkingOptionID == nil)
    }

    @Test func providerConfigurationCacheRefreshesAfterSettingsSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-chat-provider-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                DebugLog.store("RemoteChatSessionTests cleanup failed: \(error)")
            }
        }

        let providerID = ProviderID(rawValue: "session-cache-provider")
        let modelID = ModelID(rawValue: "session-cache-model")
        let configured = AgentProvidersConfig(
            providers: [AgentProvider(
                id: providerID,
                label: "Session cache",
                enabled: true,
                isDefault: true
            )],
            selectedModelIds: [providerID.rawValue: modelID]
        )
        try configured.save(to: directory)
        let session = RemoteChatSession(
            chatID: .chat(ChatID(rawValue: "chat-1")),
            providersConfigurationDirectory: directory
        )
        #expect(session.providersConfig().isChatOperationConfigured())

        let invalid = AgentProvidersConfig(
            providers: [AgentProvider(
                id: providerID,
                label: "Session cache",
                enabled: false,
                isDefault: true
            )],
            selectedModelIds: [providerID.rawValue: modelID]
        )
        try invalid.save(to: directory)
        session.refreshProvidersConfig()
        #expect(session.providerConfiguration == invalid)
        #expect(session.providersConfig().isChatOperationConfigured() == false)
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
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not met before timeout.")
    }
}
#endif
