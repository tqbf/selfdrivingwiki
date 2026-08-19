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
    func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID
    func stopChat(_ chatID: ChatID) async throws
    func chatSessionState(_ chatID: ChatID) async throws -> ChatSyncSnapshot
    func chatDiagnosticSnapshot(_ request: ChatDiagnosticSnapshotRequest) async throws -> ChatDiagnosticSnapshotEnvelope
    func resetChatDiagnostics(_ request: ChatDiagnosticResetRequest) async throws
    func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws
    func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws
}

extension DaemonWorkloadClient: ChatDaemonCommands {}

/// App-side coordinator for daemon-hosted chat sessions (Phase C4).
///
/// Owns the per-chat `RemoteChatSession` registry, routes chat event envelopes
/// demuxed by `DaemonQueueEventSink`, wraps the five current chat XPC commands behind
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
/// app has not opened. `isChatGenerating(_:)` / `anyChatGenerating` back the sidebar
/// + chats-list "responding…" indicators that previously read
    /// the session's `chatID` / `runState`.
@MainActor
@Observable
public final class ChatDaemonCoordinator {

    private let client: ChatDaemonCommands
    private let eventSink: DaemonQueueEventSink
    private let diagnosticTrace: ChatDiagnosticTrace
    private let providersConfigurationDirectory: URL?

    /// chat key → mirror session. The draft (.newChat) state uses `.draft`.
    private var sessions: [ChatSessionKey: RemoteChatSession] = [:]

    /// chatIDs the daemon currently reports as **generating** (from `chatState`
    /// envelopes), regardless of whether the app has an open session for them.
    /// Lets the sidebar badge a chat the daemon is answering (e.g. one started
    /// via `wikictl`) that the user hasn't opened here.
    ///
    /// Deliberately NOT `isRunning`. For an interactive chat session
    /// `AgentLauncher.isRunning` means "the agent process is alive **across
    /// turns**" (see its declaration: "SPAWN COMMIT: process is alive.
    /// isRunning = true (process alive across turns)"), so it stays true while
    /// the session sits idle waiting for your next message. `isGenerating` is
    /// the per-turn flag — set when a message is sent, cleared on the terminal
    /// `.result`/`.messageStop` — and `AgentLauncher` states the contract
    /// outright: "Every UI spinner / Stop affordance keys off this rather than
    /// the raw `isRunning`."
    private var generatingChatIDs: Set<ChatID> = []

    /// Bumped whenever `generatingChatIDs` changes, so SwiftUI views that badge
    /// chats (the sidebar list) re-render when a chat starts or stops
    /// answering. The set is private and read only inside `isChatGenerating(_:)`,
    /// which the table data source calls *outside* SwiftUI's tracked body — so
    /// a dedicated observable signal is the only way the sidebar learns a chat
    /// finished (otherwise the "responding…" badge sticks forever).
    public private(set) var runningStateToken: Int = 0

    private var routerTask: Task<Void, Never>?
    private var providerConfigObserver: ProviderConfigChangeObserver?

    init(
        client: ChatDaemonCommands,
        eventSink: DaemonQueueEventSink,
        diagnosticTrace: ChatDiagnosticTrace = ChatDiagnostics.appTrace,
        providersConfigurationDirectory: URL? = nil
    ) {
        // Intentionally non-`public` — `DaemonQueueEventSink` is internal, so
        // the coordinator can only be constructed from within the WikiFS module
        // (the app wires it in `WikiFSApp`; tests inject a stub `ChatDaemonCommands`).
        self.client = client
        self.eventSink = eventSink
        self.diagnosticTrace = diagnosticTrace
        self.providersConfigurationDirectory = providersConfigurationDirectory
        startRouting()
        providerConfigObserver = ProviderConfigChangeObserver { [weak self] in
            self?.reloadProviderConfigurationIfNeeded()
        }
    }

    // MARK: - Session registry

    /// Get-or-create the `RemoteChatSession` for a chat id. `nil` chatID
    /// returns the shared draft-state session (the `.newChat` composer).
    public func session(for chatID: ChatID?) -> RemoteChatSession {
        let key: ChatSessionKey = chatID.map(ChatSessionKey.chat) ?? .draft
        if let existing = sessions[key] { return existing }
        let session = providersConfigurationDirectory.map {
            RemoteChatSession(chatID: key, providersConfigurationDirectory: $0)
        } ?? RemoteChatSession(chatID: key)
        wireSessionCallbacks(session)
        sessions[key] = session
        return session
    }

    /// Reload every known draft, idle, restored, and live mirror after a
    /// committed provider-sidecar generation becomes visible.
    func reloadProviderConfigurationIfNeeded() {
        for session in sessions.values {
            let loaded = AgentProvidersConfig.loadOrSeed(
                from: session.resolveProvidersContainerDirectory())
            guard loaded.generation != session.providerConfiguration.generation else { continue }
            session.refreshProvidersConfig()
        }
    }

    /// Activation repair for notifications missed while the app was suspended.
    func applicationDidBecomeActive() {
        reloadProviderConfigurationIfNeeded()
    }

    /// Builds the redacted app/daemon diagnostic artifact for an existing chat.
    /// Request failures become an explicit app-side snapshot event so exports
    /// explain whether the daemon half was unavailable, malformed, or old.
    func diagnosticSnapshot(for chatID: ChatID?) async -> ChatDiagnosticMergedSnapshot {
        let correlation = chatID.map { ChatDiagnosticCorrelation.Value(rawValue: $0.rawValue) }
        let app = diagnosticTrace.snapshot(
            chat: correlation,
            summary: ["sync": "app-coordinator", "chat": correlation?.rawValue ?? "draft"]
        )
        guard chatID != nil else { return ChatDiagnosticSnapshotMerge.merge(app: app, daemon: nil) }
        do {
            let daemon = try await client.chatDiagnosticSnapshot(.init(chat: correlation))
            return ChatDiagnosticSnapshotMerge.merge(app: app, daemon: daemon)
        } catch let error as DaemonXPCError {
            let outcome: ChatDiagnosticOutcome
            switch error {
            case .timeout: outcome = .timeout
            case .diagnosticDecode: outcome = .decodeFailure
            case .diagnosticVersion: outcome = .versionFailure
            default: outcome = .failed
            }
            _ = diagnosticTrace.record(
                stage: .syncAcceptance,
                outcome: outcome,
                payload: .init(correlation: .init(chat: correlation), detail: "daemon-diagnostic-snapshot")
            )
            let updated = diagnosticTrace.snapshot(chat: correlation)
            return ChatDiagnosticSnapshotMerge.merge(app: updated, daemon: nil)
        } catch {
            _ = diagnosticTrace.record(
                stage: .syncAcceptance,
                outcome: .failed,
                payload: .init(correlation: .init(chat: correlation), detail: "daemon-diagnostic-snapshot")
            )
            return ChatDiagnosticSnapshotMerge.merge(app: diagnosticTrace.snapshot(chat: correlation), daemon: nil)
        }
    }

    /// Requests the app/daemon snapshot through the normal coordinator path,
    /// then writes the redacted artifact to the caller-provided destination.
    /// A written artifact immediately retires both fingerprint epochs. The
    /// daemon reset still drains both rings on success; a failed reset retains
    /// retry evidence without reusing an exported fingerprint key.
    func copyDiagnostics(
        for chatID: ChatID?,
        write: (Data) throws -> Void
    ) async throws {
        let snapshot = await diagnosticSnapshot(for: chatID)
        let exporter = ChatDiagnosticExporter(trace: diagnosticTrace)
        try await exporter.copy(snapshot, write: write)
        if let chatID {
            do {
                try await client.resetChatDiagnostics(.init(chat: .init(rawValue: chatID.rawValue)))
            } catch {
                exporter.rotateFingerprintKeyPreservingRecords()
                throw error
            }
        }
        exporter.resetAfterSuccessfulExport()
    }

    /// Writes the same redacted coordinator snapshot as JSONL for explicit
    /// diagnostic collection. Full-content ACP artifacts remain the separate
    /// debug-folder workflow owned by the chat runtime.
    func writeDiagnosticsJSONL(
        for chatID: ChatID?,
        to url: URL
    ) async throws {
        let snapshot = await diagnosticSnapshot(for: chatID)
        let exporter = ChatDiagnosticExporter(trace: diagnosticTrace)
        try await exporter.writeJSONL(snapshot, to: url)
        if let chatID {
            do {
                try await client.resetChatDiagnostics(.init(chat: .init(rawValue: chatID.rawValue)))
            } catch {
                exporter.rotateFingerprintKeyPreservingRecords()
                throw error
            }
        }
        exporter.resetAfterSuccessfulExport()
    }

    /// Drop the cached session for a chat (e.g. when retargeting the tab to a
    /// fresh draft). The daemon's own session is unaffected.
    public func discard(chatID: ChatID?) {
        sessions.removeValue(forKey: chatID.map(ChatSessionKey.chat) ?? .draft)
    }

    /// Replace the draft session with a fresh one (used by "start new chat").
    public func resetDraft() {
        let session = RemoteChatSession(chatID: .draft)
        wireSessionCallbacks(session)
        sessions[.draft] = session
    }

    func stop() {
        routerTask?.cancel()
        routerTask = nil
        providerConfigObserver?.stop()
        providerConfigObserver = nil
    }

    // MARK: - Event routing

    private func startRouting() {
        routerTask?.cancel()
        routerTask = Task { [weak self] in
            guard let self else { return }
            for await (chatID, update) in self.eventSink.chatEnvelopes {
                self.route(chatID: chatID, update: update)
            }
        }
    }

    /// chatID arrives in wire form (a `ChatID`) off the daemon's envelope
    /// stream — the sink already decoded it from the envelope's `chatID`
    /// field, so nothing past here handles a raw chat-id string.
    private func route(chatID: ChatID, update: ChatSyncUpdate) {
        setChatGenerating(chatID, generating: update.projection.isAnswering)
        sessions[.chat(chatID)]?.ingest(update)
    }

    // MARK: - Sidebar liveness aggregate

    /// The single mutator for `generatingChatIDs`. Updates the set and bumps
    /// `runningStateToken` **only when membership actually changes**, so every
    /// transition flows through one place (both the event-router `route()` and
    /// `rehydrate()`). Centralizing this guarantees the observable signal
    /// always fires — forgetting the token bump in a new call site would
    /// silently stick the sidebar "responding…" badge.
    private func setChatGenerating(_ chatID: ChatID, generating: Bool) {
        let didChange = generating
            ? generatingChatIDs.insert(chatID).inserted
            : generatingChatIDs.remove(chatID) != nil
        if didChange { runningStateToken &+= 1 }
    }

    /// True while the daemon is actively answering this chat. Backs the sidebar
    /// + chats-list "responding…" indicator.
    ///
    /// Keys off `isGenerating`, never `isRunning` — see `generatingChatIDs` for
    /// why (an interactive session's process stays alive between turns, so
    /// `isRunning` would pin the badge on for the life of the session).
    public func isChatGenerating(_ chatID: ChatID) -> Bool {
        if generatingChatIDs.contains(chatID) { return true }
        if let s = sessions[.chat(chatID)], s.runState.isAnswering { return true }
        return false
    }

    /// True if any chat is currently being answered on the daemon. Backs the
    /// app-level "is the agent busy" check (the ⌘Q confirmation).
    public var anyChatGenerating: Bool {
        if !generatingChatIDs.isEmpty { return true }
        return sessions.values.contains { $0.runState.isAnswering }
    }

    // MARK: - Commands (wrap DaemonWorkloadClient)

    /// Submit one typed turn through the daemon's unified chat-submit path.
    /// The daemon creates a chat for draft submissions and decides whether an
    /// existing chat is warm, dead, or persisted-only.
    @discardableResult
    public func submitTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        try await client.submitChatTurn(request)
    }

    /// Stop/cancel the active chat turn. Errors are logged (best-effort).
    public func stop(chatID: ChatID) async {
        do { try await client.stopChat(chatID) }
        catch { DebugLog.agent("ChatDaemonCoordinator.stop failed for \(chatID.rawValue): \(error)") }
    }

    /// Resolve a pending permission request (approve/reject). Errors logged.
    func resolvePermission(chatID: ChatID, intent: ChatPermissionResolutionIntent) async {
        do {
            try await client.resolveChatPermission(
                ChatPermissionResolveRequest(
                    chatID: chatID,
                    optionId: intent.optionID.rawValue,
                    approve: intent.isApproval
                )
            )
        } catch {
            DebugLog.agent("ChatDaemonCoordinator.resolvePermission failed for \(chatID.rawValue): \(error)")
        }
    }

    /// Set the thinking-effort config option on a live chat session via the
    /// daemon's `setChatConfigOption` XPC method. Errors are logged (the UI
    /// already flipped optimistically; a `chatState` envelope reconciles).
    public func setThinkingEffort(
        chatID: ChatID,
        optionID: ChatConfigurationOptionID,
        valueID: ChatConfigurationValueID
    ) async {
        do {
            try await client.setChatConfigOption(ChatConfigOptionRequest(
                chatID: chatID,
                option: optionID.rawValue,
                value: valueID.rawValue))
        } catch {
            DebugLog.agent("ChatDaemonCoordinator.setThinkingEffort failed for \(chatID.rawValue): \(error)")
        }
    }

    // MARK: - Rehydration

    /// Wire the session's config-option callback to route through the daemon's
    /// `setChatConfigOption` XPC method. Called when a session is created so
    /// `RemoteChatSession.setThinkingEffort` delegates to the daemon instead
    /// of being a local-only optimistic flip. Skipped for the draft session
    /// (no real chatID to target).
    private func wireSessionCallbacks(_ session: RemoteChatSession) {
        // The draft has no daemon-side session to target, and now says so in
        // the type: `.draft` has no `ChatID`.
        guard let chatID = session.chatID.chatID else { return }
        let client = self.client
        session.onSetChatConfigOption = { option, value in
            do {
                try await client.setChatConfigOption(
                    ChatConfigOptionRequest(chatID: chatID, option: option, value: value))
            } catch {
                DebugLog.agent("RemoteChatSession.onSetChatConfigOption failed for \(chatID): \(error)")
            }
        }
        session.onRequestAuthoritativeSnapshot = {
            try await client.chatSessionState(chatID)
        }
    }

    /// Rehydrate a session from the daemon's live state. Call on view appear
    /// and whenever the active chat changes so the mirror reflects the
    /// daemon's live controller (or the persisted rows once evicted).
    public func rehydrate(chatID: ChatID) async {
        let session = self.session(for: chatID)
        do {
            let state = try await client.chatSessionState(chatID)
            session.hydrate(from: state)
            setChatGenerating(chatID, generating: state.projection.isAnswering)
        } catch {
            // A rehydrate failure (e.g. the daemon evicted the session, so
            // `chatSessionState` throws `noSession`) is non-fatal — but the
            // mirror must actively RELINQUISH its liveness claim, not merely
            // keep its last-known state. Otherwise a session that never got a
            // successful hydrate stays flagged live with zero events, and
            // `ChatDetailView` renders that empty stream instead of the
            // persisted transcript.
            session.markNotLive()
            setChatGenerating(chatID, generating: false)
            DebugLog.agent("ChatDaemonCoordinator.rehydrate failed for \(chatID): \(error) — marked not live")
        }
    }

    // MARK: - Testing hooks

    /// Direct event injection (tests). Routes exactly like a daemon envelope.
    func ingestForTesting(_ envelope: QueueEventEnvelope) {
        guard let chatID = envelope.chatID else { return }
        do {
            route(chatID: chatID, update: try envelope.decodedChatSyncUpdate())
        } catch {
            DebugLog.agent("ChatDaemonCoordinator.ingestForTesting rejected chat sync update for \(chatID): \(error)")
        }
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
