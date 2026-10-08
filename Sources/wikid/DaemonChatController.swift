// pattern: Mixed (unavoidable)
// Reason: the controller is the daemon's single lifecycle owner, so it must
// coordinate persistence, runtime events, replay state, and compatibility
// signaling in one actor to keep terminal-winner and queue-order invariants.

#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

actor DaemonChatController {
    private struct PreparationContext {
        let generation: ChatSessionGenerationID
        let operationID: UUID
    }

    private struct DispatchContext {
        let claimID: ChatTurnClaimID
        let turnID: ChatTurnID
        let generation: ChatSessionGenerationID
        let operationID: UUID
    }

    private struct ActiveContext {
        let claimID: ChatTurnClaimID
        let turnID: ChatTurnID
        let generation: ChatSessionGenerationID
        let operationID: UUID
    }

    private struct SettlingContext {
        /// Where the sole settlement owner is in its work. A retry is only
        /// legal from `persistenceFailure`; every other phase treats a repeat
        /// Stop as an idempotent duplicate.
        enum Phase {
            case gatheringUsage
            case writingOutcome
            case awaitingClose
            case persistenceFailure
        }

        /// Optional because an unclaimed queued turn has no claim to settle.
        let claimID: ChatTurnClaimID?
        let turnID: ChatTurnID
        let generation: ChatSessionGenerationID
        var operationID: UUID
        var phase: Phase = .gatheringUsage
    }

    private struct ClosingContext {
        let operationID: UUID
    }

    private struct IdleEvictionContext {
        let operationID: UUID
    }

    private struct ShutdownContext {
        let operationID: UUID
    }

    private enum DispatchOwnership {
        case idle
        case preparing(PreparationContext)
        case dispatching(DispatchContext)
        case active(ActiveContext)
        case settling(SettlingContext)
        case closing(ClosingContext)
        case idleEviction(IdleEvictionContext)
        case shutdown(ShutdownContext)
    }

    private enum DeferredDrain {
        case none
        case queue
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
    private var dispatchTask: Task<Void, Never>?
    private var ownership: DispatchOwnership = .idle
    private var deferredDrain: DeferredDrain = .none
    private var cancellationRequestedTurnID: ChatTurnID?
    private var turnUsageAccumulator: ChatTurnUsageAccumulator?
    private var latestSessionUsage: SessionUsage?
    private var activePermission: ChatPendingPermissionRequest?
    private var isShutdown: Bool {
        if case .shutdown = ownership { return true }
        return false
    }
    private var currentClaimID: ChatTurnClaimID? {
        switch ownership {
        case .dispatching(let context): return context.claimID
        case .active(let context): return context.claimID
        case .settling(let context): return context.claimID
        default: return nil
        }
    }
    private var currentClaimTurnID: ChatTurnID? {
        switch ownership {
        case .dispatching(let context): return context.turnID
        case .active(let context): return context.turnID
        case .settling(let context): return context.turnID
        default: return nil
        }
    }
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
        dispatchTask?.cancel()
    }

    func submit(_ request: ChatSubmitRequest) async throws -> ChatID {
        guard isShutdown == false else { throw DaemonChatError.shutdownStarted }
        if case .idleEviction = ownership {
            deferredDrain = .queue
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

    /// Cancels the current turn, then continues the remaining durable queue in
    /// FIFO order. A nil `turnID` cancels whatever the snapshot currently
    /// treats as active, which is what the app's Stop action sends.
    ///
    /// Queued followers are preserved. Full session shutdown is a separate
    /// operation (`terminateSessionForShutdown`).
    func cancel(turnID: ChatTurnID?) async {
        guard isShutdown == false else { return }

        let resolvedTurnID: ChatTurnID
        if let activeTurn = snapshot.activeTurn {
            let candidate = turnID ?? activeTurn.turnID
            // A request naming a different turn must not mutate this one.
            guard candidate == activeTurn.turnID else { return }
            resolvedTurnID = candidate
        } else if let turnID {
            // Bootstrap can hold no active turn while a preparation is in
            // flight; the caller still names the turn it wants stopped.
            resolvedTurnID = turnID
        } else {
            return
        }

        // A settlement already in flight owns this turn. Only a settlement
        // that failed to persist admits a retry. Every other phase is a
        // duplicate Stop and must not run a second effect.
        if case .settling(var context) = ownership, context.turnID == resolvedTurnID {
            guard context.phase == .persistenceFailure else { return }
            context.phase = .writingOutcome
            context.operationID = UUID()
            ownership = .settling(context)
            await settleCancellation(context: context)
            return
        }

        // An in-flight preparation holds no claim yet. Invalidate it first so
        // it cannot claim or send, then settle the still-unclaimed row.
        if case .preparing(let preparation) = ownership {
            dispatchTask?.cancel()
            ownership = .settling(SettlingContext(
                claimID: nil,
                turnID: resolvedTurnID,
                generation: preparation.generation,
                operationID: UUID()))
            record(.cancellationRequested(turnID: resolvedTurnID))
            await cancelUnclaimedActiveTurn(resolvedTurnID)
            return
        }

        guard let activeTurn = snapshot.activeTurn, activeTurn.state.isTerminal == false else {
            // No live turn to stop. Cancel a durable unclaimed row if the
            // caller named one, without touching any other turn.
            if snapshot.activeTurn == nil {
                await cancelUnclaimedActiveTurn(resolvedTurnID)
            }
            return
        }

        // Enter the cancelling turn state before any runtime effect so the
        // projection reports Cancelling… and refuses new submissions.
        record(.cancellationRequested(turnID: resolvedTurnID))

        guard let claimID = currentClaimID else {
            await cancelUnclaimedActiveTurn(resolvedTurnID)
            return
        }

        cancellationRequestedTurnID = resolvedTurnID
        let context = SettlingContext(
            claimID: claimID,
            turnID: resolvedTurnID,
            generation: generation,
            operationID: UUID())
        ownership = .settling(context)
        await settleCancellation(context: context)
    }

    /// Cancels a durable row that no runtime has claimed. No runtime close and
    /// no generation rotation happen on this path: there is nothing to tear
    /// down. The follower is promoted by the domain and dispatched here.
    private func cancelUnclaimedActiveTurn(_ turnID: ChatTurnID) async {
        do {
            guard let cancelled = try store.cancelUnclaimedPersistedChatTurn(chatID: chatID, turnID: turnID) else {
                ownership = .idle
                await drainIfRequested(context: "cancelUnclaimedActiveTurn")
                return
            }
            ownership = .idle
            record(.cancelled(turnID: cancelled.submission.turnID))
        } catch {
            DebugLog.store("DaemonChatController.cancel unclaimed write failed: \(error)")
            // Retain a nonterminal turn with a retryable attention. Ownership
            // stays with the settlement so a retry can repeat only this write.
            ownership = .settling(SettlingContext(
                claimID: nil,
                turnID: turnID,
                generation: generation,
                operationID: UUID(),
                phase: .persistenceFailure))
            record(.cancellationPersistenceFailed(
                turnID: turnID,
                message: "Could not save cancellation. Retry cancellation."))
            return
        }
        await recoverQueuedTurnsAfterRuntimeClose(context: "cancelUnclaimedActiveTurn")
    }

    /// The sole settlement owner for a claimed turn. It gathers final usage,
    /// commits exactly one terminal outcome, then closes the runtime and lets
    /// the queue continue on a fresh generation.
    private func settleCancellation(context: SettlingContext) async {
        guard let claimID = context.claimID else {
            // Unclaimed settlement: repeat only the durable unclaimed write.
            await cancelUnclaimedActiveTurn(context.turnID)
            return
        }

        // Stop provider work first. The launcher stop is destructive, which is
        // exactly why followers wait for the close below instead of reusing
        // this handle.
        if let handle = runtimeHandle {
            do {
                try await runtime.cancelTurn(context.turnID, in: handle)
            } catch {
                DebugLog.agent("DaemonChatController runtime cancel failed: \(error)")
            }
        }

        // Revalidate the claim after every suspension. A transport close or a
        // reentrant event must not let another owner settle this turn.
        let finalUsage = await finalRuntimeUsage()
        guard case .settling(let current) = ownership,
              current.operationID == context.operationID,
              current.claimID == claimID,
              current.turnID == context.turnID,
              context.generation == generation else {
            DebugLog.agent("DaemonChatController settlement lost ownership; another owner took the turn.")
            return
        }
        if let finalUsage, var accumulator = turnUsageAccumulator {
            _ = accumulator.record(finalUsage)
            turnUsageAccumulator = accumulator
            latestSessionUsage = finalUsage
        }

        var writing = current
        writing.phase = .writingOutcome
        ownership = .settling(writing)

        do {
            _ = try store.finishPersistedChatTurn(
                chatID: chatID,
                turnID: context.turnID,
                claimID: claimID,
                state: .cancelled,
                terminalMessage: "Cancelled.",
                finishedAt: clock(),
                usage: turnUsageAccumulator?.values
            )
        } catch {
            // The durable row and the claim are retained. Followers stay
            // blocked until a retry repeats only this write.
            DebugLog.store("DaemonChatController cancellation persistence failed: \(error)")
            record(.cancellationPersistenceFailed(
                turnID: context.turnID,
                message: "Could not save cancellation. Retry cancellation."))
            var failed = context
            failed.phase = .persistenceFailure
            ownership = .settling(failed)
            return
        }

        // Terminal persistence is committed. The cancelled runtime is
        // destructive to reuse, so close it and rotate before a follower runs.
        var awaitingClose = context
        awaitingClose.phase = .awaitingClose
        ownership = .settling(awaitingClose)
        let closed = await closeRuntimeForSettlement(turnID: context.turnID)
        guard closed else {
            // Close ownership is retained; followers stay blocked until a
            // retry-close succeeds.
            record(.runtimeCleanupFailed(
                turnID: context.turnID,
                message: "Could not stop the cancelled runtime. Retry cancellation."))
            var failed = context
            failed.phase = .awaitingClose
            ownership = .settling(failed)
            return
        }

        turnUsageAccumulator = nil
        activePermission = nil
        liveEvents.removeAll(keepingCapacity: true)
        cancellationRequestedTurnID = nil
        ownership = .idle
        record(.cancelled(turnID: context.turnID))
        await recoverQueuedTurnsAfterRuntimeClose(context: "settleCancellation")
    }

    /// Permanent shutdown. It rejects new submissions and never promotes or
    /// dispatches a queued follower: unclaimed followers are retained for
    /// later daemon recovery.
    func terminateSessionForShutdown() async {
        guard isShutdown == false else { return }
        // Capture the claim before taking shutdown ownership: the claim
        // accessors report only dispatching/active/settling ownership, so
        // reading it afterwards would always look unclaimed and leave a
        // claimed durable row unsettled.
        let activeTurn = snapshot.activeTurn
        let claimedTurnID: ChatTurnID? = if let activeTurn, activeTurn.state.isTerminal == false {
            activeTurn.turnID
        } else {
            nil
        }
        let claimID = currentClaimID

        // Take shutdown ownership before any await so nothing else can dispatch.
        ownership = .shutdown(ShutdownContext(operationID: UUID()))
        dispatchTask?.cancel()

        if let claimedTurnID {
            record(.cancellationRequested(turnID: claimedTurnID))
            if let claimID {
                do {
                    _ = try store.finishPersistedChatTurn(
                        chatID: chatID,
                        turnID: claimedTurnID,
                        claimID: claimID,
                        state: .cancelled,
                        terminalMessage: "Cancelled.",
                        finishedAt: clock(),
                        usage: turnUsageAccumulator?.values
                    )
                } catch {
                    DebugLog.store("DaemonChatController shutdown settlement failed: \(error)")
                }
            } else {
                do {
                    _ = try store.cancelUnclaimedPersistedChatTurn(chatID: chatID, turnID: claimedTurnID)
                } catch {
                    DebugLog.store("DaemonChatController shutdown unclaimed settlement failed: \(error)")
                }
            }
            // Retain followers without promotion.
            record(
                .cancelled(turnID: claimedTurnID),
                terminalContinuationPolicy: .retainQueuedTurns)
        }

        if let handle = runtimeHandle {
            do { try await runtime.closeForSettlement(handle) }
            catch { DebugLog.agent("DaemonChatController shutdown close failed: \(error)") }
        }
        runtimeHandle = nil
        runtimeStartRequest = nil
        eventTask?.cancel()
        eventTask = nil
        turnUsageAccumulator = nil
        activePermission = nil
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
              isShutdown == false else {
            return false
        }
        guard runtimeHandle != nil else { return true }
        let evictionOperationID = UUID()
        ownership = .idleEviction(IdleEvictionContext(operationID: evictionOperationID))
        deferredDrain = .none
        if snapshot.lifecycle != .closed {
            record(.sessionClosed)
        }
        activePermission = nil
        _ = await closeRuntimeAndRotateGeneration()

        let remainsQuiescent = currentClaimID == nil
            && snapshot.queuedTurns.isEmpty
            && snapshot.activeTurn?.state.isTerminal != false
        guard deferredDrain == .none, remainsQuiescent else {
            ownership = .idle
            await recoverQueuedTurnsAfterRuntimeClose(context: "closeIfIdle")
            return false
        }
        ownership = .idle
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
        let valueID = ChatConfigurationValueID(rawValue: value)
        try await runtime.setConfiguration(
            ChatRuntimeConfigurationChange(
                optionID: ChatConfigurationOptionID(rawValue: option),
                valueID: valueID
            ),
            in: handle
        )
        let chat = try store.getChat(id: chatID)
        try store.updateChatModelAndThinkingSelection(
            chatID: chatID,
            providerID: chat.modelProviderId,
            modelID: chat.modelId,
            configuredThinkingID: chat.configuredThinkingOptionID ?? valueID,
            effectiveThinkingID: valueID)
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
        guard isShutdown == false else { return }
        guard case .idle = ownership else {
            // Another owner is mid-effect. Record the drain so its owner runs
            // it on unwind instead of losing it behind the busy state.
            deferredDrain = .queue
            return
        }

        guard currentClaimID == nil else { return }
        if let activeTurn = snapshot.activeTurn,
           activeTurn.state.isTerminal == false,
           activeTurn.state != .queued {
            return
        }
        switch snapshot.attention {
        case .turnFailed, .interruptedTurn:
            guard snapshot.queuedTurns.isEmpty == false else { return }
        case .cancellationPersistenceFailed, .runtimeCleanupFailed:
            // Followers stay blocked until the cancellation owner settles.
            return
        case .none, .permissionRequired:
            break
        }

        let preparingGeneration = generation
        let preparationOperationID = UUID()
        ownership = .preparing(PreparationContext(generation: preparingGeneration, operationID: preparationOperationID))
        // Any exit from preparation that does not hand off to a dispatch must
        // release ownership. Leaving `.preparing` behind would wedge the
        // controller: no later drain could run, and no close could be owned.
        let startPreparation: ChatRuntimePreparedStart
        do {
            startPreparation = try await currentRuntimeStartPreparation()
        } catch {
            releasePreparationIfCurrent(operationID: preparationOperationID)
            throw error
        }
        guard generation == preparingGeneration,
              startPreparation.request.generation == preparingGeneration,
              isShutdown == false,
              isCurrentPreparation(operationID: preparationOperationID) else {
            // A cancellation or a transport close took this preparation while
            // it was suspended. Release the token and do not claim.
            releasePreparationIfCurrent(operationID: preparationOperationID)
            await runtime.discardPreparedStart(startPreparation)
            return
        }
        let startRequest = startPreparation.request
        let claimID = ChatTurnClaimID(rawValue: ULID.generate())
        let startedAt = clock()
        guard let claimed = try store.claimNextPersistedChatTurn(
            chatID: chatID,
            claimID: claimID,
            claimedAt: startedAt,
            providerID: startRequest.providerID,
            modelID: startRequest.modelID
        ) else {
            releasePreparationIfCurrent(operationID: preparationOperationID)
            await runtime.discardPreparedStart(startPreparation)
            return
        }
        // Claiming is a store write, but cancellation can still have landed
        // between the claim and this point. A claimed row that cancellation
        // already settled must not be dispatched.
        guard isCurrentPreparation(operationID: preparationOperationID) else {
            releasePreparationIfCurrent(operationID: preparationOperationID)
            await runtime.discardPreparedStart(startPreparation)
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

        let dispatchOperationID = UUID()
        ownership = .dispatching(DispatchContext(claimID: claimID, turnID: claimed.submission.turnID, generation: generation, operationID: dispatchOperationID))
        turnUsageAccumulator = ChatTurnUsageAccumulator(
            baseline: runtimeHandle == nil ? Self.zeroUsage : (latestSessionUsage ?? Self.zeroUsage)
        )
        record(.submitted(turnID: claimed.submission.turnID))

        let handle: ChatRuntimeHandle
        do {
            if let existingHandle = runtimeHandle {
                handle = existingHandle
            } else {
                handle = try await runtime.start(startPreparation)
                // Cancellation during start invalidates this dispatch. The
                // start task is not cooperative, so fence on identity and
                // release the late token instead of sending a stale prompt.
                guard isCurrentDispatch(operationID: dispatchOperationID,
                                       turnID: claimed.submission.turnID,
                                       generation: generation) else {
                    await runtime.discardPreparedStart(startPreparation)
                    return
                }
                runtimeHandle = handle
                runtimeStartRequest = startRequest
                startEventLoop(handle)
            }
            guard isCurrentDispatch(operationID: dispatchOperationID,
                                   turnID: claimed.submission.turnID,
                                   generation: generation) else {
                await runtime.discardPreparedStart(startPreparation)
                return
            }
            ownership = .active(ActiveContext(claimID: claimID, turnID: claimed.submission.turnID, generation: generation, operationID: dispatchOperationID))
            record(.started(turnID: claimed.submission.turnID))
            await observeDiagnostic(stage: .providerTranslation, detail: "provider-submit", turnID: claimed.submission.turnID)
            // Revalidate after the diagnostic await: a cancellation may have
            // taken the turn while diagnostics were recording.
            guard isCurrentDispatch(operationID: dispatchOperationID,
                                   turnID: claimed.submission.turnID,
                                   generation: generation) else { return }
            try await runtime.submitTurn(claimed.submission, in: handle)
            guard isCurrentDispatch(operationID: dispatchOperationID,
                                   turnID: claimed.submission.turnID,
                                   generation: generation) else { return }
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
            if runtimeHandle == nil {
                await runtime.discardPreparedStart(startPreparation)
            }
            DebugLog.agent("DaemonChatController.processQueueIfPossible submit failed: \(error)")
            _ = await finishTurnIfCurrent(
                turnID: claimed.submission.turnID,
                generation: generation,
                outcome: .failed(category: .runtimeError, message: error.localizedDescription),
                at: clock()
            )
            if let runtimeError = error as? LauncherChatAgentRuntime.RuntimeError,
               case .preflight(let message) = runtimeError {
                _ = await closeRuntimeAndRotateGeneration()
                throw DaemonChatError.preflightFailed(message)
            }
        }
    }

    /// True while `ownership` still belongs to the given preparation. A
    /// cancellation replaces it with `.settling`, so a late preparation can
    /// detect that it lost the turn and release its token.
    private func isCurrentPreparation(operationID: UUID) -> Bool {
        guard case .preparing(let context) = ownership else { return false }
        return context.operationID == operationID
    }

    /// Restores idle ownership only when this operation still owns it, so a
    /// cancellation that replaced the preparation is never overwritten.
    private func releasePreparationIfCurrent(operationID: UUID) {
        guard isCurrentPreparation(operationID: operationID) else { return }
        ownership = .idle
    }

    /// True while `ownership` still belongs to the given dispatch operation.
    /// Every suspension in the dispatch path revalidates through this so a
    /// cancellation cannot be overtaken by a late start or submit.
    private func isCurrentDispatch(
        operationID: UUID,
        turnID: ChatTurnID,
        generation expectedGeneration: ChatSessionGenerationID
    ) -> Bool {
        guard expectedGeneration == generation else { return false }
        switch ownership {
        case .dispatching(let context):
            return context.operationID == operationID && context.turnID == turnID
        case .active(let context):
            return context.operationID == operationID && context.turnID == turnID
        default:
            return false
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

        case .usage(let turnID, let usage):
            recordUsageIfCurrent(
                turnID: turnID,
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
            // A transport close during final-usage collection belongs to the
            // settlement owner. It must not rotate the generation or clear the
            // claim that owner is still using.
            if case .settling = ownership {
                DebugLog.agent("DaemonChatController deferred transport close to settlement owner.")
                return
            }
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
        // A settlement owns this turn's outcome. A terminal event that races
        // the cancellation must not commit a second, contradictory outcome.
        if case .settling(let context) = ownership {
            DebugLog.agent("DaemonChatController deferred terminal signal to settlement owner for \(context.turnID.rawValue).")
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

        let finalUsage = await finalRuntimeUsage()
        guard eventGeneration == generation,
              currentClaimTurnID == turnID,
              currentClaimID == claimID,
              snapshot.activeTurn?.turnID == turnID,
              snapshot.activeTurn?.state.isTerminal == false
        else {
            DebugLog.agent("DaemonChatController rejected terminal signal after final usage snapshot changed ownership.")
            return false
        }
        if let finalUsage {
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

        ownership = .idle
        turnUsageAccumulator = nil
        activePermission = nil
        record(payload)
        liveEvents.removeAll(keepingCapacity: true)
        await drainIfRequested(context: "finishTurnIfCurrent")
        return true
    }

    /// Runs a drain that another owner deferred while it held ownership.
    /// Without this, a drain requested mid-effect would be lost and a durable
    /// follower would sit unprocessed.
    private func drainIfRequested(context: String) async {
        guard deferredDrain == .queue, case .idle = ownership, isShutdown == false else { return }
        deferredDrain = .none
        do {
            try await processQueueIfPossible()
        } catch {
            DebugLog.agent("DaemonChatController.\(context) deferred drain failed: \(error)")
        }
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
        guard cancellationRequestedTurnID == turnID else { return false }
        cancellationRequestedTurnID = nil
        return true
    }

    private func record(
        _ payload: ChatSessionEventPayload,
        terminalContinuationPolicy: ChatTerminalContinuationPolicy? = nil
    ) {
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
            payload: payload,
            terminalContinuationPolicy: terminalContinuationPolicy
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

    /// Cold starts resolve provider, model, thinking, policy, credentials, and
    /// backend state through one process-local preparation. Warm turns retain
    /// the durable request from their active runtime.
    private func currentRuntimeStartPreparation() async throws -> ChatRuntimePreparedStart {
        if let runtimeStartRequest {
            return ChatRuntimePreparedStart(request: runtimeStartRequest)
        }
        let chat = try store.getChat(id: chatID)
        let request = ChatRuntimeStartRequest(
            chatID: chatID,
            generation: generation,
            systemPrompt: try store.getSystemPrompt().body,
            providerID: chat.modelProviderId,
            modelID: chat.modelId,
            existingProviderSessionID: chat.acpSessionId,
            thinkingConfiguration: nil)
        return try await runtime.prepareStart(ChatRuntimeStartInput(
            request: request,
            configuredThinkingOptionID: chat.configuredThinkingOptionID,
            priorEffectiveThinkingOptionID: chat.effectiveThinkingOptionID))
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
        guard case .closing = ownership else {
            ownership = .closing(ClosingContext(operationID: UUID()))
            if let handle = runtimeHandle {
                do { try await runtime.closeForSettlement(handle) }
                catch { DebugLog.agent("DaemonChatController runtime close failed: \(error)") }
            }
            return finishRuntimeClose()
        }
        return false
    }

    /// Closes the cancelled runtime before a follower may run on a fresh
    /// generation. It returns false when teardown failed, in which case close
    /// ownership is retained and followers stay blocked.
    private func closeRuntimeForSettlement(turnID: ChatTurnID) async -> Bool {
        guard let handle = runtimeHandle else {
            // No runtime exists, so there is nothing to close. The generation
            // must still advance, and the snapshot must carry it: rotating only
            // the controller's copy would make the terminal record look stale
            // and strand the follower.
            rotateGenerationWithClosedSnapshot()
            return true
        }
        do {
            try await runtime.closeForSettlement(handle)
        } catch {
            DebugLog.agent("DaemonChatController cancelled runtime close failed: \(error)")
            return false
        }
        // Only clear the handle once the runtime is actually gone.
        runtimeHandle = nil
        runtimeStartRequest = nil
        eventTask?.cancel()
        eventTask = nil
        liveEvents.removeAll(keepingCapacity: true)
        latestSessionUsage = nil
        rotateGenerationWithClosedSnapshot()
        return true
    }

    /// Advances the generation and records the closed lifecycle on the snapshot
    /// so controller and snapshot can never disagree about the current
    /// generation.
    private func rotateGenerationWithClosedSnapshot() {
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
    }

    private func finishRuntimeClose() -> Bool {
        runtimeHandle = nil
        runtimeStartRequest = nil
        eventTask?.cancel()
        eventTask = nil
        liveEvents.removeAll(keepingCapacity: true)
        cancellationRequestedTurnID = nil
        ownership = .idle
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
        // Another owner is mid-effect. Record the request so its owner drains
        // when it unwinds, instead of losing the drain behind the busy state.
        guard case .idle = ownership else {
            deferredDrain = .queue
            return
        }
        deferredDrain = .none
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
