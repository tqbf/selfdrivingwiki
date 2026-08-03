import Foundation

/// Converts a unified line diff (`[DiffLine]`) into an aligned **two-column**
/// (split) model for the extraction compare UI (track C). Pure value types, no
/// rendering — the view renders `[SplitDiffElement]` into a synchronized
/// side-by-side grid.
///
/// The unified model emits, within each divergence region, all removals before
/// all additions. Split view pairs them index-by-index so a changed line shows
/// old-on-the-left / new-on-the-right on one row; the unequal remainder becomes
/// left-only or right-only rows. Separate left/right line numbers are threaded
/// through the walk (equal advances both; removed advances left; added advances
/// right) because `DiffLine` carries none.

/// One side of a split-diff row: a numbered line with its change kind.
public struct SplitCell: Hashable, Sendable {
    public let number: Int
    public let text: String
    public let kind: DiffLineKind

    public init(number: Int, text: String, kind: DiffLineKind) {
        self.number = number
        self.text = text
        self.kind = kind
    }
}

/// One row of the split diff. Either side may be `nil` (an unpaired
/// removal/addition renders as a blank filler on the opposite side).
public struct SplitRow: Hashable, Sendable, Identifiable {
    /// Stable position in the fully-expanded row list — used as SwiftUI id and
    /// as a scroll anchor for change-navigation.
    public let index: Int
    public let left: SplitCell?
    public let right: SplitCell?

    public var id: Int { index }

    public init(index: Int, left: SplitCell?, right: SplitCell?) {
        self.index = index
        self.left = left
        self.right = right
    }

    /// True when either side is an addition/removal (a real change), false for
    /// a fully-unchanged (equal|equal) row.
    public var isChange: Bool {
        (left?.kind ?? .equal) != .equal || (right?.kind ?? .equal) != .equal
    }
}

/// A rendered element: either a visible row or a collapsed band standing in for
/// a run of unchanged rows (expandable in the view).
public enum SplitDiffElement: Hashable, Sendable, Identifiable {
    case row(SplitRow)
    case collapsed(rows: [SplitRow])

    public var id: Int {
        switch self {
        case .row(let r): return r.index
        // Negative, offset by 1 so a band hiding row 0 doesn't collide with it.
        case .collapsed(let rows): return -((rows.first?.index ?? 0) + 1)
        }
    }
}

public enum SplitDiff {
    /// Align a unified diff into split rows with per-side line numbers.
    public static func rows(from lines: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        rows.reserveCapacity(lines.count)
        var idx = 0, leftNo = 1, rightNo = 1
        var removed: [String] = [], added: [String] = []

        func flush() {
            let pairs = min(removed.count, added.count)
            for k in 0..<pairs {
                rows.append(SplitRow(index: idx,
                    left: SplitCell(number: leftNo, text: removed[k], kind: .removed),
                    right: SplitCell(number: rightNo, text: added[k], kind: .added)))
                idx += 1; leftNo += 1; rightNo += 1
            }
            if removed.count > pairs {
                for k in pairs..<removed.count {
                    rows.append(SplitRow(index: idx,
                        left: SplitCell(number: leftNo, text: removed[k], kind: .removed),
                        right: nil))
                    idx += 1; leftNo += 1
                }
            }
            if added.count > pairs {
                for k in pairs..<added.count {
                    rows.append(SplitRow(index: idx, left: nil,
                        right: SplitCell(number: rightNo, text: added[k], kind: .added)))
                    idx += 1; rightNo += 1
                }
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.kind {
            case .removed: removed.append(line.text)
            case .added: added.append(line.text)
            case .equal:
                flush()
                rows.append(SplitRow(index: idx,
                    left: SplitCell(number: leftNo, text: line.text, kind: .equal),
                    right: SplitCell(number: rightNo, text: line.text, kind: .equal)))
                idx += 1; leftNo += 1; rightNo += 1
            }
        }
        flush()
        return rows
    }

    /// Collapse maximal runs of unchanged rows longer than
    /// `context * (sides) + threshold` into a band, keeping `context` rows of
    /// context adjacent to the surrounding changes (none at the document edges).
    public static func elements(from rows: [SplitRow],
                                context: Int = 3,
                                threshold: Int = 4) -> [SplitDiffElement] {
        var out: [SplitDiffElement] = []
        var i = 0
        let n = rows.count
        while i < n {
            if rows[i].isChange {
                out.append(.row(rows[i])); i += 1; continue
            }
            var j = i
            while j < n && !rows[j].isChange { j += 1 }
            let head = (i == 0) ? 0 : context      // context after the change above
            let tail = (j == n) ? 0 : context       // context before the change below
            if (j - i) > head + tail + threshold {
                for k in i..<(i + head) { out.append(.row(rows[k])) }
                out.append(.collapsed(rows: Array(rows[(i + head)..<(j - tail)])))
                for k in (j - tail)..<j { out.append(.row(rows[k])) }
            } else {
                for k in i..<j { out.append(.row(rows[k])) }
            }
            i = j
        }
        return out
    }

    /// Row indices that begin a contiguous block of changes — scroll anchors for
    /// "jump to next/previous change".
    public static func hunkAnchors(from rows: [SplitRow]) -> [Int] {
        var anchors: [Int] = []
        var prevWasChange = false
        for r in rows {
            if r.isChange && !prevWasChange { anchors.append(r.index) }
            prevWasChange = r.isChange
        }
        return anchors
    }
}
