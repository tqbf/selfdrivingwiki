#if os(macOS)
import Foundation
import Observation
import WikiCtlCore
import WikiFSCore
import WikiFSEngine

/// The chat command surface the coordinator wraps. `DaemonWorkloadClient`
/// conforms; tests inject a stub. Extracted as a protocol so the coordinator's
/// registry + routing + rehydration logic is unit-testable without a live XPC
/// connection.
public protocol ChatDaemonCommands: AnyObject, Sendable {
    func startChat(_ request: ChatStartRequest) async throws -> String
    func continueChat(_ request: ChatContinueRequest) async throws
    func sendChatMessage(chatID: String, message: String) async throws
    func stopChat(_ chatID: String) async throws
    func chatSessionState(_ chatID: String) async throws -> ChatSessionState
    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws
}

extension DaemonWorkloadClient: ChatDaemonCommands {}

/// App-side coordinator for daemon-hosted chat sessions (Phase C4).
///
/// Owns the per-chat `RemoteChatSession` registry, routes chat event envelopes
/// demuxed by `DaemonQueueEventSink`, wraps the 6 chat XPC commands behind
/// typed Swift methods, and rehydrates sessions from the daemon's live state.
/// This is the replacement for the per-wiki chat `AgentLauncher` — after C4
/// the app no longer runs chat in-process; the daemon owns every chat session.
///
/// Injected via the SwiftUI environment (see `ChatDaemonCoordinatorKey`).
/// When the daemon is unavailable the environment value is `nil` and
/// `ChatDetailView` renders an unavailable state — there is no local fallback
/// for chat (the daemon is the single chat owner).
///
/// **Live indicator aggregate:** the coordinator tracks the set of chatIDs the
/// daemon reports as running (from `chatState` envelopes), even for chats the
/// app has not opened. `isChatRunning(_:)` / `anyChatRunning` back the sidebar
/// + chats-list "responding…" indicators that previously read
/// `chatLauncher.activeChatID` / `chatLauncher.isRunning`.
@MainActor
@Observable
public final class ChatDaemonCoordinator {

    private let client: ChatDaemonCommands
    private let eventSink: DaemonQueueEventSink

    /// chatID → mirror session. The draft (.newChat) state uses `draftKey`.
    private var sessions: [String: RemoteChatSession] = [:]

    /// chatIDs the daemon currently reports as running/generating (from
    /// `chatState` envelopes), regardless of whether the app has an open
    /// session for them. Lets the sidebar badge a chat the daemon is running
    /// (e.g. one started via `wikictl`) that the user hasn't opened here.
    private var runningChatIDs: Set<String> = []

    private var routerTask: Task<Void, Never>?

    /// Key for the draft (.newChat) session — `chatID == nil` at the view level.
    static let draftKey = "__wiki_draft_chat__"

    init(client: ChatDaemonCommands, eventSink: DaemonQueueEventSink) {
        // Intentionally non-`public` — `DaemonQueueEventSink` is internal, so
        // the coordinator can only be constructed from within the WikiFS module
        // (the app wires it in `WikiFSApp`; tests inject a stub `ChatDaemonCommands`).
        self.client = client
        self.eventSink = eventSink
        startRouting()
    }

    // MARK: - Session registry

    /// Get-or-create the `RemoteChatSession` for a chat id. `nil` chatID
    /// returns the shared draft-state session (the `.newChat` composer).
    public func session(for chatID: String?) -> RemoteChatSession {
        let key = chatID ?? Self.draftKey
        if let existing = sessions[key] { return existing }
        let session = RemoteChatSession(chatID: key)
        sessions[key] = session
        return session
    }

    /// Drop the cached session for a chat (e.g. when retargeting the tab to a
    /// fresh draft). The daemon's own session is unaffected.
    public func discard(chatID: String?) {
        sessions.removeValue(forKey: chatID ?? Self.draftKey)
    }

    /// Replace the draft session with a fresh one (used by "start new chat").
    public func resetDraft() {
        sessions[Self.draftKey] = RemoteChatSession(chatID: Self.draftKey)
    }

    // MARK: - Event routing

    private func startRouting() {
        routerTask?.cancel()
        routerTask = Task { [weak self] in
            guard let self else { return }
            for await (chatID, envelope) in self.eventSink.chatEnvelopes {
                self.route(chatID: chatID, envelope: envelope)
            }
        }
    }

    private func route(chatID: String, envelope: QueueEventEnvelope) {
        // Track the running set from state envelopes so the sidebar can badge
        // chats the daemon is running even without an open app session.
        if envelope.kind == .chatState, let update = envelope.chatStateUpdate {
            if update.isRunning || update.isGenerating {
                runningChatIDs.insert(chatID)
            } else {
                runningChatIDs.remove(chatID)
            }
        }
        // Deliver to the open session if one exists.
        sessions[chatID]?.ingest(envelope)
    }

    // MARK: - Sidebar liveness aggregate

    /// True if the daemon reports this chat as running/generating. Backs the
    /// sidebar + chats-list live indicator (replaces
    /// `chatLauncher.activeChatID == id && chatLauncher.isRunning`).
    public func isChatRunning(_ chatID: String) -> Bool {
        if runningChatIDs.contains(chatID) { return true }
        if let s = sessions[chatID], s.isRunning || s.isGenerating { return true }
        return false
    }

    /// True if any chat is running/generating on the daemon. Backs the
    /// menu-bar / app-level "is the agent busy" check that previously read
    /// `session.chatLauncher.isRunning`.
    public var anyChatRunning: Bool {
        if !runningChatIDs.isEmpty { return true }
        return sessions.values.contains { $0.isRunning || $0.isGenerating }
    }

    // MARK: - Commands (wrap DaemonWorkloadClient)

    /// Start a new chat on the daemon. Returns the assigned chat ULID.
    @discardableResult
    public func startChat(wikiID: String, firstMessage: String) async throws -> String {
        try await client.startChat(ChatStartRequest(wikiID: wikiID, firstMessage: firstMessage))
    }

    /// Continue a persisted chat with a new user turn.
    public func continueChat(wikiID: String, chatID: String, message: String) async throws {
        try await client.continueChat(ChatContinueRequest(wikiID: wikiID, chatID: chatID, message: message))
    }

    /// Send a follow-up turn to an active chat session.
    public func sendMessage(chatID: String, message: String) async throws {
        try await client.sendChatMessage(chatID: chatID, message: message)
    }

    /// Stop/cancel the active chat turn. Errors are logged (best-effort).
    public func stop(chatID: String) async {
        do { try await client.stopChat(chatID) }
        catch { DebugLog.agent("ChatDaemonCoordinator.stop failed for \(chatID): \(error)") }
    }

    /// Resolve a pending permission request (approve/reject). Errors logged.
    public func resolvePermission(chatID: String, optionId: String, approve: Bool) async {
        do {
            try await client.resolveChatPermission(
                ChatPermissionResolveRequest(chatID: chatID, optionId: optionId, approve: approve))
        } catch {
            DebugLog.agent("ChatDaemonCoordinator.resolvePermission failed for \(chatID): \(error)")
        }
    }

    // MARK: - Rehydration

    /// Rehydrate a session from the daemon's live state. Call on view appear
    /// and whenever the active chat changes so the mirror reflects the
    /// daemon's held-alive launcher (or the persisted rows once evicted).
    public func rehydrate(chatID: String) async {
        let session = self.session(for: chatID)
        do {
            let state = try await client.chatSessionState(chatID)
            session.hydrate(from: state)
            if state.isRunning || state.isGenerating {
                runningChatIDs.insert(chatID)
            } else {
                runningChatIDs.remove(chatID)
            }
        } catch {
            // A rehydrate failure (e.g. the daemon evicted the session) is
            // non-fatal — the session keeps its last-known state and the
            // persisted rows remain the source of truth.
            DebugLog.agent("ChatDaemonCoordinator.rehydrate failed for \(chatID): \(error)")
        }
    }

    // MARK: - Testing hooks

    /// Direct event injection (tests). Routes exactly like a daemon envelope.
    func ingestForTesting(_ envelope: QueueEventEnvelope) {
        guard let chatID = envelope.chatID else { return }
        route(chatID: chatID, envelope: envelope)
    }
}

// MARK: - Environment key

import SwiftUI

private struct ChatDaemonCoordinatorKey: EnvironmentKey {
    /// `nil` when the daemon is unavailable — chat renders an unavailable state.
    static let defaultValue: ChatDaemonCoordinator? = nil
}

extension EnvironmentValues {
    /// The app-wide chat daemon coordinator (nil when the daemon is down).
    var chatDaemonCoordinator: ChatDaemonCoordinator? {
        get { self[ChatDaemonCoordinatorKey.self] }
        set { self[ChatDaemonCoordinatorKey.self] = newValue }
    }
}
#endif
