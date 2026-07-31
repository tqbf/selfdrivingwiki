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

    @Test func transcriptChangedCoalescesStreamingAssistantMessageAcrossSequences() {
        let base = ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            lifecycle: .ready,
            activeTurn: ChatTurnSnapshot(
                turnID: ChatTurnID(rawValue: "turn-1"),
                commandID: ChatCommandID(rawValue: "command-1"),
                visibleText: "Hello",
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1),
                state: .responding
            ),
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: .initial
        )

        let first = ChatSessionMachine.apply(
            ChatSessionUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: "generation-1"),
                sequence: ChatUpdateSequence(rawValue: 1),
                payload: .transcriptChanged([
                    .messageDelta(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        delta: "Hello",
                        createdAt: Date(timeIntervalSince1970: 2)
                    )
                ])
            ),
            to: base
        )

        guard case .applied(let afterFirst) = first else {
            Issue.record("first transcript delta should apply")
            return
        }

        let second = ChatSessionMachine.apply(
            ChatSessionUpdate(
                chatID: ChatID(rawValue: "chat-1"),
                generation: ChatSessionGenerationID(rawValue: "generation-1"),
                sequence: ChatUpdateSequence(rawValue: 2),
                payload: .transcriptChanged([
                    .messageDelta(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        delta: " world",
                        createdAt: Date(timeIntervalSince1970: 2)
                    )
                ])
            ),
            to: afterFirst
        )

        guard case .applied(let afterSecond) = second else {
            Issue.record("second transcript delta should apply")
            return
        }

        #expect(afterSecond.transientTranscriptOverlay.count == 1)
        guard case .message(let item) = afterSecond.transientTranscriptOverlay[0] else {
            Issue.record("expected a single coalesced message row")
            return
        }
        #expect(item.messageID == ChatMessageID(rawValue: "message-1"))
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

    @Test func rejectsReplacementThatReusesAMessageIDForAnotherTurn() {
        let original = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant,
            text: "Original",
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let reduction = ChatTranscriptReducer.reducingWithDiagnostics(
            items: [original],
            with: [
                .messageReplacement(
                    messageID: ChatMessageID(rawValue: "message-1"),
                    turnID: ChatTurnID(rawValue: "turn-2"),
                    role: .assistant,
                    text: "Incorrect replacement",
                    createdAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(reduction.items == [original])
        #expect(reduction.anomalies == [
            .messageIdentityMismatch(
                messageID: ChatMessageID(rawValue: "message-1"),
                existingTurnID: ChatTurnID(rawValue: "turn-1"),
                receivedTurnID: ChatTurnID(rawValue: "turn-2"),
                existingRole: .assistant,
                receivedRole: .assistant
            )
        ])
    }

    @Test func rejectsDeltaThatReusesAMessageIDForAnotherTurn() {
        let original = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant,
            text: "Original",
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let reduction = ChatTranscriptReducer.reducingWithDiagnostics(
            items: [original],
            with: [
                .messageDelta(
                    messageID: ChatMessageID(rawValue: "message-1"),
                    turnID: ChatTurnID(rawValue: "turn-2"),
                    role: .assistant,
                    delta: "Incorrect delta",
                    createdAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(reduction.items == [original])
        #expect(reduction.anomalies == [
            .messageIdentityMismatch(
                messageID: ChatMessageID(rawValue: "message-1"),
                existingTurnID: ChatTurnID(rawValue: "turn-1"),
                receivedTurnID: ChatTurnID(rawValue: "turn-2"),
                existingRole: .assistant,
                receivedRole: .assistant
            )
        ])
    }

    @Test func rejectsDeltaThatReusesAMessageIDForAnotherRole() {
        let original = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant,
            text: "Original",
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let reduction = ChatTranscriptReducer.reducingWithDiagnostics(
            items: [original],
            with: [
                .messageDelta(
                    messageID: ChatMessageID(rawValue: "message-1"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    role: .reasoning,
                    delta: "Incorrect delta",
                    createdAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(reduction.items == [original])
        #expect(reduction.anomalies == [
            .messageIdentityMismatch(
                messageID: ChatMessageID(rawValue: "message-1"),
                existingTurnID: ChatTurnID(rawValue: "turn-1"),
                receivedTurnID: ChatTurnID(rawValue: "turn-1"),
                existingRole: .assistant,
                receivedRole: .reasoning
            )
        ])
    }

    @Test func rejectsReplacementThatReusesAMessageIDForAnotherRole() {
        let original = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant,
            text: "Original",
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        let reduction = ChatTranscriptReducer.reducingWithDiagnostics(
            items: [original],
            with: [
                .messageReplacement(
                    messageID: ChatMessageID(rawValue: "message-1"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    role: .reasoning,
                    text: "Incorrect replacement",
                    createdAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )

        #expect(reduction.items == [original])
        #expect(reduction.anomalies == [
            .messageIdentityMismatch(
                messageID: ChatMessageID(rawValue: "message-1"),
                existingTurnID: ChatTurnID(rawValue: "turn-1"),
                receivedTurnID: ChatTurnID(rawValue: "turn-1"),
                existingRole: .assistant,
                receivedRole: .reasoning
            )
        ])
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
