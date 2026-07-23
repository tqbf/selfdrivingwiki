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
    public var activeChatID: String?
    public var exitStatus: Int32?
    public var runningKind: WikiOperation.Kind?
    public var runStartedAt: Date?
    public var preflightError: String?
    public var pendingPermissions: [PendingPermission] = []
    public var thinkingOption: ThinkingEffortOption?

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
    }

    // MARK: - Reset (for new chat / teardown)

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
