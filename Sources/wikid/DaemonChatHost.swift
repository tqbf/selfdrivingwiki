import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

#if canImport(WikiFSEngine)

/// The daemon-side host for interactive chat sessions (Phase C).
///
/// Owns a `[chatID → ChatSession]` registry of long-lived `AgentLauncher`
/// instances — one per chat. Unlike `DaemonQueueIngestionProvider` which
/// creates a per-run launcher and discards it, the chat host RETAINS the
/// launcher across turns AND across app ⌘Q, so a chat survives the client
/// disconnecting and reconnecting.
///
/// **RC3:** all chat launchers share a SINGLE `GenerationGate` so N
/// concurrent chats still serialize active generation (one turn at a time
/// across all chats).
///
/// **RC1:** `sendChatMessage` detects a dead session (process died between
/// turns) and re-routes to the `continueChat` path.
///
/// **RC4:** the takeover decision only retains the `.refused` case
/// (mid-generation guard). There is no cross-chat `.betweenTurns` stop —
/// each chat has its own launcher.
///
/// **RC2:** reads the per-wiki system prompt via `GRDBWikiStore.getSystemPrompt()`,
/// NOT a hardcoded `defaultBody`.
final class DaemonChatHost: @unchecked Sendable {

    // MARK: - Dependencies

    private let containerDirectory: URL
    private let extractionCoordinator: ExtractionCoordinator
    private let storeResolver: @Sendable (String) -> GRDBWikiStore?
    private let resolveSelectedProvider: @Sendable () -> AgentProvider
    private let resolveProviderConfig: @Sendable () -> AgentProvidersConfig
    private let pushEvent: @Sendable (QueueEventEnvelope) -> Void

    // MARK: - Shared generation gate (RC3)

    /// One gate shared across ALL chat launchers so concurrent chats serialize
    /// active generation (RC3). Created lazily on the main actor (GenerationGate
    /// is @MainActor). Accessed only from `makeLauncher` (main-actor context).
    private var _sharedGate: GenerationGate?

    // MARK: - Session registry (guarded by `queue`)

    private let queue = DispatchQueue(label: "com.selfdrivingwiki.wikid.chat")
    private var sessions: [String: ChatSession] = [:]
    private var statePollTasks: [String: Task<Void, Never>] = [:]

    private struct ChatSession {
        let wikiID: String
        let chatID: String
        let launcher: AgentLauncher
    }

    // MARK: - Init

    init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        storeResolver: @escaping @Sendable (String) -> GRDBWikiStore?,
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

    // MARK: - Launcher construction

    /// Create a new `AgentLauncher` for a chat, injecting the shared gate.
    private func makeLauncher() async -> AgentLauncher {
        await MainActor.run {
            let gate: GenerationGate
            if let existing = self._sharedGate {
                gate = existing
            } else {
                gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
                self._sharedGate = gate
            }
            let launcher = AgentLauncher(
                generationGate: gate,
                extractionCoordinator: self.extractionCoordinator)
            launcher.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
            return launcher
        }
    }

    /// Get an existing launcher for a chat, or create a new one.
    private func getOrCreateLauncher(chatID: String, wikiID: String) async -> AgentLauncher {
        if let existing = queue.sync(execute: { sessions[chatID]?.launcher }) {
            return existing
        }
        let launcher = await makeLauncher()
        let session = ChatSession(wikiID: wikiID, chatID: chatID, launcher: launcher)
        queue.sync {
            sessions[chatID] = session
        }
        return launcher
    }

    // MARK: - Start a new chat

    /// Create a `chats` row, seed the first user message, and start an
    /// interactive session. Returns the chat ULID.
    func startChat(wikiID: String, firstMessage: String) async throws -> String {
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }

        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DaemonChatError.emptyMessage
        }

        DebugLog.agent("DaemonChatHost.startChat: wikiID=\(wikiID) msg=\"\(trimmed.prefix(80))\"")

        // 1. Create the chat row + seed the first user message.
        let title = ChatSummary.title(fromFirstMessage: trimmed)
        let chat = try store.createChat(kind: .edit, title: title)
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText(trimmed)])

        // 2. Build wiki-state markdown + read the system prompt (RC2).
        let stateMarkdown = DaemonWikiState.stateMarkdown(from: store)
        let systemPromptBody = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody

        // 3. Create the launcher + register the session.
        let launcher = await getOrCreateLauncher(chatID: chat.id.rawValue, wikiID: wikiID)

        // 4. Start the interactive session.
        let chatIDPage = chat.id
        let wikiIDCapture = wikiID
        await launcher.startInteractiveQuery(
            firstMessage: trimmed,
            stateMarkdown: stateMarkdown,
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: systemPromptBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            chatID: chat.id.rawValue,
            firstMessagePrePersisted: true,
            onAcpSessionId: { [weak self] sessionId in
                self?.handleAcpSessionId(
                    chatID: chatIDPage, sessionId: sessionId, wikiID: wikiIDCapture)
            },
            onLock: { },
            onUnlock: {
                DarwinNotifier.postChange(forWikiID: wikiIDCapture)
            },
            onTranscript: { [weak self] events in
                self?.handleTranscript(
                    chatID: chatIDPage, events: events, wikiID: wikiIDCapture)
            },
            onSummary: { [weak self] id, summary in
                self?.handleSummary(chatID: id, summary: summary, wikiID: wikiIDCapture)
            },
            onMessageSummary: { [weak self] id in
                self?.summarizePendingMessages(
                    chatID: id, wikiID: wikiIDCapture, launcher: launcher)
            },
            onStreamingCheckpoint: { chatID, handle, event, isDraft in
                (try? store.checkpointStreamingMessage(
                    chatID: chatID, handle: handle, event: event, isDraft: isDraft)) != nil
            }
        )

        // 5. Wire the event stream (after startInteractiveQuery so
        //    resetRunArtifacts doesn't clear it).
        await wireEventStream(chatID: chat.id.rawValue, launcher: launcher)

        // 6. Start the state-change poll.
        startStatePoll(for: chat.id.rawValue, launcher: launcher)

        // 7. Preflight failure → rollback the chat row.
        let preflightError = await MainActor.run { launcher.preflightError }
        if preflightError != nil {
            DebugLog.agent("DaemonChatHost.startChat: ROLLBACK chat=\(chat.id.rawValue) error=\(preflightError ?? "?")")
            try? store.deleteChat(id: chat.id)
            throw DaemonChatError.preflightFailed(preflightError ?? "unknown")
        }

        return chat.id.rawValue
    }

    // MARK: - Continue a persisted chat

    /// Continue a chat with a new user turn. Reads the history + `acpSessionId`
    /// from the store, builds the adaptive preamble, and starts a fresh
    /// interactive session writing to the SAME chat row.
    func continueChat(wikiID: String, chatID: String, message: String) async throws {
        guard let store = storeResolver(wikiID) else {
            throw DaemonChatError.noStore(wikiID)
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DaemonChatError.emptyMessage
        }

        let chatIDPage = PageID(rawValue: chatID)
        DebugLog.agent("DaemonChatHost.continueChat: chatID=\(chatID) msg=\"\(trimmed.prefix(80))\"")

        // RC4: per-chat takeover — only refuse mid-generation on THIS chat.
        // No cross-chat stopAgent (each chat has its own launcher).
        let launcher = await getOrCreateLauncher(chatID: chatID, wikiID: wikiID)
        let decision = await MainActor.run {
            AgentOperationRunner.continueTakeoverDecision(
                isRunning: launcher.isRunning,
                isInteractiveSession: launcher.isInteractiveSession,
                isGenerating: launcher.isGenerating,
                isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot)
        }
        if decision == .refused {
            DebugLog.agent("DaemonChatHost.continueChat: refused — mid-generation on chat \(chatID)")
            throw DaemonChatError.midGeneration
        }

        // Finalize stale drafts from an interrupted turn.
        try store.finalizeStaleDrafts(forChat: chatIDPage)

        // Read history + prior ACP session ID.
        let history = try store.chatMessages(chatID: chatIDPage)
        let priorAcpSessionId = try store.getChat(id: chatIDPage).acpSessionId

        // Build the adaptive preamble (#825) — these are @MainActor static
        // funcs on AgentOperationRunner, so we hop to the main actor.
        let firstMessage = await MainActor.run {
            let budget = AgentOperationRunner.adaptivePreambleBudget(
                eligibleTurns: AgentOperationRunner.projectedPreambleTurns(from: history).count)
            return AgentOperationRunner.continuationPreamble(
                from: history, newMessage: trimmed,
                maxTurns: budget.maxTurns, maxBytes: budget.maxBytes)
        }

        // Build wiki-state markdown + system prompt (RC2).
        let stateMarkdown = DaemonWikiState.stateMarkdown(from: store)
        let systemPromptBody = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody

        DebugLog.agent("DaemonChatHost.continueChat: history=\(history.count) priorAcpSession=\(priorAcpSessionId ?? "nil")")

        let wikiIDCapture = wikiID
        await launcher.startInteractiveQuery(
            firstMessage: firstMessage,
            firstMessageDisplay: trimmed,
            stateMarkdown: stateMarkdown,
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: systemPromptBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            chatID: chatID,
            historySeed: history.map(\.event),
            priorAcpSessionId: priorAcpSessionId,
            onAcpSessionId: { [weak self] sessionId in
                self?.handleAcpSessionId(
                    chatID: chatIDPage, sessionId: sessionId, wikiID: wikiIDCapture)
            },
            onLock: { },
            onUnlock: {
                DarwinNotifier.postChange(forWikiID: wikiIDCapture)
            },
            onTranscript: { [weak self] events in
                self?.handleTranscript(
                    chatID: chatIDPage, events: events, wikiID: wikiIDCapture)
            },
            onSummary: { [weak self] id, summary in
                self?.handleSummary(chatID: id, summary: summary, wikiID: wikiIDCapture)
            },
            onMessageSummary: { [weak self] id in
                self?.summarizePendingMessages(
                    chatID: id, wikiID: wikiIDCapture, launcher: launcher)
            },
            onStreamingCheckpoint: { chatID, handle, event, isDraft in
                (try? store.checkpointStreamingMessage(
                    chatID: chatID, handle: handle, event: event, isDraft: isDraft)) != nil
            }
        )

        // Re-wire the event stream (resetRunArtifacts cleared it).
        await wireEventStream(chatID: chatID, launcher: launcher)
        startStatePoll(for: chatID, launcher: launcher)
    }

    // MARK: - Send a follow-up turn (RC1)

    /// Send a message to an active chat. If the session died between turns
    /// (RC1), re-route to the continueChat path which re-spawns.
    func sendChatMessage(chatID: String, message: String) async throws {
        let session = queue.sync { sessions[chatID] }
        guard let session else {
            throw DaemonChatError.noSession(chatID)
        }

        // RC1: detect dead session.
        let isAlive = await MainActor.run {
            session.launcher.isInteractiveSession && session.launcher.isRunning
        }

        if isAlive {
            DebugLog.agent("DaemonChatHost.sendChatMessage: alive — sending turn to chat \(chatID)")
            await MainActor.run {
                session.launcher.sendInteractiveMessage(message)
            }
        } else {
            // RC1: re-route to continueChat (re-invokes startInteractiveQuery
            // which re-seeds sinks).
            DebugLog.agent("DaemonChatHost.sendChatMessage: DEAD session — re-routing to continueChat for \(chatID)")
            try await continueChat(
                wikiID: session.wikiID, chatID: chatID, message: message)
        }
    }

    // MARK: - Stop a chat

    /// Stop the active turn and end the session. The launcher is retained in
    /// the registry (D1: no idle eviction for Phase C).
    func stopChat(chatID: String) async {
        let session = queue.sync { sessions[chatID] }
        guard let session else { return }
        DebugLog.agent("DaemonChatHost.stopChat: stopping chat \(chatID)")
        await MainActor.run {
            session.launcher.stopAgent()
        }
    }

    // MARK: - Chat session state (rehydration)

    /// Return the live state of a chat for client rehydration. If the daemon
    /// still has the launcher, reads from it; otherwise throws (the client
    /// falls back to reading from its local store).
    func chatSessionState(chatID: String) async throws -> ChatSessionState {
        let session = queue.sync { sessions[chatID] }
        guard let session else {
            throw DaemonChatError.noSession(chatID)
        }

        let launcher = session.launcher
        return await MainActor.run {
            let usageData = launcher.runTotalUsage.flatMap {
                try? JSONEncoder().encode($0)
            }
            return ChatSessionState(
                chatID: chatID,
                events: launcher.events,
                isRunning: launcher.isRunning,
                isGenerating: launcher.isGenerating,
                isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot,
                preflightError: launcher.preflightError,
                thinkingOption: launcher.thinkingOption,
                usageData: usageData,
                logFileURL: launcher.logFileURL(forChat: chatID),
                debugFolderURL: launcher.debugFolderURL(forChat: chatID),
                runKindRaw: launcher.runningKind.map { "\($0)" },
                runStartedAt: launcher.runStartedAt)
        }
    }

    // MARK: - Resolve a pending permission

    /// Forward a permission resolution to the launcher's backend.
    func resolvePermission(chatID: String, optionId: String, approve: Bool) async {
        let session = queue.sync { sessions[chatID] }
        guard let session else { return }
        DebugLog.agent("DaemonChatHost.resolvePermission: chat=\(chatID) option=\(optionId) approve=\(approve)")
        await session.launcher.resolvePendingPermission(optionId: optionId)
    }

    // MARK: - Test accessors

    /// Whether the host currently holds a live session for `chatID`.
    func hasLiveSession(_ chatID: String) -> Bool {
        queue.sync { sessions[chatID] != nil }
    }

    /// The shared generation gate (for cross-chat serialization tests, RC3).
    /// Must be accessed on the main actor.
    @MainActor var testSharedGenerationGate: GenerationGate? { _sharedGate }

    // MARK: - Private: event stream wiring

    /// Set `onAgentEvent` on the launcher so every streamed event is pushed
    /// to the client. Called after `startInteractiveQuery` (which clears it
    /// via `resetRunArtifacts`).
    private func wireEventStream(chatID: String, launcher: AgentLauncher) async {
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
    private func startStatePoll(for chatID: String, launcher: AgentLauncher) {
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
                try? await Task.sleep(for: .milliseconds(150))
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
    private func pushStateUpdate(chatID: String, launcher: AgentLauncher) {
        let usageData = launcher.runTotalUsage.flatMap {
            try? JSONEncoder().encode($0)
        }
        let update = ChatStateUpdate(
            isRunning: launcher.isRunning,
            isGenerating: launcher.isGenerating,
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot,
            preflightError: launcher.preflightError,
            thinkingOption: launcher.thinkingOption,
            usageData: usageData,
            logFileURL: launcher.logFileURL(forChat: chatID),
            debugFolderURL: launcher.debugFolderURL(forChat: chatID),
            runKindRaw: launcher.runningKind.map { "\($0)" },
            runStartedAt: launcher.runStartedAt)
        pushEvent(.chatState(chatID: chatID, update: update))
    }

    // MARK: - Private: store sink handlers

    private func handleAcpSessionId(
        chatID: PageID, sessionId: String?, wikiID: String
    ) {
        guard let store = storeResolver(wikiID) else { return }
        do {
            try store.updateChatAcpSessionId(chatID: chatID, acpSessionId: sessionId)
            // Push the session-id writeback to the client (#830).
            pushEvent(.chatAcpSessionId(
                chatID: chatID.rawValue, sessionId: sessionId))
        } catch {
            DebugLog.store("DaemonChatHost: updateChatAcpSessionId failed: \(error)")
        }
    }

    private func handleTranscript(
        chatID: PageID, events: [AgentEvent], wikiID: String
    ) {
        guard let store = storeResolver(wikiID) else { return }
        do {
            _ = try store.appendChatMessages(chatID: chatID, events: events)
        } catch {
            DebugLog.store("DaemonChatHost: appendChatMessages failed: \(error)")
        }
    }

    private func handleSummary(
        chatID: PageID, summary: String, wikiID: String
    ) {
        guard let store = storeResolver(wikiID) else { return }
        do {
            try store.updateChatSummary(chatID: chatID, summary: summary)
        } catch {
            DebugLog.store("DaemonChatHost: updateChatSummary failed: \(error)")
        }
    }

    // MARK: - Private: message summarization (RC5)

    /// Summarize all unsummarized assistant messages in `chatID` per the
    /// configured summarizer mode. Mirrors `AgentOperationRunner.summarizePendingMessages`
    /// but operates on `GRDBWikiStore` directly (no `WikiStoreModel`).
    ///
    /// RC5: this is the daemon-native generalization of the app's
    /// `summarizePendingMessages` + `runModelSummarization`.
    private func summarizePendingMessages(
        chatID: PageID, wikiID: String, launcher: AgentLauncher
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
                } catch {
                    DebugLog.store("DaemonChatHost: updateMessageSummary failed: \(error)")
                }
            }
        case .model:
            let containerDir = containerDirectory
            let credentialStore = KeychainACPCredentialStore()
            Task { @MainActor in
                await Self.runModelSummarization(
                    chatID: chatID, pending: pending, config: config,
                    containerDir: containerDir, credentialStore: credentialStore,
                    store: store)
            }
        }
    }

    /// Drive model-mode summarization for a batch of pending messages.
    /// Runs off-main for the ACP session(s); marshals each write to the store.
    @MainActor
    private static func runModelSummarization(
        chatID: PageID, pending: [ChatMessage], config: AgentProvidersConfig,
        containerDir: URL, credentialStore: any ACPCredentialStore,
        store: GRDBWikiStore
    ) async {
        guard let profile = MessageSummarizer.resolveProfile(
            config: config, credentialStore: credentialStore) else {
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
            } catch {
                DebugLog.store("DaemonChatHost.runModelSummarization: write failed: \(error)")
            }
        }
    }
}

// MARK: - Errors

enum DaemonChatError: Error, LocalizedError {
    case noStore(String)
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
