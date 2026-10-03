// pattern: Imperative Shell

#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

/// Thin launcher-backed implementation of the typed chat runtime protocol.
/// It keeps the legacy `AgentLauncher`/ACP lifecycle inside the daemon while
/// translating callback batches into typed runtime events.
actor LauncherChatAgentRuntime: ChatAgentRuntime {
    enum RuntimeError: Error, LocalizedError {
        case unknownHandle
        case duplicateSubscriber
        case preflight(String)
        /// The wiki's committed strategy could not be read for this turn. Never
        /// degraded to Default: authoritative instructions must not be invented
        /// from a store failure. `submitTurn` throws this as a visible turn
        /// failure.
        case strategyReadFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownHandle:
                return "Unknown chat runtime handle."
            case .duplicateSubscriber:
                return "Duplicate chat runtime subscriber."
            case .preflight(let message):
                return message
            case .strategyReadFailed(let message):
                return "Could not read the wiki's strategy for this turn: \(message)"
            }
        }
    }

    private struct RuntimeState {
        let request: ChatRuntimeStartRequest
        var providerPreparation: AgentInteractivePreparation?
        let handle: ChatRuntimeHandle
        let stream: AsyncStream<ChatAgentRuntimeEventEnvelope>
        let continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation
        let liveEventContinuation: AsyncStream<AgentEvent>.Continuation
        let liveEventConsumerTask: Task<Void, Never>
        let launcher: AgentLauncher
        var hasSubscriber = false
        var startedInteractiveSession = false
        var pendingPermission: PendingPermission?
        var activeTurnID: ChatTurnID?
        var latestProviderSessionID: AcpSessionID?
        var lastFingerprint: StateFingerprint?
        var translationStateByTurn: [ChatTurnID: AgentEventTranscriptTranslator] = [:]
    }

    private struct StateFingerprint: Equatable, Sendable {
        let isRunning: Bool
        let isGenerating: Bool
        let isAwaitingGenerationSlot: Bool
        let preflightError: String?
        let thinkingValue: String?
        let usageData: Data?
        let runKindRaw: String?
        let runStartedAt: Date?
        let stderr: String?
        let lastActivityAt: Date?
        let currentProcessID: Int?

        init(update: ChatStateUpdate) {
            self.isRunning = update.isRunning
            self.isGenerating = update.isGenerating
            self.isAwaitingGenerationSlot = update.isAwaitingGenerationSlot
            self.preflightError = update.preflightError
            self.thinkingValue = update.thinkingOption?.currentValue
            self.usageData = update.usageData
            self.runKindRaw = update.runKindRaw
            self.runStartedAt = update.runStartedAt
            self.stderr = update.stderr
            self.lastActivityAt = update.lastActivityAt
            self.currentProcessID = update.currentProcessID
        }
    }

    private let chatID: ChatID
    private let wikiID: WikiID
    private let store: GRDBWikiStore
    private let launcher: AgentLauncher
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void
    private let onSessionID: @Sendable (AcpSessionID?) async -> Void
    private let onStateUpdate: @Sendable (ChatStateUpdate) async -> Void
    private let onLiveEvents: @Sendable ([AgentEvent]) async -> Void
    private let onMessageSummary: @MainActor @Sendable (ChatID) -> Void
    private let onStreamingCheckpoint: (@MainActor @Sendable (ChatID, String, AgentEvent, Bool) -> Bool)?
    private let providerServices: any AgentProviderServices
    /// Internal test seam for configuring the real launcher before it starts.
    /// Production leaves this as a no-op; tests use it to inject an
    /// ``AgentBackend`` without replacing the launcher/event bridge.
    private let launcherConfigurator: @MainActor @Sendable (AgentLauncher) -> Void

    private var runtimeState: RuntimeState?
    private var monitorTask: Task<Void, Never>?

    init(
        chatID: ChatID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        launcher: AgentLauncher,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void,
        onSessionID: @escaping @Sendable (AcpSessionID?) async -> Void,
        onStateUpdate: @escaping @Sendable (ChatStateUpdate) async -> Void,
        onLiveEvents: @escaping @Sendable ([AgentEvent]) async -> Void,
        providerServices: any AgentProviderServices,
        onMessageSummary: @escaping @MainActor @Sendable (ChatID) -> Void,
        onStreamingCheckpoint: (@MainActor @Sendable (ChatID, String, AgentEvent, Bool) -> Bool)? = nil,
        launcherConfigurator: @escaping @MainActor @Sendable (AgentLauncher) -> Void = { _ in }
    ) {
        self.chatID = chatID
        self.wikiID = wikiID
        self.store = store
        self.launcher = launcher
        self.pushEvent = pushEvent
        self.onSessionID = onSessionID
        self.onStateUpdate = onStateUpdate
        self.onLiveEvents = onLiveEvents
        self.providerServices = providerServices
        self.onMessageSummary = onMessageSummary
        self.onStreamingCheckpoint = onStreamingCheckpoint
        self.launcherConfigurator = launcherConfigurator
    }

    func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart {
        let prepared = try await providerServices.prepareInteractive(
            providerOverride: input.request.providerID,
            modelOverride: input.request.modelID,
            configuredThinkingOptionID: input.configuredThinkingOptionID,
            priorEffectiveThinkingOptionID: input.priorEffectiveThinkingOptionID)
        let request = ChatRuntimeStartRequest(
            chatID: input.request.chatID,
            generation: input.request.generation,
            systemPrompt: input.request.systemPrompt,
            providerID: prepared.operation.selection.descriptor.id,
            modelID: prepared.operation.selection.model,
            existingProviderSessionID: input.request.existingProviderSessionID,
            thinkingConfiguration: prepared.thinkingConfiguration)
        return ChatRuntimePreparedStart(
            request: request,
            providerPreparation: prepared)
    }

    func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async {
        guard let prepared = preparation.providerPreparation else { return }
        await providerServices.release(prepared.operation.selection.token)
    }

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        try await start(ChatRuntimePreparedStart(request: request))
    }

    func start(_ preparation: ChatRuntimePreparedStart) async throws -> ChatRuntimeHandle {
        if let existing = runtimeState {
            if let unused = preparation.providerPreparation {
                await providerServices.release(unused.operation.selection.token)
            }
            return existing.handle
        }
        let request = preparation.request

        await MainActor.run { launcherConfigurator(launcher) }
        let (stream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
        // AgentLauncher invokes its callback in provider order. Yield those
        // events synchronously into one lossless stream so exactly one task
        // mutates transcript translation state at a time. A bounded policy
        // would make dropping user-visible transcript bytes legal.
        let (liveEvents, liveEventContinuation) = AsyncStream.makeStream(
            of: AgentEvent.self,
            bufferingPolicy: .unbounded
        )
        let liveEventConsumerTask = Task { [weak self] in
            for await event in liveEvents {
                guard let self else { return }
                await self.handleLiveEvent(event)
            }
        }
        let handle = ChatRuntimeHandle(rawValue: "chat-runtime-\(chatID.rawValue)")
        runtimeState = RuntimeState(
            request: request,
            providerPreparation: preparation.providerPreparation,
            handle: handle,
            stream: stream,
            continuation: continuation,
            liveEventContinuation: liveEventContinuation,
            liveEventConsumerTask: liveEventConsumerTask,
            launcher: launcher
        )
        return handle
    }

    func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        guard var state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        guard state.hasSubscriber == false else { throw RuntimeError.duplicateSubscriber }
        state.hasSubscriber = true
        runtimeState = state
        return state.stream
    }

    func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
        guard var state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        state.activeTurnID = submission.turnID
        runtimeState = state

        if state.startedInteractiveSession == false {
            let request = state.request
            let history = try store.chatMessages(chatID: chatID)
            let historySeed = history.map(\.event)
            let stateMarkdown = try DaemonWikiState.stateMarkdown(from: store)
            let systemPrompt = request.systemPrompt
            let priorSessionID = request.existingProviderSessionID
            let providerID = request.providerID
            let modelID = request.modelID
            let firstMessage: String
            if priorSessionID == nil, history.isEmpty == false {
                firstMessage = await MainActor.run {
                    let budget = AgentOperationRunner.adaptivePreambleBudget(
                        eligibleTurns: AgentOperationRunner.projectedPreambleTurns(from: history).count
                    )
                    return AgentOperationRunner.continuationPreamble(
                        from: history,
                        newMessage: submission.userText,
                        maxTurns: budget.maxTurns,
                        maxBytes: budget.maxBytes
                    )
                }
            } else {
                firstMessage = submission.userText
            }
            let firstPrePersisted = historySeed.contains(.userText(firstMessage))
            let liveEventContinuation = state.liveEventContinuation
            let preparedInteractiveOperation = state.providerPreparation?.operation
            state.providerPreparation = nil
            runtimeState = state

            // A resumed provider session may retain an earlier strategy
            // revision in its context — including a custom strategy since
            // reset to Default — so the first turn carries the CURRENT
            // committed revision as explicit per-request authority. A fresh
            // session's authority is the staged `WIKI_STATE.md` (nil here). A
            // failed resume falls back to the fresh-session compose, which
            // ignores the parameter and re-establishes authority from the
            // staged state file. Read failures throw (visible turn failure),
            // never degrade to an authoritative Default.
            let turnStrategyMarkdown: String?
            if priorSessionID != nil {
                turnStrategyMarkdown = Self.turnStrategyMarkdown(
                    try Self.readTurnStrategy(from: store))
            } else {
                turnStrategyMarkdown = nil
            }

            await state.launcher.startInteractiveQuery(
                firstMessage: firstMessage,
                firstMessageDisplay: submission.userText,
                stateMarkdown: stateMarkdown,
                turnStrategyMarkdown: turnStrategyMarkdown,
                wikiID: wikiID,
                wikiRoot: "",
                systemPrompt: systemPrompt,
                wikictlDirectory: HelpersLocation.wikictlDirectory,
                chatID: chatID,
                firstMessagePrePersisted: firstPrePersisted,
                historySeed: historySeed,
                priorAcpSessionId: priorSessionID,
                chatOverrideProviderId: providerID,
                chatOverrideModelId: modelID,
                preparedInteractiveOperation: preparedInteractiveOperation,
                thinkingConfiguration: request.thinkingConfiguration,
                onThinkingConfirmed: { [weak self] confirmedValueID in
                    guard let self else { return }
                    do {
                        let chat = try self.store.getChat(id: self.chatID)
                        try self.store.updateChatModelAndThinkingSelection(
                            chatID: self.chatID,
                            providerID: chat.modelProviderId,
                            modelID: chat.modelId,
                            configuredThinkingID: chat.configuredThinkingOptionID,
                            effectiveThinkingID: confirmedValueID)
                    } catch {
                        DebugLog.store("LauncherChatAgentRuntime thinking confirmation writeback failed: \(error)")
                    }
                },
                onAcpSessionId: { [weak self] sessionID in
                    guard let self else { return }
                    Task {
                        await self.updateLatestProviderSessionID(sessionID)
                        await self.onSessionID(sessionID)
                        await self.emit(.resumed(providerSessionID: sessionID))
                    }
                },
                onEvent: { event in
                    switch liveEventContinuation.yield(event) {
                    case .enqueued:
                        break
                    case .dropped(let dropped):
                        DebugLog.agent("LauncherChatAgentRuntime unexpectedly dropped live event: \(dropped)")
                    case .terminated:
                        DebugLog.agent("LauncherChatAgentRuntime received a live event after ingress closed")
                    @unknown default:
                        DebugLog.agent("LauncherChatAgentRuntime received an unknown ingress yield result")
                    }
                },
                onLiveUsage: { [weak self] usage in
                    guard let self else { return }
                    Task {
                        await self.emitLiveUsage(usage)
                    }
                },
                onPendingPermission: { [weak self] permission in
                    guard let self else { return }
                    Task {
                        await self.handlePendingPermission(permission)
                    }
                },
                onLock: { },
                onUnlock: { },
                onTranscript: nil,
                onMessageSummary: onMessageSummary,
                onStreamingCheckpoint: onStreamingCheckpoint
            )

            if let preflight = await MainActor.run(body: { state.launcher.preflightError }) {
                throw RuntimeError.preflight(preflight)
            }
            state.startedInteractiveSession = true
            runtimeState = state
            let providerSessionID = currentProviderSessionID(
                fallback: request.existingProviderSessionID
            )
            try await emit(.sessionReady(
                capabilities: Self.capabilities(from: await MainActor.run { state.launcher.thinkingOption }),
                providerState: ChatProviderState(
                    providerID: request.providerID,
                    modelID: request.modelID,
                    providerSessionID: providerSessionID
                )
            ))
            try await armCompatibilityPolling(for: state)
            return
        }

        // Warm follow-up: the session already carries the staged `WIKI_STATE.md`
        // from its first turn, so this turn re-sends no state file. The one thing
        // a warm turn DOES carry is explicit strategy authority — the latest
        // committed revision at submission, custom OR an explicit Default.
        // Silence is not neutral here: after a reset, the session's context
        // still holds the previous custom strategy, and only an explicit
        // Default document supersedes it. The composed prompt is immutable for
        // the turn: a strategy saved mid-turn cannot change this turn's
        // instructions; the NEXT turn captures the newer revision.
        // `displayText` keeps the transcript on the user's raw message — the
        // same preamble/display split the continue path uses.
        //
        // A strategy READ failure throws rather than degrading to Default:
        // masking a store failure as authoritative Default instructions would
        // silently strip editorial guidance. `submitTurn` already throws, so
        // the failure surfaces as a visible turn failure.
        let warmStrategy = try Self.readTurnStrategy(from: store)
        let warmPrompt = Self.turnPrompt(
            strategyMarkdown: Self.turnStrategyMarkdown(warmStrategy),
            userText: submission.userText)
        await MainActor.run {
            state.launcher.sendInteractiveMessage(
                warmPrompt,
                displayText: submission.userText)
        }
        runtimeState = state
    }

    /// Read the strategy this turn captures: the latest committed revision at
    /// submission. `nil` is the **Default strategy** — a real read result,
    /// never a failure fallback. A read failure throws
    /// `RuntimeError.strategyReadFailed`: this boundary must not mask a store
    /// failure as authoritative Default instructions.
    static func readTurnStrategy(from store: GRDBWikiStore) throws -> WikiStrategy? {
        do {
            return try store.getWikiStrategy()
        } catch {
            throw RuntimeError.strategyReadFailed("\(error)")
        }
    }

    /// One turn's explicit strategy authority: the custom strategy document,
    /// or the Default document when the wiki is at Default. Every warm or
    /// resumed turn carries this even under Default — the session's context
    /// may retain an earlier custom strategy that only an explicit Default
    /// supersedes. Page inventory is never included.
    static func turnStrategyMarkdown(_ strategy: WikiStrategy?) -> String {
        WikiStrategyRenderer.render(strategy)
    }

    /// Compose a turn prompt: the strategy authority above the user's
    /// message, using the same `--- new message ---` split as
    /// `AgentOperationRunner.continuationPreamble`.
    static func turnPrompt(strategyMarkdown: String, userText: String) -> String {
        """
        The wiki's committed editorial strategy, captured for this turn:

        \(strategyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))

        --- new message ---
        \(userText)
        """
    }

    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {
        guard let state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        await MainActor.run {
            state.launcher.stopAgent()
        }
        await state.launcher.awaitProviderRelease()
    }

    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {
        guard let state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        guard let optionID = resolution.optionID?.rawValue else {
            return
        }
        await state.launcher.resolvePendingPermission(optionId: optionID)
        await emit(.permissionResolved(resolution))
    }

    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {
        guard let state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        try await state.launcher.setConfigOption(
            configId: change.optionID.rawValue,
            value: change.valueID.rawValue)
    }

    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
        guard let state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        let launcherState = await MainActor.run { () -> (ChatStateUpdate, ThinkingEffortOption?) in
            let usageData = state.launcher.runTotalUsage.flatMap { usage in
                DebugLog.trying("LauncherChatAgentRuntime.snapshot.encodeUsage") {
                    try JSONEncoder().encode(usage)
                }
            }
            return (
                ChatStateUpdate(
                    isRunning: state.launcher.isRunning,
                    isGenerating: state.launcher.isGenerating,
                    isAwaitingGenerationSlot: state.launcher.isAwaitingGenerationSlot,
                    preflightError: state.launcher.preflightError,
                    thinkingOption: state.launcher.thinkingOption,
                    usageData: usageData,
                    logFileURL: state.launcher.logFileURL(forChat: chatID.rawValue),
                    debugFolderURL: state.launcher.debugFolderURL(forChat: chatID.rawValue),
                    runKindRaw: state.launcher.runningKind.map { "\($0)" },
                    runStartedAt: state.launcher.runStartedAt,
                    stderr: state.launcher.stderr.isEmpty ? nil : state.launcher.stderr,
                    lastActivityAt: state.launcher.lastActivityAt,
                    currentProcessID: state.launcher.currentProcessID.map(Int.init)
                ),
                state.launcher.thinkingOption
            )
        }
        return ChatRuntimeSnapshot(
            chatID: chatID,
            generation: state.request.generation,
            lifecycle: launcherState.0.isRunning ? .ready : .closed,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: Self.capabilities(from: launcherState.1),
            providerState: ChatProviderState(
                providerID: state.request.providerID,
                modelID: state.request.modelID,
                providerSessionID: state.request.existingProviderSessionID
            ),
            usage: launcherState.0.usageData.flatMap { data in
                DebugLog.trying("LauncherChatAgentRuntime.snapshot.decodeUsage") {
                    try JSONDecoder().decode(SessionUsage.self, from: data)
                }
            },
            diagnostics: ChatDiagnosticsState(
                stderr: launcherState.0.stderr ?? "",
                lastActivityAt: launcherState.0.lastActivityAt,
                currentProcessID: launcherState.0.currentProcessID.flatMap(Int32.init(exactly:))
            ),
            transientTranscriptOverlay: [],
            lastIncludedSequence: .initial
        )
    }

    func close(_ handle: ChatRuntimeHandle) async {
        guard let state = runtimeState, state.handle == handle else { return }
        monitorTask?.cancel()
        monitorTask = nil
        await MainActor.run {
            state.launcher.stopAgent()
        }
        await state.launcher.awaitProviderRelease()
        if state.startedInteractiveSession == false,
           let unused = state.providerPreparation {
            await providerServices.release(unused.operation.selection.token)
        }
        state.liveEventContinuation.finish()
        state.liveEventConsumerTask.cancel()
        runtimeState = nil
        state.continuation.finish()
    }

    private func armCompatibilityPolling(for state: RuntimeState) async throws {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                guard let current = await self.runtimeState else { return }
                let stateAndStatus = await MainActor.run { () -> (ChatStateUpdate, Int32?) in
                    let usageData = current.launcher.runTotalUsage.flatMap { usage in
                        DebugLog.trying("LauncherChatAgentRuntime.poll.encodeUsage") {
                            try JSONEncoder().encode(usage)
                        }
                    }
                    return (
                        ChatStateUpdate(
                            isRunning: current.launcher.isRunning,
                            isGenerating: current.launcher.isGenerating,
                            isAwaitingGenerationSlot: current.launcher.isAwaitingGenerationSlot,
                            preflightError: current.launcher.preflightError,
                            thinkingOption: current.launcher.thinkingOption,
                            usageData: usageData,
                            logFileURL: current.launcher.logFileURL(forChat: self.chatID.rawValue),
                            debugFolderURL: current.launcher.debugFolderURL(forChat: self.chatID.rawValue),
                            runKindRaw: current.launcher.runningKind.map { "\($0)" },
                            runStartedAt: current.launcher.runStartedAt,
                            stderr: current.launcher.stderr.isEmpty ? nil : current.launcher.stderr,
                            lastActivityAt: current.launcher.lastActivityAt,
                            currentProcessID: current.launcher.currentProcessID.map(Int.init)
                        ),
                        current.launcher.exitStatus
                    )
                }
                let update = stateAndStatus.0
                await self.forwardStateUpdate(update)

                if update.isRunning == false,
                   update.isGenerating == false,
                   let current = await self.runtimeState {
                    current.continuation.yield(.init(
                        generation: current.request.generation,
                        event: .transportClosed(status: stateAndStatus.1)
                    ))
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch is CancellationError {
                    return
                } catch {
                    DebugLog.agent("LauncherChatAgentRuntime polling sleep failed: \(error)")
                    return
                }
            }
        }
    }

    private func handleLiveEvent(_ event: AgentEvent) async {
        guard var state = runtimeState,
              let turnID = state.activeTurnID else { return }
        var translator = state.translationStateByTurn[turnID] ?? AgentEventTranscriptTranslator()
        let deltas = translator.translate([event], turnID: turnID)
        state.translationStateByTurn[turnID] = translator
        runtimeState = state

        // Commit actor-owned translation state before crossing either async
        // callback boundary. This also keeps the method correct if a future
        // caller bypasses the ordered ingress.
        await onLiveEvents([event])
        if deltas.isEmpty == false {
            await emit(
                .transcript(deltas),
                activeContentBlock: translator.activeContentBlock
            )
        }

        switch event {
        case .turnFailed(let reason):
            let category = AgentEventTranscriptTranslator.failureCategory(for: reason)
            await emit(.turnFailed(turnID: turnID, category: category, message: reason.description))
        default:
            if AgentEvent.endsGeneration(event) {
                await emit(.turnCompleted(turnID))
            }
        }
    }

    private func handlePendingPermission(_ permission: PendingPermission?) async {
        guard var state = runtimeState else { return }
        guard permission?.toolCallId != state.pendingPermission?.toolCallId else { return }
        state.pendingPermission = permission
        runtimeState = state

        guard let permission,
              let turnID = state.activeTurnID else { return }
        await emit(.permissionRequested(
            Self.permissionRequest(from: permission, turnID: turnID)
        ))
    }

    private func forwardStateUpdate(_ update: ChatStateUpdate) async {
        guard var state = runtimeState else { return }
        let fingerprint = StateFingerprint(update: update)
        guard fingerprint != state.lastFingerprint else { return }
        state.lastFingerprint = fingerprint
        runtimeState = state
        await onStateUpdate(update)
        if let usage = update.usageData.flatMap({ data in
            DebugLog.trying("LauncherChatAgentRuntime.decodeUsage") {
                try JSONDecoder().decode(SessionUsage.self, from: data)
            }
        }) {
            if let turnID = state.activeTurnID {
                await emit(.usage(turnID: turnID, usage: usage))
            }
        }
    }

    private func emitLiveUsage(_ usage: SessionUsage) async {
        guard let turnID = runtimeState?.activeTurnID else { return }
        await emit(.usage(turnID: turnID, usage: usage))
    }

    private func updateLatestProviderSessionID(_ sessionID: AcpSessionID?) {
        guard var state = runtimeState else { return }
        state.latestProviderSessionID = sessionID
        runtimeState = state
    }

    func usesStreamingCheckpointForTesting() -> Bool {
        onStreamingCheckpoint != nil
    }

    private func currentProviderSessionID(fallback: AcpSessionID?) -> AcpSessionID? {
        runtimeState?.latestProviderSessionID ?? fallback
    }

    private func emit(
        _ event: ChatAgentRuntimeEvent,
        activeContentBlock: ChatActiveContentBlock? = nil
    ) async {
        guard let state = runtimeState else { return }
        state.continuation.yield(ChatAgentRuntimeEventEnvelope(
            generation: state.request.generation,
            event: event,
            activeContentBlock: activeContentBlock
        ))
    }

    static func permissionRequest(from permission: PendingPermission, turnID: ChatTurnID) -> ChatPendingPermissionRequest {
        ChatPendingPermissionRequest(
            requestID: PermissionRequestID(rawValue: "permission-\(permission.toolCallId.rawValue)"),
            turnID: turnID,
            toolCallID: permission.toolCallId,
            title: permission.title ?? permission.toolName ?? "Permission request",
            message: permission.inputSummary ?? permission.title ?? permission.toolName ?? "Approve or reject the requested tool call.",
            options: permission.options.enumerated().map { index, option in
                ChatPermissionOption(
                    id: PermissionOptionID(rawValue: option.optionId),
                    label: option.name,
                    behavior: permissionBehavior(for: option.kind),
                    isDefault: index == 0,
                    visualIntent: permissionVisualIntent(for: option.kind)
                )
            }
        )
    }

    private static func permissionBehavior(for rawKind: String) -> ChatPermissionOptionBehavior {
        if rawKind.hasPrefix("allow") {
            return .allow
        }
        if rawKind.hasPrefix("cancel") {
            return .cancel
        }
        return .deny
    }

    private static func permissionVisualIntent(for rawKind: String) -> ChatPermissionVisualIntent? {
        if rawKind.hasPrefix("allow") {
            return .accent
        }
        if rawKind.hasPrefix("cancel") || rawKind.hasPrefix("reject") || rawKind.hasPrefix("deny") {
            return .destructive
        }
        return nil
    }

    private static func capabilities(from thinkingOption: ThinkingEffortOption?) -> ChatCapabilitySet {
        let configurationOptions: [ChatConfigurationOption] = if let thinkingOption {
            [
                ChatConfigurationOption(
                    id: ChatConfigurationOptionID(rawValue: thinkingOption.configId),
                    label: "Thinking",
                    currentValueID: ChatConfigurationValueID(rawValue: thinkingOption.currentValue),
                    valueOptions: thinkingOption.choices.map {
                        ChatConfigurationValueOption(
                            id: ChatConfigurationValueID(rawValue: $0.value),
                            label: $0.label
                        )
                    }
                )
            ]
        } else {
            []
        }
        return ChatCapabilitySet(
            supportsResume: true,
            supportsClose: true,
            configurationOptions: configurationOptions,
            supportsReasoning: true,
            supportsToolCalls: true,
            supportsPermissions: true
        )
    }
}
#endif // canImport(WikiFSEngine)
