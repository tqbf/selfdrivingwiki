// pattern: Functional Core

import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

/// Stable, namespaced identity for one display row. These identifiers preserve
/// the durable transcript namespace all the way to presentation.
enum ChatDisplayRowID: Hashable, Sendable, Identifiable {
    case message(ChatMessageID)
    case toolCall(ToolCallID)
    case notice(ChatTranscriptNoticeID)
    case failure(ChatTranscriptFailureID)

    var id: Self { self }
}

/// Lifecycle state deliberately available only on assistant and reasoning rows.
enum ChatDisplayContentState: Hashable, Sendable {
    case streaming
    case final
}

/// One typed transcript row ready for presentation. It is app-only: durable
/// transcript vocabulary remains in `WikiFSTypes` and sync vocabulary remains
/// in `WikiFSEngine`.
enum ChatDisplayRow: Hashable, Sendable, Identifiable {
    case userMessage(
        id: ChatMessageID,
        turnID: ChatTurnID,
        text: String,
        createdAt: Date
    )
    case assistantMessage(
        id: ChatMessageID,
        turnID: ChatTurnID,
        text: String,
        createdAt: Date,
        contentState: ChatDisplayContentState
    )
    case reasoning(
        id: ChatMessageID,
        turnID: ChatTurnID,
        text: String,
        createdAt: Date,
        contentState: ChatDisplayContentState
    )
    case toolCall(
        id: ToolCallID,
        turnID: ChatTurnID,
        toolName: String,
        status: ChatToolCallStatus,
        detail: String?,
        output: String?,
        permissionRequestID: PermissionRequestID?,
        updatedAt: Date
    )
    case notice(
        id: ChatTranscriptNoticeID,
        turnID: ChatTurnID?,
        kind: ChatSystemNoticeKind,
        title: String,
        message: String,
        createdAt: Date
    )
    case failure(
        id: ChatTranscriptFailureID,
        turnID: ChatTurnID,
        category: ChatTurnFailureCategory,
        message: String,
        createdAt: Date
    )

    var id: ChatDisplayRowID {
        switch self {
        case .userMessage(let id, _, _, _),
             .assistantMessage(let id, _, _, _, _),
             .reasoning(let id, _, _, _, _):
            .message(id)
        case .toolCall(let id, _, _, _, _, _, _, _):
            .toolCall(id)
        case .notice(let id, _, _, _, _, _):
            .notice(id)
        case .failure(let id, _, _, _, _):
            .failure(id)
        }
    }

    var turnID: ChatTurnID? {
        switch self {
        case .userMessage(_, let turnID, _, _),
             .assistantMessage(_, let turnID, _, _, _),
             .reasoning(_, let turnID, _, _, _),
             .toolCall(_, let turnID, _, _, _, _, _, _),
             .failure(_, let turnID, _, _, _):
            turnID
        case .notice(_, let turnID, _, _, _, _):
            turnID
        }
    }

    var contentState: ChatDisplayContentState? {
        switch self {
        case .assistantMessage(_, _, _, _, let state), .reasoning(_, _, _, _, let state):
            state
        case .userMessage, .toolCall, .notice, .failure:
            nil
        }
    }

    var isPrompt: Bool {
        if case .userMessage = self { return true }
        return false
    }

    var textForSearch: String {
        switch self {
        case .userMessage(_, _, let text, _),
             .assistantMessage(_, _, let text, _, _),
             .reasoning(_, _, let text, _, _),
             .failure(_, _, _, let text, _):
            text
        case .toolCall(_, _, let toolName, _, let detail, let output, _, _):
            [toolName, detail, output].compactMap { $0 }.joined(separator: "\n")
        case .notice(_, _, _, let title, let message, _):
            [title, message].joined(separator: "\n")
        }
    }

    var timestamp: Date {
        switch self {
        case .userMessage(_, _, _, let createdAt),
             .assistantMessage(_, _, _, let createdAt, _),
             .reasoning(_, _, _, let createdAt, _),
             .notice(_, _, _, _, _, let createdAt),
             .failure(_, _, _, _, let createdAt):
            createdAt
        case .toolCall(_, _, _, _, _, _, _, let updatedAt):
            updatedAt
        }
    }
}

enum ChatDisplaySectionID: Hashable, Sendable, Identifiable {
    case turn(turnID: ChatTurnID, firstRow: ChatDisplayRowID)
    case unattributed(rows: [ChatDisplayRowID])

    var id: Self { self }
}

struct ChatDisplayTurn: Hashable, Sendable, Identifiable {
    let id: ChatDisplaySectionID
    let turnID: ChatTurnID
    /// A page beginning mid-turn has no user prompt; retaining that absence is
    /// more honest than inventing an empty prompt.
    let prompt: ChatDisplayRow?
    let rows: [ChatDisplayRow]
}

struct ChatDisplayUnattributedSection: Hashable, Sendable, Identifiable {
    let id: ChatDisplaySectionID
    let rows: [ChatDisplayRow]
}

enum ChatDisplaySection: Hashable, Sendable, Identifiable {
    case turn(ChatDisplayTurn)
    case unattributed(ChatDisplayUnattributedSection)

    var id: ChatDisplaySectionID {
        switch self {
        case .turn(let turn): turn.id
        case .unattributed(let section): section.id
        }
    }

    var rows: [ChatDisplayRow] {
        switch self {
        case .turn(let turn): turn.rows
        case .unattributed(let section): section.rows
        }
    }
}

struct ChatDisplayTranscript: Hashable, Sendable {
    let sections: [ChatDisplaySection]

    static let empty = ChatDisplayTranscript(sections: [])

    var rows: [ChatDisplayRow] { sections.flatMap(\.rows) }
}

/// Selection intent emitted by the typed outline. The WebKit bridge resolves
/// this durable target to its temporary DOM index at the rendering boundary.
struct ChatScrollRequest: Equatable {
    let version: Int
    let target: ChatOutlineEntry.ID
}

/// Proof that an active block names a present assistant/reasoning row. The
/// projection accepts this value rather than raw wire metadata so invalid live
/// state cannot accidentally mark a row streaming.
struct ChatDisplayActiveContentBlock: Hashable, Sendable {
    let messageID: ChatMessageID
    let turnID: ChatTurnID
    let role: ChatTranscriptMessageRole

    init?(validating block: ChatActiveContentBlock, among items: [ChatTranscriptItem]) {
        guard block.role == .assistant || block.role == .reasoning else { return nil }
        guard items.contains(where: { item in
            guard case .message(let message) = item else { return false }
            return message.messageID == block.messageID
                && message.turnID == block.turnID
                && message.role == block.role
        }) else { return nil }
        self.messageID = block.messageID
        self.turnID = block.turnID
        self.role = block.role
    }
}

enum ChatDisplayProjectionAnomaly: Hashable, Sendable {
    case noncontiguousTurn(turnID: ChatTurnID)
    case duplicateInputRowID(ChatDisplayRowID)
    case lostRow(expected: ChatDisplayRowID)
    case duplicatedRow(actual: ChatDisplayRowID)
    case reorderedRow(expected: ChatDisplayRowID, actual: ChatDisplayRowID)
}

enum ChatDisplayProjection {
    struct Result: Hashable, Sendable {
        let transcript: ChatDisplayTranscript
        let anomalies: [ChatDisplayProjectionAnomaly]
    }

    static func project(
        items: [ChatTranscriptItem],
        activeContentBlock: ChatDisplayActiveContentBlock?
    ) -> Result {
        let rows = items.map { row(from: $0, activeContentBlock: activeContentBlock) }
        var anomalies = duplicateInputAnomalies(for: rows.map(\.id))
        var sections: [ChatDisplaySection] = []
        var currentTurnID: ChatTurnID?
        var currentTurnRows: [ChatDisplayRow] = []
        var unattributedRows: [ChatDisplayRow] = []
        var encounteredTurnIDs: Set<ChatTurnID> = []
        var lastClosedTurnID: ChatTurnID?

        func appendCurrentTurn() {
            guard let currentTurnID, let firstRow = currentTurnRows.first else { return }
            sections.append(.turn(ChatDisplayTurn(
                id: .turn(turnID: currentTurnID, firstRow: firstRow.id),
                turnID: currentTurnID,
                prompt: currentTurnRows.first(where: \.isPrompt),
                rows: currentTurnRows
            )))
            lastClosedTurnID = currentTurnID
            currentTurnRows = []
        }

        func appendUnattributed() {
            guard unattributedRows.isEmpty == false else { return }
            sections.append(.unattributed(ChatDisplayUnattributedSection(
                id: .unattributed(rows: unattributedRows.map(\.id)),
                rows: unattributedRows
            )))
            unattributedRows = []
        }

        for row in rows {
            guard let turnID = row.turnID else {
                appendCurrentTurn()
                currentTurnID = nil
                unattributedRows.append(row)
                continue
            }

            appendUnattributed()
            if currentTurnID != turnID {
                appendCurrentTurn()
                if encounteredTurnIDs.contains(turnID),
                   let lastClosedTurnID,
                   lastClosedTurnID != turnID {
                    anomalies.append(.noncontiguousTurn(turnID: turnID))
                }
                currentTurnID = turnID
                encounteredTurnIDs.insert(turnID)
            }
            currentTurnRows.append(row)
        }
        appendCurrentTurn()
        appendUnattributed()

        let transcript = ChatDisplayTranscript(sections: sections)
        anomalies += validationAnomalies(input: rows.map(\.id), output: transcript.rows.map(\.id))
        return Result(transcript: transcript, anomalies: anomalies)
    }

    private static func row(
        from item: ChatTranscriptItem,
        activeContentBlock: ChatDisplayActiveContentBlock?
    ) -> ChatDisplayRow {
        switch item {
        case .message(let message):
            switch message.role {
            case .user:
                .userMessage(
                    id: message.messageID,
                    turnID: message.turnID,
                    text: message.text,
                    createdAt: message.createdAt
                )
            case .assistant:
                .assistantMessage(
                    id: message.messageID,
                    turnID: message.turnID,
                    text: message.text,
                    createdAt: message.createdAt,
                    contentState: contentState(for: message, activeContentBlock: activeContentBlock)
                )
            case .reasoning:
                .reasoning(
                    id: message.messageID,
                    turnID: message.turnID,
                    text: message.text,
                    createdAt: message.createdAt,
                    contentState: contentState(for: message, activeContentBlock: activeContentBlock)
                )
            }
        case .toolCall(let toolCall):
            .toolCall(
                id: toolCall.toolCallID,
                turnID: toolCall.turnID,
                toolName: toolCall.toolName,
                status: toolCall.status,
                detail: toolCall.detail,
                output: toolCall.output,
                permissionRequestID: toolCall.permissionRequestID,
                updatedAt: toolCall.updatedAt
            )
        case .systemNotice(let notice):
            .notice(
                id: notice.noticeID,
                turnID: notice.turnID,
                kind: notice.kind,
                title: notice.title,
                message: notice.message,
                createdAt: notice.createdAt
            )
        case .turnFailure(let failure):
            .failure(
                id: failure.failureID,
                turnID: failure.turnID,
                category: failure.category,
                message: failure.message,
                createdAt: failure.createdAt
            )
        }
    }

    private static func contentState(
        for message: ChatTranscriptMessageItem,
        activeContentBlock: ChatDisplayActiveContentBlock?
    ) -> ChatDisplayContentState {
        guard activeContentBlock?.messageID == message.messageID,
              activeContentBlock?.turnID == message.turnID,
              activeContentBlock?.role == message.role else {
            return .final
        }
        return .streaming
    }

    private static func duplicateInputAnomalies(for ids: [ChatDisplayRowID]) -> [ChatDisplayProjectionAnomaly] {
        var seen: Set<ChatDisplayRowID> = []
        return ids.compactMap { id in
            seen.insert(id).inserted ? nil : .duplicateInputRowID(id)
        }
    }

    private static func validationAnomalies(
        input: [ChatDisplayRowID],
        output: [ChatDisplayRowID]
    ) -> [ChatDisplayProjectionAnomaly] {
        var anomalies: [ChatDisplayProjectionAnomaly] = []
        var remaining = input
        for id in output {
            guard let index = remaining.firstIndex(of: id) else {
                anomalies.append(.duplicatedRow(actual: id))
                continue
            }
            if index != remaining.startIndex {
                anomalies.append(.reorderedRow(expected: remaining[remaining.startIndex], actual: id))
            }
            remaining.remove(at: index)
        }
        anomalies += remaining.map { .lostRow(expected: $0) }
        return anomalies
    }
}

/// The app-side approval callback contract. It carries the namespaced option
/// identity and intent together, instead of letting a caller reconstruct a
/// semantic action from a raw string and a Boolean.
enum ChatPermissionResolutionIntent: Hashable, Sendable {
    case approve(optionID: PermissionOptionID)
    case deny(optionID: PermissionOptionID)
    case cancel(optionID: PermissionOptionID)

    var optionID: PermissionOptionID {
        switch self {
        case .approve(let optionID), .deny(let optionID), .cancel(let optionID): optionID
        }
    }

    var isApproval: Bool {
        if case .approve = self { return true }
        return false
    }
}
