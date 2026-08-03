import Foundation

/// A line-based three-way merge engine (W2, PR #312).
///
/// Computes the merged result of applying two independent edits (ours and
/// theirs) to a common base. When both sides change the same region
/// differently, the result is a conflict; otherwise the changes are combined
/// automatically.
///
/// **Pure** — no I/O, no side effects, Sendable. Unit-testable directly.
///
/// Algorithm: compute the longest common subsequence (LCS) between base↔ours
/// and base↔theirs, then walk all three sequences in lockstep. At each
/// position:
/// - If all three agree → output the line (unchanged).
/// - If ours == theirs (but != base) → output it (both made the same change).
/// - If only ours changed → output ours.
/// - If only theirs changed → output theirs.
/// - If both changed differently → conflict.
public enum Diff3 {

    /// The result of a three-way merge.
    public enum Result: Equatable, Sendable {
        /// The merge succeeded — all changes combined with no conflicts.
        case clean(merged: String)
        /// Both sides changed the same region differently. The merge cannot
        /// proceed automatically; the workspace is parked for resolution.
        case conflict
    }

    /// Merge two independent edits of `base` into a single result.
    ///
    /// - Parameters:
    ///   - base: The common ancestor (the version the workspace observed at
    ///     first write).
    ///   - ours: The main branch's current version (main_head).
    ///   - theirs: The workspace's version.
    /// - Returns: `.clean` if all changes are combinable, `.conflict` if
    ///   both sides changed the same line differently.
    public static func merge(base: String, ours: String, theirs: String) -> Result {
        let baseLines = base.components(separatedBy: "\n")
        let oursLines = ours.components(separatedBy: "\n")
        let theirsLines = theirs.components(separatedBy: "\n")

        return chunkMerge(
            baseLines: baseLines, oursLines: oursLines, theirsLines: theirsLines)
    }

    // MARK: - Chunk-based merge (the actual algorithm)

    /// The classic diff3 algorithm: find "matching" blocks where all three
    /// sequences agree on a line, then classify the gaps between them.
    private static func chunkMerge(
        baseLines: [String], oursLines: [String], theirsLines: [String]
    ) -> Result {
        var result: [String] = []
        var hasConflict = false

        // Walk all three simultaneously. A "stable point" is a line that
        // appears at the current position in ALL three sequences (same content).
        var bi = 0, oi = 0, ti = 0

        while bi < baseLines.count || oi < oursLines.count || ti < theirsLines.count {
            // Find the next line that is common to all three at or after
            // the current positions. This is a simpler, more robust approach
            // than requiring LCS-matched base lines.
            if let (sb, so, st) = findNextCommonLine(
                bi, oi, ti, baseLines, oursLines, theirsLines) {

                // Unstable region before the common line.
                let baseChunk = Array(baseLines[bi..<sb])
                let oursChunk = Array(oursLines[oi..<so])
                let theirsChunk = Array(theirsLines[ti..<st])

                if !baseChunk.isEmpty || !oursChunk.isEmpty || !theirsChunk.isEmpty {
                    let chunkResult = mergeChunk(base: baseChunk, ours: oursChunk, theirs: theirsChunk)
                    switch chunkResult {
                    case .clean(let lines):
                        result.append(contentsOf: lines.components(separatedBy: "\n"))
                    case .conflict:
                        hasConflict = true
                    }
                }

                // Add the common line.
                result.append(baseLines[sb])

                bi = sb + 1
                oi = so + 1
                ti = st + 1
            } else {
                // No more common lines — merge the trailing chunks.
                let baseChunk = Array(baseLines[bi..<baseLines.count])
                let oursChunk = Array(oursLines[oi..<oursLines.count])
                let theirsChunk = Array(theirsLines[ti..<theirsLines.count])

                if !baseChunk.isEmpty || !oursChunk.isEmpty || !theirsChunk.isEmpty {
                    let chunkResult = mergeChunk(base: baseChunk, ours: oursChunk, theirs: theirsChunk)
                    switch chunkResult {
                    case .clean(let lines):
                        result.append(contentsOf: lines.components(separatedBy: "\n"))
                    case .conflict:
                        hasConflict = true
                    }
                }
                break
            }
        }

        if hasConflict { return .conflict }
        return .clean(merged: result.joined(separator: "\n"))
    }

    /// Find the earliest position (at or after the current indices) where all
    /// three sequences have a line with the same content. Returns
    /// (baseIndex, oursIndex, theirsIndex).
    private static func findNextCommonLine(
        _ bi: Int, _ oi: Int, _ ti: Int,
        _ baseLines: [String], _ oursLines: [String], _ theirsLines: [String]
    ) -> (Int, Int, Int)? {
        // For efficiency, build a set of theirs lines for O(1) lookup.
        // But first try the simple O(n^3) approach with early termination —
        // page bodies are small enough in practice.
        var b = bi
        while b < baseLines.count {
            let line = baseLines[b]
            // Find this line in ours at or after oi.
            var o = oi
            while o < oursLines.count {
                if oursLines[o] == line {
                    // Find this line in theirs at or after ti.
                    var t = ti
                    while t < theirsLines.count {
                        if theirsLines[t] == line {
                            return (b, o, t)
                        }
                        t += 1
                    }
                }
                o += 1
            }
            b += 1
        }
        return nil
    }

    /// Merge one unstable chunk. Returns the merged lines, or .conflict.
    private static func mergeChunk(base: [String], ours: [String], theirs: [String]) -> Result {
        if ours == theirs {
            return .clean(merged: ours.joined(separator: "\n"))
        }
        if base == ours {
            return .clean(merged: theirs.joined(separator: "\n"))
        }
        if base == theirs {
            return .clean(merged: ours.joined(separator: "\n"))
        }
        // Both changed differently — try to interleave by finding common
        // lines within the chunk (sub-diff). This handles the case where ours
        // and theirs changed DIFFERENT lines (e.g. ours changed line1, theirs
        // changed line2 — both changes can be combined).
        return interleavedMerge(base: base, ours: ours, theirs: theirs)
    }

    /// Attempt to interleave two non-overlapping changes. Recursively finds
    /// common lines (either ours↔theirs, or via base as an anchor) within the
    /// chunk to split it into smaller sub-chunks.
    private static func interleavedMerge(
        base: [String], ours: [String], theirs: [String]
    ) -> Result {
        // Base cases: if any two of the three are equal, take the third
        // (the differing one) — this handles empty-vs-nonempty as well.
        if ours == theirs { return .clean(merged: ours.joined(separator: "\n")) }
        if base == ours { return .clean(merged: theirs.joined(separator: "\n")) }
        if base == theirs { return .clean(merged: ours.joined(separator: "\n")) }
        // All empty → empty.
        if base.isEmpty && ours.isEmpty && theirs.isEmpty { return .clean(merged: "") }

        // Strategy: find a line that is common to at least two of the three
        // sequences, use it as a split point, and recurse.

        // Case 1: common line in ours and theirs.
        if let (oi, ti) = findFirstCommonLine(ours, theirs) {
            return splitAtCommon(base: base, ours: ours, theirs: theirs,
                                 oursIdx: oi, theirsIdx: ti, commonLine: ours[oi])
        }

        // Case 2: find a base line that survived in ours (ours didn't change it).
        for (bi, line) in base.enumerated() {
            if let oi = ours.firstIndex(of: line) {
                // Ours preserved this base line. Theirs changed around it.
                // Split: before this line, take ours (theirs changed); the
                // line itself; after, recurse.
                let baseBefore = Array(base[..<bi])
                let oursBefore = Array(ours[..<oi])
                let theirsBefore = Array(theirs[..<min(theirs.count, tiForBase(base: base, theirs: theirs, baseIdx: bi))])
                _ = theirsBefore  // not used — theirs before this anchor

                // The base line survived in ours. Before it, ours may have
                // added lines and theirs may have changed lines. Take theirs
                // (ours is unchanged before this point relative to base).
                let baseAfter = Array(base[(bi+1)...])
                let oursAfter = Array(ours[(oi+1)...])
                // Theirs after: everything after the corresponding point.
                // We don't know exactly which theirs line maps to this base
                // line, so merge the entire theirs as the "before" + "after".
                // Simpler: take theirs entirely up to the anchor, and ours after.
                let beforeResult = mergeChunk(base: baseBefore, ours: oursBefore, theirs: theirs)
                guard case .clean(let beforeLines) = beforeResult else {
                    return .conflict
                }
                // The remaining theirs has nothing left (we took it all).
                // Continue with ours after the anchor.
                let afterResult = interleavedMerge(base: baseAfter, ours: oursAfter, theirs: [])
                guard case .clean(let afterLines) = afterResult else {
                    return .conflict
                }
                var result = beforeLines.components(separatedBy: "\n")
                result.append(line)
                result.append(contentsOf: afterLines.components(separatedBy: "\n"))
                return .clean(merged: result.joined(separator: "\n"))
            }
        }

        // Case 3: symmetric — base line survived in theirs.
        for (bi, line) in base.enumerated() {
            if let ti = theirs.firstIndex(of: line) {
                let baseBefore = Array(base[..<bi])
                let theirsBefore = Array(theirs[..<ti])
                let beforeResult = mergeChunk(base: baseBefore, ours: ours, theirs: theirsBefore)
                guard case .clean(let beforeLines) = beforeResult else {
                    return .conflict
                }
                let baseAfter = Array(base[(bi+1)...])
                let theirsAfter = Array(theirs[(ti+1)...])
                let afterResult = interleavedMerge(base: baseAfter, ours: [], theirs: theirsAfter)
                guard case .clean(let afterLines) = afterResult else {
                    return .conflict
                }
                var result = beforeLines.components(separatedBy: "\n")
                result.append(line)
                result.append(contentsOf: afterLines.components(separatedBy: "\n"))
                return .clean(merged: result.joined(separator: "\n"))
            }
        }

        // No common line between any pair → genuine conflict.
        return .conflict
    }

    /// Helper for Case 2 (not currently used — the logic is inlined above).
    private static func tiForBase(base: [String], theirs: [String], baseIdx: Int) -> Int {
        return theirs.count  // placeholder
    }

    /// Split at a common line between ours and theirs (Case 1).
    private static func splitAtCommon(
        base: [String], ours: [String], theirs: [String],
        oursIdx: Int, theirsIdx: Int, commonLine: String
    ) -> Result {
        let oursBefore = Array(ours[..<oursIdx])
        let theirsBefore = Array(theirs[..<theirsIdx])

        if let bi = base.firstIndex(of: commonLine) {
            let baseBefore = Array(base[..<bi])
            let beforeResult = mergeChunk(base: baseBefore, ours: oursBefore, theirs: theirsBefore)
            guard case .clean(let beforeLines) = beforeResult else { return .conflict }

            let baseAfter = Array(base[(bi+1)...])
            let oursAfter = Array(ours[(oursIdx+1)...])
            let theirsAfter = Array(theirs[(theirsIdx+1)...])
            let afterResult = interleavedMerge(base: baseAfter, ours: oursAfter, theirs: theirsAfter)
            guard case .clean(let afterLines) = afterResult else { return .conflict }

            var result = beforeLines.components(separatedBy: "\n")
            result.append(commonLine)
            result.append(contentsOf: afterLines.components(separatedBy: "\n"))
            return .clean(merged: result.joined(separator: "\n"))
        }
        // Common line not in base (added by both sides).
        let beforeResult = mergeChunk(base: [], ours: oursBefore, theirs: theirsBefore)
        guard case .clean(let beforeLines) = beforeResult else { return .conflict }
        let baseAfter = base
        let oursAfter = Array(ours[(oursIdx+1)...])
        let theirsAfter = Array(theirs[(theirsIdx+1)...])
        let afterResult = interleavedMerge(base: baseAfter, ours: oursAfter, theirs: theirsAfter)
        guard case .clean(let afterLines) = afterResult else { return .conflict }
        var result = beforeLines.components(separatedBy: "\n")
        result.append(commonLine)
        result.append(contentsOf: afterLines.components(separatedBy: "\n"))
        return .clean(merged: result.joined(separator: "\n"))
    }

    /// Find the first line that appears in both arrays. Returns (oursIndex,
    /// theirsIndex).
    private static func findFirstCommonLine(_ ours: [String], _ theirs: [String]) -> (Int, Int)? {
        for (oi, line) in ours.enumerated() {
            if let ti = theirs.firstIndex(of: line) {
                return (oi, ti)
            }
        }
        return nil
    }

    // MARK: - LCS (unused — kept for future section-aware merge)

    // The current algorithm finds common lines across all three sequences
    // directly (findNextCommonLine). The LCS-based approach was used by the
    // earlier stable-point algorithm but is no longer needed. Future
    // section-aware diff3 (heading-scoped merge) may reuse it.
}
