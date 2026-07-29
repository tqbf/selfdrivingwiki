// pattern: Imperative Shell

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
        var terminalEmittedForTurn: Set<ChatTurnID> = []
        var pendingPermission: PendingPermission?
    }

    private let chatID: ChatID
    private let wikiID: WikiID
    private let store: GRDBWikiStore
    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void
    private let onSessionID: @Sendable (AcpSessionID?) async -> Void
    private let onStateUpdate: @Sendable (ChatStateUpdate) async -> Void
    private let onLiveEvents: @Sendable ([AgentEvent]) async -> Void

    private var runtimeState: RuntimeState?
    private var monitorTask: Task<Void, Never>?

    init(
        chatID: ChatID,
        wikiID: WikiID,
        store: GRDBWikiStore,
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void,
        onSessionID: @escaping @Sendable (AcpSessionID?) async -> Void,
        onStateUpdate: @escaping @Sendable (ChatStateUpdate) async -> Void,
        onLiveEvents: @escaping @Sendable ([AgentEvent]) async -> Void
    ) {
        self.chatID = chatID
        self.wikiID = wikiID
        self.store = store
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.pushEvent = pushEvent
        self.onSessionID = onSessionID
        self.onStateUpdate = onStateUpdate
        self.onLiveEvents = onLiveEvents
    }

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        if let existing = runtimeState {
            return existing.handle
        }

        let launcher = await MainActor.run {
            let launcher = AgentLauncher(extractionCoordinator: extractionCoordinator)
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

        if state.startedInteractiveSession == false {
            let request = state.request
            let historySeed = try store.chatMessages(chatID: chatID).map(\.event)
            let stateMarkdown = DaemonWikiState.stateMarkdown(from: store)
            let systemPrompt = request.systemPrompt
            let priorSessionID = request.existingProviderSessionID
            let providerID = request.providerID
            let modelID = request.modelID
            let firstMessage = submission.userText
            let firstPrePersisted = historySeed.contains(.userText(firstMessage))

            await state.launcher.startInteractiveQuery(
                firstMessage: firstMessage,
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
                        await self.onSessionID(sessionID)
                        await self.emit(.resumed(providerSessionID: sessionID))
                    }
                },
                onLock: { },
                onUnlock: { },
                onTranscript: { [weak self] events in
                    guard let self else { return }
                    Task {
                        await self.onLiveEvents(events)
                        await self.pushCompatibilityTranscript(events)
                        await self.emitTranscript(events, turnID: submission.turnID)
                    }
                }
            )

            state.startedInteractiveSession = true
            runtimeState = state
            try await armCompatibilityPolling(for: state)
            try await emit(.sessionReady(
                capabilities: Self.capabilities(from: await MainActor.run { state.launcher.thinkingOption }),
                providerState: ChatProviderState(
                    providerID: request.providerID,
                    modelID: request.modelID,
                    providerSessionID: request.existingProviderSessionID
                )
            ))
            if let preflight = await MainActor.run(body: { state.launcher.preflightError }) {
                throw RuntimeError.preflight(preflight)
            }
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
                await self.onStateUpdate(update)
                self.pushEvent(.chatState(chatID: self.chatID, update: update))

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

    private func emitTranscript(_ events: [AgentEvent], turnID: ChatTurnID) async {
        let deltas = Self.transcriptDeltas(from: events, turnID: turnID)
        if deltas.isEmpty == false {
            await emit(.transcript(deltas))
        }

        for event in events {
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
    }

    private func pushCompatibilityTranscript(_ events: [AgentEvent]) {
        for event in events where event.isPersistable {
            pushEvent(.chatEvent(chatID: chatID, event: event))
        }
    }

    private func emit(_ event: ChatAgentRuntimeEvent) async {
        guard let state = runtimeState else { return }
        state.continuation.yield(ChatAgentRuntimeEventEnvelope(
            generation: state.request.generation,
            event: event
        ))
    }

    private static func transcriptDeltas(from events: [AgentEvent], turnID: ChatTurnID) -> [ChatTranscriptDelta] {
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
                return .append(.message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: ULID.generate()),
                    turnID: turnID,
                    role: .assistant,
                    text: text,
                    createdAt: Date()
                )))
            case .thinking(let text):
                return .append(.message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: ULID.generate()),
                    turnID: turnID,
                    role: .reasoning,
                    text: text,
                    createdAt: Date()
                )))
            case .assistantTextDelta(let delta):
                return .messageDelta(
                    messageID: ChatMessageID(rawValue: "assistant-\(turnID.rawValue)"),
                    turnID: turnID,
                    role: .assistant,
                    delta: delta,
                    createdAt: Date()
                )
            case .thinkingDelta(let delta):
                return .messageDelta(
                    messageID: ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)"),
                    turnID: turnID,
                    role: .reasoning,
                    delta: delta,
                    createdAt: Date()
                )
            case .toolUse(let name, let inputSummary):
                return .toolCallUpsert(ChatTranscriptToolCallItem(
                    toolCallID: ToolCallID(rawValue: "\(turnID.rawValue)-\(name)"),
                    turnID: turnID,
                    toolName: name,
                    status: .running,
                    detail: inputSummary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                ))
            case .toolResult(let isError, let summary):
                return .append(.toolCall(ChatTranscriptToolCallItem(
                    toolCallID: ToolCallID(rawValue: "\(turnID.rawValue)-result"),
                    turnID: turnID,
                    toolName: "Tool",
                    status: isError ? .failed : .completed,
                    detail: summary,
                    permissionRequestID: nil,
                    updatedAt: Date()
                )))
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
