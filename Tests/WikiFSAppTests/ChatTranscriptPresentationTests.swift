#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSTypes

@MainActor
struct ChatTranscriptPresentationTests {
    private let turnID = ChatTurnID(rawValue: "turn-1")

    @Test func typedRowsExposeStableSemanticMarkupAndAccessibleCopy() {
        let assistant = ChatDisplayRow.assistantMessage(
            id: ChatMessageID(rawValue: "assistant-1"),
            turnID: turnID,
            text: "Answer",
            createdAt: .distantPast,
            contentState: .streaming
        )

        let html = ChatWebView.Coordinator.chatDisplayRowHTML(assistant)

        #expect(html.contains("data-row-id=\"message-assistant-1\""))
        #expect(html.contains("role=\"article\""))
        #expect(html.contains("aria-busy=\"true\""))
        #expect(html.contains("aria-label=\"Copy assistant response\""))
        #expect(html.contains("◌ Streaming"))
    }

    @Test func reasoningAndToolRowsGiveTextualStateCues() {
        let reasoning = ChatDisplayRow.reasoning(
            id: ChatMessageID(rawValue: "reasoning-1"),
            turnID: turnID,
            text: "Checking the available context",
            createdAt: .distantPast,
            contentState: .final
        )
        let tool = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-1"),
            turnID: turnID,
            toolName: "Read",
            status: .running,
            detail: "page.md",
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )

        let reasoningHTML = ChatWebView.Coordinator.chatDisplayRowHTML(reasoning)
        let toolHTML = ChatWebView.Coordinator.chatDisplayRowHTML(tool)

        #expect(reasoningHTML.contains("<details"))
        #expect(reasoningHTML.contains("aria-label=\"Show reasoning, completed\""))
        #expect(toolHTML.contains("data-row-id=\"tool-tool-1\""))
        #expect(toolHTML.contains("Tool Read, Running"))
        #expect(toolHTML.contains("◌"))
    }

    @Test func completedToolWithoutOutputShowsNoSyntheticResultText() {
        let tool = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-no-output"),
            turnID: turnID,
            toolName: "Bash",
            status: .completed,
            detail: nil,
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )

        let html = ChatWebView.Coordinator.chatDisplayRowHTML(tool)

        #expect(html.contains("Tool Bash, Completed"))
        #expect(!html.contains("(ok)"))
        #expect(!html.contains("(error)"))
        #expect(!html.contains("chat-tool-detail"))
    }

    @Test(arguments: [
        ("```console\nfile changed\n```", "file changed"),
        ("```json\n{\"ok\":true}\n```", "{\"ok\":true}"),
        ("~~~text\nplain output\n~~~", "plain output"),
    ])
    func legacyToolOutputNeverUsesAMarkdownFenceAsItsCollapsedDescriptor(
        _ output: String,
        expectedSummary: String
    ) {
        let legacyRow = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-legacy"),
            turnID: turnID,
            toolName: "Bash",
            status: .completed,
            detail: output,
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )

        let html = ChatWebView.Coordinator.chatDisplayRowHTML(legacyRow)

        #expect(html.contains("Completed — \(expectedSummary)"))
        #expect(!html.contains("Completed — ```"))
        #expect(!html.contains("Completed — ~~~"))
        #expect(html.contains("<pre class=\"chat-tool-detail\">\(expectedSummary)</pre>"))
        #expect(html.contains("<pre class=\"chat-tool-detail\">```") == false)
        #expect(html.contains("~~~</pre>") == false)
    }

    @Test func insightCalloutMarkersRenderAsTextInsteadOfAnInlineCodeSpan() {
        let markdown = """
        `★ Insight ─────────────────────────────────────`
        The parser should render this as prose, not code.
        `─────────────────────────────────────────────────`
        """

        let html = ChatWebView.Coordinator.renderedMarkdown(markdown)

        #expect(html.contains("★ Insight ─────────────────────────────────────"))
        #expect(html.contains("<code>★ Insight") == false)
        #expect(html.contains("<code>─────────────────────────────────────────────────</code>") == false)
    }

    @Test func incompleteToolFenceRemainsVisibleAsRawOutput() {
        let row = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-incomplete-fence"),
            turnID: turnID,
            toolName: "Bash",
            status: .completed,
            detail: nil,
            output: "```console\nfile changed",
            permissionRequestID: nil,
            updatedAt: .distantPast
        )

        let html = ChatWebView.Coordinator.chatDisplayRowHTML(row)

        #expect(html.contains("<pre class=\"chat-tool-detail\">```console\nfile changed</pre>"))
    }

    @Test func noticesAndFailuresAreNotAssistantRows() {
        let notice = ChatDisplayRow.notice(
            id: ChatTranscriptNoticeID(rawValue: "notice-1"),
            turnID: nil,
            kind: .session,
            title: "Context updated",
            message: "The agent resumed.",
            createdAt: .distantPast
        )
        let failure = ChatDisplayRow.failure(
            id: ChatTranscriptFailureID(rawValue: "failure-1"),
            turnID: turnID,
            category: .runtimeError,
            message: "Provider stopped.",
            createdAt: .distantPast
        )

        let noticeHTML = ChatWebView.Coordinator.chatDisplayRowHTML(notice)
        let failureHTML = ChatWebView.Coordinator.chatDisplayRowHTML(failure)

        #expect(noticeHTML.contains("role=\"status\""))
        #expect(!noticeHTML.contains("chat-assistant"))
        #expect(failureHTML.contains("role=\"alert\""))
        #expect(failureHTML.contains("⚠︎"))
    }

    @Test func followStateOnlyFollowsNearTheBottom() {
        let away = ChatTranscriptFollowState.reducing(
            .following,
            event: .viewportChanged(distanceFromBottom: ChatTranscriptFollowMetrics.nearBottomDistance + 1)
        )
        let near = ChatTranscriptFollowState.reducing(
            away,
            event: .viewportChanged(distanceFromBottom: ChatTranscriptFollowMetrics.nearBottomDistance)
        )

        #expect(!away.followsStreamingContent)
        #expect(near.followsStreamingContent)
        #expect(ChatTranscriptFollowState.reducing(away, event: .transcriptReset) == .following)
    }

    @Test func stylesheetPreservesAppearanceMotionAndFocusedRowInteraction() {
        let shell = ChatWebView.Coordinator.shellHTML

        #expect(shell.contains("prefers-color-scheme: dark"))
        #expect(shell.contains("prefers-reduced-motion: reduce"))
        #expect(shell.contains("data-focus-key"))
        #expect(shell.contains("selectionOffsets"))
        #expect(shell.contains("isNearBottom"))
        #expect(shell.contains(".chat-tool {\n    display: block"))
        #expect(shell.contains(".chat-tool > summary {\n    display: flex"))
    }
}
#endif
