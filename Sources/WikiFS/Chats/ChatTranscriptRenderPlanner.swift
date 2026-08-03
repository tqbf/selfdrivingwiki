// pattern: Functional Core

import Foundation

/// Rendering identity outside the durable transcript. A changed value means the
/// existing DOM cannot safely receive an incremental command.
struct ChatTranscriptRenderContext: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        case chat
        case activityFeed
    }

    let transcriptID: TranscriptID?
    let style: Style
    /// A caller increments this token for an explicit renderer reset even when
    /// the transcript identity has not changed.
    let resetToken: Int

    init(
        transcriptID: TranscriptID?,
        style: Style = .chat,
        resetToken: Int = 0
    ) {
        self.transcriptID = transcriptID
        self.style = style
        self.resetToken = resetToken
    }
}

/// The complete desired state for the one-document transcript surface.
struct ChatTranscriptRenderSnapshot: Hashable, Sendable {
    let context: ChatTranscriptRenderContext
    let rows: [ChatDisplayRow]
}

enum ChatTranscriptRenderCommand: Hashable, Sendable {
    case reload(ChatTranscriptRenderSnapshot)
    case append([ChatDisplayRow])
    case insert(ChatDisplayRow, before: ChatDisplayRowID)
    case replace(ChatDisplayRow)
    case remove(ChatDisplayRowID)

    var kind: ChatTranscriptRenderCommandKind {
        switch self {
        case .reload: .reload
        case .append: .append
        case .insert: .insert
        case .replace: .replace
        case .remove: .remove
        }
    }

    var rowID: ChatDisplayRowID? {
        switch self {
        case .reload: nil
        case .append(let rows): rows.last?.id
        case .insert(let row, _), .replace(let row): row.id
        case .remove(let rowID): rowID
        }
    }
}

enum ChatTranscriptRenderCommandKind: String, Codable, Hashable, Sendable {
    case reload
    case append
    case insert
    case replace
    case remove
}

/// A pure, identity-based DOM update plan. Array positions exist only while
/// this planner finds insertion points; WebKit receives durable row identities.
enum ChatTranscriptRenderPlanner {
    static func commands(
        previous: ChatTranscriptRenderSnapshot?,
        desired: ChatTranscriptRenderSnapshot
    ) -> [ChatTranscriptRenderCommand] {
        guard let previous else { return [.reload(desired)] }
        guard previous.context == desired.context else { return [.reload(desired)] }

        let previousIDs = previous.rows.map(\.id)
        let desiredIDs = desired.rows.map(\.id)
        guard Set(previousIDs).count == previousIDs.count,
              Set(desiredIDs).count == desiredIDs.count,
              preservesCommonRowOrder(previousIDs: previousIDs, desiredIDs: desiredIDs)
        else {
            return [.reload(desired)]
        }
        // Equal counts with a changed identity are not a last-row replacement.
        // A reload makes the identity boundary explicit instead of guessing that
        // a remove-plus-append was an in-place content change.
        if previousIDs.count == desiredIDs.count, previousIDs != desiredIDs {
            return [.reload(desired)]
        }

        let previousIDSet = Set(previousIDs)
        let previousRowsByID = Dictionary(uniqueKeysWithValues: previous.rows.map { ($0.id, $0) })
        // Keep changes to existing rows ahead of structural growth. The executor
        // may coalesce repeated replacements for this same row, but it must not
        // move a replacement across an append boundary for a different row.
        var commands: [ChatTranscriptRenderCommand] = desired.rows.compactMap { row in
            guard let previousRow = previousRowsByID[row.id], previousRow != row else { return nil }
            return .replace(row)
        }

        let desiredIDSet = Set(desiredIDs)
        commands += previousIDs.reversed().compactMap { rowID in
            desiredIDSet.contains(rowID) ? nil : ChatTranscriptRenderCommand.remove(rowID)
        }
        for (index, row) in desired.rows.enumerated() where !previousIDSet.contains(row.id) {
            if let nextExistingRow = desired.rows[(index + 1)...].first(where: { previousIDSet.contains($0.id) }) {
                commands.append(.insert(row, before: nextExistingRow.id))
            } else {
                let appendedRows = desired.rows[index...].prefix { !previousIDSet.contains($0.id) }
                commands.append(.append(Array(appendedRows)))
                break
            }
        }

        return commands
    }

    private static func preservesCommonRowOrder(
        previousIDs: [ChatDisplayRowID],
        desiredIDs: [ChatDisplayRowID]
    ) -> Bool {
        let desiredIDSet = Set(desiredIDs)
        let previousCommon = previousIDs.filter(desiredIDSet.contains)
        let previousIDSet = Set(previousIDs)
        let desiredCommon = desiredIDs.filter(previousIDSet.contains)
        return previousCommon == desiredCommon
    }
}
