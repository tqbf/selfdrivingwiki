// pattern: Functional Core

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
        reducingWithDiagnostics(items: items, with: deltas).items
    }

    public static func reducingWithDiagnostics(
        items: [ChatTranscriptItem],
        with deltas: [ChatTranscriptDelta]
    ) -> ChatTranscriptReduction {
        deltas.reduce(ChatTranscriptReduction(items: items)) { reduction, delta in
            apply(reduction, delta)
        }
    }

    public static func apply(
        _ items: [ChatTranscriptItem],
        _ delta: ChatTranscriptDelta
    ) -> [ChatTranscriptItem] {
        apply(ChatTranscriptReduction(items: items), delta).items
    }

    private static func apply(
        _ reduction: ChatTranscriptReduction,
        _ delta: ChatTranscriptDelta
    ) -> ChatTranscriptReduction {
        var next = reduction.items
        var anomalies = reduction.anomalies

        switch delta {
        case .append(let item):
            next.append(item)

        case .messageDelta(let messageID, let turnID, let role, let deltaText, let createdAt):
            if let index = next.lastIndex(where: { item in
                guard case .message(let message) = item else { return false }
                return message.messageID == messageID
            }), case .message(let existing) = next[index] {
                if existing.turnID == turnID, existing.role == role {
                    next[index] = .message(ChatTranscriptMessageItem(
                        messageID: existing.messageID,
                        turnID: existing.turnID,
                        role: existing.role,
                        text: existing.text + deltaText,
                        createdAt: existing.createdAt
                    ))
                } else {
                    anomalies.append(messageIdentityMismatch(
                        messageID: messageID,
                        existing: existing,
                        receivedTurnID: turnID,
                        receivedRole: role
                    ))
                }
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
            }), case .message(let existing) = next[index] {
                if existing.turnID == turnID, existing.role == role {
                    next[index] = replacement
                } else {
                    anomalies.append(messageIdentityMismatch(
                        messageID: messageID,
                        existing: existing,
                        receivedTurnID: turnID,
                        receivedRole: role
                    ))
                }
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

        return ChatTranscriptReduction(items: next, anomalies: anomalies)
    }

    private static func messageIdentityMismatch(
        messageID: ChatMessageID,
        existing: ChatTranscriptMessageItem,
        receivedTurnID: ChatTurnID,
        receivedRole: ChatTranscriptMessageRole
    ) -> ChatTranscriptReductionAnomaly {
        .messageIdentityMismatch(
            messageID: messageID,
            existingTurnID: existing.turnID,
            receivedTurnID: receivedTurnID,
            existingRole: existing.role,
            receivedRole: receivedRole
        )
    }
}

public struct ChatTranscriptReduction: Hashable, Sendable {
    public let items: [ChatTranscriptItem]
    public let anomalies: [ChatTranscriptReductionAnomaly]

    public init(
        items: [ChatTranscriptItem],
        anomalies: [ChatTranscriptReductionAnomaly] = []
    ) {
        self.items = items
        self.anomalies = anomalies
    }
}

public enum ChatTranscriptReductionAnomaly: Hashable, Sendable {
    case messageIdentityMismatch(
        messageID: ChatMessageID,
        existingTurnID: ChatTurnID,
        receivedTurnID: ChatTurnID,
        existingRole: ChatTranscriptMessageRole,
        receivedRole: ChatTranscriptMessageRole
    )
}
