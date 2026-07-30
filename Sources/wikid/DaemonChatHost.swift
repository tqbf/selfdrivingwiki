import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

#if canImport(WikiFSEngine)

/// The daemon-side transport facade for interactive chat sessions.
///
/// The typed controller owns lifecycle and state. This host retains only the
/// raw XPC adapters that still form a compatibility boundary.
// pattern: Mixed (unavoidable)
// Reason: this transport facade coordinates persistence, controller lifecycle,
// and raw XPC compatibility adapters at the daemon boundary.
final class DaemonChatHost: @unchecked Sendable {

    // MARK: - Dependencies

    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void

    private let sharedGate: GenerationGate
    private let registry = ControllerRegistry()

    private static let idleEvictionSeconds = 300
    private static let idleEvictionDelay: Duration = .seconds(idleEvictionSeconds)

    // MARK: - Init

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        generationGate: GenerationGate,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void
    ) {
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.sharedGate = generationGate
        self.storeResolver = storeResolver
        self.pushEvent = pushEvent
    }

    // MARK: - Unified submit path

    @discardableResult
    func submitTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        let trimmed = request.submission.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw DaemonChatError.emptyMessage
        }
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

        let controller = try await makeOrGetController(chatID: resolvedChatID, wikiID: request.wikiID)
        do {
            _ = try await controller.submit(request)
            return resolvedChatID
        } catch {
            if request.chatID == nil,
               let store = storeResolver(request.wikiID) {
                do {
                    try store.deleteChat(id: resolvedChatID)
                } catch {
                    DebugLog.store("DaemonChatHost.submitTurn rollback failed: \(error)")
                }
            }
            throw error
        }
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
        _ = try await submitTurn(ChatSubmitRequest(
            wikiID: try await resolveWikiID(for: chatID),
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

    /// Stop the active turn and end the session.
    func stopChat(chatID: ChatID) async {
        guard let controller = await registry.controller(for: chatID) else { return }
        await controller.stopSession()
        await scheduleIdleEviction(for: chatID)
    }

    // MARK: - Chat session state (rehydration)

    /// Return the authoritative sync snapshot for a chat. If the daemon still
    /// has a live controller, reads from it; otherwise synthesizes the same
    /// typed projection from persisted state.
    func chatSessionState(chatID: ChatID) async throws -> ChatSyncSnapshot {
        if let controller = await registry.controller(for: chatID) {
            return try await controller.chatSyncSnapshot()
        }
        let wikiID = try await resolveWikiID(for: chatID)
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }
        _ = try store.getChat(id: chatID)
        return try Self.persistedOnlySessionState(chatID: chatID, store: store)
    }

    // MARK: - Resolve a pending permission

    /// Forward a permission resolution to the launcher's backend.
    func resolvePermission(chatID: ChatID, optionId: String, approve: Bool) async {
        guard let controller = await registry.controller(for: chatID) else { return }
        await controller.resolvePermission(optionID: optionId)
    }

    // MARK: - Set a config option (C4 follow-up)

    /// Set a config option (e.g. `thought_level`) on the live ACP session for
    /// `chatID`, without restarting it. Forwards to the launcher's generic
    /// `setConfigOption(configId:value:)`, which calls the ACP backend's
    /// `session/set_config_option`. Throws if no live session is held.
    func setChatConfigOption(chatID: ChatID, option: String, value: String) async throws {
        let controller = try await makeOrGetController(
            chatID: chatID,
            wikiID: try await resolveWikiID(for: chatID)
        )
        try await controller.setConfiguration(option: option, value: value)
    }

    // MARK: - Test accessors

    /// Whether the host currently holds a live session for `chatID`.
    func hasLiveSession(_ chatID: ChatID) async -> Bool {
        await registry.controller(for: chatID) != nil
    }

    /// The shared generation gate (for cross-chat serialization tests, RC3).
    /// Must be accessed on the main actor.
    @MainActor var testSharedGenerationGate: GenerationGate? { sharedGate }

    func controllerUsesStreamingCheckpointForTesting(
        chatID: ChatID,
        wikiID: WikiID
    ) async throws -> Bool {
        let controller = try await makeOrGetController(chatID: chatID, wikiID: wikiID)
        return await controller.runtimeUsesStreamingCheckpointForTesting()
    }

    func evictIdleControllerForTesting(chatID: ChatID) async -> Bool {
        await evictIdleController(chatID: chatID)
    }

    private func makeOrGetController(chatID: ChatID, wikiID: WikiID) async throws -> DaemonChatController {
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }

        if let existing = await registry.controller(for: chatID) {
            return existing
        }

        let runtime = LauncherChatAgentRuntime(
            chatID: chatID,
            wikiID: wikiID,
            store: store,
            extractionCoordinator: extractionCoordinator,
            generationGate: sharedGate,
            pushEvent: pushEvent,
            onSessionID: { [weak self] sessionID in
                guard let self else { return }
                if let controller = await self.registry.controller(for: chatID) {
                    await controller.didUpdateProviderSessionID(sessionID)
                }
                do {
                    try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: sessionID)
                } catch {
                    DebugLog.store("DaemonChatHost session-id writeback failed: \(error)")
                }
            },
            onStateUpdate: { [weak self] update in
                guard let self else { return }
                if let controller = await self.registry.controller(for: chatID) {
                    await controller.didUpdateCompatibilityState(update)
                }
                if update.isGenerating {
                    await self.registry.cancelIdleEviction(for: chatID)
                } else {
                    await self.scheduleIdleEviction(for: chatID)
                }
            },
            onLiveEvents: { [weak self] events in
                guard let self else { return }
                if let controller = await self.registry.controller(for: chatID) {
                    await controller.didReceiveLiveEvents(events)
                }
            },
            onMessageSummary: { [weak self] chatID in
                guard let self else { return }
                self.summarizePendingMessages(chatID: chatID, wikiID: wikiID)
            },
            // Phase 3's typed per-delta controller persistence is the sole
            // owner of compatibility `chat_messages` rows in the daemon path.
            // Wiring the legacy checkpoint sink here would dual-write the same
            // assistant message under a second identity and reopen #982/#990.
            onStreamingCheckpoint: nil
        )
        let controller = try DaemonChatController(
            chatID: chatID,
            wikiID: wikiID,
            store: store,
            runtime: runtime,
            pushEvent: pushEvent
        )
        return await registry.insertIfAbsent(controller, chatID: chatID, wikiID: wikiID)
    }

    private func resolveWikiID(for chatID: ChatID) async throws -> WikiID {
        if let wikiID = await registry.wikiID(for: chatID) {
            return wikiID
        }
        let registry = WikiRegistry.load(from: containerDirectory)
        for descriptor in registry.wikis {
            guard let store = storeResolver(descriptor.id) else { continue }
            do {
                _ = try store.getChat(id: chatID)
                return descriptor.id
            } catch {
                DebugLog.store("DaemonChatHost.resolveWikiID skipped \(descriptor.id.rawValue): \(error)")
                continue
            }
        }
        throw DaemonChatError.noSession(chatID.rawValue)
    }

    private static func persistedOnlySessionState(chatID: ChatID, store: GRDBWikiStore) throws -> ChatSyncSnapshot {
        let generation = ChatSessionGenerationID(rawValue: "persisted-\(chatID.rawValue)")
        let runtimeSnapshot = try DaemonChatController.bootstrapSnapshot(
            chatID: chatID,
            store: store,
            generation: generation
        )
        let committedCursor = try store.chatTranscriptCheckpoint(chatID: chatID)
        return ChatSyncSnapshot(
            projection: ChatSyncProjection.from(
                snapshot: runtimeSnapshot,
                committedCursor: committedCursor,
                pendingPermission: nil,
                runMetadata: .empty,
                usage: nil,
                diagnostics: ChatDiagnosticsState()
            )
        )
    }

    // MARK: - Idle controller eviction

    private func scheduleIdleEviction(for chatID: ChatID) async {
        await registry.scheduleIdleEviction(
            for: chatID,
            after: Self.idleEvictionDelay
        ) { [weak self] chatID in
            guard let self else { return }
            _ = await self.evictIdleController(chatID: chatID)
        }
    }

    private func evictIdleController(chatID: ChatID) async -> Bool {
        guard let controller = await registry.controller(for: chatID) else { return false }
        guard await controller.closeIfIdle() else { return false }
        await registry.remove(controller, for: chatID)
        return true
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
        chatID: ChatID, wikiID: WikiID
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

private actor ControllerRegistry {
    private struct Entry {
        let wikiID: WikiID
        let controller: DaemonChatController
    }

    private var entries: [ChatID: Entry] = [:]
    private var idleEvictionTasks: [ChatID: Task<Void, Never>] = [:]

    func controller(for chatID: ChatID) -> DaemonChatController? {
        entries[chatID]?.controller
    }

    func wikiID(for chatID: ChatID) -> WikiID? {
        entries[chatID]?.wikiID
    }

    func insertIfAbsent(
        _ controller: DaemonChatController,
        chatID: ChatID,
        wikiID: WikiID
    ) -> DaemonChatController {
        if let existing = entries[chatID] {
            return existing.controller
        }
        entries[chatID] = Entry(wikiID: wikiID, controller: controller)
        return controller
    }

    func scheduleIdleEviction(
        for chatID: ChatID,
        after delay: Duration,
        eviction: @escaping @Sendable (ChatID) async -> Void
    ) {
        idleEvictionTasks[chatID]?.cancel()
        idleEvictionTasks[chatID] = Task {
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                DebugLog.agent("DaemonChatHost idle eviction sleep failed: \(error)")
                return
            }
            await eviction(chatID)
        }
    }

    func cancelIdleEviction(for chatID: ChatID) {
        idleEvictionTasks.removeValue(forKey: chatID)?.cancel()
    }

    func remove(_ controller: DaemonChatController, for chatID: ChatID) {
        guard let current = entries[chatID], current.controller === controller else { return }
        entries.removeValue(forKey: chatID)
        idleEvictionTasks.removeValue(forKey: chatID)?.cancel()
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
