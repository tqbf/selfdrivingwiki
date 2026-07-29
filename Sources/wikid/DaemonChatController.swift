// pattern: Mixed (unavoidable)
// Reason: the controller is the daemon's single lifecycle owner, so it must
// coordinate persistence, runtime events, replay state, and compatibility
// signaling in one actor to keep terminal-winner and queue-order invariants.

#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

actor DaemonChatController {
    private let chatID: ChatID
    private let wikiID: WikiID
    private let store: GRDBWikiStore
    private let runtime: ChatAgentRuntime
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void

    private var generation: ChatSessionGenerationID
    private var snapshot: ChatRuntimeSnapshot
    private var replayBuffer = ChatUpdateReplayBuffer(capacity: 128)
    private var nextSequence = ChatUpdateSequence.initial
    private var runtimeHandle: ChatRuntimeHandle?
    private var eventTask: Task<Void, Never>?
    private var currentClaimID: ChatTurnClaimID?
    private var currentClaimTurnID: ChatTurnID?
    private var pendingCancellationTurnID: ChatTurnID?
    private var activePermission: ChatPendingPermissionRequest?
    private var latestStateUpdate = ChatStateUpdate(
        isRunning: false,
        isGenerating: false,
        isAwaitingGenerationSlot: false,
        preflightError: nil,
        thinkingOption: nil,
        usageData: nil,
        logFileURL: nil,
        debugFolderURL: nil,
        runKindRaw: nil,
        runStartedAt: nil
    )
    private var liveEvents: [AgentEvent] = []

    init(
        chatID: ChatID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        runtime: ChatAgentRuntime,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void
    ) throws {
        self.chatID = chatID
        self.wikiID = wikiID
        self.store = store
        self.runtime = runtime
        self.pushEvent = pushEvent
        self.generation = ChatSessionGenerationID(rawValue: ULID.generate())
        self.snapshot = try Self.bootstrapSnapshot(chatID: chatID, store: store, generation: generation)
        if case .permissionRequired = snapshot.attention {
            self.activePermission = nil
        }
    }

    deinit {
        eventTask?.cancel()
    }

    func submit(_ request: ChatSubmitRequest) async throws -> ChatID {
        let existingTurns = try store.listPersistedChatTurns(chatID: chatID)
        if existingTurns.contains(where: { $0.submission.commandID == request.submission.commandID }) {
            return chatID
        }

        let persistedTurn = try store.enqueuePersistedChatTurn(chatID: chatID, submission: request.submission)
        try appendTranscriptItems([
            .message(ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: ULID.generate()),
                turnID: request.submission.turnID,
                role: .user,
                text: request.submission.userText,
                createdAt: request.submission.submittedAt
            ))
        ])
        pushEvent(.chatEvent(chatID: chatID, event: .userText(request.submission.userText)))
        record(.queued(ChatQueuedTurn(
            ordinal: persistedTurn.ordinal,
            submission: persistedTurn.submission,
            editedAt: persistedTurn.editedAt
        )))
        try await processQueueIfPossible()
        return chatID
    }

    /// Cancels only the currently active turn. Queued turns are intentionally
    /// preserved here; the typed domain models their mutation separately via
    /// `removeQueuedTurn`.
    func cancel(turnID: ChatTurnID?) async {
        guard let activeTurn = snapshot.activeTurn else { return }
        let resolvedTurnID = turnID ?? activeTurn.turnID
        guard resolvedTurnID == activeTurn.turnID else { return }
        guard activeTurn.state != .queued else {
            return
        }

        pendingCancellationTurnID = resolvedTurnID
        if let handle = runtimeHandle {
            do {
                try await runtime.cancelTurn(resolvedTurnID, in: handle)
            } catch {
                DebugLog.agent("DaemonChatController.cancel runtime cancel failed: \(error)")
            }
        }
    }

    func resolvePermission(optionID: String) async {
        guard let permission = activePermission,
              let handle = runtimeHandle else { return }
        do {
            try await runtime.resolvePermission(
                ChatPermissionResolution(
                    requestID: permission.requestID,
                    optionID: PermissionOptionID(rawValue: optionID)
                ),
                in: handle
            )
        } catch {
            DebugLog.agent("DaemonChatController.resolvePermission failed: \(error)")
        }
    }

    func setConfiguration(option: String, value: String) async throws {
        guard let handle = runtimeHandle else { return }
        try await runtime.setConfiguration(
            ChatRuntimeConfigurationChange(
                optionID: ChatConfigurationOptionID(rawValue: option),
                valueID: ChatConfigurationValueID(rawValue: value)
            ),
            in: handle
        )
    }

    func chatSessionState() throws -> ChatSessionState {
        let events = runtimeHandle == nil
            ? try store.chatMessages(chatID: chatID).map(\.event)
            : AgentEvent.mergingStreamDeltas(liveEvents)
        return ChatSessionState(
            chatID: chatID,
            events: events,
            isRunning: latestStateUpdate.isRunning,
            isGenerating: latestStateUpdate.isGenerating,
            isAwaitingGenerationSlot: latestStateUpdate.isAwaitingGenerationSlot,
            preflightError: latestStateUpdate.preflightError,
            thinkingOption: latestStateUpdate.thinkingOption,
            usageData: latestStateUpdate.usageData,
            logFileURL: latestStateUpdate.logFileURL,
            debugFolderURL: latestStateUpdate.debugFolderURL,
            runKindRaw: latestStateUpdate.runKindRaw,
            runStartedAt: latestStateUpdate.runStartedAt,
            stderr: latestStateUpdate.stderr,
            lastActivityAt: latestStateUpdate.lastActivityAt,
            currentProcessID: latestStateUpdate.currentProcessID
        )
    }

    func typedSnapshot() -> ChatRuntimeSnapshot { snapshot }

    func replay(after watermark: ChatUpdateSequence) -> ChatReplayResult {
        replayBuffer.replay(after: watermark)
    }

    func didUpdateProviderSessionID(_ sessionID: AcpSessionID?) {
        let providerState = ChatProviderState(
            providerID: snapshot.providerState.providerID,
            modelID: snapshot.providerState.modelID,
            providerSessionID: sessionID
        )
        snapshot = ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: snapshot.lifecycle,
            activeTurn: snapshot.activeTurn,
            queuedTurns: snapshot.queuedTurns,
            attention: snapshot.attention,
            capabilities: snapshot.capabilities,
            providerState: providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
            lastIncludedSequence: snapshot.lastIncludedSequence
        )
    }

    func didUpdateCompatibilityState(_ update: ChatStateUpdate) {
        latestStateUpdate = update
    }

    func didReceiveLiveEvents(_ events: [AgentEvent]) {
        liveEvents.append(contentsOf: events)
    }

    private func processQueueIfPossible() async throws {
        guard currentClaimID == nil else { return }
        if let activeTurn = snapshot.activeTurn,
           activeTurn.state.isTerminal == false,
           activeTurn.state != .queued {
            return
        }
        switch snapshot.attention {
        case .turnFailed, .interruptedTurn:
            return
        case .none, .permissionRequired:
            break
        }

        let claimID = ChatTurnClaimID(rawValue: ULID.generate())
        guard let claimed = try store.claimNextPersistedChatTurn(
            chatID: chatID,
            claimID: claimID,
            claimedAt: Date()
        ) else {
            return
        }

        let queuedTurn = ChatQueuedTurn(
            ordinal: claimed.ordinal,
            submission: claimed.submission,
            editedAt: claimed.editedAt
        )
        if snapshot.activeTurn?.turnID != claimed.submission.turnID {
            record(.queued(queuedTurn))
        }

        let handle: ChatRuntimeHandle
        if let existingHandle = runtimeHandle {
            handle = existingHandle
        } else {
            let chat = try store.getChat(id: chatID)
            handle = try await runtime.start(
                ChatRuntimeStartRequest(
                    chatID: chatID,
                    generation: generation,
                    systemPrompt: try store.getSystemPrompt().body,
                    providerID: chat.modelProviderId,
                    modelID: chat.modelId,
                    existingProviderSessionID: chat.acpSessionId
                )
            )
            runtimeHandle = handle
            startEventLoop(handle)
        }

        currentClaimID = claimID
        currentClaimTurnID = claimed.submission.turnID
        record(.submitted(turnID: claimed.submission.turnID))

        do {
            try await runtime.submitTurn(claimed.submission, in: handle)
            let marked = try store.markPersistedChatTurnProviderSubmitted(
                chatID: chatID,
                turnID: claimed.submission.turnID,
                claimID: claimID,
                providerSessionID: snapshot.providerState.providerSessionID,
                submittedAt: Date()
            )
            if marked.providerSessionID != snapshot.providerState.providerSessionID {
                snapshot = ChatRuntimeSnapshot(
                    chatID: snapshot.chatID,
                    generation: snapshot.generation,
                    lifecycle: snapshot.lifecycle,
                    activeTurn: snapshot.activeTurn,
                    queuedTurns: snapshot.queuedTurns,
                    attention: snapshot.attention,
                    capabilities: snapshot.capabilities,
                    providerState: ChatProviderState(
                        providerID: snapshot.providerState.providerID,
                        modelID: snapshot.providerState.modelID,
                        providerSessionID: marked.providerSessionID
                    ),
                    usage: snapshot.usage,
                    diagnostics: snapshot.diagnostics,
                    transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
                    lastIncludedSequence: snapshot.lastIncludedSequence
                )
            }
            record(.started(turnID: claimed.submission.turnID))
        } catch {
            DebugLog.agent("DaemonChatController.processQueueIfPossible submit failed: \(error)")
            _ = finishPersistedTurn(
                turnID: claimed.submission.turnID,
                outcome: .failed(category: .runtimeError, message: error.localizedDescription)
            )
        }
    }

    private func startEventLoop(_ handle: ChatRuntimeHandle) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await runtime.eventStream(for: handle)
                for await envelope in stream {
                    await self.handleRuntimeEvent(envelope)
                }
            } catch {
                DebugLog.agent("DaemonChatController event loop failed: \(error)")
            }
        }
    }

    private func handleRuntimeEvent(_ envelope: ChatAgentRuntimeEventEnvelope) async {
        guard envelope.generation == generation else { return }

        switch envelope.event {
        case .sessionReady(let capabilities, let providerState):
            record(.sessionReady(capabilities: capabilities, providerState: providerState))

        case .transcript(let deltas):
            do {
                try appendTranscriptItems(Self.persistedTranscriptItems(from: deltas))
            } catch {
                DebugLog.store("DaemonChatController transcript persistence failed: \(error)")
            }
            record(.transcriptChanged(deltas))

        case .permissionRequested(let request):
            activePermission = request
            record(.permissionRequested(request))

        case .permissionResolved(let resolution):
            activePermission = nil
            record(.permissionResolved(resolution.requestID))

        case .turnCompleted(let turnID):
            if consumePendingCancellation(turnID: turnID) {
                _ = finishPersistedTurn(turnID: turnID, outcome: .cancelled)
            } else {
                _ = finishPersistedTurn(turnID: turnID, outcome: .completed)
            }
            do {
                try await processQueueIfPossible()
            } catch {
                DebugLog.agent("DaemonChatController.turnCompleted queue advance failed: \(error)")
            }

        case .turnFailed(let turnID, let category, let message):
            if consumePendingCancellation(turnID: turnID) {
                _ = finishPersistedTurn(turnID: turnID, outcome: .cancelled)
            } else {
                _ = finishPersistedTurn(turnID: turnID, outcome: .failed(category: category, message: message))
            }

        case .turnCancelled(let turnID):
            _ = finishPersistedTurn(turnID: turnID, outcome: .cancelled)
            do {
                try await processQueueIfPossible()
            } catch {
                DebugLog.agent("DaemonChatController.turnCancelled queue advance failed: \(error)")
            }

        case .transportClosed:
            if let turnID = currentClaimTurnID {
                if consumePendingCancellation(turnID: turnID) {
                    _ = finishPersistedTurn(turnID: turnID, outcome: .cancelled)
                } else {
                    _ = finishPersistedTurn(
                        turnID: turnID,
                        outcome: .interrupted(message: "The daemon transport exited before the turn completed.")
                    )
                }
            }
            if snapshot.lifecycle != .closed {
                record(.sessionClosed)
            }
            runtimeHandle = nil

        case .resumed(let providerSessionID):
            do {
                try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: providerSessionID)
            } catch {
                DebugLog.store("DaemonChatController resume writeback failed: \(error)")
            }
        }
    }

    private func appendTranscriptItems(_ items: [ChatTranscriptItem]) throws {
        guard items.isEmpty == false else { return }
        _ = try store.appendChatTranscriptItems(chatID: chatID, items: items)
    }

    @discardableResult
    private func finishPersistedTurn(
        turnID: ChatTurnID,
        outcome: ChatTurnTerminalOutcome
    ) -> Bool {
        guard let claimID = currentClaimID,
              currentClaimTurnID == turnID,
              let activeTurn = snapshot.activeTurn,
              activeTurn.turnID == turnID,
              activeTurn.state.isTerminal == false else {
            return false
        }

        let persistenceState: ChatTurnPersistenceState
        let message: String?
        let payload: ChatSessionEventPayload
        switch outcome {
        case .completed:
            persistenceState = .completed
            message = nil
            payload = .completed(turnID: turnID)
        case .cancelled:
            persistenceState = .cancelled
            message = "Cancelled."
            payload = .cancelled(turnID: turnID)
        case .failed(let category, let terminalMessage):
            persistenceState = .failed
            message = terminalMessage
            payload = .failed(
                turnID: turnID,
                category: category,
                message: terminalMessage,
                createdAt: Date()
            )
        case .interrupted(let terminalMessage):
            persistenceState = .failed
            message = terminalMessage
            payload = .failed(
                turnID: turnID,
                category: .interrupted,
                message: terminalMessage,
                createdAt: Date()
            )
        }

        do {
            _ = try store.finishPersistedChatTurn(
                chatID: chatID,
                turnID: turnID,
                claimID: claimID,
                state: persistenceState,
                terminalMessage: message
            )
        } catch {
            DebugLog.store("DaemonChatController.finishPersistedTurn failed: \(error)")
        }

        currentClaimID = nil
        currentClaimTurnID = nil
        record(payload)
        return true
    }

    private func consumePendingCancellation(turnID: ChatTurnID) -> Bool {
        guard pendingCancellationTurnID == turnID else { return false }
        pendingCancellationTurnID = nil
        return true
    }

    private func record(_ payload: ChatSessionEventPayload) {
        let next: ChatUpdateSequence
        do {
            next = try nextSequence.next()
        } catch {
            DebugLog.agent("DaemonChatController sequence overflow: \(error)")
            return
        }
        let update = ChatSessionUpdate(
            chatID: chatID,
            generation: generation,
            sequence: next,
            payload: payload
        )
        replayBuffer.append(update)
        nextSequence = next

        if case .applied(let applied) = ChatSessionMachine.apply(update, to: snapshot) {
            snapshot = applied
        } else if case .sessionClosed = payload {
            snapshot = ChatRuntimeSnapshot(
                chatID: snapshot.chatID,
                generation: snapshot.generation,
                lifecycle: .closed,
                activeTurn: nil,
                queuedTurns: snapshot.queuedTurns,
                attention: .none,
                capabilities: snapshot.capabilities,
                providerState: snapshot.providerState,
                usage: snapshot.usage,
                diagnostics: snapshot.diagnostics,
                transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
                lastIncludedSequence: next
            )
        }
    }

    private static func bootstrapSnapshot(
        chatID: ChatID,
        store: GRDBWikiStore,
        generation: ChatSessionGenerationID
    ) throws -> ChatRuntimeSnapshot {
        let chat = try store.getChat(id: chatID)
        let turns = try store.listPersistedChatTurns(chatID: chatID)

        let interruptedMessage = "This turn was interrupted when the daemon restarted."
        let interrupted = turns.filter { [.claimed, .providerSubmitted].contains($0.state) }
        for turn in interrupted {
            guard let claimID = turn.claimID else { continue }
            do {
                _ = try store.finishPersistedChatTurn(
                    chatID: chatID,
                    turnID: turn.submission.turnID,
                    claimID: claimID,
                    state: .failed,
                    terminalMessage: interruptedMessage
                )
            } catch {
                DebugLog.store("DaemonChatController.bootstrapSnapshot interrupted finish failed: \(error)")
            }
        }
        if interrupted.isEmpty == false {
            do {
                try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: nil)
            } catch {
                DebugLog.store("DaemonChatController.bootstrapSnapshot session reset failed: \(error)")
            }
        }

        let queuedTurns = turns
            .filter { $0.state == .queued }
            .sorted(by: { $0.ordinal < $1.ordinal })
            .map { ChatQueuedTurn(ordinal: $0.ordinal, submission: $0.submission, editedAt: $0.editedAt) }

        let interruptedTurn = interrupted.first.map {
            ChatTurnSnapshot(
                turnID: $0.submission.turnID,
                commandID: $0.submission.commandID,
                visibleText: $0.submission.userText,
                contextReferences: $0.submission.contextReferences,
                submittedAt: $0.submission.submittedAt,
                editedAt: $0.editedAt,
                state: .terminal(.interrupted(message: interruptedMessage))
            )
        }

        let activeTurn = interruptedTurn ?? queuedTurns.first.map {
            ChatTurnSnapshot(
                turnID: $0.submission.turnID,
                commandID: $0.submission.commandID,
                visibleText: $0.submission.userText,
                contextReferences: $0.submission.contextReferences,
                submittedAt: $0.submission.submittedAt,
                editedAt: $0.editedAt,
                state: .queued
            )
        }
        let remainingQueuedTurns = interruptedTurn == nil && queuedTurns.isEmpty == false
            ? Array(queuedTurns.dropFirst())
            : queuedTurns

        return ChatRuntimeSnapshot(
            chatID: chatID,
            generation: generation,
            lifecycle: .closed,
            activeTurn: activeTurn,
            queuedTurns: remainingQueuedTurns,
            attention: interruptedTurn.map { .interruptedTurn($0.turnID) } ?? .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(
                providerID: chat.modelProviderId,
                modelID: chat.modelId,
                providerSessionID: interrupted.isEmpty ? chat.acpSessionId : nil
            ),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: .initial
        )
    }

    private static func persistedTranscriptItems(from deltas: [ChatTranscriptDelta]) -> [ChatTranscriptItem] {
        deltas.compactMap { delta in
            switch delta {
            case .append(let item):
                return item
            case .messageReplacement(let messageID, let turnID, let role, let text, let createdAt):
                return .message(ChatTranscriptMessageItem(
                    messageID: messageID,
                    turnID: turnID,
                    role: role,
                    text: text,
                    createdAt: createdAt
                ))
            case .toolCallUpsert(let toolCall):
                return .toolCall(toolCall)
            case .messageDelta:
                return nil
            }
        }
    }
}
#endif // canImport(WikiFSEngine)
