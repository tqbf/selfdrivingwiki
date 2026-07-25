import Foundation
import WikiFSCore

/// Codable request/response types for the Phase C chat XPC protocol.
///
/// These mirror `QueueItemRequest` (WikiFSCore): the XPC `WikiDaemonProtocol`
/// methods carry JSON-encoded `Data`, and both the daemon and the client
/// decode into these typed structs. Lives in WikiFSEngine (not WikiFSCore)
/// because `ChatSessionState` references `ThinkingEffortOption` + `AgentEvent`
/// + `SessionUsage`.

/// Start a new chat. Sent by the client; the daemon creates the `chats` row +
/// seeds the first user message, then starts an interactive session.
public struct ChatStartRequest: Codable, Sendable {
    public let wikiID: String
    public let firstMessage: String
    /// The per-chat model override picked in the composer's `ProviderSelector`
    /// BEFORE the chat existed (a `.draft` session has no `chats` row yet to
    /// write it to). `nil` = no override. Seeds `ChatSummary.modelProviderId`/
    /// `.modelId` at creation (`DaemonChatHost.startChat`).
    public let providerId: String?
    public let modelId: String?

    public init(wikiID: String, firstMessage: String, providerId: String? = nil, modelId: String? = nil) {
        self.wikiID = wikiID
        self.firstMessage = firstMessage
        self.providerId = providerId
        self.modelId = modelId
    }
}

/// Reply to `startChat`: the assigned chat ULID + an optional preflight error.
public struct ChatStartReply: Codable, Sendable {
    public let chatID: PageID?
    public let error: String?

    public init(chatID: PageID?, error: String?) {
        self.chatID = chatID
        self.error = error
    }
}

/// Continue a persisted chat with a new user turn. The daemon reads the
/// chat's history + `acpSessionId` from the store, builds the adaptive
/// preamble (or attempts ACP resume), and starts a fresh session writing to
/// the SAME chat row.
public struct ChatContinueRequest: Codable, Sendable {
    public let wikiID: String
    public let chatID: PageID
    public let message: String

    public init(wikiID: String, chatID: PageID, message: String) {
        self.wikiID = wikiID
        self.chatID = chatID
        self.message = message
    }
}

/// Generic error reply for `continueChat` / `sendChatMessage`.
public struct ChatErrorReply: Codable, Sendable {
    public let error: String?

    public init(error: String?) {
        self.error = error
    }
}

/// Resolve a pending permission request for a chat (approve/reject).
public struct ChatPermissionResolveRequest: Codable, Sendable {
    public let chatID: PageID
    public let optionId: String
    public let approve: Bool

    public init(chatID: PageID, optionId: String, approve: Bool) {
        self.chatID = chatID
        self.optionId = optionId
        self.approve = approve
    }
}

/// Set a config option (e.g. `thought_level`) on a live chat session without
/// restarting it. Sent by the client; the daemon forwards to the launcher's
/// ACP backend (`session/set_config_option`). Reply is `ChatErrorReply`.
public struct ChatConfigOptionRequest: Codable, Sendable {
    public let chatID: PageID
    /// The ACP config option id (e.g. `"thought_level"`).
    public let option: String
    /// The value id to set (e.g. `"high"`).
    public let value: String

    public init(chatID: PageID, option: String, value: String) {
        self.chatID = chatID
        self.option = option
        self.value = value
    }
}

/// Rehydrate a chat's live state after (re)connect. Returned by
/// `chatSessionState(chatID:)` so the client can rebuild its `RemoteChatSession`
/// from the daemon's held-alive launcher (or from the persisted store if the
/// launcher was evicted).
public struct ChatSessionState: Codable, Sendable {
    public let chatID: PageID
    /// The live transcript mirror (persistable events only — matching the
    /// store's `chat_messages` rows). Non-persistable streaming deltas are
    /// lossy by design; the finalized `.assistantText` row is the source of
    /// truth.
    public let events: [AgentEvent]
    public let isRunning: Bool
    public let isGenerating: Bool
    public let isAwaitingGenerationSlot: Bool
    public let preflightError: String?
    public let thinkingOption: ThinkingEffortOption?
    /// The cumulative session usage for this chat (mirrors
    /// `AgentLauncher.runTotalUsage`). `nil` if no turn has run.
    public let usageData: Data?
    /// The chat's most-recent run's log file URL (pure disk resolve).
    public let logFileURL: URL?
    /// The chat's most-recent run's debug folder URL.
    public let debugFolderURL: URL?
    /// The run kind (`.queryChat`), if a run has started.
    public let runKindRaw: String?
    /// The wall-clock start time of the current/last run.
    public let runStartedAt: Date?
    /// The agent's stderr capture (diagnostics), if any. Read from the
    /// launcher's `stderr` buffer. `nil` when empty or no session exists.
    public let stderr: String?
    /// When the session last had activity (stdout/stderr bytes or a state
    /// change). `nil` when no run has started.
    public let lastActivityAt: Date?
    /// The ACP subprocess PID, if a process is/was spawned.
    public let currentProcessID: Int?

    public init(
        chatID: PageID,
        events: [AgentEvent],
        isRunning: Bool,
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool,
        preflightError: String?,
        thinkingOption: ThinkingEffortOption?,
        usageData: Data?,
        logFileURL: URL?,
        debugFolderURL: URL?,
        runKindRaw: String?,
        runStartedAt: Date?,
        stderr: String? = nil,
        lastActivityAt: Date? = nil,
        currentProcessID: Int? = nil
    ) {
        self.chatID = chatID
        self.events = events
        self.isRunning = isRunning
        self.isGenerating = isGenerating
        self.isAwaitingGenerationSlot = isAwaitingGenerationSlot
        self.preflightError = preflightError
        self.thinkingOption = thinkingOption
        self.usageData = usageData
        self.logFileURL = logFileURL
        self.debugFolderURL = debugFolderURL
        self.runKindRaw = runKindRaw
        self.runStartedAt = runStartedAt
        self.stderr = stderr
        self.lastActivityAt = lastActivityAt
        self.currentProcessID = currentProcessID
    }

    /// Decoded `SessionUsage` from `usageData`, or nil.
    public var usage: SessionUsage? {
        guard let usageData else { return nil }
        return DebugLog.trying("decode SessionUsage", operation: { try JSONDecoder().decode(SessionUsage.self, from: usageData) })
    }
}
