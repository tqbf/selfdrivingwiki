#if os(macOS)
import Foundation
import Observation
import WikiFSCore
import WikiFSEngine

/// The app-side `@Observable` mirror for a daemon-hosted chat session
/// (Phase C). This is the drop-in replacement for the `AgentLauncher` surface
/// that `ChatDetailView` previously bound to directly.
///
/// Instead of driving an in-process `AgentLauncher`, `RemoteChatSession`
/// reflects the state of the daemon's long-lived launcher via:
/// 1. **XPC commands** (`DaemonWorkloadClient.startChat`/`continueChat`/…)
/// 2. **Chat event envelopes** demuxed from `DaemonQueueEventSink` → `ingest(_:)`
/// 3. **Rehydration** from `chatSessionState(chatID:)` on (re)connect
///
/// RC9: exposes `resolvePendingPermission(_:)`, `availableThinkingOptions`,
/// `logFileURL`, and `runTotalUsage` — the full binding surface ChatDetailView
/// needs.
@MainActor
@Observable
public final class RemoteChatSession {

    // MARK: - Mirrored launcher state (ChatDetailView binds these)

    public var events: [AgentEvent] = []
    public var eventTimestamps: [Date] = []
    public private(set) var isRunning = false
    public private(set) var isGenerating = false
    public private(set) var isAwaitingGenerationSlot = false
    public private(set) var isInteractiveSession = false
    /// The chat id this mirror currently reflects as the LIVE session, or nil
    /// when this chat is not the daemon's active session (persisted/idle).
    /// Managed by `hydrate`/`applyStateUpdate` from the daemon's run flags so
    /// the `ChatDetailView` source-of-truth rule (`activeChatID == chatID`)
    /// flips a chat live precisely when the daemon is running it.
    public var activeChatID: String?
    public var exitStatus: Int32?
    public var runningKind: WikiOperation.Kind?
    public var runStartedAt: Date?
    public var preflightError: String?
    public var pendingPermissions: [PendingPermission] = []
    public var thinkingOption: ThinkingEffortOption?

    /// stderr mirror (best-effort). The daemon does not stream per-chat stderr
    /// over the chat envelope channel today; this stays empty unless a future
    /// envelope kind populates it. `AgentQueueView` reads it for the internals
    /// banner, same as the launcher path.
    public var stderr: String = ""

    /// Last-activity timestamp mirror. Not carried by the chat envelope
    /// protocol today, so this stays nil unless a future envelope populates
    /// it. `AgentRunStatusView` degrades gracefully when nil.
    public var lastActivityAt: Date?

    /// Spawned process id mirror. Not carried by the chat envelope protocol
    /// today, so this stays nil unless a future envelope populates it.
    public var currentProcessID: Int32?

    /// Cumulative usage for this chat (mirrors AgentLauncher.runTotalUsage).
    public private(set) var runTotalUsage: SessionUsage?

    /// The chat's most-recent run's log file URL (pure disk resolve).
    public var logFileURL: URL? {
        guard let chatID = activeChatID else { return nil }
        return AgentLauncher.logFileURLStatic(forChat: chatID)
    }

    /// The chat's debug folder URL.
    public var debugFolderURL: URL? {
        guard let chatID = activeChatID else { return nil }
        return AgentLauncher.debugFolderURLStatic(forChat: chatID)
    }

    /// Available thinking-effort choices (derived from `thinkingOption`).
    public var availableThinkingOptions: [ThinkingEffortOption.Choice] {
        thinkingOption?.choices ?? []
    }

    // MARK: - Identity

    public let chatID: String

    public init(chatID: String) {
        self.chatID = chatID
        self.activeChatID = chatID
    }

    // MARK: - Envelope ingestion

    /// Consume a chat `QueueEventEnvelope` from the daemon's event stream.
    /// Called by the app's chat-event router (which demuxes from
    /// `DaemonQueueEventSink`).
    func ingest(_ envelope: QueueEventEnvelope) {
        guard envelope.chatID == chatID else { return }
        switch envelope.kind {
        case .chatEvent:
            if let event = envelope.chatAgentEvent {
                mergeOrAppendEvent(event)
            }
        case .chatState:
            if let update = envelope.chatStateUpdate {
                applyStateUpdate(update)
            }
        case .chatAcpSessionId:
            break // The store handles ACP session-id persistence.
        case .chatPendingPermission:
            // Parse the pending-permission JSON (best-effort).
            if let json = envelope.pendingPermissionJSON,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let toolCallId = dict["toolCallId"] as? String ?? ""
                let title = dict["title"] as? String
                let toolName = dict["toolName"] as? String
                let inputSummary = dict["inputSummary"] as? String
                pendingPermissions = [PendingPermission(
                    toolCallId: toolCallId,
                    title: title, toolName: toolName,
                    inputSummary: inputSummary,
                    options: [])]
            } else {
                pendingPermissions = []
            }
        default:
            break // Queue events are not routed here.
        }
    }

    /// Apply a full state snapshot (from `chatSessionState` rehydration).
    func hydrate(from state: ChatSessionState) {
        events = state.events
        eventTimestamps = Array(repeating: Date(), count: state.events.count)
        isRunning = state.isRunning
        isGenerating = state.isGenerating
        isAwaitingGenerationSlot = state.isAwaitingGenerationSlot
        preflightError = state.preflightError
        thinkingOption = state.thinkingOption
        runTotalUsage = state.usage
        if let raw = state.runKindRaw {
            runningKind = WikiOperation.Kind(rawValue: raw)
        }
        runStartedAt = state.runStartedAt
        isInteractiveSession = state.isRunning || state.isGenerating
        // Source-of-truth rule: this mirror is "live" (activeChatID set)
        // exactly while the daemon reports the session interactive.
        activeChatID = isInteractiveSession ? chatID : nil
    }

    // MARK: - Private: event merge logic

    /// Mirror `AgentLauncher.mergeOrAppend` for the remote case: delta
    /// continuations replace the last event; everything else appends.
    private func mergeOrAppendEvent(_ event: AgentEvent) {
        let now = Date()
        switch event {
        case .assistantText(let text):
            // If the last event is also .assistantText and the new text
            // starts with the old text (delta continuation), replace.
            if let last = events.last, case .assistantText(let existing) = last,
               text.hasPrefix(existing) {
                events[events.count - 1] = event
                if !eventTimestamps.isEmpty {
                    eventTimestamps[eventTimestamps.count - 1] = now
                }
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
        case .thinking(let text):
            if let last = events.last, case .thinking(let existing) = last,
               text.hasPrefix(existing) {
                events[events.count - 1] = event
                if !eventTimestamps.isEmpty {
                    eventTimestamps[eventTimestamps.count - 1] = now
                }
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
        default:
            events.append(event)
            eventTimestamps.append(now)
        }
    }

    private func applyStateUpdate(_ update: ChatStateUpdate) {
        isRunning = update.isRunning
        isGenerating = update.isGenerating
        isAwaitingGenerationSlot = update.isAwaitingGenerationSlot
        preflightError = update.preflightError
        thinkingOption = update.thinkingOption
        if let usageData = update.usageData,
           let usage = try? JSONDecoder().decode(SessionUsage.self, from: usageData) {
            runTotalUsage = usage
        }
        if let raw = update.runKindRaw {
            runningKind = WikiOperation.Kind(rawValue: raw)
        }
        runStartedAt = update.runStartedAt
        isInteractiveSession = update.isRunning || update.isGenerating
        // Source-of-truth rule: keep activeChatID in sync with interactivity.
        activeChatID = isInteractiveSession ? chatID : nil
    }

    // MARK: - Provider config surface (shared file, same as the daemon reads)

    /// The App Group container the provider config is loaded from + saved to.
    /// Same resolution the daemon's chat launcher uses, so an app-side write
    /// is visible to the next `startChat` / `continueChat` on the daemon.
    public func resolveProvidersContainerDirectory() -> URL {
        (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
    }

    /// Read the persisted provider config (loads + seeds on first run). The
    /// composer's provider selector binds to this — refreshed on demand so a
    /// fresh selection (Settings OR composer) is visible next read. Mirrors
    /// `AgentLauncher.providersConfig()`.
    public func providersConfig() -> AgentProvidersConfig {
        AgentProvidersConfig.loadOrSeed(from: resolveProvidersContainerDirectory())
    }

    /// The provider this chat will use, resolved fresh from the config file.
    /// Mirrors `AgentLauncher.resolveSelectedProvider()`.
    public func resolveSelectedProvider() -> AgentProvider {
        providersConfig().selectedProvider()
    }

    /// Atomically set the default provider AND a per-provider model selection
    /// in one load→mutate→save cycle. Choosing a model implies choosing its
    /// provider (paseo two-step); both land together. Mirrors
    /// `AgentLauncher.setSelectedModelAndDefault(_:provider:)`.
    @discardableResult
    public func setSelectedModelAndDefault(
        _ modelId: String?, provider: AgentProvider
    ) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        DebugLog.store("RemoteChatSession.setSelectedModelAndDefault: provider=\(provider.id) modelId=\(modelId ?? "nil") → save")
        let updated = providersConfig()
            .settingDefault(id: provider.id)
            .settingSelectedModel(modelId, forProvider: provider.id)
        do {
            try updated.save(to: dir)
        } catch {
            DebugLog.store("RemoteChatSession.setSelectedModelAndDefault save failed (provider=\(provider.id) modelId=\(modelId ?? "nil")): \(error)")
        }
        return updated
    }

    /// The user's persisted model selection for `providerId` (nil = agent
    /// default). Mirrors `AgentLauncher.selectedModelId(forProvider:)`.
    public func selectedModelId(forProvider providerId: String) -> String? {
        providersConfig().selectedModelId(forProvider: providerId)
    }

    /// Toggle + persist a model's favorite state. Display-only (favorites sort
    /// to the top of the picker). Mirrors
    /// `AgentLauncher.toggleFavoriteModel(_:forProvider:)`.
    @discardableResult
    public func toggleFavoriteModel(_ modelId: String, forProvider providerId: String) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().togglingFavoriteModel(modelId, forProvider: providerId)
        do {
            try updated.save(to: dir)
        } catch {
            DebugLog.store("RemoteChatSession.toggleFavoriteModel save failed (provider=\(providerId) model=\(modelId)): \(error)")
        }
        return updated
    }

    // MARK: - Mid-session thinking effort (best-effort)

    /// Optimistically flip the thinking-effort chip. The daemon-side apply
    /// (a live `session/set_config_option`) needs a chat XPC method not in
    /// the Phase C 6-method protocol, so C4 flips the UI locally and the next
    /// `chatState` envelope from the daemon reconciles to its truth. A future
    /// XPC method (`setChatConfigOption`) will make this authoritative.
    public func setThinkingEffort(_ value: String) {
        guard let option = thinkingOption else { return }
        DebugLog.agent("RemoteChatSession.setThinkingEffort: value=\(value) (daemon apply deferred — no chat-config XPC method in C4)")
        thinkingOption = option.withCurrentValue(value)
    }

    // MARK: - Per-chat debug/log URL resolution (instance companions)

    /// Resolve the chat's most-recent run debug-folder URL from disk. Mirrors
    /// `AgentLauncher.debugFolderURL(forChat:)` (pure disk resolve).
    public func debugFolderURL(forChat id: String) -> URL? {
        AgentLauncher.debugFolderURLStatic(forChat: id)
    }

    /// Resolve the chat's most-recent run log file URL from disk. Mirrors
    /// `AgentLauncher.logFileURL(forChat:)` (pure disk resolve).
    public func logFileURL(forChat id: String) -> URL? {
        AgentLauncher.logFileURLStatic(forChat: id)
    }

    // MARK: - Reset (for new chat / teardown)

    /// Local reset used when retargeting the tab to a fresh draft. The
    /// daemon's own session is unaffected; this only clears the app-side
    /// mirror so the draft composer starts empty. Clears `activeChatID` so the
    /// source-of-truth rule no longer treats this mirror as live.
    func startNewChat() {
        reset()
        activeChatID = nil
    }

    func reset() {
        events = []
        eventTimestamps = []
        isRunning = false
        isGenerating = false
        isAwaitingGenerationSlot = false
        isInteractiveSession = false
        exitStatus = nil
        preflightError = nil
        pendingPermissions = []
        thinkingOption = nil
        runTotalUsage = nil
        runningKind = nil
        runStartedAt = nil
    }
}
#endif
