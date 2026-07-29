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
