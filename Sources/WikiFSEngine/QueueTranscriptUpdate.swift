// pattern: Functional Core

import Foundation
import WikiFSCore

/// One ordered, immutable typed transcript batch for a claimed queue attempt.
/// The batch number is monotonic within `attemptID` and is validated by every
/// consumer before it changes live presentation state.
public struct QueueTranscriptUpdate: Codable, Sendable, Hashable {
    public let attemptID: QueueAttemptID
    public let batchNumber: Int
    public let changedItems: [ChatTranscriptItem]

    public init(
        attemptID: QueueAttemptID,
        batchNumber: Int,
        changedItems: [ChatTranscriptItem]
    ) {
        self.attemptID = attemptID
        self.batchNumber = batchNumber
        self.changedItems = changedItems
    }
}

/// Tagged identity used for transcript reduction and persisted/live merging.
/// Raw values are deliberately never compared across item kinds.
public enum QueueTranscriptItemIdentity: Hashable, Sendable {
    case message(ChatMessageID)
    case toolCall(ToolCallID)
    case systemNotice(ChatTranscriptNoticeID)
    case turnFailure(ChatTranscriptFailureID)

    public init(_ item: ChatTranscriptItem) {
        switch item {
        case .message(let message): self = .message(message.messageID)
        case .toolCall(let call): self = .toolCall(call.toolCallID)
        case .systemNotice(let notice): self = .systemNotice(notice.noticeID)
        case .turnFailure(let failure): self = .turnFailure(failure.failureID)
        }
    }
}

public enum QueueTranscriptCanonicalMerge {
    /// Stable persisted order, live replacement by tagged identity, then live
    /// additions in received order.
    public static func merging(
        persisted: [ChatTranscriptItem],
        live: [ChatTranscriptItem]
    ) -> [ChatTranscriptItem] {
        var merged = persisted
        for item in live {
            let identity = QueueTranscriptItemIdentity(item)
            if let index = merged.lastIndex(where: { QueueTranscriptItemIdentity($0) == identity }) {
                merged[index] = item
            } else {
                merged.append(item)
            }
        }
        return merged
    }
}
