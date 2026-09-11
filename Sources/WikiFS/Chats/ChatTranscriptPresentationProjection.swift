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
        var cleaned: [ChatDisplayRow] = []
        var pendingRun: [ChatDisplayToolCall] = []
        // Group rows are accumulated as contiguous runs close, so cleaning
        // (which can drop rows) happens before boundaries are decided.
        func closeRun() {
            guard pendingRun.isEmpty == false else { return }
            let calls = pendingRun
            pendingRun = []
            cleaned.append(.toolCallGroup(ChatToolCallGroupRow(
                id: ChatToolCallGroupID(hostedBy: calls[0]),
                turnID: calls[0].turnID,
                calls: calls,
                state: .aggregating(calls),
                summary: .summarizing(calls)
            )))
        }

        for row in rows {
            switch row {
            case .toolCall(let call):
                switch toolCallDisplayMode {
                case .hidden:
                    continue
                case .summary:
                    pendingRun.append(call)
                case .detailed:
                    cleaned.append(row)
                }

            case .assistantMessage(let id, let turnID, let text, let createdAt, let contentState):
                closeRun()
                // The known warning is assistant prose, so only assistant
                // rows are cleaned; unrelated Warning: content is preserved.
                let policy: AgentPresentationPreambleWarningPolicy =
                    contentState == .streaming ? .streamingPrefixAware : .completeOnly
                guard let visible = AgentPresentationPreamble.visibleText(text, policy: policy) else {
                    continue
                }
                if visible == text {
                    cleaned.append(row)
                } else {
                    // Same message ID, cleaned text.
                    cleaned.append(.assistantMessage(
                        id: id,
                        turnID: turnID,
                        text: visible,
                        createdAt: createdAt,
                        contentState: contentState
                    ))
                }

            default:
                closeRun()
                cleaned.append(row)
            }
        }
        closeRun()
        return cleaned
    }
}
