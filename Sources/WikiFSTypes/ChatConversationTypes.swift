// pattern: Functional Core

import Foundation

/// A typed context reference attached to a user turn.
public enum ChatContextReference: Hashable, Sendable, Codable {
    case page(PageID)
    case source(SourceID)
    case chat(ChatID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case page
        case source
        case chat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .page:
            self = .page(try container.decode(PageID.self, forKey: .id))
        case .source:
            self = .source(try container.decode(SourceID.self, forKey: .id))
        case .chat:
            self = .chat(try container.decode(ChatID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .page(let id):
            try container.encode(Kind.page, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .source(let id):
            try container.encode(Kind.source, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .chat(let id):
            try container.encode(Kind.chat, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

/// One durable user turn submission before provider prompt shaping.
public struct ChatTurnSubmission: Hashable, Sendable, Codable {
    public let commandID: ChatCommandID
    public let turnID: ChatTurnID
    public let userText: String
    public let contextReferences: [ChatContextReference]
    public let submittedAt: Date

    public init(
        commandID: ChatCommandID,
        turnID: ChatTurnID,
        userText: String,
        contextReferences: [ChatContextReference],
        submittedAt: Date
    ) {
        self.commandID = commandID
        self.turnID = turnID
        self.userText = userText
        self.contextReferences = contextReferences
        self.submittedAt = submittedAt
    }
}

/// Stable claim identity for one durable turn-claim attempt.
public struct ChatTurnClaimID: Hashable, Sendable, Codable, RawRepresentable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

/// The typed status of one tool call in the shared transcript vocabulary.
public enum ChatToolCallStatus: String, Sendable, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// The message-role subset that is durable transcript content.
public enum ChatTranscriptMessageRole: String, Sendable, Codable, CaseIterable {
    case user
    case assistant
    case reasoning
}

/// A user-safe category for turn failure display and persistence.
public enum ChatTurnFailureCategory: String, Sendable, Codable, CaseIterable {
    case cancelled
    case interrupted
    case runtimeError
    case permissionDenied
    case transportError
}

/// A typed system-notice category that clients can project without string
/// parsing.
public enum ChatSystemNoticeKind: String, Sendable, Codable, CaseIterable {
    case session
    case recovery
    case queue
    case diagnostics
}

/// One transcript message row.
public struct ChatTranscriptMessageItem: Hashable, Sendable, Codable {
    public let messageID: ChatMessageID
    public let turnID: ChatTurnID
    public let role: ChatTranscriptMessageRole
    public let text: String
    public let createdAt: Date

    public init(
        messageID: ChatMessageID,
        turnID: ChatTurnID,
        role: ChatTranscriptMessageRole,
        text: String,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.turnID = turnID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// One tool-call row in the durable transcript vocabulary.
public struct ChatTranscriptToolCallItem: Hashable, Sendable, Codable {
    public let toolCallID: ToolCallID
    public let turnID: ChatTurnID
    public let toolName: String
    public let status: ChatToolCallStatus
    /// Stable human-readable descriptor of the tool input (for example, a
    /// command, path, URL, or query). It remains stable when an output arrives.
    public let detail: String?
    /// The provider's raw-for-display tool output. This is deliberately
    /// separate from `detail` so presentation can expand output without using
    /// a transport wrapper as the tool descriptor.
    public let output: String?
    public let permissionRequestID: PermissionRequestID?
    public let updatedAt: Date

    public init(
        toolCallID: ToolCallID,
        turnID: ChatTurnID,
        toolName: String,
        status: ChatToolCallStatus,
        detail: String?,
        output: String? = nil,
        permissionRequestID: PermissionRequestID?,
        updatedAt: Date
    ) {
        self.toolCallID = toolCallID
        self.turnID = turnID
        self.toolName = toolName
        self.status = status
        self.detail = detail
        self.output = output
        self.permissionRequestID = permissionRequestID
        self.updatedAt = updatedAt
    }
}

/// One system notice row in the durable transcript vocabulary.
public struct ChatTranscriptSystemNoticeItem: Hashable, Sendable, Codable {
    public let noticeID: ChatTranscriptNoticeID
    public let turnID: ChatTurnID?
    public let kind: ChatSystemNoticeKind
    public let title: String
    public let message: String
    public let createdAt: Date

    public init(
        noticeID: ChatTranscriptNoticeID,
        turnID: ChatTurnID?,
        kind: ChatSystemNoticeKind,
        title: String,
        message: String,
        createdAt: Date
    ) {
        self.noticeID = noticeID
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.message = message
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case noticeID
        case turnID
        case kind
        case title
        case message
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.noticeID) else {
            throw ChatTranscriptItemDecodingError.missingNoticeIdentity
        }
        self.noticeID = try container.decode(ChatTranscriptNoticeID.self, forKey: .noticeID)
        self.turnID = try container.decodeIfPresent(ChatTurnID.self, forKey: .turnID)
        self.kind = try container.decode(ChatSystemNoticeKind.self, forKey: .kind)
        self.title = try container.decode(String.self, forKey: .title)
        self.message = try container.decode(String.self, forKey: .message)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noticeID, forKey: .noticeID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(message, forKey: .message)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// One terminal turn-failure row in the durable transcript vocabulary.
public struct ChatTranscriptTurnFailureItem: Hashable, Sendable, Codable {
    public let failureID: ChatTranscriptFailureID
    public let turnID: ChatTurnID
    public let category: ChatTurnFailureCategory
    public let message: String
    public let createdAt: Date

    public init(
        failureID: ChatTranscriptFailureID,
        turnID: ChatTurnID,
        category: ChatTurnFailureCategory,
        message: String,
        createdAt: Date
    ) {
        self.failureID = failureID
        self.turnID = turnID
        self.category = category
        self.message = message
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case failureID
        case turnID
        case category
        case message
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.failureID) else {
            throw ChatTranscriptItemDecodingError.missingFailureIdentity
        }
        self.failureID = try container.decode(ChatTranscriptFailureID.self, forKey: .failureID)
        self.turnID = try container.decode(ChatTurnID.self, forKey: .turnID)
        self.category = try container.decode(ChatTurnFailureCategory.self, forKey: .category)
        self.message = try container.decode(String.self, forKey: .message)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(failureID, forKey: .failureID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(category, forKey: .category)
        try container.encode(message, forKey: .message)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// The shared Foundation-only transcript item vocabulary.
public enum ChatTranscriptItem: Hashable, Sendable, Codable {
    case message(ChatTranscriptMessageItem)
    case toolCall(ChatTranscriptToolCallItem)
    case systemNotice(ChatTranscriptSystemNoticeItem)
    case turnFailure(ChatTranscriptTurnFailureItem)

    public var turnID: ChatTurnID? {
        switch self {
        case .message(let item):
            return item.turnID
        case .toolCall(let item):
            return item.turnID
        case .systemNotice(let item):
            return item.turnID
        case .turnFailure(let item):
            return item.turnID
        }
    }
}

/// Monotonic, per-chat transcript cursor used for authoritative history paging.
public struct ChatTranscriptCursor: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ChatTranscriptCursor, rhs: ChatTranscriptCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let zero = ChatTranscriptCursor(rawValue: 0)
}

/// Durable lifecycle of one persisted turn row.
public enum ChatTurnPersistenceState: String, Hashable, Sendable, Codable, CaseIterable {
    case queued
    case claimed
    case providerSubmitted
    case completed
    case cancelled
    case failed
}

/// Usage fields observed for one durable chat turn. Provider and model are
/// snapshots from claim time; all counters and cost fields remain optional so
/// rows written before schema v48 retain their original meaning.
public struct ChatTurnUsage: Hashable, Sendable, Codable {
    public let turnID: ChatTurnID
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let state: ChatTurnPersistenceState
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cost: Decimal?
    public let currency: String?

    public init(
        turnID: ChatTurnID,
        providerID: ProviderID?,
        modelID: ModelID?,
        startedAt: Date?,
        finishedAt: Date?,
        state: ChatTurnPersistenceState,
        inputTokens: Int?,
        outputTokens: Int?,
        thoughtTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        cost: Decimal?,
        currency: String?
    ) {
        self.turnID = turnID
        self.providerID = providerID
        self.modelID = modelID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }
}

/// The mutable subset of a turn's usage record. Lifecycle identity and claim
/// snapshots are intentionally absent: only the controller's claim/finish
/// paths establish those fields.
public struct ChatTurnUsageValues: Hashable, Sendable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let cost: Decimal?
    public let currency: String?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        thoughtTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cost: Decimal? = nil,
        currency: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }
}

/// Aggregate durable usage for one chat. Counter totals are zero for an empty
/// chat or legacy rows with no usage, while money remains unavailable until all
/// contributing cost rows share one non-nil currency.
public struct ChatUsageSummary: Hashable, Sendable {
    public let latestTurn: ChatTurnUsage?
    public let inputTokens: Int
    public let outputTokens: Int
    public let thoughtTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cost: Decimal?
    public let currency: String?

    public init(
        latestTurn: ChatTurnUsage?,
        inputTokens: Int,
        outputTokens: Int,
        thoughtTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cost: Decimal?,
        currency: String?
    ) {
        self.latestTurn = latestTurn
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.currency = currency
    }

    public static let empty = ChatUsageSummary(
        latestTurn: nil,
        inputTokens: 0,
        outputTokens: 0,
        thoughtTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        cost: nil,
        currency: nil
    )
}

/// One durable turn row persisted for later controller recovery/replay.
public struct PersistedChatTurn: Hashable, Sendable, Codable {
    public let chatID: ChatID
    public let ordinal: Int
    public let submission: ChatTurnSubmission
    public let editedAt: Date?
    public let state: ChatTurnPersistenceState
    public let claimID: ChatTurnClaimID?
    public let claimedAt: Date?
    public let providerSubmittedAt: Date?
    public let providerSessionID: AcpSessionID?
    public let terminalMessage: String?
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let finishedAt: Date?
    public let usage: ChatTurnUsageValues

    public init(
        chatID: ChatID,
        ordinal: Int,
        submission: ChatTurnSubmission,
        editedAt: Date?,
        state: ChatTurnPersistenceState,
        claimID: ChatTurnClaimID?,
        claimedAt: Date?,
        providerSubmittedAt: Date?,
        providerSessionID: AcpSessionID?,
        terminalMessage: String?,
        providerID: ProviderID? = nil,
        modelID: ModelID? = nil,
        finishedAt: Date? = nil,
        usage: ChatTurnUsageValues = .init()
    ) {
        self.chatID = chatID
        self.ordinal = ordinal
        self.submission = submission
        self.editedAt = editedAt
        self.state = state
        self.claimID = claimID
        self.claimedAt = claimedAt
        self.providerSubmittedAt = providerSubmittedAt
        self.providerSessionID = providerSessionID
        self.terminalMessage = terminalMessage
        self.providerID = providerID
        self.modelID = modelID
        self.finishedAt = finishedAt
        self.usage = usage
    }
}

/// One persisted transcript row plus its cursor and current-renderer projection.
public struct PersistedChatTranscriptItem: Hashable, Sendable, Codable {
    public let cursor: ChatTranscriptCursor
    public let item: ChatTranscriptItem
    public let projectedEventJSON: String?
    public let projectedPlainText: String
    public let createdAt: Date
    /// Cached summary from the compatibility `chat_messages` row at this
    /// cursor. The store joins it by the durable cursor/sequence relationship;
    /// it is deliberately not keyed by the compatibility row's `PageID`.
    public let cachedResponseSummary: String?

    public init(
        cursor: ChatTranscriptCursor,
        item: ChatTranscriptItem,
        projectedEventJSON: String?,
        projectedPlainText: String,
        createdAt: Date,
        cachedResponseSummary: String?
    ) {
        self.cursor = cursor
        self.item = item
        self.projectedEventJSON = projectedEventJSON
        self.projectedPlainText = projectedPlainText
        self.createdAt = createdAt
        self.cachedResponseSummary = cachedResponseSummary
    }

    /// Source-compatible initializer for callers that do not have a cached
    /// summary (newly appended rows and existing test fixtures).
    public init(
        cursor: ChatTranscriptCursor,
        item: ChatTranscriptItem,
        projectedEventJSON: String?,
        projectedPlainText: String,
        createdAt: Date
    ) {
        self.cursor = cursor
        self.item = item
        self.projectedEventJSON = projectedEventJSON
        self.projectedPlainText = projectedPlainText
        self.createdAt = createdAt
        self.cachedResponseSummary = nil
    }
}

/// One transcript page plus the high-water checkpoint visible at read time.
public struct ChatTranscriptPage: Hashable, Sendable, Codable {
    public let items: [PersistedChatTranscriptItem]
    public let checkpoint: ChatTranscriptCursor
    public let nextCursor: ChatTranscriptCursor?

    public init(
        items: [PersistedChatTranscriptItem],
        checkpoint: ChatTranscriptCursor,
        nextCursor: ChatTranscriptCursor?
    ) {
        self.items = items
        self.checkpoint = checkpoint
        self.nextCursor = nextCursor
    }
}
