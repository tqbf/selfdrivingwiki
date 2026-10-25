import Foundation

/// The per-run patch budget for a repair-capable selected-page lint run: a
/// coordinator POLICY, not a format limit. `PagePatchValidator` keeps its own
/// payload ceiling for every caller (wikictl included); this budget only
/// caps how much one managed lint run may change, scaled by how many
/// confirmed repairable findings the inspected page had.
///
/// The trusted daemon checks a patch against the budget BEFORE the patch
/// reaches the store. Above the cap the WHOLE patch is rejected (the patch
/// path is already all-or-nothing) and the run's write phase closes.
public struct LintPatchBudget: Hashable, Sendable {

    // MARK: - Tuning

    /// Hunks allowed per confirmed repairable finding. Most repairs are one
    /// hunk; a fence or wrapper repair touches the open and the close, and a
    /// citation repair may also touch its footnote — three covers those.
    public static let hunksPerFinding = 3
    /// Hunk floor, so a page with zero to two confirmed findings can still
    /// take a small judgment repair without being blocked.
    public static let minimumHunks = 8
    /// Hunk ceiling. Past this a run is rewriting the page, not repairing it.
    public static let maximumHunks = 48

    /// Changed bytes allowed per confirmed repairable finding. Covers
    /// rewriting a damaged table row, a fence body line, or a footnote.
    public static let changedBytesPerFinding = 2_048
    /// Changed-byte floor for small pages (same rationale as `minimumHunks`).
    public static let minimumChangedBytes = 8_192
    /// Changed-byte ceiling: no single lint run may change more than this,
    /// however many findings the page had.
    public static let maximumChangedBytes = 65_536

    /// The title prefix of the trusted daemon's `--kind lint` audit entry
    /// for a rejected patch. Host accounting reads it back to mark the run's
    /// write phase not performed; it is never counted as the agent's log.
    public static let auditTitlePrefix = "Lint patch budget exceeded — "

    // MARK: - Budget

    public let maxHunks: Int
    public let maxChangedBytes: Int

    public init(maxHunks: Int, maxChangedBytes: Int) {
        self.maxHunks = maxHunks
        self.maxChangedBytes = maxChangedBytes
    }

    /// The budget for a run whose inspected page had `findings` confirmed
    /// repairable findings, clamped to the floors and ceilings above.
    public init(confirmedRepairableFindings findings: Int) {
        let count = max(0, findings)
        self.init(
            maxHunks: min(Self.maximumHunks, max(Self.minimumHunks, count * Self.hunksPerFinding)),
            maxChangedBytes: min(
                Self.maximumChangedBytes,
                max(Self.minimumChangedBytes, count * Self.changedBytesPerFinding)))
    }

    /// The budget for an inspected page's pre-flight scan.
    public init(preflight: LintPreflightReport) {
        self.init(confirmedRepairableFindings: Self.confirmedRepairableCount(in: preflight))
    }

    /// Findings the detectors CONFIRMED (not candidates) whose class the
    /// policy lets a lint run repair.
    public static func confirmedRepairableCount(in report: LintPreflightReport) -> Int {
        report.sections.flatMap(\.findings).filter { finding in
            finding.confidence == .confirmed && finding.defectClass.repairPolicy == .repairable
        }.count
    }

    // MARK: - Usage

    /// Hunks and changed bytes — what a patch asks for or a run has spent.
    public struct Usage: Hashable, Sendable {
        public var hunks: Int
        public var changedBytes: Int

        public init(hunks: Int, changedBytes: Int) {
            self.hunks = hunks
            self.changedBytes = changedBytes
        }

        public static let zero = Usage(hunks: 0, changedBytes: 0)

        /// Saturating sum: usage values aggregate child-controlled counts,
        /// so an overflow saturates at `Int.max` — which exceeds every cap
        /// and is rejected — instead of wrapping negative or trapping.
        public static func + (lhs: Usage, rhs: Usage) -> Usage {
            func saturating(_ a: Int, _ b: Int) -> Int {
                let (sum, overflow) = a.addingReportingOverflow(b)
                return overflow ? (b > 0 ? Int.max : Int.min) : sum
            }
            return Usage(
                hunks: saturating(lhs.hunks, rhs.hunks),
                changedBytes: saturating(lhs.changedBytes, rhs.changedBytes))
        }
    }

    /// The bytes one exact hunk changes: the replaced span plus the inserted
    /// text. TOTAL for any input: the offsets are child-controlled, so a
    /// malformed (inverted or negative) span counts as zero replaced bytes
    /// — the patch validator rejects it later anyway — and extreme offsets
    /// saturate instead of trapping. Every budget consumer can call this
    /// before range validation without giving a hostile payload a crash.
    public static func changedBytes(startByte: Int, endByte: Int, newText: String) -> Int {
        let replaced: Int
        if startByte < 0 || endByte < startByte {
            replaced = 0
        } else {
            // Both bounds are non-negative and ordered, so the subtraction
            // cannot overflow; the guard keeps that invariant explicit.
            replaced = endByte - startByte
        }
        let (sum, overflow) = replaced.addingReportingOverflow(newText.utf8.count)
        return overflow ? Int.max : sum
    }

    /// Why a patch was rejected, with every number the audit needs.
    public struct Rejection: Hashable, Sendable {
        public let requested: Usage
        public let alreadySpent: Usage
        public let budget: LintPatchBudget

        public init(requested: Usage, alreadySpent: Usage, budget: LintPatchBudget) {
            self.requested = requested
            self.alreadySpent = alreadySpent
            self.budget = budget
        }

        /// The plain-text numbers for audit lines, receipts, and the child.
        public var summary: String {
            "budget_exceeded: patch requested \(requested.hunks) hunks / \(requested.changedBytes) changed bytes; "
                + "run already spent \(alreadySpent.hunks) hunks / \(alreadySpent.changedBytes) bytes; "
                + "run cap \(budget.maxHunks) hunks / \(budget.maxChangedBytes) bytes"
        }
    }

    public enum Verdict: Equatable, Sendable {
        case withinBudget
        case exceeded(Rejection)
    }

    /// Check one patch against the run's budget. A patch that lands EXACTLY
    /// on the cap passes.
    public func check(request: Usage, alreadySpent: Usage) -> Verdict {
        let total = alreadySpent + request
        if total.hunks > maxHunks || total.changedBytes > maxChangedBytes {
            return .exceeded(Rejection(requested: request, alreadySpent: alreadySpent, budget: self))
        }
        return .withinBudget
    }
}
