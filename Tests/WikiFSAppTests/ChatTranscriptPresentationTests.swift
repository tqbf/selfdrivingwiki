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
                ChatDisplayToolCall(
                    id: ToolCallID(rawValue: "tool-1"),
                    turnID: turnID,
                    toolName: "Read",
                    status: .running,
                    detail: "page.md",
                    output: nil,
                    permissionRequestID: nil,
                    updatedAt: .distantPast
                )
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
                ChatDisplayToolCall(
                    id: ToolCallID(rawValue: "tool-no-output"),
                    turnID: turnID,
                    toolName: "Bash",
                    status: .completed,
                    detail: nil,
                    output: nil,
                    permissionRequestID: nil,
                    updatedAt: .distantPast
                )
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
                ChatDisplayToolCall(
                    id: ToolCallID(rawValue: "tool-legacy"),
                    turnID: turnID,
                    toolName: "Bash",
                    status: .completed,
                    detail: output,
                    output: nil,
                    permissionRequestID: nil,
                    updatedAt: .distantPast
                )
            )

        let html = ChatWebView.Coordinator.chatDisplayRowHTML(legacyRow)

        #expect(html.contains("Completed — \(expectedSummary)"))
        #expect(!html.contains("Completed — ```"))
        #expect(!html.contains("Completed — ~~~"))
        #expect(html.contains("<pre class=\"chat-tool-detail\">\(expectedSummary)</pre>"))
        #expect(html.contains("<pre class=\"chat-tool-detail\">```") == false)
        #expect(html.contains("~~~</pre>") == false)
    }

    // MARK: - Tool activity groups (Summary mode)

    private func groupFixture(
        states: [ChatToolCallStatus],
        names: [String]? = nil,
        details: [String?]? = nil
    ) -> ChatToolCallGroupRow {
        let callNames = names ?? states.map { _ in "Bash" }
        let callDetails = details ?? states.map { _ in String?(nil) }
        let calls = zip(zip(callNames, callDetails), states).enumerated().map { index, pair in
            ChatDisplayToolCall(
                id: ToolCallID(rawValue: "tg\(index)"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                toolName: pair.0.0,
                status: pair.1,
                detail: pair.0.1,
                output: nil,
                permissionRequestID: nil,
                updatedAt: .distantPast
            )
        }
        return ChatToolCallGroupRow(
            id: ChatToolCallGroupID(hostedBy: calls[0]),
            turnID: ChatTurnID(rawValue: "turn-1"),
            calls: calls,
            state: .aggregating(calls),
            summary: .summarizing(calls)
        )
    }

    @Test func toolGroupHasAccessibleStateAndSemanticMarkup() {
        let group = groupFixture(states: [.completed, .failed, .running])
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(.toolCallGroup(group))

        // Stable host identity via the root row protocol; children use the
        // separate source-identity attribute and never the root one.
        #expect(html.contains("<details"))
        #expect(html.contains("data-row-id=\"toolgroup-tg0\""))
        #expect(html.contains("data-tool-call-id=\"tg1\""))
        #expect(html.contains("data-tool-call-id=\"tg2\""))
        #expect(html.contains("data-row-id=\"tool-tg") == false)

        // Deterministic category phrase and state, with a text+symbol cue.
        #expect(html.contains("Tool activity"))
        #expect(html.contains("3 commands — Running, 1 failed"))
        #expect(html.contains("◌"))
        #expect(html.contains("⚠"))

        // Accessibility label carries total and failure counts plus state.
        #expect(html.contains("Tool activity, 3 tool calls, Running, 1 failed"))

        // Expanded body renders every child with name, status, detail, and
        // output formatting, inside the bounded scrolling detail area.
        #expect(html.contains("chat-tool-group-detail"))
        #expect(html.contains("chat-tool-child"))
        #expect(html.contains("Show tool details for Bash"))
        #expect(group.summary.totalCount == 3)
    }

    @Test func toolGroupStylesSupportBothAppearancesAndReducedMotion() {
        let shell = ChatWebView.Coordinator.shellHTML

        // Light-mode semantic variables (the variables tool-group styles use).
        #expect(shell.contains("--text: #1c1c1e"))
        #expect(shell.contains("--code-bg:"))
        #expect(shell.contains("--border:"))
        // Dark-mode override of the same variables.
        #expect(shell.contains("prefers-color-scheme: dark"))
        #expect(shell.contains("--text: #e6e6e6"))
        // Tool-group rules consume the semantic variables (no hardcoded
        // appearance in the group block itself).
        #expect(shell.contains(".chat-tool-group {"))
        #expect(shell.contains(".chat-tool-group-detail {"))
        #expect(shell.contains("max-height: 400px"))
        #expect(shell.contains("overflow-y: auto"))
        // Reduced-motion behavior is preserved globally.
        #expect(shell.contains("prefers-reduced-motion: reduce"))
    }

    @Test func interimAssistantRowsRenderAsOneLineDisclosures() {
        let interim = ChatDisplayRow.assistantInterim(
            id: ChatMessageID(rawValue: "a-interim"),
            turnID: turnID,
            text: "Checking the tide tables now",
            createdAt: .distantPast,
            contentState: .final
        )
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(interim)

        #expect(html.contains("<details"))
        #expect(html.contains("chat-interim"))
        #expect(html.contains("aria-label=\"Interim note, completed\""))
        #expect(html.contains("aria-label=\"Show interim note, completed\""))
        #expect(html.contains("data-row-id=\"message-a-interim\""))
        #expect(html.contains("data-focus-key=\"disclosure\""))
        #expect(html.contains("Note"))
        #expect(html.contains("Checking the tide tables now"))
    }

    @Test func toolGroupRendersFoldedReasoningInsideItsBody() {
        var group = groupFixture(states: [.completed, .completed])
        group.reasoning = [
            ChatDisplayReasoningEntry(
                id: ChatMessageID(rawValue: "r-1"),
                text: "Scanning the index first",
                contentState: .final
            ),
        ]
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(.toolCallGroup(group))

        // The folded reasoning lives in the expanded body under its own
        // source identity, and it never changes the summary phrase.
        #expect(html.contains("chat-tool-group-reasoning"))
        #expect(html.contains("data-reasoning-id=\"r-1\""))
        #expect(html.contains("Scanning the index first"))
        #expect(html.contains("2 commands"))
        #expect(html.contains("data-row-id=\"message-r-1\"") == false)
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

    @Test func fencedCodeStaysEscapedAndUnhighlightedInChat() {
        let source = "let value = \"<script>inert</script>\""
        let html = ChatWebView.Coordinator.renderedMarkdown("```swift\n\(source)\n```")

        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("sdw-code-") == false)
        #expect(html.contains("<script>inert</script>") == false)
        #expect(html.contains("&lt;script&gt;inert&lt;/script&gt;"))
    }

    @Test func incompleteToolFenceRemainsVisibleAsRawOutput() {
        let row = ChatDisplayRow.toolCall(
                ChatDisplayToolCall(
                    id: ToolCallID(rawValue: "tool-incomplete-fence"),
                    turnID: turnID,
                    toolName: "Bash",
                    status: .completed,
                    detail: nil,
                    output: "```console\nfile changed",
                    permissionRequestID: nil,
                    updatedAt: .distantPast
                )
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
        #expect(shell.contains(".chat-row.row-thinking {\n    display: block"))
        #expect(shell.contains(".chat-tool > summary {\n    display: grid"))
    }
}
#endif
