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
    private let storeResolver: @Sendable (WikiID) -> GRDBWikiStore?
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void
    private let diagnosticTrace: DaemonChatDiagnostics
    private let providerServices: any AgentProviderServices

    private let launcher: AgentLauncher
    private let sharedGate: GenerationGate
    private let registry = ControllerRegistry()
    private let idleEvictionDelay: Duration

    private static let idleEvictionSeconds = 300
    private static let defaultIdleEvictionDelay: Duration = .seconds(idleEvictionSeconds)

    // MARK: - Init

    @MainActor
    init(
        containerDirectory: URL,
        launcherPair: LauncherPair,
        storeResolver: @escaping @Sendable (WikiID) -> GRDBWikiStore?,
        pushEvent: @escaping @Sendable (QueueEventEnvelope) -> Void,
        diagnosticTrace: DaemonChatDiagnostics = DaemonChatDiagnostics(),
        providerServices: any AgentProviderServices,
        idleEvictionDelay: Duration = DaemonChatHost.defaultIdleEvictionDelay
    ) {
        self.containerDirectory = containerDirectory
        self.launcher = launcherPair.launcher
        self.sharedGate = launcherPair.gate
        self.storeResolver = storeResolver
        self.pushEvent = pushEvent
        self.diagnosticTrace = diagnosticTrace
        self.providerServices = providerServices
        self.idleEvictionDelay = idleEvictionDelay
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
            let config = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
            let thinking = config.resolveThinkingCapability(
                chatOverrideProviderID: request.providerId,
                chatOverrideModelID: request.modelId,
                configuredValueID: request.configuredThinkingOptionID)
            resolvedChatID = try store.createChat(
                kind: .edit,
                title: title,
                modelProviderId: request.providerId,
                modelId: request.modelId,
                configuredThinkingOptionID: request.configuredThinkingOptionID,
                effectiveThinkingOptionID: thinking.effectiveValueID
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
                    let removed = await evictIdleController(chatID: resolvedChatID)
                    if removed == false {
                        // A close may be in flight. Keep a bounded retry for
                        // this now-deleted draft instead of retaining its
                        // controller until an unrelated state update occurs.
                        await scheduleIdleEviction(for: resolvedChatID)
                    }
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
        providerId: ProviderID? = nil,
        modelId: ModelID? = nil,
        configuredThinkingOptionID: ChatConfigurationValueID? = nil
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
            modelId: modelId,
            configuredThinkingOptionID: configuredThinkingOptionID
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

    func shutdown() async {
        let controllers = await registry.removeAllForShutdown()
        for controller in controllers {
            await controller.stopSession()
        }
    }

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

    func liveControllerCountForTesting() async -> Int {
        await registry.count()
    }

    func isIdleEvictionScheduledForTesting(chatID: ChatID) async -> Bool {
        await registry.isIdleEvictionScheduled(for: chatID)
    }

    func idleEvictionTaskCountForTesting(chatID: ChatID) async -> Int {
        await registry.idleEvictionTaskCount(for: chatID)
    }

    private func makeOrGetController(chatID: ChatID, wikiID: WikiID) async throws -> DaemonChatController {
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }

        if let existing = await registry.acquireController(for: chatID) {
            await scheduleIdleEviction(for: chatID)
            return existing
        }

        let runtime = LauncherChatAgentRuntime(
            chatID: chatID,
            wikiID: wikiID,
            store: store,
            launcher: launcher,
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
            providerServices: providerServices,
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
            pushEvent: pushEvent,
            diagnosticTrace: diagnosticTrace
        )
        let resolvedController = await registry.insertIfAbsent(
            controller,
            chatID: chatID,
            wikiID: wikiID
        )
        await scheduleIdleEviction(for: chatID)
        return resolvedController
    }

    private func resolveWikiID(for chatID: ChatID) async throws -> WikiID {
        if let wikiID = await registry.wikiID(for: chatID) {
            return wikiID
        }
        let wikiRegistry = WikiRegistry.load(from: containerDirectory)
        for descriptor in wikiRegistry.wikis {
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
            after: idleEvictionDelay
        ) { [weak self] chatID in
            guard let self else { return }
            _ = await self.evictIdleController(chatID: chatID)
        }
    }

    private func evictIdleController(chatID: ChatID) async -> Bool {
        let reservation = await registry.reserveForIdleEviction(for: chatID)
        guard case .reserved(let controller) = reservation else {
            return false
        }
        guard await controller.closeIfIdle() else {
            await registry.abandonIdleEviction(for: chatID, controller: controller)
            await scheduleIdleEviction(for: chatID)
            return false
        }
        let removed = await registry.removeIfIdleEvictionReserved(controller, for: chatID)
        if removed == false {
            // A command can revoke our reservation while `closeIfIdle` is
            // awaiting the runtime. The warm path owns a new timer too, but
            // re-arming here keeps direct eviction callers equally safe.
            await scheduleIdleEviction(for: chatID)
        }
        return removed
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

        let services = providerServices
        Task { @MainActor in
            do {
                let preparation = try await services.prepareSummarization()
                switch preparation {
                case .defaultTruncation:
                    Self.writeDefaultSummaries(
                        chatID: chatID, pending: pending, store: store,
                        chatSummaryMessageID: chatSummaryMessageID)
                case .model(let preparation):
                    await Self.runModelSummarization(
                        chatID: chatID,
                        pending: pending,
                        services: services,
                        preparation: preparation,
                        store: store,
                        chatSummaryMessageID: chatSummaryMessageID)
                    await services.release(preparation.selection.token)
                }
            } catch AgentProviderRuntimeError.unavailable {
                Self.writeDefaultSummaries(
                    chatID: chatID,
                    pending: pending,
                    store: store,
                    chatSummaryMessageID: chatSummaryMessageID)
            } catch {
                DebugLog.agent("DaemonChatHost: summarization preparation failed: \(error)")
            }
        }
    }

    @MainActor
    private static func writeDefaultSummaries(
        chatID: ChatID, pending: [ChatMessage], store: GRDBWikiStore,
        chatSummaryMessageID: PageID?
    ) {
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
    }

    /// Drive model-mode summarization with one frozen preparation per batch.
    @MainActor
    private static func runModelSummarization(
        chatID: ChatID,
        pending: [ChatMessage],
        services: any AgentProviderServices,
        preparation: AgentOperationPreparation,
        store: GRDBWikiStore,
        chatSummaryMessageID: PageID?
    ) async {
        for msg in pending {
            guard let text = MessageSummarizer.textToSummarize(from: msg.event) else { continue }
            let summary: String
            do {
                guard let value = try await services.modelSummary(
                    text: text,
                    preparation: preparation) else { continue }
                summary = value
            } catch {
                DebugLog.agent("DaemonChatHost: model summary failed: \(error.localizedDescription)")
                continue
            }
            do {
                try store.updateMessageSummary(
                    chatID: chatID, messageID: msg.id,
                    summary: summary, kind: .model)
                // Keep the model's one-sentence result verbatim in chats.summary.
                if msg.id == chatSummaryMessageID {
                    try store.updateChatSummary(chatID: chatID, summary: summary)
                }
            } catch {
                DebugLog.store("DaemonChatHost.runModelSummarization: write failed: \(error)")
            }
        }
    }
}

/// Internal only so the daemon-host regression suite can directly exercise
/// reservation revocation; production access remains private to the host.
actor ControllerRegistry {
    private struct Entry {
        let wikiID: WikiID
        let controller: DaemonChatController
        var isIdleEvictionReserved = false
    }

    private struct IdleEvictionTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    enum IdleEvictionReservation {
        case missing
        case alreadyReserved
        case reserved(DaemonChatController)
    }

    private var entries: [ChatID: Entry] = [:]
    private var idleEvictionTasks: [ChatID: IdleEvictionTask] = [:]

    func controller(for chatID: ChatID) -> DaemonChatController? {
        entries[chatID]?.controller
    }

    /// Acquiring a controller for a command revokes a pending eviction before
    /// the caller can await the controller. This prevents an idle timer from
    /// removing a controller between lookup and submit.
    func acquireController(for chatID: ChatID) -> DaemonChatController? {
        guard var entry = entries[chatID] else { return nil }
        entry.isIdleEvictionReserved = false
        entries[chatID] = entry
        idleEvictionTasks.removeValue(forKey: chatID)?.task.cancel()
        return entry.controller
    }

    func wikiID(for chatID: ChatID) -> WikiID? {
        entries[chatID]?.wikiID
    }

    func count() -> Int {
        entries.count
    }

    func removeAllForShutdown() -> [DaemonChatController] {
        let controllers = entries.values.map(\.controller)
        entries.removeAll()
        let tasks = idleEvictionTasks.values.map(\.task)
        idleEvictionTasks.removeAll()
        for task in tasks { task.cancel() }
        return controllers
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
        let token = UUID()
        idleEvictionTasks.removeValue(forKey: chatID)?.task.cancel()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                DebugLog.agent("DaemonChatHost idle eviction sleep failed: \(error)")
                return
            }
            await self?.runScheduledIdleEviction(
                for: chatID,
                token: token,
                eviction: eviction
            )
        }
        idleEvictionTasks[chatID] = IdleEvictionTask(token: token, task: task)
    }

    func cancelIdleEviction(for chatID: ChatID) {
        idleEvictionTasks.removeValue(forKey: chatID)?.task.cancel()
    }

    func isIdleEvictionScheduled(for chatID: ChatID) -> Bool {
        idleEvictionTasks[chatID] != nil
    }

    func idleEvictionTaskCount(for chatID: ChatID) -> Int {
        idleEvictionTasks[chatID] == nil ? 0 : 1
    }

    func reserveForIdleEviction(for chatID: ChatID) -> IdleEvictionReservation {
        guard var entry = entries[chatID] else {
            return .missing
        }
        guard entry.isIdleEvictionReserved == false else {
            return .alreadyReserved
        }
        entry.isIdleEvictionReserved = true
        entries[chatID] = entry
        return .reserved(entry.controller)
    }

    /// Test-only observation of the actual reservation state; this is kept
    /// separate from task state because a close may be active after its timer
    /// has fired and been removed.
    func isIdleEvictionReservedForTesting(for chatID: ChatID) -> Bool {
        entries[chatID]?.isIdleEvictionReserved == true
    }

    func abandonIdleEviction(for chatID: ChatID, controller: DaemonChatController) {
        guard var current = entries[chatID], current.controller === controller else { return }
        current.isIdleEvictionReserved = false
        entries[chatID] = current
    }

    func removeIfIdleEvictionReserved(_ controller: DaemonChatController, for chatID: ChatID) -> Bool {
        guard let current = entries[chatID],
              current.controller === controller,
              current.isIdleEvictionReserved else {
            return false
        }
        entries.removeValue(forKey: chatID)
        idleEvictionTasks.removeValue(forKey: chatID)?.task.cancel()
        return true
    }

    private func runScheduledIdleEviction(
        for chatID: ChatID,
        token: UUID,
        eviction: @escaping @Sendable (ChatID) async -> Void
    ) async {
        guard idleEvictionTasks[chatID]?.token == token else { return }
        // The delayed task is complete before the host begins its async
        // reservation/close work. A refusal can now reliably install exactly
        // one replacement timer instead of leaving a completed task recorded.
        idleEvictionTasks.removeValue(forKey: chatID)
        await eviction(chatID)
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
