#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

struct ChatTranscriptReducerTests {
    @Test func assistantDeltasCoalesceByMessageIdentity() {
        let deltas: [ChatTranscriptDelta] = [
            .messageDelta(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                delta: "Hello",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            .messageDelta(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                delta: " world",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]

        let reduced = ChatTranscriptReducer.reducing(items: [], with: deltas)
        guard let first = reduced.first else {
            Issue.record("expected message item")
            return
        }
        guard case .message(let item) = first else {
            Issue.record("expected message item")
            return
        }
        #expect(item.text == "Hello world")
    }

    @Test func fullReplacementDoesNotDuplicateStreamingMessage() {
        let initial = ChatTranscriptReducer.reducing(items: [], with: [
            .messageDelta(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                delta: "Hel",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ])

        let reduced = ChatTranscriptReducer.reducing(items: initial, with: [
            .messageReplacement(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant,
                text: "Hello",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ])

        #expect(reduced.count == 1)
        guard case .message(let item) = reduced[0] else {
            Issue.record("expected message item")
            return
        }
        #expect(item.text == "Hello")
    }

    @Test func toolCallStatusUpsertKeepsStableRowIdentity() {
        let pending = ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: "tool-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Edit file",
            status: .pending,
            detail: nil,
            permissionRequestID: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let running = ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: "tool-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Edit file",
            status: .running,
            detail: "README.md",
            permissionRequestID: nil,
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let first = ChatTranscriptReducer.reducing(items: [], with: [.toolCallUpsert(pending)])
        let second = ChatTranscriptReducer.reducing(items: first, with: [.toolCallUpsert(running)])

        #expect(second.count == 1)
        guard case .toolCall(let item) = second[0] else {
            Issue.record("expected tool call item")
            return
        }
        #expect(item.status == .running)
        #expect(item.detail == "README.md")
    }
}
#endif
