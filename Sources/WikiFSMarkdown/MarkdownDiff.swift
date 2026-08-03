import Foundation

/// A line-level diff between two markdown bodies, for the extraction compare UI
/// (track C). Pure value types, no rendering — the compare sheet renders
/// `[DiffLine]` however it likes (split or unified). The algorithm is a classic
/// LCS dynamic program over lines; it is capped for very large inputs so the UI
/// never allocates a pathological DP table.

public enum DiffLineKind: String, Sendable, Hashable {
    /// Present in both bodies (unchanged).
    case equal
    /// Present only in the right ("after") body — an addition.
    case added
    /// Present only in the left ("before") body — a removal.
    case removed
}

/// One line of a diff. `text` excludes the trailing newline.
public struct DiffLine: Hashable, Sendable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum MarkdownDiff {
    /// Hard cap on the DP table cell count (`lines(left)+1) * (lines(right)+1)`).
    /// Above this, `lineDiff` falls back to a degraded whole-document change
    /// (all-removed then all-added) so the UI stays responsive on huge bodies —
    /// the rendered side-by-side view is the better surface for those anyway.
    private static let maxCells = 4_000_000

    /// A line-level diff of `left` (before) vs `right` (after). `removed` lines
    /// come from `left`, `added` lines from `right`. In each divergence region
    /// removals are emitted before additions (the conventional unified look).
    /// Returns `[]` when both bodies are empty.
    public static func lineDiff(_ left: String, _ right: String) -> [DiffLine] {
        let a = Self.lines(left)
        let b = Self.lines(right)
        guard !(a.isEmpty && b.isEmpty) else { return [] }
        // Fast path: identical.
        if a == b { return a.map { DiffLine(kind: .equal, text: $0) } }

        let cells = (a.count + 1) * (b.count + 1)
        if cells > maxCells { return degraded(a, b) }

        // dp[i][j] = LCS length of a[i..<n], b[j..<m]. Built from the bottom
        // right up so the forward walk can greedily reconstruct the edit.
        let n = a.count, m = b.count
        var dp = [Int](repeating: 0, count: cells)
        let rowStride = m + 1
        var i = n - 1
        while i >= 0 {
            let ai = a[i]
            var j = m - 1
            while j >= 0 {
                let v: Int
                if ai == b[j] {
                    v = dp[(i + 1) * rowStride + (j + 1)] + 1
                } else {
                    let down = dp[(i + 1) * rowStride + j]
                    let across = dp[i * rowStride + (j + 1)]
                    v = down > across ? down : across
                }
                dp[i * rowStride + j] = v
                j -= 1
            }
            i -= 1
        }

        // Forward reconstruction: at a divergence, prefer removals (>=) so they
        // group before additions.
        var out: [DiffLine] = []
        out.reserveCapacity(max(n, m))
        var pi = 0, pj = 0
        while pi < n || pj < m {
            if pi < n, pj < m, a[pi] == b[pj] {
                out.append(DiffLine(kind: .equal, text: a[pi]))
                pi += 1; pj += 1
            } else if pi < n, pj == m || dp[(pi + 1) * rowStride + pj] >= dp[pi * rowStride + (pj + 1)] {
                out.append(DiffLine(kind: .removed, text: a[pi]))
                pi += 1
            } else {
                out.append(DiffLine(kind: .added, text: b[pj]))
                pj += 1
            }
        }
        return out
    }

    /// Split a body into lines (no trailing newline). An empty string yields
    /// `[]`; a single trailing newline does not produce a spurious empty final
    /// line (so "a\n" → ["a"]), but an interior/blank line is preserved
    /// ("a\n\nb" → ["a","","b"]).
    private static func lines(_ body: String) -> [String] {
        guard !body.isEmpty else { return [] }
        var parts = body.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        ).map(String.init)
        // Drop the artifact empty segment produced by a terminating newline.
        if parts.count > 1, parts.last == "",
           body.last == "\n" || body.last == "\r" {
            parts.removeLast()
        }
        return parts
    }

    /// Degraded fallback for oversized inputs: report the whole left body as
    /// removed followed by the whole right body as added. Correct (just not
    /// minimal); keeps memory bounded.
    private static func degraded(_ a: [String], _ b: [String]) -> [DiffLine] {
        var out: [DiffLine] = []
        out.reserveCapacity(a.count + b.count)
        for line in a { out.append(DiffLine(kind: .removed, text: line)) }
        for line in b { out.append(DiffLine(kind: .added, text: line)) }
        return out
    }
}
