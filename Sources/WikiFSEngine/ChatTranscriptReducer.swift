import Foundation
import WikiFSCore

public enum ChatTranscriptDelta: Hashable, Sendable, Codable {
    case append(ChatTranscriptItem)
    case messageDelta(
        messageID: ChatMessageID,
        turnID: ChatTurnID,
        role: ChatTranscriptMessageRole,
        delta: String,
        createdAt: Date
    )
    case messageReplacement(
        messageID: ChatMessageID,
        turnID: ChatTurnID,
        role: ChatTranscriptMessageRole,
        text: String,
        createdAt: Date
    )
    case toolCallUpsert(ChatTranscriptToolCallItem)
}

public enum ChatTranscriptReducer {
    public static func reducing(
        items: [ChatTranscriptItem],
        with deltas: [ChatTranscriptDelta]
    ) -> [ChatTranscriptItem] {
        deltas.reduce(items, apply)
    }

    public static func apply(
        _ items: [ChatTranscriptItem],
        _ delta: ChatTranscriptDelta
    ) -> [ChatTranscriptItem] {
        var next = items

        switch delta {
        case .append(let item):
            next.append(item)

        case .messageDelta(let messageID, let turnID, let role, let deltaText, let createdAt):
            if let index = next.lastIndex(where: { item in
                guard case .message(let message) = item else { return false }
                return message.messageID == messageID
            }), case .message(let existing) = next[index] {
                next[index] = .message(ChatTranscriptMessageItem(
                    messageID: existing.messageID,
                    turnID: existing.turnID,
                    role: existing.role,
                    text: existing.text + deltaText,
                    createdAt: existing.createdAt
                ))
            } else {
                next.append(.message(ChatTranscriptMessageItem(
                    messageID: messageID,
                    turnID: turnID,
                    role: role,
                    text: deltaText,
                    createdAt: createdAt
                )))
            }

        case .messageReplacement(let messageID, let turnID, let role, let text, let createdAt):
            let replacement = ChatTranscriptItem.message(ChatTranscriptMessageItem(
                messageID: messageID,
                turnID: turnID,
                role: role,
                text: text,
                createdAt: createdAt
            ))
            if let index = next.lastIndex(where: { item in
                guard case .message(let message) = item else { return false }
                return message.messageID == messageID
            }) {
                next[index] = replacement
            } else {
                next.append(replacement)
            }

        case .toolCallUpsert(let toolCall):
            let replacement = ChatTranscriptItem.toolCall(toolCall)
            if let index = next.lastIndex(where: { item in
                guard case .toolCall(let current) = item else { return false }
                return current.toolCallID == toolCall.toolCallID
            }) {
                next[index] = replacement
            } else {
                next.append(replacement)
            }
        }

        return next
    }
}
