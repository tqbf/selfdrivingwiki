import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

#if canImport(WikiFSEngine)

/// The daemon-side transport facade for interactive chat sessions.
///
/// Phase 3 moves lifecycle ownership into one controller per `ChatID`, but the
/// daemon still exports the existing request/reply surface while the XPC/client
/// synchronization migration is deferred to a later phase.
final class DaemonChatHost: @unchecked Sendable {

    // MARK: - Dependencies

    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?
    private let resolveSelectedProvider: @Sendable () -> AgentProvider
    private let resolveProviderConfig: @Sendable () -> AgentProvidersConfig
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void

    // Retained only so the pre-Phase-3 compatibility code below still
    // compiles while the controller path is taking over behavior.
    private var _sharedGate: GenerationGate?
    private let queue = DispatchQueue(label: "com.selfdrivingwiki.wikid.chat")
    private var controllers: [ChatID: DaemonChatController] = [:]
    private var sessions: [ChatID: ChatSession] = [:]
    private var statePollTasks: [ChatID: Task<Void, Never>] = [:]

    private struct ChatSession {
        let wikiID: WikiID
        let chatID: ChatID
        let launcher: AgentLauncher
    }

    // MARK: - Init

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
        resolveSelectedProvider: @escaping @Sendable () -> AgentProvider,
        resolveProviderConfig: @escaping @Sendable () -> AgentProvidersConfig,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void
    ) {
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.storeResolver = storeResolver
        self.resolveSelectedProvider = resolveSelectedProvider
        self.resolveProviderConfig = resolveProviderConfig
        self.pushEvent = pushEvent
    }

    // MARK: - Unified submit path

    @discardableResult
    func submitTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        let resolvedChatID: ChatID
        if let existingChatID = request.chatID {
            resolvedChatID = existingChatID
        } else {
            guard let store = storeResolver(request.wikiID) else {
                throw DaemonChatError.noStore(request.wikiID)
            }
            let title = ChatSummary.title(fromFirstMessage: request.submission.userText)
            resolvedChatID = try store.createChat(
                kind: .edit,
                title: title,
                modelProviderId: request.providerId,
                modelId: request.modelId
            ).id
        }

        let controller = try makeOrGetController(chatID: resolvedChatID, wikiID: request.wikiID)
        _ = try await controller.submit(request)
        return resolvedChatID
    }

    // MARK: - Start a new chat

    /// Create a `chats` row, seed the first user message, and start an
    /// interactive session. Returns the chat ULID. `providerId`/`modelId`
    /// seed the per-chat model override picked in the composer BEFORE the
    /// chat existed (`ProviderSelector` on a `.draft` session) — nil/nil for
    /// every pre-existing caller.
    func startChat(
        wikiID: WikiID, firstMessage: String,
        providerId: ProviderID? = nil, modelId: ModelID? = nil
    ) async throws -> ChatID {
        try await submitTurn(ChatSubmitRequest(
            wikiID: wikiID,
            chatID: nil,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: ULID.generate()),
                turnID: ChatTurnID(rawValue: ULID.generate()),
                userText: firstMessage,
                contextReferences: [],
                submittedAt: Date()
            ),
            providerId: providerId,
            modelId: modelId
        ))
    }

    // MARK: - Continue a persisted chat

    /// Continue a chat with a new user turn. Reads the history + `acpSessionId`
    /// from the store, builds the adaptive preamble, and starts a fresh
    /// interactive session writing to the SAME chat row.
    func continueChat(wikiID: WikiID, chatID: ChatID, message: String) async throws {
        _ = try await submitTurn(ChatSubmitRequest(
            wikiID: wikiID,
            chatID: chatID,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: ULID.generate()),
                turnID: ChatTurnID(rawValue: ULID.generate()),
                userText: message,
                contextReferences: [],
                submittedAt: Date()
            )
        ))
    }

    // MARK: - Send a follow-up turn (RC1)

    /// Send a message to an active chat. If the session died between turns
    /// (RC1), re-route to the continueChat path which re-spawns.
    func sendChatMessage(chatID: ChatID, message: String) async throws {
        guard let controller = queue.sync(execute: { controllers[chatID] }) else {
            throw DaemonChatError.noSession(chatID.rawValue)
        }
        _ = try await controller.submit(ChatSubmitRequest(
            wikiID: try resolveWikiID(for: chatID),
            chatID: chatID,
            submission: ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: ULID.generate()),
                turnID: ChatTurnID(rawValue: ULID.generate()),
                userText: message,
                contextReferences: [],
                submittedAt: Date()
            )
        ))
    }

    // MARK: - Stop a chat

    /// Stop the active turn and end the session. The launcher is retained in
    /// the registry (D1: no idle eviction for Phase C).
    func stopChat(chatID: ChatID) async {
        guard let controller = queue.sync(execute: { controllers[chatID] }) else { return }
        await controller.stopSession()
    }

    // MARK: - Chat session state (rehydration)

    /// Return the live state of a chat for client rehydration. If the daemon
    /// still has the launcher, reads from it; otherwise throws (the client
    /// falls back to reading from its local store).
    func chatSessionState(chatID: ChatID) async throws -> ChatSessionState {
        let controller = try makeOrGetController(chatID: chatID, wikiID: try resolveWikiID(for: chatID))
        return try await controller.chatSessionState()
    }

    // MARK: - Resolve a pending permission

    /// Forward a permission resolution to the launcher's backend.
    func resolvePermission(chatID: ChatID, optionId: String, approve: Bool) async {
        guard let controller = queue.sync(execute: { controllers[chatID] }) else { return }
        await controller.resolvePermission(optionID: optionId)
    }

    // MARK: - Set a config option (C4 follow-up)

    /// Set a config option (e.g. `thought_level`) on the live ACP session for
    /// `chatID`, without restarting it. Forwards to the launcher's generic
    /// `setConfigOption(configId:value:)`, which calls the ACP backend's
    /// `session/set_config_option`. Throws if no live session is held.
    func setChatConfigOption(chatID: ChatID, option: String, value: String) async throws {
        let controller = try makeOrGetController(chatID: chatID, wikiID: try resolveWikiID(for: chatID))
        try await controller.setConfiguration(option: option, value: value)
    }

    // MARK: - Test accessors

    /// Whether the host currently holds a live session for `chatID`.
    func hasLiveSession(_ chatID: ChatID) -> Bool {
        queue.sync { sessions[chatID] != nil }
    }

    /// The shared generation gate (for cross-chat serialization tests, RC3).
    /// Must be accessed on the main actor.
    @MainActor var testSharedGenerationGate: GenerationGate? { nil }

    private func makeOrGetController(chatID: ChatID, wikiID: WikiID) throws -> DaemonChatController {
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }

        return try queue.sync {
            if let existing = controllers[chatID] {
                return existing
            }

            let runtime = LauncherChatAgentRuntime(
                chatID: chatID,
                wikiID: wikiID,
                store: store,
                containerDirectory: containerDirectory,
                extractionCoordinator: extractionCoordinator,
                pushEvent: pushEvent,
                onSessionID: { sessionID in
                    if let controller = self.queue.sync(execute: { self.controllers[chatID] }) {
                        await controller.didUpdateProviderSessionID(sessionID)
                    }
                    do {
                        try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: sessionID)
                        self.pushEvent(.chatAcpSessionId(chatID: chatID, sessionId: sessionID))
                    } catch {
                        DebugLog.store("DaemonChatHost session-id writeback failed: \(error)")
                    }
                },
                onStateUpdate: { update in
                    if let controller = self.queue.sync(execute: { self.controllers[chatID] }) {
                        await controller.didUpdateCompatibilityState(update)
                    }
                },
                onLiveEvents: { events in
                    if let controller = self.queue.sync(execute: { self.controllers[chatID] }) {
                        await controller.didReceiveLiveEvents(events)
                    }
                }
            )
            let controller = try DaemonChatController(
                chatID: chatID,
                wikiID: wikiID,
                store: store,
                runtime: runtime,
                pushEvent: pushEvent
            )
            controllers[chatID] = controller
            return controller
        }
    }

    private func resolveWikiID(for chatID: ChatID) throws -> WikiID {
        let registry = WikiRegistry.load(from: containerDirectory)
        for descriptor in registry.wikis {
            guard let store = storeResolver(descriptor.id) else { continue }
            do {
                _ = try store.getChat(id: chatID)
                return descriptor.id
            } catch {
                continue
            }
        }
        throw DaemonChatError.noSession(chatID.rawValue)
    }

    // MARK: - Private: event stream wiring

    /// Set `onAgentEvent` on the launcher so every streamed event is pushed
    /// to the client. Called after `startInteractiveQuery` (which clears it
    /// via `resetRunArtifacts`).
    private func wireEventStream(chatID: ChatID, launcher: AgentLauncher) async {
        await MainActor.run {
            let push = self.pushEvent
            launcher.onAgentEvent = { event in
                push(.chatEvent(chatID: chatID, event: event))
            }
            // Also wire onPendingPermission so the client sees permission requests.
            launcher.onPendingPermission = { permission in
                push(.chatPendingPermission(chatID: chatID, permission: permission))
            }
        }
    }

    // MARK: - Private: state-change poll

    /// Start a 150ms poll that pushes `ChatStateUpdate` envelopes when the
    /// launcher's run flags change. Mirrors the existing `pendingPollTask`
    /// pattern in AgentLauncher.
    private func startStatePoll(for chatID: ChatID, launcher: AgentLauncher) {
        // Cancel any existing poll for this chat.
        queue.sync { statePollTasks[chatID]?.cancel() }

        let task = Task { @MainActor [weak self, weak launcher] in
            var lastFingerprint = ""
            while let launcher,
                  launcher.isRunning || launcher.isInteractiveSession {
                let fingerprint = Self.stateFingerprint(launcher)
                if fingerprint != lastFingerprint {
                    lastFingerprint = fingerprint
                    self?.pushStateUpdate(chatID: chatID, launcher: launcher)
                }
                // Task.sleep only throws CancellationError — expected, not actionable.
                // swiftlint:disable:next silent_try_optional
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch is CancellationError {
                    return
                } catch {
                    DebugLog.agent("DaemonChatHost state poll sleep failed: \(error)")
                    return
                }
            }
            // Final push after the session ends.
            if let launcher {
                self?.pushStateUpdate(chatID: chatID, launcher: launcher)
            }
        }
        queue.sync {
            statePollTasks[chatID] = task
        }
    }

    @MainActor
    private static func stateFingerprint(_ launcher: AgentLauncher) -> String {
        "\(launcher.isRunning)|\(launcher.isGenerating)|"
        + "\(launcher.isAwaitingGenerationSlot)|"
        + "\(launcher.preflightError ?? "")|"
        + "\(launcher.thinkingOption?.currentValue ?? "")"
    }

    @MainActor
    private func pushStateUpdate(chatID: ChatID, launcher: AgentLauncher) {
        let usageData = launcher.runTotalUsage.flatMap { usage in
            DebugLog.trying("JSONEncoder.encode", operation: { try JSONEncoder().encode(usage) })
        }
        let update = ChatStateUpdate(
            isRunning: launcher.isRunning,
            isGenerating: launcher.isGenerating,
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot,
            preflightError: launcher.preflightError,
            thinkingOption: launcher.thinkingOption,
            usageData: usageData,
            logFileURL: launcher.logFileURL(forChat: chatID.rawValue),
            debugFolderURL: launcher.debugFolderURL(forChat: chatID.rawValue),
            runKindRaw: launcher.runningKind.map { "\($0)" },
            runStartedAt: launcher.runStartedAt,
            stderr: launcher.stderr.isEmpty ? nil : launcher.stderr,
            lastActivityAt: launcher.lastActivityAt,
            currentProcessID: launcher.currentProcessID.map(Int.init))
        // TEMPORARY (stuck "responding…" badge): seam 1 of 6. If the terminal
        // update (running=false gen=false) never appears here, the daemon never
        // observed the session end and nothing downstream can clear the badge.
        DebugLog.chatLive(
            "1.daemon.push chat=\(chatID.rawValue) running=\(launcher.isRunning) "
            + "gen=\(launcher.isGenerating) awaiting=\(launcher.isAwaitingGenerationSlot)")
        pushEvent(.chatState(chatID: chatID, update: update))
    }

    // MARK: - Private: store sink handlers

    private func handleAcpSessionId(
        chatID: ChatID, sessionId: AcpSessionID?, wikiID: WikiID
    ) {
        guard let store = storeResolver(wikiID) else { return }
        do {
            try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: sessionId)
            // Push the session-id writeback to the client (#830).
            pushEvent(.chatAcpSessionId(
                chatID: chatID, sessionId: sessionId))
        } catch {
            DebugLog.store("DaemonChatHost: updateChatAcpSessionId failed: \(error)")
        }
    }

    private func handleTranscript(
        chatID: ChatID, events: [AgentEvent], wikiID: WikiID
    ) {
        guard let store = storeResolver(wikiID) else { return }
        do {
            _ = try store.appendChatMessages(chatID: chatID, events: events)
        } catch {
            DebugLog.store("DaemonChatHost: appendChatMessages failed: \(error)")
        }
    }

    // MARK: - Private: message summarization (RC5)

    /// Summarize all unsummarized assistant messages in `chatID` per the
    /// configured summarizer mode. Mirrors `AgentOperationRunner.summarizePendingMessages`
    /// but operates on `GRDBWikiStore` directly (no `WikiStoreModel`).
    ///
    /// RC5: this is the daemon-native generalization of the app's
    /// `summarizePendingMessages` + `runModelSummarization`.
    ///
    /// Also mirrors the FIRST summarizable message's summary into
    /// `chats.summary` (issue #411) — the sole writer of that column now that
    /// the launcher's always-truncated path is gone.
    private func summarizePendingMessages(
        chatID: ChatID, wikiID: WikiID, launcher: AgentLauncher
    ) {
        guard let store = storeResolver(wikiID) else { return }

        let config = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        let mode = MessageSummarizer.mode(for: config)

        let messages: [ChatMessage]
        do {
            messages = try store.chatMessages(chatID: chatID)
        } catch {
            DebugLog.store("DaemonChatHost.summarizePendingMessages: chatMessages failed: \(error)")
            return
        }

        let pending = messages.filter { msg in
            msg.summary == nil
                && (MessageSummarizer.textToSummarize(from: msg.event)?.isEmpty == false)
        }
        guard !pending.isEmpty else { return }

        // The message whose summary doubles as `chats.summary` (issue #411).
        let chatSummaryMessageID = MessageSummarizer.chatSummaryMessageID(in: messages)

        switch mode {
        case .defaultTruncation:
            for msg in pending {
                guard let text = MessageSummarizer.textToSummarize(from: msg.event) else { continue }
                let summary = MessageSummarizer.defaultSummary(for: text)
                guard !summary.isEmpty else { continue }
                do {
                    try store.updateMessageSummary(
                        chatID: chatID, messageID: msg.id,
                        summary: summary, kind: .defaultTruncation)
                    if msg.id == chatSummaryMessageID {
                        try store.updateChatSummary(chatID: chatID, summary: summary)
                    }
                } catch {
                    DebugLog.store("DaemonChatHost: summary write failed: \(error)")
                }
            }
        case .model:
            let containerDir = containerDirectory
            let credentialStore = KeychainACPCredentialStore()
            Task { @MainActor in
                await Self.runModelSummarization(
                    chatID: chatID, pending: pending, config: config,
                    containerDir: containerDir, credentialStore: credentialStore,
                    store: store, chatSummaryMessageID: chatSummaryMessageID)
            }
        }
    }

    /// Drive model-mode summarization for a batch of pending messages.
    /// Runs off-main for the ACP session(s); marshals each write to the store.
    @MainActor
    private static func runModelSummarization(
        chatID: ChatID, pending: [ChatMessage], config: AgentProvidersConfig,
        containerDir: URL, credentialStore: any ACPCredentialStore,
        store: GRDBWikiStore, chatSummaryMessageID: PageID?
    ) async {
        let loginShellPath = await PathPreflight.loginShellPATH()
        guard let profile = MessageSummarizer.resolveProfile(
            config: config,
            credentialStore: credentialStore,
            searchPath: loginShellPath) else {
            DebugLog.agent("DaemonChatHost.runModelSummarization: profile resolution failed")
            return
        }
        let backend = AgentBackendFactory.makeBackend(policy: .bypass)
        for msg in pending {
            guard let text = MessageSummarizer.textToSummarize(from: msg.event) else { continue }
            guard let summary = await MessageSummarizer.modelSummary(
                text: text, backend: backend, profile: profile) else { continue }
            do {
                try store.updateMessageSummary(
                    chatID: chatID, messageID: msg.id,
                    summary: summary, kind: .model)
                // VERBATIM into the chat row — the model already produced a
                // one-sentence summary; eliding it would chop the answer.
                if msg.id == chatSummaryMessageID {
                    try store.updateChatSummary(chatID: chatID, summary: summary)
                }
            } catch {
                DebugLog.store("DaemonChatHost.runModelSummarization: write failed: \(error)")
            }
        }
    }
}

// MARK: - Errors

enum DaemonChatError: Error, LocalizedError {
    case noStore(WikiID)
    case noSession(String)
    case emptyMessage
    case preflightFailed(String)
    case midGeneration

    var errorDescription: String? {
        switch self {
        case .noStore(let id):
            return "No store found for wiki \(id)"
        case .noSession(let id):
            return "No live chat session for \(id)"
        case .emptyMessage:
            return "The chat message is empty"
        case .preflightFailed(let msg):
            return msg
        case .midGeneration:
            return "A turn is currently generating — wait for it to finish"
        }
    }
}

#endif // canImport(WikiFSEngine)
