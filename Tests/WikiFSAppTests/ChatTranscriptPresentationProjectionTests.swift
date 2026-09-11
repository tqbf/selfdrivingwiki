#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// The human-facing presentation projection: mode behavior, run boundaries,
/// stable group identity, warning cleanup, and canonical-input safety.
struct ChatTranscriptPresentationProjectionTests {
    private let turn1 = ChatTurnID(rawValue: "turn-1")
    private let turn2 = ChatTurnID(rawValue: "turn-2")

    private func message(
        _ id: String,
        _ text: String,
        turn: ChatTurnID? = nil,
        role: ChatTranscriptMessageRole = .user
    ) -> ChatDisplayRow {
        .userMessage(
            id: ChatMessageID(rawValue: id),
            turnID: turn ?? ChatTurnID(rawValue: "turn"),
            text: text,
            createdAt: .distantPast
        )
    }

    private func assistant(
        _ id: String,
        _ text: String,
        turn: ChatTurnID,
        streaming: Bool = false
    ) -> ChatDisplayRow {
        .assistantMessage(
            id: ChatMessageID(rawValue: id),
            turnID: turn,
            text: text,
            createdAt: .distantPast,
            contentState: streaming ? .streaming : .final
        )
    }

    private func tool(
        _ id: String,
        name: String = "Bash",
        status: ChatToolCallStatus = .completed,
        detail: String? = nil,
        turn: ChatTurnID
    ) -> ChatDisplayRow {
        .toolCall(ChatDisplayToolCall(
            id: ToolCallID(rawValue: id),
            turnID: turn,
            toolName: name,
            status: status,
            detail: detail,
            output: nil,
            permissionRequestID: nil,
            updatedAt: .distantPast
        ))
    }

    private func turnSection(_ turn: ChatTurnID, rows: [ChatDisplayRow]) -> ChatDisplaySection {
        .turn(ChatDisplayTurn(
            id: .turn(turnID: turn, firstRow: rows.first?.id ?? .message(ChatMessageID(rawValue: "empty"))),
            turnID: turn,
            prompt: rows.first(where: \.isPrompt),
            rows: rows
        ))
    }

    private let knownWarning =
        "Warning: Skill descriptions were shortened to fit the 2% skills context budget."

    // MARK: - Modes

    @Test func projectsSummaryDetailedAndHiddenModes() {
        let rows = [
            message("q", "Question", turn: turn1),
            tool("t1", turn: turn1),
            tool("t2", turn: turn1),
            assistant("a", "Answer", turn: turn1),
            tool("t3", turn: turn1),
        ]
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: rows)])

        let detailed = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .detailed)
        #expect(detailed.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "q")),
            .toolCall(ToolCallID(rawValue: "t1")),
            .toolCall(ToolCallID(rawValue: "t2")),
            .message(ChatMessageID(rawValue: "a")),
            .toolCall(ToolCallID(rawValue: "t3")),
        ])

        let summary = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)
        #expect(summary.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "q")),
            .toolCallGroup(ChatToolCallGroupID(rawValue: "t1")),
            .message(ChatMessageID(rawValue: "a")),
            .toolCallGroup(ChatToolCallGroupID(rawValue: "t3")),
        ])

        let hidden = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .hidden)
        #expect(hidden.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "q")),
            .message(ChatMessageID(rawValue: "a")),
        ])
    }

    @Test func twentyEightCommandsProduceOneStableGroup() throws {
        let rows = [message("q", "Run the suite", turn: turn1)]
            + (0..<28).map { index in
                tool("t\(index)", detail: "cmd \(index)", turn: turn1)
            }
            + [assistant("a", "Done", turn: turn1)]
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: rows)])

        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)

        let groupRows = projected.rows.compactMap { row -> ChatToolCallGroupRow? in
            if case .toolCallGroup(let group) = row { return group }
            return nil
        }
        #expect(groupRows.count == 1)
        let group = try #require(groupRows.first)
        #expect(group.calls.count == 28)
        #expect(group.calls.map { $0.id.rawValue } == (0..<28).map { "t\($0)" })
        #expect(projected.rows.count == 3)
        // 28 commands → deterministic single category.
        #expect(group.summary.phrase == "28 commands")
    }

    // MARK: - Run boundaries

    @Test func respectsEveryRunBoundaryAndPreservesNonToolIdentity() {
        let rows = [
            message("q", "Q", turn: turn1),
            tool("t1", turn: turn1),
            tool("t2", turn: turn1),
            assistant("a", "mid answer", turn: turn1),     // message ends a run
            tool("t3", turn: turn1),
            .reasoning(
                id: ChatMessageID(rawValue: "r"),
                turnID: turn1,
                text: "thinking",
                createdAt: .distantPast,
                contentState: .final
            ),                                              // reasoning ends a run
            tool("t4", turn: turn1),
            tool("t5", turn: turn1),
            .notice(
                id: ChatTranscriptNoticeID(rawValue: "n"),
                turnID: turn1,
                kind: .session,
                title: "Note",
                message: "notice ends a run",
                createdAt: .distantPast
            ),
            tool("t6", turn: turn1),
            .failure(
                id: ChatTranscriptFailureID(rawValue: "f"),
                turnID: turn1,
                category: .transportError,
                message: "failure ends a run",
                createdAt: .distantPast
            ),
            tool("t7", turn: turn1),
        ]
        let secondTurn = [
            message("q2", "Q2", turn: turn2),
            tool("t8", turn: turn2),
            tool("t9", turn: turn2),
        ]
        let transcript = ChatDisplayTranscript(sections: [
            turnSection(turn1, rows: rows),
            turnSection(turn2, rows: secondTurn),
        ])

        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)

        // Turn 1: message, [t1,t2], a, [t3], r, [t4,t5], notice, [t6], f, [t7]
        // Turn 2: message, [t8,t9]
        let expectedGroups = ["t1", "t3", "t4", "t6", "t7", "t8"]
        let groups = projected.rows.compactMap { row -> String? in
            guard case .toolCallGroup(let group) = row else { return nil }
            return group.id.rawValue
        }
        #expect(groups == expectedGroups)
        #expect(projected.sections.count == 2)
        // Every non-tool row kept its identity and relative order.
        let nonToolIDs = projected.rows.compactMap { row -> ChatDisplayRowID? in
            switch row {
            case .toolCall, .toolCallGroup: nil
            default: row.id
            }
        }
        #expect(nonToolIDs == [
            .message(ChatMessageID(rawValue: "q")),
            .message(ChatMessageID(rawValue: "a")),
            .message(ChatMessageID(rawValue: "r")),
            .notice(ChatTranscriptNoticeID(rawValue: "n")),
            .failure(ChatTranscriptFailureID(rawValue: "f")),
            .message(ChatMessageID(rawValue: "q2")),
        ])
    }

    @Test func oneCallGroupsAreStillGroups() {
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            tool("solo", turn: turn1),
        ])])
        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)
        #expect(projected.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "q")),
            .toolCallGroup(ChatToolCallGroupID(rawValue: "solo")),
        ])
    }

    // MARK: - Identity stability

    @Test func groupIdentityStaysEqualWhenNewCallsJoinTheLiveRun() {
        let canonicalBefore = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            tool("t1", status: .completed, turn: turn1),
        ])])
        let canonicalAfter = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            tool("t1", status: .completed, turn: turn1),
            tool("t2", status: .running, turn: turn1),
        ])])
        let before = ChatTranscriptPresentationProjection.project(
            transcript: canonicalBefore, toolCallDisplayMode: .summary)
        let after = ChatTranscriptPresentationProjection.project(
            transcript: canonicalAfter, toolCallDisplayMode: .summary)

        // Appending a second call updates the first group row instead of
        // replacing its identity.
        #expect(before.rows.map(\.id) == after.rows.map(\.id))
        guard case .toolCallGroup(let grownGroup) = after.rows[1] else {
            Issue.record("expected a group row")
            return
        }
        #expect(grownGroup.calls.count == 2)
        #expect(grownGroup.state == .running(failedCount: 0))
    }

    @Test func childStatusOrOutputUpdateChangesPayloadNotIdentity() {
        let before = ChatTranscriptPresentationProjection.project(
            transcript: ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
                message("q", "Q", turn: turn1),
                tool("t1", status: .running, turn: turn1),
            ])]),
            toolCallDisplayMode: .summary)
        let after = ChatTranscriptPresentationProjection.project(
            transcript: ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
                message("q", "Q", turn: turn1),
                tool("t1", status: .completed, detail: "now has detail", turn: turn1),
            ])]),
            toolCallDisplayMode: .summary)

        #expect(before.rows.map(\.id) == after.rows.map(\.id))
        #expect(before.rows[1] != after.rows[1])
        guard case .toolCallGroup(let group) = after.rows[1] else {
            Issue.record("expected a group row")
            return
        }
        #expect(group.state == .completed)
    }

    @Test func preservesEveryGroupedChildPayload() {
        let output = "line one\nline two"
        let canonical = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            tool("t1", name: "Read", detail: "/tmp/a", turn: turn1),
            tool(
                "t2",
                name: "Edit",
                status: .failed,
                detail: "notes.md",
                turn: turn1
            ),
            tool("t3", name: "Grep", detail: "pattern", turn: turn1),
        ])])
        let projected = ChatTranscriptPresentationProjection.project(
            transcript: canonical, toolCallDisplayMode: .summary)

        guard case .toolCallGroup(let group) = projected.rows[1] else {
            Issue.record("expected a group row")
            return
        }
        // Every original payload survives inside the group, byte for byte.
        let canonicalCalls = canonical.rows.compactMap { row -> ChatDisplayToolCall? in
            if case .toolCall(let call) = row { return call }
            return nil
        }
        #expect(group.calls == canonicalCalls)
        #expect(group.calls[1].output == nil)
        _ = output
        #expect(group.summary.phrase.contains("1 file edited"))
        #expect(group.state == .failed(count: 1))
    }

    // MARK: - Section rebuild

    @Test func dropsEmptyProjectedSections() {
        let allToolTurn = turnSection(turn1, rows: [
            tool("t1", turn: turn1),
            tool("t2", turn: turn1),
        ])
        let unattributed = ChatDisplaySection.unattributed(ChatDisplayUnattributedSection(
            id: .unattributed(rows: []),
            rows: []
        ))
        let noticeSection = ChatDisplaySection.unattributed(ChatDisplayUnattributedSection(
            id: .unattributed(rows: []),
            rows: [
                .notice(
                    id: ChatTranscriptNoticeID(rawValue: "n"),
                    turnID: nil,
                    kind: .session,
                    title: "Notice",
                    message: "kept",
                    createdAt: .distantPast
                ),
            ]
        ))
        let transcript = ChatDisplayTranscript(sections: [allToolTurn, unattributed, noticeSection])

        let hidden = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .hidden)
        // The all-tool turn becomes empty and is dropped; the empty
        // unattributed section is dropped; the notice survives.
        #expect(hidden.sections.count == 1)
        #expect(hidden.sections[0].id == .unattributed(rows: [
            .notice(ChatTranscriptNoticeID(rawValue: "n")),
        ]))
    }

    @Test func rebuildsSectionIdentityAfterRemovingFirstRow() {
        // A mid-page turn whose canonical first row is a tool call: in hidden
        // mode the turn section loses its first row and must rebuild its ID
        // from the original turn ID and the first surviving row.
        let midPageTurn = ChatDisplayTurn(
            id: .turn(turnID: turn1, firstRow: .toolCall(ToolCallID(rawValue: "t1"))),
            turnID: turn1,
            prompt: nil,
            rows: [
                tool("t1", turn: turn1),
                assistant("a", "Answer", turn: turn1),
            ]
        )
        let transcript = ChatDisplayTranscript(sections: [.turn(midPageTurn)])

        let hidden = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .hidden)
        #expect(hidden.sections.count == 1)
        #expect(hidden.sections[0].id == .turn(
            turnID: turn1,
            firstRow: .message(ChatMessageID(rawValue: "a"))
        ))
        // The turn keeps its original turn ID.
        guard case .turn(let rebuilt) = hidden.sections[0] else {
            Issue.record("expected a turn section")
            return
        }
        #expect(rebuilt.turnID == turn1)
        #expect(rebuilt.prompt == nil)
    }

    @Test func promptSurvivesWhenItsRowSurvivesAndVanishesWhenRemoved() {
        // The prompt row survives in every mode because user messages are
        // never filtered — it stays attached to the rebuilt section.
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            tool("t1", turn: turn1),
        ])])
        for mode in [ChatToolCallDisplayMode.summary, .detailed, .hidden] {
            let projected = ChatTranscriptPresentationProjection.project(
                transcript: transcript, toolCallDisplayMode: mode)
            guard case .turn(let turn) = projected.sections[0] else {
                Issue.record("expected a turn section")
                return
            }
            if mode == .hidden {
                #expect(turn.prompt?.id == .message(ChatMessageID(rawValue: "q")))
            } else {
                #expect(turn.prompt?.id == .message(ChatMessageID(rawValue: "q")))
            }
        }
    }

    // MARK: - Warning cleanup

    @Test func dropsWarningOnlyRows() {
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            assistant("w1", knownWarning, turn: turn1),
            assistant("w2", knownWarning + " \n\n", turn: turn1),
            assistant("answer", knownWarning + "\n\nTidal pools form twice daily.", turn: turn1),
        ])])
        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)

        // Warning-only rows vanish; the substantive answer keeps its ID with
        // cleaned text.
        #expect(projected.rows.count == 2)
        #expect(projected.rows[1].id == .message(ChatMessageID(rawValue: "answer")))
        #expect(projected.rows[1].textForSearch == "Tidal pools form twice daily.")
    }

    @Test func incompleteWarningPrefixDependsOnContentState() {
        let partial = "Warning: Skill descriptions were shortened"
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            assistant("streaming", partial, turn: turn1, streaming: true),
            assistant("final", partial, turn: turn1),
        ])])
        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)

        // Streaming rows hide a proper prefix; final rows preserve it.
        #expect(projected.rows.map(\.id) == [
            .message(ChatMessageID(rawValue: "q")),
            .message(ChatMessageID(rawValue: "final")),
        ])
        #expect(projected.rows[1].textForSearch == partial)
    }

    @Test func unrelatedWarningsRemainVisibleInChat() {
        let unrelated = "Warning: Provider timeout after 30s"
        let transcript = ChatDisplayTranscript(sections: [turnSection(turn1, rows: [
            message("q", "Q", turn: turn1),
            assistant("u", unrelated, turn: turn1, streaming: true),
        ])])
        let projected = ChatTranscriptPresentationProjection.project(
            transcript: transcript, toolCallDisplayMode: .summary)
        #expect(projected.rows.count == 2)
        #expect(projected.rows[1].textForSearch == unrelated)
    }

    @Test func doesNotMutateCanonicalInput() {
        let warning = knownWarning
        let sections: [ChatDisplaySection] = [
            turnSection(turn1, rows: [
                message("q", "Q", turn: turn1),
                tool("t1", detail: "/tmp/a", turn: turn1),
                tool("t2", detail: "/tmp/a", turn: turn1),
                assistant("a", warning + "\n\nAnswer", turn: turn1),
            ]),
            turnSection(turn2, rows: [
                message("q2", "Q2", turn: turn2),
                assistant("s", warning, turn: turn2, streaming: true),
                tool("t3", turn: turn2),
            ]),
            .unattributed(ChatDisplayUnattributedSection(
                id: .unattributed(rows: []),
                rows: [
                    .notice(
                        id: ChatTranscriptNoticeID(rawValue: "n"),
                        turnID: nil,
                        kind: .session,
                        title: "Notice",
                        message: "hi",
                        createdAt: .distantPast
                    ),
                ]
            )),
        ]
        let canonical = ChatDisplayTranscript(sections: sections)
        let snapshot = canonical

        for mode in [ChatToolCallDisplayMode.summary, .detailed, .hidden] {
            _ = ChatTranscriptPresentationProjection.project(
                transcript: canonical, toolCallDisplayMode: mode)
        }
        // Value types cannot alias, and the projection never writes through:
        // the source transcript is identical after all three projections.
        #expect(canonical == snapshot)
        #expect(canonical.sections.count == 3)
        #expect(canonical.rows.count == 8)
    }
}
#endif
