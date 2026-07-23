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

    public init(wikiID: String, firstMessage: String) {
        self.wikiID = wikiID
        self.firstMessage = firstMessage
    }
}

/// Reply to `startChat`: the assigned chat ULID + an optional preflight error.
public struct ChatStartReply: Codable, Sendable {
    public let chatID: String?
    public let error: String?

    public init(chatID: String?, error: String?) {
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
    public let chatID: String
    public let message: String

    public init(wikiID: String, chatID: String, message: String) {
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
    public let chatID: String
    public let optionId: String
    public let approve: Bool

    public init(chatID: String, optionId: String, approve: Bool) {
        self.chatID = chatID
        self.optionId = optionId
        self.approve = approve
    }
}

/// Rehydrate a chat's live state after (re)connect. Returned by
/// `chatSessionState(chatID:)` so the client can rebuild its `RemoteChatSession`
/// from the daemon's held-alive launcher (or from the persisted store if the
/// launcher was evicted).
public struct ChatSessionState: Codable, Sendable {
    public let chatID: String
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

    public init(
        chatID: String,
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
        runStartedAt: Date?
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
    }

    /// Decoded `SessionUsage` from `usageData`, or nil.
    public var usage: SessionUsage? {
        guard let usageData else { return nil }
        return try? JSONDecoder().decode(SessionUsage.self, from: usageData)
    }
}
