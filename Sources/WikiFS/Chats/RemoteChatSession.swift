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
/// Run lifecycle is modeled as a `ChatRunState` FSM (`runState`), the single
/// stored source of truth. The five legacy boolean/optional flags
/// (`isRunning`, `isGenerating`, `isAwaitingGenerationSlot`,
/// `isInteractiveSession`, `activeChatID`) are backward-compatible computed
/// shims derived from `runState` — existing read sites are unchanged.
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
    /// The single source of truth for this session's run lifecycle.
    /// All five legacy flags derive from this via computed shims.
    public private(set) var runState: ChatRunState = .idle

    // MARK: - Backward-compatible run-flag shims (computed from runState)

    /// Mirrors `AgentLauncher.isRunning` — "the agent process is alive", which
    /// for an interactive chat is true *across turns*. NOT "a turn is in
    /// flight"; use `isGenerating` (or `runState.isAnswering`) for that.
    public var isRunning: Bool { runState.isLive }
    /// Mirrors `AgentLauncher.isGenerating` — a turn is in flight, covering the
    /// thinking phase as well as streaming. The flag every spinner keys off.
    public var isGenerating: Bool { runState.isAnswering }
    public var isAwaitingGenerationSlot: Bool { runState == .queued }
    public var isInteractiveSession: Bool { runState.isLive }
    /// The chat id this mirror currently reflects as the LIVE session, or nil
    /// when this chat is not the daemon's active session (persisted/idle).
    /// Derived from `runState` so the `ChatDetailView` source-of-truth rule
    /// (`activeChatID == chatID`) flips a chat live precisely when the daemon
    /// is running it.
    /// `PageID?`, not `String?` — so `ChatDetailView`'s liveness rule compares
    /// two chat ids rather than two strings, and the draft (which has no
    /// `PageID`) can never satisfy it.
    public var activeChatID: PageID? { runState.isLive ? chatID.pageID : nil }
    public var exitStatus: Int32?
    public var runningKind: WikiOperation.Kind?
    public var runStartedAt: Date?
    public var preflightError: String?
    public var pendingPermissions: [PendingPermission] = []
    public var thinkingOption: ThinkingEffortOption?

    /// stderr mirror (best-effort). Populated from `ChatSessionState` on
    /// rehydrate and from `chatState` streaming envelopes. Read by
    /// `AgentQueueView` for the internals banner.
    public var stderr: String = ""

    /// Last-activity timestamp mirror. Populated from `ChatSessionState` on
    /// rehydrate and from `chatState` streaming envelopes. `AgentRunStatusView`
    /// degrades gracefully when nil.
    public var lastActivityAt: Date?

    /// Spawned process id mirror. Populated from `ChatSessionState` on
    /// rehydrate and from `chatState` streaming envelopes.
    public var currentProcessID: Int32?

    /// Optional callback to apply a config-option change on the daemon's live
    /// session via the `setChatConfigOption` XPC method. Set by
    /// `ChatDaemonCoordinator` when it creates the session; nil for the draft
    /// session or when no coordinator is wired (optimistic-only flip).
    public var onSetChatConfigOption: (@Sendable (String, String) async -> Void)?

    /// Cumulative usage for this chat (mirrors AgentLauncher.runTotalUsage).
    public private(set) var runTotalUsage: SessionUsage?

    /// The chat's most-recent run's log file URL (pure disk resolve).
    public var logFileURL: URL? {
        guard let chatID = activeChatID else { return nil }
        return AgentLauncher.logFileURLStatic(forChat: chatID.rawValue)
    }

    /// The chat's debug folder URL.
    public var debugFolderURL: URL? {
        guard let chatID = activeChatID else { return nil }
        return AgentLauncher.debugFolderURLStatic(forChat: chatID.rawValue)
    }

    /// Available thinking-effort choices (derived from `thinkingOption`).
    public var availableThinkingOptions: [ThinkingEffortOption.Choice] {
        thinkingOption?.choices ?? []
    }

    /// A per-chat model override (`ProviderSelector` pick) made on a `.draft`
    /// session — one that has no `chats` row yet to write it to. Consumed by
    /// `ChatDetailView.submitMessage`'s draft branch, which passes it as
    /// `startChat`'s `providerId`/`modelId` so it seeds `ChatSummary` at
    /// creation. Meaningless (and unused) once `chatID` is `.chat(_)` — an
    /// existing chat's picker writes straight to the `chats` row instead
    /// (`WikiStoreModel.updateChatModelOverride`). Never read/written for a
    /// `.chat(_)` session; no clearing needed, since starting the chat
    /// discards this whole draft `RemoteChatSession` (a fresh one is created
    /// for the new `PageID`, per `chatID`'s `let`-ness).
    public var pendingModelOverride: (providerId: String, modelId: String?)?

    // MARK: - Private: streaming-row bookkeeping

    /// Which kind of row (if any) `events.last` is still accumulating from
    /// streamed delta chunks. A delta extends that row instead of starting a
    /// new one; a *finished* row is never extended by the next block.
    ///
    /// An enum rather than a pair of booleans: the two states are mutually
    /// exclusive (a row cannot be mid-assistant-text and mid-thinking at once),
    /// so booleans would make that impossible combination representable and
    /// oblige every branch to remember to clear the other one — the same
    /// denormalized-flags trap `ChatRunState` exists to close.
    private enum StreamingRow {
        /// No row is accumulating; the next delta starts a fresh one.
        case none
        /// `events.last` is an `.assistantText` row built from `.assistantTextDelta`.
        case assistant
        /// `events.last` is a `.thinking` row built from `.thinkingDelta`.
        case thinking
    }

    /// `@ObservationIgnored`: internal merge bookkeeping, not view state. It
    /// changes on every delta and no view reads it, so tracking it would
    /// invalidate the transcript on writes nothing renders.
    @ObservationIgnored private var streamingRow: StreamingRow = .none

    // MARK: - Identity

    public let chatID: ChatSessionKey

    public init(chatID: ChatSessionKey) {
        self.chatID = chatID
        // A fresh mirror knows NOTHING about the daemon yet, so it must not
        // claim liveness: `runState` defaults to `.idle`, which makes the
        // computed `activeChatID` return nil. Seeding `activeChatID` with
        // `chatID` here made every newly-opened chat pass
        // `ChatDetailView.isLiveChat`, which then rendered this mirror's
        // empty `events` INSTEAD of the persisted rows — a chat with a full
        // transcript showed "Ask a question to start a chat." whenever
        // rehydration couldn't correct the claim (the daemon throws
        // `noSession` for any chat whose launcher it has evicted).
    }

    /// Drop this mirror's liveness claim: the daemon is not running this chat,
    /// so `ChatDetailView` must fall back to the persisted rows. Called by
    /// `ChatDaemonCoordinator.rehydrate` when the state fetch fails — an
    /// evicted session is indistinguishable from a transport error here, and
    /// "not live" is the safe answer for both (the persisted transcript is
    /// always renderable; an empty live stream is not).
    func markNotLive() {
        runState = .idle
        streamingRow = .none
    }

    // MARK: - Envelope ingestion

    /// Consume a chat `QueueEventEnvelope` from the daemon's event stream.
    /// Called by the app's chat-event router (which demuxes from
    /// `DaemonQueueEventSink`).
    func ingest(_ envelope: QueueEventEnvelope) {
        // Envelopes carry the typed chat-id; compare against the session's
        // `PageID` (the draft has none and is never a wire target).
        guard envelope.chatID == chatID.pageID else { return }
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
               let dict = DebugLog.trying("parse pending permission", operation: { try JSONSerialization.jsonObject(with: data) as? [String: Any] }) {
                let toolCallId = dict["toolCallId"] as? String ?? ""
                let title = dict["title"] as? String
                let toolName = dict["toolName"] as? String
                let inputSummary = dict["inputSummary"] as? String
                pendingPermissions = [PendingPermission(
                    toolCallId: ToolCallID(rawValue: toolCallId),
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
        // Same contract as `mergeOrAppendEvent`: a rehydrated history is one of
        // the "OTHER consumers of the raw stream" `mergingStreamDeltas` names,
        // so raw `.assistantTextDelta`/`.thinkingDelta` chunks in the snapshot
        // must be folded here too — otherwise a rehydrate would re-break a
        // transcript the live path had already assembled correctly. Idempotent:
        // an already-merged array contains no deltas and passes through.
        let merged = AgentEvent.mergingStreamDeltas(state.events)
        events = merged
        eventTimestamps = Array(repeating: Date(), count: merged.count)
        // The snapshot is a complete history, not a row mid-flight.
        streamingRow = .none
        runState = .from(isRunning: state.isRunning,
                          isGenerating: state.isGenerating,
                          isAwaitingSlot: state.isAwaitingGenerationSlot)
        preflightError = state.preflightError
        thinkingOption = state.thinkingOption
        runTotalUsage = state.usage
        if let raw = state.runKindRaw {
            runningKind = WikiOperation.Kind(rawValue: raw)
        }
        runStartedAt = state.runStartedAt
        stderr = state.stderr ?? ""
        lastActivityAt = state.lastActivityAt
        currentProcessID = state.currentProcessID.flatMap(Int32.init(exactly:))
    }

    // MARK: - Private: event merge logic

    /// Mirror `AgentLauncher.mergeOrAppend` for the remote case: streamed
    /// deltas coalesce into the in-progress row, and a final full-text event
    /// replaces that row rather than duplicating it.
    ///
    /// **Folding the deltas is not cosmetic — without it the transcript renders
    /// nothing at all.** The daemon streams a turn as `.assistantTextDelta` /
    /// `.thinkingDelta` chunks, and both are `isInternalTranscriptEvent`, so
    /// `transcriptVisible` filters every one of them out. Appending them raw
    /// (the old `default:` branch) produced hundreds of events that the
    /// transcript could not show: a live chat sat frozen on its user message
    /// and tool-call rows while `events` climbed past 500, and the reply only
    /// appeared after switching away and back — which re-read the *persisted*
    /// rows, where the daemon had written properly coalesced text.
    ///
    /// `AgentEvent.mergingStreamDeltas` states the contract this satisfies:
    /// "any OTHER consumer of the raw stream (queue transcripts, rehydrated
    /// histories) must apply it too, or a streamed reply renders as one row per
    /// word-fragment." This mirror is such a consumer. The logic here is the
    /// incremental (event-at-a-time) form of that same fold; the two must stay
    /// in step.
    private func mergeOrAppendEvent(_ event: AgentEvent) {
        let now = Date()
        switch event {
        case .assistantTextDelta(let delta):
            if streamingRow == .assistant, case .assistantText(let existing) = events.last {
                // Keep the original timestamp — the row's "first seen" time.
                events[events.count - 1] = .assistantText(existing + delta)
            } else {
                events.append(.assistantText(delta))
                eventTimestamps.append(now)
            }
            streamingRow = .assistant

        case .assistantText(let text):
            // The authoritative full text for a block we were streaming
            // replaces the in-progress row instead of appending a duplicate.
            if streamingRow == .assistant, case .assistantText = events.last {
                replaceLastEvent(with: event, at: now)
            } else if let last = events.last, case .assistantText(let existing) = last,
                      text.hasPrefix(existing) {
                // Providers that resend cumulative full text (no delta events)
                // still collapse onto one row.
                replaceLastEvent(with: event, at: now)
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
            streamingRow = .none

        case .thinkingDelta(let delta):
            if streamingRow == .thinking, case .thinking(let existing) = events.last {
                events[events.count - 1] = .thinking(existing + delta)
            } else {
                events.append(.thinking(delta))
                eventTimestamps.append(now)
            }
            streamingRow = .thinking

        case .thinking(let text):
            if streamingRow == .thinking, case .thinking = events.last {
                replaceLastEvent(with: event, at: now)
            } else if let last = events.last, case .thinking(let existing) = last,
                      text.hasPrefix(existing) {
                replaceLastEvent(with: event, at: now)
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
            streamingRow = .none

        default:
            events.append(event)
            eventTimestamps.append(now)
            streamingRow = .none
        }
    }

    /// Overwrite the last event, keeping `eventTimestamps` parallel.
    private func replaceLastEvent(with event: AgentEvent, at now: Date) {
        guard !events.isEmpty else { return }
        events[events.count - 1] = event
        if !eventTimestamps.isEmpty {
            eventTimestamps[eventTimestamps.count - 1] = now
        }
    }

    private func applyStateUpdate(_ update: ChatStateUpdate) {
        runState = .from(isRunning: update.isRunning,
                          isGenerating: update.isGenerating,
                          isAwaitingSlot: update.isAwaitingGenerationSlot)
        preflightError = update.preflightError
        thinkingOption = update.thinkingOption
        if let usageData = update.usageData,
           let usage = DebugLog.trying("decode session usage", operation: { try JSONDecoder().decode(SessionUsage.self, from: usageData) }) {
            runTotalUsage = usage
        }
        if let raw = update.runKindRaw {
            runningKind = WikiOperation.Kind(rawValue: raw)
        }
        runStartedAt = update.runStartedAt
        if let stderr = update.stderr { self.stderr = stderr }
        if let lastActivityAt = update.lastActivityAt { self.lastActivityAt = lastActivityAt }
        if let pid = update.currentProcessID { self.currentProcessID = Int32(exactly: pid) }
    }

    // MARK: - Provider config surface (shared file, same as the daemon reads)

    /// The App Group container the provider config is loaded from + saved to.
    /// Same resolution the daemon's chat launcher uses, so an app-side write
    /// is visible to the next `startChat` / `continueChat` on the daemon.
    public func resolveProvidersContainerDirectory() -> URL {
        DebugLog.trying("resolve providers container", operation: { try DatabaseLocation.appGroupContainerDirectory() })
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

    /// The user's persisted model selection for `providerId` (nil = agent
    /// default). Mirrors `AgentLauncher.selectedModelId(forProvider:)`.
    public func selectedModelId(forProvider providerId: ProviderID) -> String? {
        providersConfig().selectedModelId(forProvider: providerId)
    }

    /// Toggle + persist a model's favorite state. Display-only (favorites sort
    /// to the top of the picker). Mirrors
    /// `AgentLauncher.toggleFavoriteModel(_:forProvider:)`.
    @discardableResult
    public func toggleFavoriteModel(_ modelId: String, forProvider providerId: ProviderID) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().togglingFavoriteModel(modelId, forProvider: providerId)
        do {
            try updated.save(to: dir)
        } catch {
            DebugLog.store("RemoteChatSession.toggleFavoriteModel save failed (provider=\(providerId.rawValue) model=\(modelId)): \(error)")
        }
        return updated
    }

    // MARK: - Mid-session thinking effort (best-effort)

    /// Optimistically flip the thinking-effort chip AND fire the daemon's
    /// `setChatConfigOption` XPC method so the live ACP session applies the
    /// change. The optimistic flip keeps the UI snappy; a subsequent
    /// `chatState` envelope from the daemon reconciles to its truth. If
    /// `onSetChatConfigOption` is nil (draft session or no coordinator), only
    /// the local flip happens.
    public func setThinkingEffort(_ value: String) {
        guard let option = thinkingOption else { return }
        DebugLog.agent("RemoteChatSession.setThinkingEffort: value=\(value) configId=\(option.configId)")
        thinkingOption = option.withCurrentValue(value)
        let configId = option.configId
        let callback = onSetChatConfigOption
        Task { await callback?(configId, value) }
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
    }

    func reset() {
        events = []
        eventTimestamps = []
        runState = .idle
        streamingRow = .none
        exitStatus = nil
        preflightError = nil
        pendingPermissions = []
        thinkingOption = nil
        runTotalUsage = nil
        runningKind = nil
        runStartedAt = nil
        stderr = ""
        lastActivityAt = nil
        currentProcessID = nil
    }
}
#endif
