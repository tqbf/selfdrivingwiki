#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
import WikiFSTypes
@testable import WikiFS

struct ChatDisplayProjectionTests {
    @Test func preservesDurableRowIdentityAndGlobalOrder() {
        let rows = [
            userMessage(id: "message-1", turn: "turn-1", text: "Question"),
            toolCall(id: "tool-1", turn: "turn-1"),
            assistantMessage(id: "message-2", turn: "turn-1", text: "Answer"),
            notice(id: "notice-1", turn: nil),
            userMessage(id: "message-3", turn: "turn-2", text: "Next question"),
        ]

        let result = ChatDisplayProjection.project(items: rows, activeContentBlock: nil)

        #expect(result.transcript.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "message-1")),
            .toolCall(ToolCallID(rawValue: "tool-1")),
            .message(ChatMessageID(rawValue: "message-2")),
            .notice(ChatTranscriptNoticeID(rawValue: "notice-1")),
            .message(ChatMessageID(rawValue: "message-3")),
        ])
        #expect(result.anomalies.isEmpty)
    }

    @Test func preservesNoticesOutsideTurnsAsDeterministicUnattributedSections() throws {
        let before = notice(id: "notice-before", turn: nil)
        let between = notice(id: "notice-between", turn: nil)
        let result = ChatDisplayProjection.project(items: [
            before,
            userMessage(id: "message-1", turn: "turn-1", text: "Question"),
            between,
            userMessage(id: "message-2", turn: "turn-2", text: "Next question"),
        ], activeContentBlock: nil)

        let first = try #require(result.transcript.sections.first)
        let middle = try #require(result.transcript.sections.dropFirst(2).first)
        #expect(first.id == .unattributed(rows: [.notice(ChatTranscriptNoticeID(rawValue: "notice-before"))]))
        #expect(middle.id == .unattributed(rows: [.notice(ChatTranscriptNoticeID(rawValue: "notice-between"))]))
    }

    @Test func pagedTurnWithoutPromptKeepsItsRows() throws {
        let result = ChatDisplayProjection.project(items: [
            assistantMessage(id: "message-1", turn: "turn-1", text: "Earlier page answer"),
        ], activeContentBlock: nil)

        let section = try #require(result.transcript.sections.first)
        guard case .turn(let turn) = section else {
            Issue.record("Expected a turn section.")
            return
        }
        #expect(turn.prompt == nil)
        #expect(turn.rows.map(\.id) == [.message(ChatMessageID(rawValue: "message-1"))])
    }

    @Test func noncontiguousTurnStartsAnotherSectionAndReportsTypedAnomaly() {
        let result = ChatDisplayProjection.project(items: [
            userMessage(id: "message-1", turn: "turn-1", text: "Question"),
            userMessage(id: "message-2", turn: "turn-2", text: "Other question"),
            assistantMessage(id: "message-3", turn: "turn-1", text: "Late answer"),
        ], activeContentBlock: nil)

        #expect(result.transcript.sections.count == 3)
        #expect(result.anomalies.contains(.noncontiguousTurn(turnID: ChatTurnID(rawValue: "turn-1"))))
    }

    @Test func noticeSeparatedRowsOfTheSameTurnDoNotReportANoncontiguousTurn() {
        let result = ChatDisplayProjection.project(items: [
            userMessage(id: "message-1", turn: "turn-1", text: "Question"),
            notice(id: "notice-1", turn: nil),
            assistantMessage(id: "message-2", turn: "turn-1", text: "Answer"),
        ], activeContentBlock: nil)

        #expect(result.transcript.sections.count == 3)
        #expect(result.anomalies.contains(.noncontiguousTurn(turnID: ChatTurnID(rawValue: "turn-1"))) == false)
    }

    @Test func onlyValidatedAssistantOrReasoningActiveRowsStream() {
        let streamingAssistant = assistantMessage(id: "message-1", turn: "turn-1", text: "Partial")
        let validBlock = ChatDisplayActiveContentBlock(
            validating: .init(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant
            ),
            among: [streamingAssistant]
        )
        let orphanedBlock = ChatDisplayActiveContentBlock(
            validating: .init(
                messageID: ChatMessageID(rawValue: "missing"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .assistant
            ),
            among: [streamingAssistant]
        )
        let malformedBlock = ChatDisplayActiveContentBlock(
            validating: .init(
                messageID: ChatMessageID(rawValue: "message-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: .user
            ),
            among: [streamingAssistant]
        )

        let streaming = ChatDisplayProjection.project(items: [streamingAssistant], activeContentBlock: validBlock)
        let final = ChatDisplayProjection.project(items: [streamingAssistant], activeContentBlock: orphanedBlock)

        #expect(streaming.transcript.rows.first?.contentState == .streaming)
        #expect(final.transcript.rows.first?.contentState == .final)
        #expect(orphanedBlock == nil)
        #expect(malformedBlock == nil)
    }

    @Test func duplicateInputIdentityIsRetainedAndReported() {
        let duplicate = notice(id: "notice-1", turn: nil)
        let result = ChatDisplayProjection.project(items: [duplicate, duplicate], activeContentBlock: nil)

        #expect(result.transcript.rows.map(\.id) == [
            .notice(ChatTranscriptNoticeID(rawValue: "notice-1")),
            .notice(ChatTranscriptNoticeID(rawValue: "notice-1")),
        ])
        #expect(result.anomalies.contains(.duplicateInputRowID(.notice(ChatTranscriptNoticeID(rawValue: "notice-1")))))
    }

    @Test func permissionResolutionIntentUsesNamespacedOptionID() {
        let optionID = PermissionOptionID(rawValue: "allow-once")
        let intent = ChatPermissionResolutionIntent.approve(optionID: optionID)

        #expect(intent.optionID == optionID)
        #expect(intent.isApproval)
    }

    @Test func failuresRetainTheirTypedCategoryAndOutlineUsesDurableTarget() throws {
        let turnID = ChatTurnID(rawValue: "turn-1")
        let result = ChatDisplayProjection.project(items: [
            userMessage(id: "message-1", turn: turnID.rawValue, text: "Question"),
            assistantMessage(id: "message-2", turn: turnID.rawValue, text: "Answer"),
            .turnFailure(.init(
                failureID: ChatTranscriptFailureID(rawValue: "failure-1"),
                turnID: turnID,
                category: .transportError,
                message: "Connection lost",
                createdAt: .distantPast
            )),
        ], activeContentBlock: nil)

        let failure = try #require(result.transcript.rows.last)
        guard case .failure(_, _, let category, _, _) = failure else {
            Issue.record("Expected a failure row.")
            return
        }
        let outline = ChatDetailPresentation.buildOutlineEntries(displayTranscript: result.transcript)
        #expect(category == .transportError)
        #expect(outline.first?.id == .turn(
            turnID: turnID,
            promptRowID: .message(ChatMessageID(rawValue: "message-1"))
        ))
    }

    private func userMessage(id: String, turn: String, text: String) -> ChatTranscriptItem {
        .message(.init(
            messageID: ChatMessageID(rawValue: id),
            turnID: ChatTurnID(rawValue: turn),
            role: .user,
            text: text,
            createdAt: .distantPast
        ))
    }

    private func assistantMessage(id: String, turn: String, text: String) -> ChatTranscriptItem {
        .message(.init(
            messageID: ChatMessageID(rawValue: id),
            turnID: ChatTurnID(rawValue: turn),
            role: .assistant,
            text: text,
            createdAt: .distantPast
        ))
    }

    private func toolCall(id: String, turn: String) -> ChatTranscriptItem {
        .toolCall(.init(
            toolCallID: ToolCallID(rawValue: id),
            turnID: ChatTurnID(rawValue: turn),
            toolName: "read",
            status: .completed,
            detail: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        ))
    }

    private func notice(id: String, turn: String?) -> ChatTranscriptItem {
        .systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: id),
            turnID: turn.map(ChatTurnID.init(rawValue:)),
            kind: .session,
            title: "Notice",
            message: "Message",
            createdAt: .distantPast
        ))
    }
}

@MainActor
struct ChatTranscriptRenderingInputTests {
    @Test func toolCallKeepsItsTypedIdentityAtTheRendererBoundary() {
        let input = renderingInput(for: .toolCall(.init(
            toolCallID: ToolCallID(rawValue: "tool-read"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Read",
            status: .failed,
            detail: "permission denied",
            permissionRequestID: nil,
            updatedAt: .distantPast
        )))

        #expect(input.rows.map(\.id) == [.toolCall(ToolCallID(rawValue: "tool-read"))])
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(input.rows[0])
        #expect(html.isEmpty == false)
        #expect(html.contains("data-row-id=\"tool-tool-read\""))
        #expect(html.contains("role=\"group\""))
        #expect(html.contains("is-error"))
        #expect(html.contains("permission denied"))
    }

    @Test func completedToolCallRemainsVisibleBetweenAssistantBlocks() {
        let input = renderingInput(for: .toolCall(.init(
            toolCallID: ToolCallID(rawValue: "tool-write"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Write",
            status: .completed,
            detail: "updated page.md",
            permissionRequestID: nil,
            updatedAt: .distantPast
        )))

        #expect(input.visibleRows(hidingToolCalls: false).map(\.id) == [
            .toolCall(ToolCallID(rawValue: "tool-write"))
        ])
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(input.rows[0])
        #expect(html.contains("Completed"))
        #expect(html.contains("updated page.md"))
    }

    @Test func hideToolCallsFiltersRowsWithoutChangingOtherIdentity() {
        let input = renderingInput(for: .toolCall(.init(
            toolCallID: ToolCallID(rawValue: "tool-cancelled"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Write",
            status: .cancelled,
            detail: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        )))

        #expect(input.visibleRows(hidingToolCalls: true).isEmpty)
        #expect(input.rows.map(\.id) == [.toolCall(ToolCallID(rawValue: "tool-cancelled"))])
    }

    @Test func noticeRemainsDistinctFromAssistantContentAtTheRendererBoundary() {
        let input = renderingInput(for: .systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "notice-1"),
            turnID: nil,
            kind: .session,
            title: "Context updated",
            message: "The agent resumed the session.",
            createdAt: .distantPast
        )))

        #expect(input.rows.map(\.id) == [.notice(ChatTranscriptNoticeID(rawValue: "notice-1"))])
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(input.rows[0])
        #expect(html.isEmpty == false)
        #expect(html.contains("role=\"status\""))
        #expect(html.contains("Context updated"))
        #expect(html.contains("The agent resumed the session."))
    }

    private func renderingInput(for item: ChatTranscriptItem) -> ChatTranscriptRenderingInput {
        ChatTranscriptRenderingInput(
            transcript: ChatDisplayProjection.project(items: [item], activeContentBlock: nil).transcript
        )
    }

    private func toolCall(status: ChatToolCallStatus) -> ChatTranscriptItem {
        .toolCall(.init(
            toolCallID: ToolCallID(rawValue: "tool-edit"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            toolName: "Edit",
            status: status,
            detail: "page.md",
            permissionRequestID: nil,
            updatedAt: .distantPast
        ))
    }
}
#endif
