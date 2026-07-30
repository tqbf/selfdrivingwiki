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

        var errorDescription: String? {
            switch self {
            case .unknownHandle:
                return "Unknown chat runtime handle."
            case .duplicateSubscriber:
                return "Duplicate chat runtime subscriber."
            case .preflight(let message):
                return message
            }
        }
    }

    private struct RuntimeState {
        let request: ChatRuntimeStartRequest
        let handle: ChatRuntimeHandle
        let stream: AsyncStream<ChatAgentRuntimeEventEnvelope>
        let continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation
        let launcher: AgentLauncher
        var hasSubscriber = false
        var startedInteractiveSession = false
        var pendingPermission: PendingPermission?
        var activeTurnID: ChatTurnID?
        var latestProviderSessionID: AcpSessionID?
        var lastFingerprint: StateFingerprint?
        var translationStateByTurn: [ChatTurnID: TranscriptTranslationState] = [:]
    }

    private struct TranscriptTranslationState: Sendable {
        struct StreamingMessageState: Sendable {
            let messageID: ChatMessageID
            let createdAt: Date
            var text: String
        }

        struct RunningToolCallState: Sendable {
            let toolCallID: ToolCallID
            let toolName: String
        }

        var assistantMessage: StreamingMessageState?
        var reasoningMessage: StreamingMessageState?
        var nextToolCallOrdinal = 0
        var runningToolCalls: [RunningToolCallState] = []
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
    private let extractionCoordinator: ExtractionCoordinator
    private let generationGate: GenerationGate
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void
    private let onSessionID: @Sendable (AcpSessionID?) async -> Void
    private let onStateUpdate: @Sendable (ChatStateUpdate) async -> Void
    private let onLiveEvents: @Sendable ([AgentEvent]) async -> Void
    private let onMessageSummary: @MainActor @Sendable (ChatID) -> Void
    private let onStreamingCheckpoint: (@MainActor @Sendable (ChatID, String, AgentEvent, Bool) -> Bool)?

    private var runtimeState: RuntimeState?
    private var monitorTask: Task<Void, Never>?

    init(
        chatID: ChatID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        extractionCoordinator: ExtractionCoordinator,
        generationGate: GenerationGate,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void,
        onSessionID: @escaping @Sendable (AcpSessionID?) async -> Void,
        onStateUpdate: @escaping @Sendable (ChatStateUpdate) async -> Void,
        onLiveEvents: @escaping @Sendable ([AgentEvent]) async -> Void,
        onMessageSummary: @escaping @MainActor @Sendable (ChatID) -> Void,
        onStreamingCheckpoint: (@MainActor @Sendable (ChatID, String, AgentEvent, Bool) -> Bool)? = nil
    ) {
        self.chatID = chatID
        self.wikiID = wikiID
        self.store = store
        self.extractionCoordinator = extractionCoordinator
        self.generationGate = generationGate
        self.pushEvent = pushEvent
        self.onSessionID = onSessionID
        self.onStateUpdate = onStateUpdate
        self.onLiveEvents = onLiveEvents
        self.onMessageSummary = onMessageSummary
        self.onStreamingCheckpoint = onStreamingCheckpoint
    }

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        if let existing = runtimeState {
            return existing.handle
        }

        let launcher = await MainActor.run {
            let launcher = AgentLauncher(generationGate: generationGate, extractionCoordinator: extractionCoordinator)
            launcher.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
            return launcher
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
        let handle = ChatRuntimeHandle(rawValue: "chat-runtime-\(chatID.rawValue)")
        runtimeState = RuntimeState(
            request: request,
            handle: handle,
            stream: stream,
            continuation: continuation,
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
            let stateMarkdown = DaemonWikiState.stateMarkdown(from: store)
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

            await state.launcher.startInteractiveQuery(
                firstMessage: firstMessage,
                firstMessageDisplay: submission.userText,
                stateMarkdown: stateMarkdown,
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
                onAcpSessionId: { [weak self] sessionID in
                    guard let self else { return }
                    Task {
                        await self.updateLatestProviderSessionID(sessionID)
                        await self.onSessionID(sessionID)
                        await self.emit(.resumed(providerSessionID: sessionID))
                    }
                },
                onEvent: { [weak self] event in
                    guard let self else { return }
                    Task {
                        await self.handleLiveEvent(event)
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

        await MainActor.run {
            state.launcher.sendInteractiveMessage(submission.userText)
        }
        runtimeState = state
    }

    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {
        guard let state = runtimeState, state.handle == handle else { throw RuntimeError.unknownHandle }
        await MainActor.run {
            state.launcher.stopAgent()
        }
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
        await MainActor.run {
            state.launcher.setConfigOption(
                configId: change.optionID.rawValue,
                value: change.valueID.rawValue
            )
        }
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
        await onLiveEvents([event])
        var translationState = state.translationStateByTurn[turnID] ?? TranscriptTranslationState()
        let deltas = Self.transcriptDeltas(
            from: [event],
            turnID: turnID,
            translationState: &translationState
        )
        state.translationStateByTurn[turnID] = translationState
        runtimeState = state
        if deltas.isEmpty == false {
            await emit(.transcript(deltas))
        }

        switch event {
        case .turnFailed(let reason):
            let category = Self.failureCategory(for: reason)
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

    private func emit(_ event: ChatAgentRuntimeEvent) async {
        guard let state = runtimeState else { return }
        state.continuation.yield(ChatAgentRuntimeEventEnvelope(
            generation: state.request.generation,
            event: event
        ))
    }

    private static func transcriptDeltas(
        from events: [AgentEvent],
        turnID: ChatTurnID,
        translationState: inout TranscriptTranslationState
    ) -> [ChatTranscriptDelta] {
        events.compactMap { event in
            switch event {
            case .userText(let text):
                return .append(.message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: ULID.generate()),
                    turnID: turnID,
                    role: .user,
                    text: text,
                    createdAt: Date()
                )))
            case .assistantText(let text):
                let current = translationState.assistantMessage
                    ?? TranscriptTranslationState.StreamingMessageState(
                        messageID: ChatMessageID(rawValue: "assistant-\(turnID.rawValue)"),
                        createdAt: Date(),
                        text: ""
                    )
                translationState.assistantMessage = TranscriptTranslationState.StreamingMessageState(
                    messageID: current.messageID,
                    createdAt: current.createdAt,
                    text: text
                )
                return .messageReplacement(
                    messageID: current.messageID,
                    turnID: turnID,
                    role: .assistant,
                    text: text,
                    createdAt: current.createdAt
                )
            case .thinking(let text):
                let current = translationState.reasoningMessage
                    ?? TranscriptTranslationState.StreamingMessageState(
                        messageID: ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)"),
                        createdAt: Date(),
                        text: ""
                    )
                translationState.reasoningMessage = TranscriptTranslationState.StreamingMessageState(
                    messageID: current.messageID,
                    createdAt: current.createdAt,
                    text: text
                )
                return .messageReplacement(
                    messageID: current.messageID,
                    turnID: turnID,
                    role: .reasoning,
                    text: text,
                    createdAt: current.createdAt
                )
            case .assistantTextDelta(let delta):
                let current = translationState.assistantMessage
                    ?? TranscriptTranslationState.StreamingMessageState(
                        messageID: ChatMessageID(rawValue: "assistant-\(turnID.rawValue)"),
                        createdAt: Date(),
                        text: ""
                    )
                let nextText = current.text + delta
                translationState.assistantMessage = TranscriptTranslationState.StreamingMessageState(
                    messageID: current.messageID,
                    createdAt: current.createdAt,
                    text: nextText
                )
                return .messageReplacement(
                    messageID: current.messageID,
                    turnID: turnID,
                    role: .assistant,
                    text: nextText,
                    createdAt: current.createdAt
                )
            case .thinkingDelta(let delta):
                let current = translationState.reasoningMessage
                    ?? TranscriptTranslationState.StreamingMessageState(
                        messageID: ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)"),
                        createdAt: Date(),
                        text: ""
                    )
                let nextText = current.text + delta
                translationState.reasoningMessage = TranscriptTranslationState.StreamingMessageState(
                    messageID: current.messageID,
                    createdAt: current.createdAt,
                    text: nextText
                )
                return .messageReplacement(
                    messageID: current.messageID,
                    turnID: turnID,
                    role: .reasoning,
                    text: nextText,
                    createdAt: current.createdAt
                )
            case .toolUse(let name, let inputSummary):
                let toolCallID = ToolCallID(rawValue: "\(turnID.rawValue)-tool-\(translationState.nextToolCallOrdinal)")
                translationState.nextToolCallOrdinal += 1
                translationState.runningToolCalls.append(.init(toolCallID: toolCallID, toolName: name))
                return .toolCallUpsert(ChatTranscriptToolCallItem(
                    toolCallID: toolCallID,
                    turnID: turnID,
                    toolName: name,
                    status: .running,
                    detail: inputSummary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                ))
            case .toolResult(let isError, let summary):
                let toolCall = translationState.runningToolCalls.isEmpty
                    ? TranscriptTranslationState.RunningToolCallState(
                        toolCallID: ToolCallID(rawValue: "\(turnID.rawValue)-tool-\(translationState.nextToolCallOrdinal)"),
                        toolName: "Tool"
                    )
                    : translationState.runningToolCalls.removeFirst()
                return .toolCallUpsert(ChatTranscriptToolCallItem(
                    toolCallID: toolCall.toolCallID,
                    turnID: turnID,
                    toolName: toolCall.toolName,
                    status: isError ? .failed : .completed,
                    detail: summary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                ))
            case .turnFailed(let reason):
                return .append(.turnFailure(ChatTranscriptTurnFailureItem(
                    turnID: turnID,
                    category: failureCategory(for: reason),
                    message: reason.description,
                    createdAt: Date()
                )))
            default:
                return nil
            }
        }
    }

    static func transcriptDeltasForTesting(from events: [AgentEvent], turnID: ChatTurnID) -> [ChatTranscriptDelta] {
        var translationState = TranscriptTranslationState()
        return transcriptDeltas(from: events, turnID: turnID, translationState: &translationState)
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

    private static func failureCategory(for reason: TurnFailureReason) -> ChatTurnFailureCategory {
        switch reason {
        case .stalled, .ceilingExceeded:
            return .interrupted
        case .agentError:
            return .runtimeError
        case .quotaExhausted:
            return .transportError
        }
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
