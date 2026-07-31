// pattern: Functional Core

import Foundation
import WikiFSTypes

/// Core-only persistence compatibility adapter for typed transcript rows.
///
/// `GRDBWikiStore` uses this adapter only while it maintains the legacy
/// `projected_event_json` and `projected_text` columns. The app transcript
/// renderer must use `ChatDisplayRow` directly. Keep this adapter until a
/// separately versioned persistence contract replaces those columns.
enum LegacyChatTranscriptPersistenceProjection {
    static func project(_ item: ChatTranscriptItem) -> AgentEvent {
        switch item {
        case .message(let message):
            switch message.role {
            case .user:
                return .userText(message.text)
            case .assistant:
                return .assistantText(message.text)
            case .reasoning:
                return .thinking(message.text)
            }
        case .toolCall(let toolCall):
            switch toolCall.status {
            case .pending, .running:
                return .toolUse(
                    name: toolCall.toolName,
                    inputSummary: toolCall.detail ?? ""
                )
            case .completed:
                return .toolResult(isError: false, summary: toolCall.output ?? toolCall.detail ?? toolCall.toolName)
            case .failed, .cancelled:
                return .toolResult(isError: true, summary: toolCall.output ?? toolCall.detail ?? toolCall.toolName)
            }
        case .systemNotice(let notice):
            return .assistantText("\(notice.title)\n\n\(notice.message)")
        case .turnFailure(let failure):
            return .turnFailed(reason: .agentError(failure.message))
        }
    }
}
