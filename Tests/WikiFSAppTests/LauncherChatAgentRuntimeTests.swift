#if os(macOS)
import ACPModel
import Foundation
import Testing
@testable import WikiFS
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

    @Test(arguments: [
        ("```console\n<command-output>\n```", "```console\n&lt;command-output&gt;\n```"),
        ("```json\n{\"ok\": true}\n```", "```json\n{\"ok\": true}\n```"),
        ("build completed", "build completed"),
    ])
    @MainActor
    func acpToolOutputKeepsTheDescriptorAndRendersRawOutputSafely(
        _ output: String,
        escapedOutput: String
    ) {
        let command = "wikictl page add --title Fence"
        let translator = ACPEventTranslator()
        let events = translator.translate(.toolCall(ToolCallUpdate(
            toolCallId: "tool-fence",
            status: .pending,
            kind: .execute,
            rawInput: AnyCodable(["command": command])
        ))) + translator.translate(.toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: "tool-fence",
            status: .completed,
            content: [.content(.text(TextContent(text: output)))]
        )))

        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: events,
            turnID: ChatTurnID(rawValue: "turn-fence")
        )
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)
        let toolCall = items.compactMap { item -> ChatTranscriptToolCallItem? in
            guard case .toolCall(let toolCall) = item else { return nil }
            return toolCall
        }.last

        guard let toolCall else {
            Issue.record("expected an ACP tool-call transcript row")
            return
        }
        #expect(toolCall.status == .completed)
        #expect(toolCall.detail == command)
        #expect(toolCall.output == output)

        let row = ChatDisplayProjection.project(items: items, activeContentBlock: nil).transcript.rows.last
        guard let row else {
            Issue.record("expected a display row")
            return
        }
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(row)
        #expect(html.contains("Completed — \(command)"))
        #expect(!html.contains("Completed — ```"))
        #expect(html.contains("<pre class=\"chat-tool-detail\">\(escapedOutput)</pre>"))
        #expect(!html.contains("<command-output>"))
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
        #expect(messages[0].messageID == ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-0"))
        #expect(messages[0].role == .assistant)
        #expect(messages[0].text == "Hello world")
        #expect(messages[1].messageID == ChatMessageID(rawValue: "reasoning-\(turnID.rawValue)-block-1"))
        #expect(messages[1].role == .reasoning)
        #expect(messages[1].text == "Need context")
    }

    @Test func assistantToolAssistantProducesDistinctMessageBlocks() {
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantTextDelta("I will inspect the page."),
                .toolUse(name: "Read", inputSummary: "README.md"),
                .toolResult(isError: false, summary: "read complete"),
                .assistantTextDelta("The page is ready."),
            ],
            turnID: ChatTurnID(rawValue: "turn-block-boundary")
        )

        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.count == 2)
        #expect(messages.map(\.role) == [.assistant, .assistant])
        #expect(messages[0].messageID != messages[1].messageID)
        #expect(messages.map(\.text) == ["I will inspect the page.", "The page is ready."])
    }

    @Test func reasoningAssistantReasoningProducesThreeOrderedContentBlocks() {
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .thinkingDelta("Need context."),
                .assistantTextDelta("Here is the answer."),
                .thinkingDelta("Check the cited source."),
            ],
            turnID: ChatTurnID(rawValue: "turn-role-boundary")
        )

        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.map(\.role) == [.reasoning, .assistant, .reasoning])
        #expect(Set(messages.map(\.messageID)).count == 3)
        #expect(messages.map(\.text) == ["Need context.", "Here is the answer.", "Check the cited source."])
    }

    @Test func deltaAfterFinalReplacementStartsANewContentBlock() {
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantTextDelta("Partial"),
                .assistantText("Complete first block."),
                .assistantTextDelta("Second block."),
            ],
            turnID: ChatTurnID(rawValue: "turn-finalized-block")
        )

        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.map(\.text) == ["Complete first block.", "Second block."])
        #expect(messages[0].messageID != messages[1].messageID)
    }

    @Test func terminalProviderAssistantBlocksInOneTurnReceiveDistinctMessageIDs() {
        let turnID = ChatTurnID(rawValue: "turn-terminal-provider-blocks")
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantText("First provider block."),
                .assistantText("Second provider block."),
            ],
            turnID: turnID
        )

        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.map(\.messageID) == [
            ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-0"),
            ChatMessageID(rawValue: "assistant-\(turnID.rawValue)-block-1"),
        ])
        #expect(messages.map(\.text) == ["First provider block.", "Second provider block."])
    }

    @Test func duplicateTerminalEventsDoNotReopenAFinalizedContentBlock() {
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantTextDelta("Partial"),
                .assistantText("Final block."),
                .messageStop,
                .messageStop,
            ],
            turnID: ChatTurnID(rawValue: "turn-duplicate-terminal")
        )

        let messages = ChatTranscriptReducer.reducing(items: [], with: deltas).compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }

        #expect(messages.count == 1)
        #expect(messages.first?.text == "Final block.")
        #expect(messages.first?.messageID == ChatMessageID(rawValue: "assistant-turn-duplicate-terminal-block-0"))
    }
}
#endif
