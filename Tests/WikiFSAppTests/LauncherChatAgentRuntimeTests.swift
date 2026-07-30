#if os(macOS)
import ACPModel
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

struct LauncherChatAgentRuntimeTests {
    @Test func permissionTranslationPreservesToolCallIDAndTypedOptions() {
        let request = LauncherChatAgentRuntime.permissionRequest(
            from: PendingPermission(
                toolCallId: ToolCallID(rawValue: "tool-call-1"),
                title: "Edit file",
                toolName: "Edit",
                inputSummary: "/tmp/file.md",
                options: [
                    PermissionOption(kind: "allow_once", name: "Allow once", optionId: "allow-once"),
                    PermissionOption(kind: "reject_once", name: "Reject", optionId: "reject-once"),
                    PermissionOption(kind: "cancel", name: "Cancel", optionId: "cancel"),
                ]
            ),
            turnID: ChatTurnID(rawValue: "turn-1")
        )

        #expect(request.requestID == PermissionRequestID(rawValue: "permission-tool-call-1"))
        #expect(request.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(request.toolCallID == ToolCallID(rawValue: "tool-call-1"))
        #expect(request.options.map(\.id) == [
            PermissionOptionID(rawValue: "allow-once"),
            PermissionOptionID(rawValue: "reject-once"),
            PermissionOptionID(rawValue: "cancel"),
        ])
        #expect(request.options.map(\.behavior) == [.allow, .deny, .cancel])
        #expect(request.options.map(\.visualIntent) == [.accent, .destructive, .destructive])
        #expect(request.options.map(\.isDefault) == [true, false, false])
    }

    @Test func transcriptTranslationPreservesToolIdentityAcrossUseAndResult() {
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .toolUse(name: "Edit", inputSummary: "/tmp/file.md"),
                .toolResult(isError: false, summary: "updated file"),
            ],
            turnID: ChatTurnID(rawValue: "turn-2")
        )

        guard case .toolCallUpsert(let useItem) = deltas.first,
              case .toolCallUpsert(let resultItem) = deltas.last else {
            Issue.record("expected tool-call upserts for start and result")
            return
        }

        #expect(useItem.toolCallID == resultItem.toolCallID)
        #expect(useItem.toolName == resultItem.toolName)
        #expect(useItem.status == .running)
        #expect(resultItem.status == .completed)
    }

    @Test func transcriptTranslationCoalescesAssistantAndReasoningDeltasIntoStableMessageReplacements() {
        let turnID = ChatTurnID(rawValue: "turn-3")
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantTextDelta("Hello"),
                .assistantTextDelta(" world"),
                .assistantText("Hello world"),
                .thinkingDelta("Need"),
                .thinkingDelta(" context"),
                .thinking("Need context"),
            ],
            turnID: turnID
        )

        let reduced = ChatTranscriptReducer.reducing(items: [], with: deltas)
        let messages = reduced.compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.count == 2)
        #expect(messages[0].messageID == ChatMessageID(rawValue: "assistant-\(turnID.rawValue)"))
        #expect(messages[0].role == .assistant)
        #expect(messages[0].text == "Hello world")
        #expect(messages[1].messageID == ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)"))
        #expect(messages[1].role == .reasoning)
        #expect(messages[1].text == "Need context")
    }
}
#endif
