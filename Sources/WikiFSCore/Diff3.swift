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

        let oursMatches = lcsMatch(base: baseLines, other: oursLines)
        let theirsMatches = lcsMatch(base: baseLines, other: theirsLines)

        return chunkMerge(
            baseLines: baseLines, oursLines: oursLines, theirsLines: theirsLines,
            oursMatches: oursMatches, theirsMatches: theirsMatches)
    }

    // MARK: - Chunk-based merge (the actual algorithm)

    /// The classic diff3 algorithm: walk all three arrays, identifying
    /// "stable" regions (where base is matched in both ours and theirs) and
    /// "unstable" gaps between them. Classify each gap as clean or conflict.
    private static func chunkMerge(
        baseLines: [String], oursLines: [String], theirsLines: [String],
        oursMatches: [Int?], theirsMatches: [Int?]
    ) -> Result {
        // Build the matched-index arrays. oursMatches[baseIndex] = oursIndex
        // if that base line appears in ours at that position (LCS).
        var result: [String] = []
        var hasConflict = false

        // Walk through base, ours, theirs simultaneously.
        // At each step, either all three are at a matched line (stable) or
        // we're in a gap (unstable).
        var bi = 0, oi = 0, ti = 0

        while bi < baseLines.count || oi < oursLines.count || ti < theirsLines.count {
            // Find the next "stable point" — a base line that is matched in
            // both ours and theirs at or after the current positions.
            let stableBase = findNextStablePoint(
                bi, oi, ti, baseLines.count, oursLines.count, theirsLines.count,
                oursMatches, theirsMatches)

            if let (sb, so, st) = stableBase {
                // Unstable region before the stable point.
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

                // Add the stable line (same in all three).
                result.append(baseLines[sb])

                bi = sb + 1
                oi = so + 1
                ti = st + 1
            } else {
                // No more stable points — merge the trailing chunks.
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

    /// Find the next base line that is matched in BOTH ours and theirs at or
    /// after the current positions. Returns (baseIndex, oursIndex, theirsIndex).
    private static func findNextStablePoint(
        _ bi: Int, _ oi: Int, _ ti: Int,
        _ baseCount: Int, _ oursCount: Int, _ theirsCount: Int,
        _ oursMatches: [Int?], _ theirsMatches: [Int?]
    ) -> (Int, Int, Int)? {
        var b = bi
        while b < baseCount {
            if let o = oursMatches[b], o >= oi,
               let t = theirsMatches[b], t >= ti {
                return (b, o, t)
            }
            b += 1
        }
        return nil
    }

    /// Merge one unstable chunk. Returns the merged lines, or .conflict.
    private static func mergeChunk(base: [String], ours: [String], theirs: [String]) -> Result {
        if ours == theirs {
            // Both sides made the same change → take it.
            return .clean(merged: ours.joined(separator: "\n"))
        }
        if base == ours {
            // Only theirs changed → take theirs.
            return .clean(merged: theirs.joined(separator: "\n"))
        }
        if base == theirs {
            // Only ours changed → take ours.
            return .clean(merged: ours.joined(separator: "\n"))
        }
        // Both changed differently → conflict.
        return .conflict
    }

    // MARK: - LCS

    /// Compute the LCS match array: for each base line index, the index in
    /// `other` it matches (or nil if unmatched). This is the standard
    /// dynamic-programming LCS, O(n*m) in time and space.
    private static func lcsMatch(base: [String], other: [String]) -> [Int?] {
        let n = base.count
        let m = other.count

        // DP table.
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...max(n, 0) {
            guard i <= n else { break }
            for j in 1...max(m, 0) {
                guard j <= m else { break }
                if base[i - 1] == other[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find matched pairs.
        var matches = Array(repeating: Int?.none, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if base[i - 1] == other[j - 1] {
                matches[i - 1] = j - 1
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matches
    }
}
