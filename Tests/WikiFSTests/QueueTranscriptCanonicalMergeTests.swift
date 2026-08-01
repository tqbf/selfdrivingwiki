import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSCore

struct QueueTranscriptCanonicalMergeTests {
    @Test func persistedOrderIsStable() {
        let first = message(id: "first", text: "persisted first")
        let second = message(id: "second", text: "persisted second")

        #expect(QueueTranscriptCanonicalMerge.merging(persisted: [first, second], live: []) == [first, second])
    }

    @Test func liveItemReplacesMatchingTaggedIdentity() {
        let persisted = message(id: "same", text: "persisted")
        let replacement = message(id: "same", text: "live")

        #expect(QueueTranscriptCanonicalMerge.merging(persisted: [persisted], live: [replacement]) == [replacement])
    }

    @Test func sameRawIDInDifferentKindsDoesNotCollide() {
        let rawID = "shared-provider-id"
        let persistedMessage = message(id: rawID, text: "message")
        let liveTool = tool(id: rawID, detail: "live tool")

        #expect(QueueTranscriptCanonicalMerge.merging(persisted: [persistedMessage], live: [liveTool]) == [persistedMessage, liveTool])
    }

    @Test func newLiveIdentityAppendsInLiveOrder() {
        let persisted = message(id: "persisted", text: "persisted")
        let firstLive = message(id: "live-1", text: "first live")
        let secondLive = message(id: "live-2", text: "second live")

        #expect(QueueTranscriptCanonicalMerge.merging(
            persisted: [persisted],
            live: [firstLive, secondLive]
        ) == [persisted, firstLive, secondLive])
    }

    private func message(id: String, text: String) -> ChatTranscriptItem {
        .message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: id),
            turnID: ChatTurnID(rawValue: "queue-turn"),
            role: .assistant,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    private func tool(id: String, detail: String) -> ChatTranscriptItem {
        .toolCall(ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: id),
            turnID: ChatTurnID(rawValue: "queue-turn"),
            toolName: "Bash",
            status: .running,
            detail: detail,
            permissionRequestID: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }
}
