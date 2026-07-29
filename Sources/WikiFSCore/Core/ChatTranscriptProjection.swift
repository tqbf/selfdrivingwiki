import Foundation
import WikiFSTypes

/// Current-renderer compatibility projection for Phase 2 typed transcript rows.
/// This keeps the durable vocabulary (`ChatTranscriptItem`) separate from the
/// existing `AgentEvent` renderer contract while later phases migrate the live
/// path.
public enum ChatTranscriptProjection {
    public static func project(_ item: ChatTranscriptItem) -> AgentEvent {
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
                return .toolResult(isError: false, summary: toolCall.detail ?? toolCall.toolName)
            case .failed, .cancelled:
                return .toolResult(isError: true, summary: toolCall.detail ?? toolCall.toolName)
            }
        case .systemNotice(let notice):
            return .assistantText("\(notice.title)\n\n\(notice.message)")
        case .turnFailure(let failure):
            return .turnFailed(reason: .agentError(failure.message))
        }
    }
}
