// pattern: Functional Core

import Foundation
import WikiFSCore
import WikiFSTypes

/// The human-facing projection layered over the canonical
/// `ChatDisplayProjection` output. Pure, app-only, and never persisted:
///
/// 1. Removes the known skill-description budget preamble from assistant
///    rows under the policy the row's content state selects
///    (`streamingPrefixAware` while streaming, `completeOnly` once final).
/// 2. Applies the selected `ChatToolCallDisplayMode`:
///    - `summary` replaces each maximal contiguous run of tool calls with
///      one stable `toolCallGroup` row,
///    - `detailed` preserves every canonical row and ID,
///    - `hidden` removes only tool-call rows.
/// 3. Drops sections that become empty and rebuilds every surviving section
///    identity from the projected rows.
///
/// The canonical transcript, durable events, diagnostics, and Activity views
/// are never inputs to or outputs of this type.
enum ChatTranscriptPresentationProjection {
    static func project(
        transcript: ChatDisplayTranscript,
        toolCallDisplayMode: ChatToolCallDisplayMode
    ) -> ChatDisplayTranscript {
        ChatDisplayTranscript(
            sections: transcript.sections.compactMap { section in
                projectedSection(section, toolCallDisplayMode: toolCallDisplayMode)
            }
        )
    }

    // MARK: - Sections

    /// One section projects independently — grouping and cleanup never cross
    /// a section boundary, and section boundaries never cross turns.
    private static func projectedSection(
        _ section: ChatDisplaySection,
        toolCallDisplayMode: ChatToolCallDisplayMode
    ) -> ChatDisplaySection? {
        let rows = projectedRows(
            section.rows,
            toolCallDisplayMode: toolCallDisplayMode
        )
        guard rows.isEmpty == false else { return nil }

        switch section {
        case .turn(let turn):
            let prompt = turn.prompt.flatMap { survivingPrompt(in: rows, canonical: $0) }
            return .turn(ChatDisplayTurn(
                id: .turn(turnID: turn.turnID, firstRow: rows[0].id),
                turnID: turn.turnID,
                prompt: prompt,
                rows: rows
            ))
        case .unattributed:
            return .unattributed(ChatDisplayUnattributedSection(
                id: .unattributed(rows: rows.map(\.id)),
                rows: rows
            ))
        }
    }

    /// The prompt survives only when its own row survived. A filtered
    /// prompt leaves the turn honestly prompt-less rather than pointing at a
    /// removed row.
    private static func survivingPrompt(
        in rows: [ChatDisplayRow],
        canonical prompt: ChatDisplayRow
    ) -> ChatDisplayRow? {
        rows.first { $0.id == prompt.id && $0 == prompt }
    }

    // MARK: - Rows

    private static func projectedRows(
        _ rows: [ChatDisplayRow],
        toolCallDisplayMode: ChatToolCallDisplayMode
    ) -> [ChatDisplayRow] {
        switch toolCallDisplayMode {
        case .summary:
            return summarizedRows(rows)
        case .detailed:
            return nonGroupedRows(rows, hidingTools: false)
        case .hidden:
            return nonGroupedRows(rows, hidingTools: true)
        }
    }

    /// Warning cleanup without grouping (Detailed and Hidden modes preserve
    /// the canonical row sequence).
    private static func nonGroupedRows(
        _ rows: [ChatDisplayRow],
        hidingTools: Bool
    ) -> [ChatDisplayRow] {
        var cleaned: [ChatDisplayRow] = []
        for row in rows {
            if case .toolCall = row, hidingTools { continue }
            if case .assistantMessage(let id, let turnID, let text, let createdAt, let contentState) = row {
                if let cleanedRow = cleanedAssistant(
                    id: id, turnID: turnID, text: text, createdAt: createdAt, contentState: contentState
                ) {
                    cleaned.append(cleanedRow)
                }
                continue
            }
            cleaned.append(row)
        }
        return cleaned
    }

    /// Summary mode: contiguous runs of reasoning + tool calls collapse into
    /// one group row (reasoning folds into the group's expanded body), and
    /// every assistant block except the turn's final answer becomes a
    /// one-line interim disclosure. Nothing is deleted; collapsed rows keep
    /// their durable message IDs.
    private static func summarizedRows(_ rows: [ChatDisplayRow]) -> [ChatDisplayRow] {
        var projected: [ChatDisplayRow] = []
        var pendingReasoning: [(entry: ChatDisplayReasoningEntry, row: ChatDisplayRow)] = []
        var pendingTools: [ChatDisplayToolCall] = []

        // A run closes at any non-work row. A run with tools becomes one
        // group row; reasoning-only runs keep their standalone rows (there is
        // no tool to host a group identity).
        func flushRun() {
            defer {
                pendingReasoning = []
                pendingTools = []
            }
            guard pendingTools.isEmpty == false else {
                projected.append(contentsOf: pendingReasoning.map(\.row))
                return
            }
            let calls = pendingTools
            projected.append(.toolCallGroup(ChatToolCallGroupRow(
                id: ChatToolCallGroupID(hostedBy: calls[0]),
                turnID: calls[0].turnID,
                calls: calls,
                reasoning: pendingReasoning.map(\.entry),
                state: .aggregating(calls),
                summary: .summarizing(calls)
            )))
        }

        for row in rows {
            switch row {
            case .toolCall(let call):
                pendingTools.append(call)

            case .reasoning(let id, _, let text, _, let contentState):
                pendingReasoning.append((
                    entry: ChatDisplayReasoningEntry(
                        id: id,
                        text: text,
                        contentState: contentState
                    ),
                    row: row
                ))

            case .assistantMessage(let id, let turnID, let text, let createdAt, let contentState):
                flushRun()
                if let cleanedRow = cleanedAssistant(
                    id: id, turnID: turnID, text: text, createdAt: createdAt, contentState: contentState
                ) {
                    projected.append(cleanedRow)
                }

            default:
                flushRun()
                projected.append(row)
            }
        }
        flushRun()
        return collapseInterimAssistants(projected)
    }

    /// The turn's last assistant block is the answer and stays expanded;
    /// earlier blocks become interim disclosures under the same message ID.
    private static func collapseInterimAssistants(_ rows: [ChatDisplayRow]) -> [ChatDisplayRow] {
        guard let lastAssistantIndex = rows.lastIndex(where: \.isAssistant) else {
            return rows
        }
        var result = rows
        for index in rows.indices where index != lastAssistantIndex {
            guard case .assistantMessage(let id, let turnID, let text, let createdAt, let contentState) = rows[index]
            else { continue }
            result[index] = .assistantInterim(
                id: id,
                turnID: turnID,
                text: text,
                createdAt: createdAt,
                contentState: contentState
            )
        }
        return result
    }

    /// Warning cleanup for one assistant block. Returns nil when the block
    /// cleans to nothing (warning-only).
    private static func cleanedAssistant(
        id: ChatMessageID,
        turnID: ChatTurnID,
        text: String,
        createdAt: Date,
        contentState: ChatDisplayContentState
    ) -> ChatDisplayRow? {
        // The known warning is assistant prose, so only assistant rows are
        // cleaned; unrelated Warning: content is preserved.
        let policy: AgentPresentationPreambleWarningPolicy =
            contentState == .streaming ? .streamingPrefixAware : .completeOnly
        guard let visible = AgentPresentationPreamble.visibleText(text, policy: policy) else {
            return nil
        }
        if visible == text {
            return .assistantMessage(
                id: id, turnID: turnID, text: text, createdAt: createdAt, contentState: contentState
            )
        }
        // Same message ID, cleaned text.
        return .assistantMessage(
            id: id, turnID: turnID, text: visible, createdAt: createdAt, contentState: contentState
        )
    }
}
