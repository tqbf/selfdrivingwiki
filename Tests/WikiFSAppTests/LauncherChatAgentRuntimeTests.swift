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

    @Test(arguments: [
        ("```console\n<command-output>\n```", "&lt;command-output&gt;"),
        ("```json\n{\"ok\": true}\n```", "{\"ok\": true}"),
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

        var transcriptTranslator = AgentEventTranscriptTranslator()
        let deltas = transcriptTranslator.translate(
            events,
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
        #expect(html.contains("Completed — ```") == false)
        #expect(html.contains("<pre class=\"chat-tool-detail\">\(escapedOutput)</pre>"))
        #expect(html.contains("<command-output>") == false)
    }

    @Test func launcherRuntimeUsesSharedTranslator() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/wikid/LauncherChatAgentRuntime.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("[ChatTurnID: AgentEventTranscriptTranslator]"))
        #expect(source.contains("translator.translate([event], turnID: turnID)"))
        #expect(source.contains("translator.activeContentBlock"))
        #expect(source.contains("TranscriptTranslationState") == false)
        #expect(source.contains("transcriptDeltasForTesting") == false)
    }
}
#endif
