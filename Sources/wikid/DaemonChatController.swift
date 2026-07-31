// pattern: Mixed (unavoidable)
// Reason: the controller is the daemon's single lifecycle owner, so it must
// coordinate persistence, runtime events, replay state, and compatibility
// signaling in one actor to keep terminal-winner and queue-order invariants.

#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

actor DaemonChatController {
    private enum RuntimeCloseState {
        case open
        case closing
    }

    private static let replayCapacity = 128
    private static let liveEventOverlayCapacity = 512

    private let chatID: ChatID
    private let wikiID: WikiID
    private let store: GRDBWikiStore
    private let runtime: ChatAgentRuntime
    private let clock: @Sendable () -> Date
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void
    private let diagnosticTrace: DaemonChatDiagnostics

    private var generation: ChatSessionGenerationID
    private var snapshot: ChatRuntimeSnapshot
    private var activeContentBlock: ChatActiveContentBlock? = nil
    private var replayBuffer: ChatUpdateReplayBuffer
    private var nextSequence = ChatUpdateSequence.initial
    private var committedCursor: ChatTranscriptCursor
    private var runtimeHandle: ChatRuntimeHandle?
    private var runtimeStartRequest: ChatRuntimeStartRequest?
    private var eventTask: Task<Void, Never>?
    private var currentClaimID: ChatTurnClaimID?
    private var currentClaimTurnID: ChatTurnID?
    private var turnUsageAccumulator: ChatTurnUsageAccumulator?
    private var latestSessionUsage: SessionUsage?
    private var pendingCancellationTurnID: ChatTurnID?
    private var activePermission: ChatPendingPermissionRequest?
    private var isProcessingQueue = false
    /// The sole close owner has released this actor while `runtime.close` is
    /// in flight. Re-entrant lifecycle events must leave this state alone:
    /// only that owner may rotate the generation and reopen queue processing.
    private var runtimeCloseState: RuntimeCloseState = .open
    private var isIdleEvictionAttempt = false
    private var idleEvictionWasCancelled = false
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
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void,
        diagnosticTrace: DaemonChatDiagnostics = DaemonChatDiagnostics(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.chatID = chatID
        self.wikiID = wikiID
        self.store = store
        self.runtime = runtime
        self.clock = clock
        self.pushEvent = pushEvent
        self.diagnosticTrace = diagnosticTrace
        self.generation = ChatSessionGenerationID(rawValue: ULID.generate())
        self.replayBuffer = ChatUpdateReplayBuffer(capacity: Self.replayCapacity)
        self.snapshot = try Self.bootstrapSnapshot(
            chatID: chatID,
            store: store,
            generation: generation,
            bootstrapAt: clock()
        )
        self.committedCursor = try store.chatTranscriptCheckpoint(chatID: chatID)
        if case .permissionRequired = snapshot.attention {
            self.activePermission = nil
        }
    }

    deinit {
        eventTask?.cancel()
    }

    func submit(_ request: ChatSubmitRequest) async throws -> ChatID {
        if isIdleEvictionAttempt {
            idleEvictionWasCancelled = true
        }
        let existingTurns = try store.listPersistedChatTurns(chatID: chatID)
        if existingTurns.contains(where: { $0.submission.commandID == request.submission.commandID }) {
            return chatID
        }

        await observeDiagnostic(
            stage: .providerReceipt,
            detail: "turn-received",
            turnID: request.submission.turnID,
            content: request.submission.userText
        )

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
        await observeDiagnostic(stage: .persistence, detail: "turn-enqueued", turnID: request.submission.turnID)
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
        _ = await finishTurnIfCurrent(
            turnID: resolvedTurnID,
            generation: generation,
            outcome: .cancelled,
            at: clock()
        )
    }

    func stopSession() async {
        if let activeTurn = snapshot.activeTurn,
           activeTurn.state.isTerminal == false {
            await cancel(turnID: activeTurn.turnID)
            return
        }
        guard runtimeHandle != nil else { return }
        record(.sessionClosed)
        activePermission = nil
        let didCloseRuntime = await closeRuntimeAndRotateGeneration()
        if didCloseRuntime {
            await recoverQueuedTurnsAfterRuntimeClose(context: "stopSession")
        }
    }

    /// Closes a warm runtime only after its durable queue and active turn are
    /// quiescent. The host uses this before removing an idle controller.
    func closeIfIdle() async -> Bool {
        guard currentClaimID == nil,
              snapshot.queuedTurns.isEmpty,
              snapshot.activeTurn?.state.isTerminal != false,
              runtimeCloseState == .open else {
            return false
        }
        guard runtimeHandle != nil else { return true }
        isIdleEvictionAttempt = true
        idleEvictionWasCancelled = false
        if snapshot.lifecycle != .closed {
            record(.sessionClosed)
        }
        activePermission = nil
        _ = await closeRuntimeAndRotateGeneration()
        isIdleEvictionAttempt = false

        let remainsQuiescent = currentClaimID == nil
            && snapshot.queuedTurns.isEmpty
            && snapshot.activeTurn?.state.isTerminal != false
        guard idleEvictionWasCancelled == false, remainsQuiescent else {
            await recoverQueuedTurnsAfterRuntimeClose(context: "closeIfIdle")
            return false
        }
        return true
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

    func chatSyncSnapshot() throws -> ChatSyncSnapshot {
        ChatSyncSnapshot(projection: syncProjection())
    }

    func typedSnapshot() -> ChatRuntimeSnapshot { snapshot }

    func runtimeUsesStreamingCheckpointForTesting() async -> Bool {
        guard let launcherRuntime = runtime as? LauncherChatAgentRuntime else {
            return false
        }
        return await launcherRuntime.usesStreamingCheckpointForTesting()
    }

    func replay(after watermark: ChatUpdateSequence) -> ChatReplayResult {
        replayBuffer.replay(after: watermark)
    }

    func didUpdateProviderSessionID(_ sessionID: AcpSessionID?) {
        record(.sessionReady(
            capabilities: snapshot.capabilities,
            providerState: ChatProviderState(
                providerID: snapshot.providerState.providerID,
                modelID: snapshot.providerState.modelID,
                providerSessionID: sessionID
            )
        ))
    }

    func didUpdateCompatibilityState(_ update: ChatStateUpdate) {
        guard update != latestStateUpdate else { return }
        let previousProjection = syncProjection()
        latestStateUpdate = update
        let nextProjection = syncProjection()
        guard compatibilityMeaningfullyChanged(from: previousProjection, to: nextProjection) else { return }
        pushSyncUpdate(reason: .compatibilityRefreshed)
    }

    func didReceiveLiveEvents(_ events: [AgentEvent]) {
        let filtered = events.filter { event in
            if case .userText = event {
                return false
            }
            return true
        }
        guard filtered.isEmpty == false else { return }
        liveEvents.append(contentsOf: filtered)
        if liveEvents.count > Self.liveEventOverlayCapacity {
            liveEvents.removeFirst(liveEvents.count - Self.liveEventOverlayCapacity)
        }
    }

    private func processQueueIfPossible() async throws {
        guard isProcessingQueue == false, runtimeCloseState == .open else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        guard currentClaimID == nil else { return }
        if let activeTurn = snapshot.activeTurn,
           activeTurn.state.isTerminal == false,
           activeTurn.state != .queued {
            return
        }
        switch snapshot.attention {
        case .turnFailed, .interruptedTurn:
            guard snapshot.queuedTurns.isEmpty == false else { return }
        case .none, .permissionRequired:
            break
        }

        let startRequest = try currentRuntimeStartRequest()
        let claimID = ChatTurnClaimID(rawValue: ULID.generate())
        let startedAt = clock()
        guard let claimed = try store.claimNextPersistedChatTurn(
            chatID: chatID,
            claimID: claimID,
            claimedAt: startedAt,
            providerID: startRequest.providerID,
            modelID: startRequest.modelID
        ) else {
            return
        }

        let queuedTurn = ChatQueuedTurn(
            ordinal: claimed.ordinal,
            submission: claimed.submission,
            editedAt: claimed.editedAt
        )
        let alreadyTracked = snapshot.activeTurn?.turnID == claimed.submission.turnID
            || snapshot.queuedTurns.contains(where: { $0.submission.turnID == claimed.submission.turnID })
        if alreadyTracked == false {
            record(.queued(queuedTurn))
        }
        adoptClaimedTurnIfNeeded(queuedTurn)

        currentClaimID = claimID
        currentClaimTurnID = claimed.submission.turnID
        turnUsageAccumulator = ChatTurnUsageAccumulator(
            baseline: runtimeHandle == nil ? Self.zeroUsage : (latestSessionUsage ?? Self.zeroUsage)
        )
        record(.submitted(turnID: claimed.submission.turnID))

        let handle: ChatRuntimeHandle
        do {
            if let existingHandle = runtimeHandle {
                handle = existingHandle
            } else {
                handle = try await runtime.start(startRequest)
                runtimeHandle = handle
                runtimeStartRequest = startRequest
                startEventLoop(handle)
            }
            record(.started(turnID: claimed.submission.turnID))
            await observeDiagnostic(stage: .providerTranslation, detail: "provider-submit", turnID: claimed.submission.turnID)
            try await runtime.submitTurn(claimed.submission, in: handle)
            let marked = try store.markPersistedChatTurnProviderSubmitted(
                chatID: chatID,
                turnID: claimed.submission.turnID,
                claimID: claimID,
                providerSessionID: snapshot.providerState.providerSessionID,
                submittedAt: clock()
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
            await observeDiagnostic(stage: .persistence, detail: "provider-submitted", turnID: claimed.submission.turnID)
        } catch {
            DebugLog.agent("DaemonChatController.processQueueIfPossible submit failed: \(error)")
            _ = await finishTurnIfCurrent(
                turnID: claimed.submission.turnID,
                generation: generation,
                outcome: .failed(category: .runtimeError, message: error.localizedDescription),
                at: clock()
            )
            if let runtimeError = error as? LauncherChatAgentRuntime.RuntimeError,
               case .preflight(let message) = runtimeError {
                throw DaemonChatError.preflightFailed(message)
            }
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
        let diagnosticContext = Self.diagnosticContext(for: envelope.event)
        await observeDiagnostic(
            stage: .providerReceipt,
            detail: "runtime-event",
            turnID: diagnosticContext?.turnID,
            durableItem: diagnosticContext?.durableItem,
            content: diagnosticContext?.content
        )
        // The runtime supplies this transition with the same envelope as the
        // transcript delta. Clearing it first prevents a closed block from
        // remaining live across a semantic boundary.
        activeContentBlock = envelope.activeContentBlock

        switch envelope.event {
        case .sessionReady(let capabilities, let providerState):
            record(.sessionReady(capabilities: capabilities, providerState: providerState))

        case .transcript(let deltas):
            do {
                try appendTranscriptItems(Self.persistedTranscriptItems(from: deltas))
            } catch {
                DebugLog.store("DaemonChatController transcript persistence failed: \(error)")
            }
            await observeDiagnostic(
                stage: .reduction,
                detail: "transcript-reduced",
                turnID: diagnosticContext?.turnID,
                durableItem: diagnosticContext?.durableItem,
                content: diagnosticContext?.content
            )
            await observeDiagnostic(
                stage: .persistence,
                detail: "transcript-persisted",
                turnID: diagnosticContext?.turnID,
                durableItem: diagnosticContext?.durableItem,
                content: diagnosticContext?.content
            )
            record(.transcriptChanged(deltas))

        case .permissionRequested(let request):
            activePermission = request
            record(.permissionRequested(request))

        case .permissionResolved(let resolution):
            activePermission = nil
            record(.permissionResolved(resolution.requestID))

        case .usage(let usage):
            recordUsageIfCurrent(
                turnID: currentClaimTurnID,
                generation: envelope.generation,
                usage: usage
            )

        case .turnCompleted(let turnID):
            if consumePendingCancellation(turnID: turnID) {
                _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .cancelled, at: clock())
            } else {
                _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .completed, at: clock())
            }
            do {
                try await processQueueIfPossible()
            } catch {
                DebugLog.agent("DaemonChatController.turnCompleted queue advance failed: \(error)")
            }

        case .turnFailed(let turnID, let category, let message):
            if consumePendingCancellation(turnID: turnID) {
                _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .cancelled, at: clock())
            } else {
                _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .failed(category: category, message: message), at: clock())
            }
            do {
                try await processQueueIfPossible()
            } catch {
                DebugLog.agent("DaemonChatController.turnFailed queue advance failed: \(error)")
            }

        case .turnCancelled(let turnID):
            _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .cancelled, at: clock())
            do {
                try await processQueueIfPossible()
            } catch {
                DebugLog.agent("DaemonChatController.turnCancelled queue advance failed: \(error)")
            }

        case .transportClosed:
            if let turnID = currentClaimTurnID {
                if consumePendingCancellation(turnID: turnID) {
                    _ = await finishTurnIfCurrent(turnID: turnID, generation: envelope.generation, outcome: .cancelled, at: clock())
                } else {
                    _ = await finishTurnIfCurrent(
                        turnID: turnID,
                        generation: envelope.generation,
                        outcome: .interrupted(message: "The daemon transport exited before the turn completed."),
                        at: clock()
                    )
                }
            }
            if snapshot.lifecycle != .closed {
                record(.sessionClosed)
            }
            activePermission = nil
            let didCloseRuntime = await closeRuntimeAndRotateGeneration()
            if didCloseRuntime {
                await recoverQueuedTurnsAfterRuntimeClose(context: "transportClosed")
            }

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
        let inserted = try store.appendChatTranscriptItems(chatID: chatID, items: items)
        if let latestCursor = inserted.last?.cursor {
            committedCursor = max(committedCursor, latestCursor)
        }
    }

    @discardableResult
    private func finishTurnIfCurrent(
        turnID: ChatTurnID,
        generation eventGeneration: ChatSessionGenerationID,
        outcome: ChatTurnTerminalOutcome,
        at finishedAt: Date
    ) async -> Bool {
        guard eventGeneration == generation else {
            DebugLog.agent("DaemonChatController rejected terminal signal for stale generation \(eventGeneration.rawValue).")
            return false
        }
        guard currentClaimTurnID == turnID else {
            DebugLog.agent("DaemonChatController rejected terminal signal for non-current turn \(turnID.rawValue).")
            return false
        }
        guard let claimID = currentClaimID else {
            DebugLog.agent("DaemonChatController rejected terminal signal without a current claim.")
            return false
        }
        guard
              let activeTurn = snapshot.activeTurn,
              activeTurn.turnID == turnID,
              activeTurn.state.isTerminal == false else {
            DebugLog.agent("DaemonChatController rejected terminal signal after terminal snapshot.")
            return false
        }

        if let finalUsage = await finalRuntimeUsage() {
            guard eventGeneration == generation,
                  currentClaimTurnID == turnID,
                  currentClaimID == claimID,
                  snapshot.activeTurn?.turnID == turnID,
                  snapshot.activeTurn?.state.isTerminal == false
            else {
                DebugLog.agent("DaemonChatController rejected terminal signal after final usage snapshot changed ownership.")
                return false
            }
            if var accumulator = turnUsageAccumulator {
                _ = accumulator.record(finalUsage)
                turnUsageAccumulator = accumulator
                latestSessionUsage = finalUsage
            }
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
                failureID: ChatTranscriptFailureID(rawValue: ULID.generate()),
                category: category,
                message: terminalMessage,
                createdAt: finishedAt
            )
        case .interrupted(let terminalMessage):
            persistenceState = .failed
            message = terminalMessage
            payload = .failed(
                turnID: turnID,
                failureID: ChatTranscriptFailureID(rawValue: ULID.generate()),
                category: .interrupted,
                message: terminalMessage,
                createdAt: finishedAt
            )
        }

        do {
            _ = try store.finishPersistedChatTurn(
                chatID: chatID,
                turnID: turnID,
                claimID: claimID,
                state: persistenceState,
                terminalMessage: message,
                finishedAt: finishedAt,
                usage: turnUsageAccumulator?.values
            )
        } catch {
            DebugLog.store("DaemonChatController.finishTurnIfCurrent failed: \(error)")
            return false
        }

        currentClaimID = nil
        currentClaimTurnID = nil
        turnUsageAccumulator = nil
        activePermission = nil
        record(payload)
        liveEvents.removeAll(keepingCapacity: true)
        return true
    }

    private func finalRuntimeUsage() async -> SessionUsage? {
        guard let runtimeHandle else { return nil }
        do {
            return (try await runtime.snapshot(for: runtimeHandle)).usage
        } catch {
            DebugLog.agent("DaemonChatController.finalRuntimeUsage failed: \(error)")
            return nil
        }
    }

    private func recordUsageIfCurrent(
        turnID: ChatTurnID?,
        generation eventGeneration: ChatSessionGenerationID,
        usage: SessionUsage
    ) {
        guard eventGeneration == generation else {
            DebugLog.agent("DaemonChatController rejected usage for stale generation \(eventGeneration.rawValue).")
            return
        }
        guard let turnID, currentClaimTurnID == turnID else {
            DebugLog.agent("DaemonChatController rejected usage for non-current turn.")
            return
        }
        guard let claimID = currentClaimID else {
            DebugLog.agent("DaemonChatController rejected usage without a current claim.")
            return
        }
        guard let activeTurn = snapshot.activeTurn,
              activeTurn.turnID == turnID,
              activeTurn.state.isTerminal == false else {
            DebugLog.agent("DaemonChatController rejected usage after terminal snapshot.")
            return
        }
        guard var accumulator = turnUsageAccumulator else {
            DebugLog.agent("DaemonChatController rejected usage without an accumulator.")
            return
        }

        let values = accumulator.record(usage)
        do {
            _ = try store.updatePersistedChatTurnUsage(
                chatID: chatID,
                turnID: turnID,
                claimID: claimID,
                usage: values
            )
            turnUsageAccumulator = accumulator
            latestSessionUsage = usage
        } catch {
            DebugLog.store("DaemonChatController.recordUsageIfCurrent rejected usage: \(error)")
        }
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
        switch ChatSessionMachine.apply(update, to: snapshot) {
        case .applied(let applied):
            replayBuffer.append(update)
            nextSequence = next
            snapshot = applied
            pushSyncUpdate(reason: .sessionEvent(payload))
        case .rejected(let rejection):
            DebugLog.agent("DaemonChatController rejected update \(payload): \(rejection)")
        }
    }

    private func observeDiagnostic(
        stage: ChatDiagnosticStage,
        detail: String,
        turnID: ChatTurnID? = nil,
        durableItem: ChatDiagnosticCorrelation.Value? = nil,
        content: String? = nil
    ) async {
        await diagnosticTrace.record(
            stage: stage,
            outcome: .accepted,
            correlation: .init(
                chat: .init(rawValue: chatID.rawValue),
                generation: .init(rawValue: generation.rawValue),
                updateSequence: .init(UInt64(max(0, nextSequence.rawValue))),
                turn: turnID.map { .init(rawValue: $0.rawValue) },
                durableItem: durableItem
            ),
            detail: detail,
            content: content
        )
    }

    private func pushSyncUpdate(reason: ChatSyncUpdateReason) {
        let update = ChatSyncUpdate(
            reason: reason,
            projection: syncProjection()
        )
        pushEvent(.chatSyncUpdate(chatID: chatID, update: update))
    }

    private func syncProjection() -> ChatSyncProjection {
        ChatSyncProjection.from(
            snapshot: snapshot,
            committedCursor: committedCursor,
            pendingPermission: activePermission,
            runMetadata: compatibilityRunMetadata(),
            usage: compatibilityUsage() ?? snapshot.usage,
            diagnostics: compatibilityDiagnostics(),
            activeContentBlock: activeContentBlock
        )
    }

    private func compatibilityMeaningfullyChanged(
        from previousProjection: ChatSyncProjection?,
        to nextProjection: ChatSyncProjection?
    ) -> Bool {
        compatibilityProjectionIgnoringLastActivity(previousProjection)
            != compatibilityProjectionIgnoringLastActivity(nextProjection)
    }

    private func compatibilityProjectionIgnoringLastActivity(
        _ projection: ChatSyncProjection?
    ) -> ChatSyncProjection? {
        guard let projection else { return nil }
        return ChatSyncProjection(
            chatID: projection.chatID,
            generation: projection.generation,
            lifecycle: projection.lifecycle,
            activeTurn: projection.activeTurn,
            queuedTurns: projection.queuedTurns,
            attention: projection.attention,
            capabilities: projection.capabilities,
            providerState: projection.providerState,
            usage: projection.usage,
            diagnostics: ChatDiagnosticsState(
                stderr: projection.diagnostics.stderr,
                lastActivityAt: nil,
                currentProcessID: projection.diagnostics.currentProcessID
            ),
            activeContentBlock: projection.activeContentBlock,
            transcriptOverlay: projection.transcriptOverlay,
            committedCursor: projection.committedCursor,
            lastIncludedSequence: projection.lastIncludedSequence,
            pendingPermission: projection.pendingPermission,
            runMetadata: projection.runMetadata
        )
    }

    private func compatibilityUsage() -> SessionUsage? {
        guard let usageData = latestStateUpdate.usageData else { return nil }
        return DebugLog.trying("DaemonChatController.decodeUsage", operation: {
            try JSONDecoder().decode(SessionUsage.self, from: usageData)
        })
    }

    private func compatibilityDiagnostics() -> ChatDiagnosticsState {
        ChatDiagnosticsState(
            stderr: latestStateUpdate.stderr ?? "",
            lastActivityAt: latestStateUpdate.lastActivityAt,
            currentProcessID: latestStateUpdate.currentProcessID.flatMap(Int32.init(exactly:))
        )
    }

    private func compatibilityRunMetadata() -> ChatRunMetadata {
        ChatRunMetadata(
            preflightError: latestStateUpdate.preflightError,
            thinkingOption: latestStateUpdate.thinkingOption,
            logFileURL: latestStateUpdate.logFileURL,
            debugFolderURL: latestStateUpdate.debugFolderURL,
            runKindRaw: latestStateUpdate.runKindRaw,
            runStartedAt: latestStateUpdate.runStartedAt
        )
    }

    private func adoptClaimedTurnIfNeeded(_ queuedTurn: ChatQueuedTurn) {
        guard let activeTurn = snapshot.activeTurn else { return }
        guard activeTurn.state.isTerminal else { return }
        guard let queuedIndex = snapshot.queuedTurns.firstIndex(where: { $0.submission.turnID == queuedTurn.submission.turnID }) else {
            return
        }

        var remainingQueuedTurns = snapshot.queuedTurns
        remainingQueuedTurns.remove(at: queuedIndex)
        snapshot = ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: snapshot.generation,
            lifecycle: snapshot.lifecycle,
            activeTurn: ChatTurnSnapshot(
                turnID: queuedTurn.submission.turnID,
                commandID: queuedTurn.submission.commandID,
                visibleText: queuedTurn.submission.userText,
                contextReferences: queuedTurn.submission.contextReferences,
                submittedAt: queuedTurn.submission.submittedAt,
                editedAt: queuedTurn.editedAt,
                state: .queued
            ),
            queuedTurns: remainingQueuedTurns,
            attention: .none,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            transientTranscriptOverlay: snapshot.transientTranscriptOverlay,
            lastIncludedSequence: snapshot.lastIncludedSequence
        )
    }

    /// The configuration used to claim a turn is the exact configuration used
    /// to start its runtime. Warm turns retain their existing session's
    /// configuration instead of reading settings that can change mid-session.
    private func currentRuntimeStartRequest() throws -> ChatRuntimeStartRequest {
        if let runtimeStartRequest { return runtimeStartRequest }
        let chat = try store.getChat(id: chatID)
        return ChatRuntimeStartRequest(
            chatID: chatID,
            generation: generation,
            systemPrompt: try store.getSystemPrompt().body,
            providerID: chat.modelProviderId,
            modelID: chat.modelId,
            existingProviderSessionID: chat.acpSessionId
        )
    }

    private static let zeroUsage = SessionUsage(
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cachedReadTokens: nil,
        cachedWriteTokens: nil,
        thoughtTokens: nil,
        cost: nil,
        currency: nil,
        contextUsed: 0,
        contextSize: 0
    )

    /// Acquires the single close-owner role. A re-entrant lifecycle path can
    /// observe that close but cannot perform teardown or clear its guard.
    @discardableResult
    private func closeRuntimeAndRotateGeneration() async -> Bool {
        guard runtimeCloseState == .open else { return false }
        runtimeCloseState = .closing
        defer { runtimeCloseState = .open }
        if let handle = runtimeHandle {
            await runtime.close(handle)
        }
        runtimeHandle = nil
        runtimeStartRequest = nil
        eventTask?.cancel()
        eventTask = nil
        liveEvents.removeAll(keepingCapacity: true)
        pendingCancellationTurnID = nil
        currentClaimID = nil
        currentClaimTurnID = nil
        turnUsageAccumulator = nil
        latestSessionUsage = nil
        generation = ChatSessionGenerationID(rawValue: ULID.generate())
        snapshot = ChatRuntimeSnapshot(
            chatID: snapshot.chatID,
            generation: generation,
            lifecycle: .closed,
            activeTurn: snapshot.activeTurn,
            queuedTurns: snapshot.queuedTurns,
            attention: snapshot.attention,
            capabilities: snapshot.capabilities,
            providerState: snapshot.providerState,
            usage: snapshot.usage,
            diagnostics: snapshot.diagnostics,
            transientTranscriptOverlay: [],
            lastIncludedSequence: snapshot.lastIncludedSequence
        )
        return true
    }

    /// A turn can be durably queued while the close owner is awaiting a
    /// runtime. Recover only after that owner has restored an open lifecycle,
    /// so a queued turn can never be stranded behind a completed close.
    private func recoverQueuedTurnsAfterRuntimeClose(context: String) async {
        do {
            try await processQueueIfPossible()
        } catch {
            DebugLog.agent("DaemonChatController.\(context) queue recovery failed: \(error)")
        }
    }

    static func bootstrapSnapshot(
        chatID: ChatID,
        store: GRDBWikiStore,
        generation: ChatSessionGenerationID,
        bootstrapAt: Date = Date()
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
                    terminalMessage: interruptedMessage,
                    finishedAt: bootstrapAt,
                    usage: turn.usage
                )
            } catch {
                DebugLog.store("DaemonChatController.bootstrapSnapshot interrupted finish failed: \(error)")
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
                providerSessionID: chat.acpSessionId
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
            case .messageDelta(let messageID, let turnID, let role, let delta, let createdAt):
                return .message(ChatTranscriptMessageItem(
                    messageID: messageID,
                    turnID: turnID,
                    role: role,
                    text: delta,
                    createdAt: createdAt
                ))
            }
        }
    }

    private struct DiagnosticTranscriptContext {
        let durableItem: ChatDiagnosticCorrelation.Value
        let turnID: ChatTurnID
        let content: String?
    }

    /// Returns a stable identity only when the runtime envelope changes one
    /// durable item. Mixed batches deliberately stay uncoalesced so unrelated
    /// transcript changes cannot overwrite one another in the diagnostic ring.
    private static func diagnosticContext(
        for event: ChatAgentRuntimeEvent
    ) -> DiagnosticTranscriptContext? {
        guard case .transcript(let deltas) = event else { return nil }
        let contexts = deltas.compactMap(diagnosticContext(for:))
        guard let first = contexts.first,
              contexts.count == deltas.count,
              contexts.allSatisfy({ $0.durableItem == first.durableItem })
        else { return nil }
        return contexts.last
    }

    private static func diagnosticContext(
        for delta: ChatTranscriptDelta
    ) -> DiagnosticTranscriptContext? {
        switch delta {
        case .messageDelta(let messageID, let turnID, _, let text, _),
             .messageReplacement(let messageID, let turnID, _, let text, _):
            return .init(
                durableItem: .init(rawValue: messageID.rawValue),
                turnID: turnID,
                content: text
            )
        case .toolCallUpsert(let toolCall):
            return .init(
                durableItem: .init(rawValue: toolCall.toolCallID.rawValue),
                turnID: toolCall.turnID,
                content: nil
            )
        case .append(let item):
            guard case .message(let message) = item else { return nil }
            return .init(
                durableItem: .init(rawValue: message.messageID.rawValue),
                turnID: message.turnID,
                content: message.text
            )
        }
    }
}
#endif // canImport(WikiFSEngine)
