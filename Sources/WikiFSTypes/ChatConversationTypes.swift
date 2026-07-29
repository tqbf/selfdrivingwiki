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
    public let detail: String?
    public let permissionRequestID: PermissionRequestID?
    public let updatedAt: Date

    public init(
        toolCallID: ToolCallID,
        turnID: ChatTurnID,
        toolName: String,
        status: ChatToolCallStatus,
        detail: String?,
        permissionRequestID: PermissionRequestID?,
        updatedAt: Date
    ) {
        self.toolCallID = toolCallID
        self.turnID = turnID
        self.toolName = toolName
        self.status = status
        self.detail = detail
        self.permissionRequestID = permissionRequestID
        self.updatedAt = updatedAt
    }
}

/// One system notice row in the durable transcript vocabulary.
public struct ChatTranscriptSystemNoticeItem: Hashable, Sendable, Codable {
    public let turnID: ChatTurnID?
    public let kind: ChatSystemNoticeKind
    public let title: String
    public let message: String
    public let createdAt: Date

    public init(
        turnID: ChatTurnID?,
        kind: ChatSystemNoticeKind,
        title: String,
        message: String,
        createdAt: Date
    ) {
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.message = message
        self.createdAt = createdAt
    }
}

/// One terminal turn-failure row in the durable transcript vocabulary.
public struct ChatTranscriptTurnFailureItem: Hashable, Sendable, Codable {
    public let turnID: ChatTurnID
    public let category: ChatTurnFailureCategory
    public let message: String
    public let createdAt: Date

    public init(
        turnID: ChatTurnID,
        category: ChatTurnFailureCategory,
        message: String,
        createdAt: Date
    ) {
        self.turnID = turnID
        self.category = category
        self.message = message
        self.createdAt = createdAt
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
        terminalMessage: String?
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
    }
}

/// One persisted transcript row plus its cursor and current-renderer projection.
public struct PersistedChatTranscriptItem: Hashable, Sendable, Codable {
    public let cursor: ChatTranscriptCursor
    public let item: ChatTranscriptItem
    public let projectedEventJSON: String?
    public let projectedPlainText: String
    public let createdAt: Date

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
