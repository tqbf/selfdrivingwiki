import Foundation
import WikiFSCore

/// The diff oracle (plan §6.7): judge a run's byte outcome from the
/// SERVER-OBSERVED original/new bytes and the hunks that were actually
/// applied. The oracle rejects known-bad edits and accepts only
/// fixture-declared exact repairs; judgment fixtures defer semantic
/// acceptance to recorded human review.
public enum LintDiffOracle {

    public enum Rejection: Equatable, Sendable {
        /// The recorded hunks do not reproduce the new bytes from the
        /// original — unattributed edits, dropped data, or invented content.
        case hunksDoNotReproduce
        /// A hunk replaced text that was not at its range (already covered
        /// by reproduction, kept for direct callers).
        case oldTextMismatch
        /// The hunk's class does not match a fixture-declared repair.
        case wrongClassAttribution(hunkIndex: Int)
        /// A hunk touches bytes the fixture protects.
        case touchesProtectedBytes(hunkIndex: Int)
        /// A single hunk replaces the whole body — a full-body rewrite
        /// disguised as a local repair.
        case fullBodyReplacement
        /// A mechanical fixture's repair text differs from its declaration.
        case undeclaredRepair(hunkIndex: Int)
    }

    public struct Verdict: Equatable, Sendable {
        public let accepted: Bool
        public let rejections: [Rejection]

        public static let accepted = Verdict(accepted: true, rejections: [])
    }

    /// Verify one run's byte outcome against its fixture.
    ///
    /// - `original`/`new`: the server-observed bytes (seeded body, final body).
    /// - `hunks`: the hunks the patch write actually applied with their
    ///   classes (submission order, original coordinates).
    /// - `fixture`: the evaluation fixture declaring allowed repairs and
    ///   protected bytes.
    public static func verify(
        original: String,
        new: String,
        hunks: [(hunk: PagePatchHunk, defectClass: LintDefectClass)],
        fixture: LintEvalFixture
    ) -> Verdict {
        var rejections: [Rejection] = []

        // 1. Reproduction: applying the hunks to the original must produce
        //    the new bytes EXACTLY. This single check rules out unattributed
        //    edits, dropped data, invented evidence, and unexpected
        //    canonicalization (bytes outside hunk ranges must be identical).
        let reproduced = Self.apply(hunks: hunks.map(\.hunk), to: original)
        if reproduced != new {
            rejections.append(.hunksDoNotReproduce)
        }

        // 2. Old text honesty: each hunk's declared oldText must sit exactly
        //    at its range in the original.
        let originalBytes = Array(original.utf8)
        for hunk in hunks.map(\.hunk) {
            let declared = Array(hunk.oldText.utf8)
            guard hunk.startByte >= 0, hunk.endByte <= originalBytes.count,
                  hunk.startByte <= hunk.endByte,
                  Array(originalBytes[hunk.startByte..<hunk.endByte]) == declared else {
                rejections.append(.oldTextMismatch)
                continue
            }
        }

        // 3. Protected bytes: no hunk range may intersect a protected range.
        for (index, pair) in hunks.enumerated() {
            let hunk = pair.hunk
            let touches = fixture.protectedByteRanges.contains {
                hunk.startByte < $0.upperBound && $0.lowerBound < hunk.endByte
            }
            if touches {
                rejections.append(.touchesProtectedBytes(hunkIndex: index))
            }
        }

        // 4. Full-body replacement: hunks whose MERGED coverage spans nearly
        //    the whole original are a rewrite disguised as repairs (review
        //    M9d — two 50% hunks or one 79% hunk no longer evade this).
        let bodyBytes = original.utf8.count
        if bodyBytes > 0 {
            let ranges = hunks.map { pair -> (Int, Int) in
                (max(pair.hunk.startByte, 0), min(pair.hunk.endByte, bodyBytes))
            }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
            var merged: [(start: Int, end: Int)] = []
            for range in ranges {
                if var last = merged.last, range.0 <= last.end {
                    last.end = max(last.end, range.1)
                    merged[merged.count - 1] = last
                } else {
                    merged.append((start: range.0, end: range.1))
                }
            }
            let coveredBytes = merged.reduce(0) { $0 + ($1.end - $1.start) }
            if Double(coveredBytes) >= Double(bodyBytes) * 0.8 {
                rejections.append(.fullBodyReplacement)
            }
        }

        // 5. Declaration match — mechanical fixtures only: every hunk must
        //    pair its class with a fixture-declared exact old/new repair,
        //    and each declaration is CONSUMED once (review M9c — the same
        //    declared repair applied twice, or at a second occurrence of
        //    the same text, no longer passes). Judgment fixtures defer to
        //    human review (the oracle only rejects the known-bad shapes
        //    above).
        if fixture.kind == "mechanical" {
            var consumed: Set<Int> = []
            for (index, pair) in hunks.enumerated() {
                let attributed = pair.defectClass
                let declaredIndex = fixture.allowedRepairs.indices.first { declIndex in
                    guard consumed.contains(declIndex) == false else { return false }
                    let decl = fixture.allowedRepairs[declIndex]
                    return decl.defectClass == attributed.rawValue
                        && decl.oldText == pair.hunk.oldText
                        && decl.newText == pair.hunk.newText
                }
                guard let declIndex = declaredIndex else {
                    rejections.append(.undeclaredRepair(hunkIndex: index))
                    continue
                }
                consumed.insert(declIndex)
            }
        }

        if rejections.isEmpty { return .accepted }
        return Verdict(accepted: false, rejections: rejections)
    }

    /// Apply hunks to a body — the SAME concatenation composer the patch
    /// write uses (sorted by (start, end), gaps copied from the original),
    /// so oracle reproduction can never accept an application-order
    /// artifact the store would not produce. Public so the harness tests
    /// can compose expected outcomes from declared repairs without
    /// re-implementing the application.
    public static func apply(hunks: [PagePatchHunk], to original: String) -> String {
        let bytes = Array(original.utf8)
        var composed = String()
        composed.reserveCapacity(bytes.count)
        var cursor = 0
        for hunk in hunks.sorted(by: { $0.startByte == $1.startByte ? $0.endByte < $1.endByte : $0.startByte < $1.startByte }) {
            guard hunk.startByte >= cursor, hunk.endByte <= bytes.count, hunk.startByte <= hunk.endByte
            else { continue }
            composed += String(decoding: bytes[cursor..<hunk.startByte], as: UTF8.self)
            composed += hunk.newText
            cursor = hunk.endByte
        }
        composed += String(decoding: bytes[cursor...], as: UTF8.self)
        return composed
    }
}
