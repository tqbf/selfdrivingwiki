#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
import WikiFSTypes
@testable import WikiFS

/// The typed display projection replaces the launcher-event selector.
struct ChatDisplayMessagesTests {
    @Test func typedRowsDoNotDropToolCalls() {
        let item = ChatTranscriptItem.toolCall(.init(
            toolCallID: ToolCallID(rawValue: "tool"),
            turnID: ChatTurnID(rawValue: "turn"),
            toolName: "Read",
            status: .completed,
            detail: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        ))
        let result = ChatDisplayProjection.project(items: [item], activeContentBlock: nil)
        #expect(result.transcript.rows.map(\.id) == [.toolCall(ToolCallID(rawValue: "tool"))])
    }
}
#endif
