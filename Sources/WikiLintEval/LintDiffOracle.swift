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

        // 4. Full-body replacement: a single hunk covering nearly the whole
        //    original is a rewrite disguised as a repair.
        let bodyBytes = original.utf8.count
        if let pair = hunks.first, hunks.count == 1,
           bodyBytes > 0,
           Double(pair.hunk.endByte - pair.hunk.startByte)
               >= Double(bodyBytes) * 0.8 {
            rejections.append(.fullBodyReplacement)
        }

        // 5. Declaration match — mechanical fixtures only: every hunk must
        //    pair its class with the fixture's exact old/new texts. Judgment
        //    fixtures defer to human review (the oracle only rejects the
        //    known-bad shapes above).
        if fixture.kind == "mechanical" {
            for (index, pair) in hunks.enumerated() {
                let attributed = pair.defectClass
                let declared = fixture.allowedRepairs.first {
                    $0.defectClass == attributed.rawValue && $0.oldText == pair.hunk.oldText
                }
                switch declared {
                case .some(let repair) where repair.newText == pair.hunk.newText:
                    continue
                default:
                    rejections.append(.undeclaredRepair(hunkIndex: index))
                }
            }
        }

        if rejections.isEmpty { return .accepted }
        return Verdict(accepted: false, rejections: rejections)
    }

    /// Apply hunks (original coordinates, reverse order) to a body — the
    /// same shape the patch write uses, for oracle reproduction. Public so
    /// the harness tests can compose expected outcomes from declared
    /// repairs without re-implementing the application.
    public static func apply(hunks: [PagePatchHunk], to original: String) -> String {
        var bytes = Array(original.utf8)
        for hunk in hunks.sorted(by: { $0.startByte > $1.startByte }) {
            let start = hunk.startByte
            let end = hunk.endByte
            guard start >= 0, end <= bytes.count, start <= end else { continue }
            bytes.replaceSubrange(start..<end, with: Array(hunk.newText.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
