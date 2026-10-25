import Foundation
import Testing
@testable import WikiFSCore

/// W2a §3: the per-run patch budget is a coordinator policy that scales with
/// the inspected page's confirmed repairable findings, bounded by named
/// floors and ceilings.
struct LintPatchBudgetTests {

    @Test func smallRunsGetTheFloor() {
        let budget = LintPatchBudget(confirmedRepairableFindings: 0)
        #expect(budget.maxHunks == LintPatchBudget.minimumHunks)
        #expect(budget.maxChangedBytes == LintPatchBudget.minimumChangedBytes)
        // A negative count (never produced) is treated as zero.
        #expect(LintPatchBudget(confirmedRepairableFindings: -3) == budget)
    }

    @Test func budgetScalesWithFindings() {
        let findings = 10
        let budget = LintPatchBudget(confirmedRepairableFindings: findings)
        #expect(budget.maxHunks == findings * LintPatchBudget.hunksPerFinding)
        #expect(budget.maxChangedBytes == findings * LintPatchBudget.changedBytesPerFinding)
    }

    @Test func hugeRunsAreCappedByTheCeiling() {
        let budget = LintPatchBudget(confirmedRepairableFindings: 10_000)
        #expect(budget.maxHunks == LintPatchBudget.maximumHunks)
        #expect(budget.maxChangedBytes == LintPatchBudget.maximumChangedBytes)
    }

    @Test func exactlyAtTheCapPasses() {
        let budget = LintPatchBudget(maxHunks: 4, maxChangedBytes: 100)
        #expect(budget.check(
            request: .init(hunks: 4, changedBytes: 100), alreadySpent: .zero) == .withinBudget)
        // Spent + requested lands exactly on the cap: still within budget.
        #expect(budget.check(
            request: .init(hunks: 1, changedBytes: 40),
            alreadySpent: .init(hunks: 3, changedBytes: 60)) == .withinBudget)
    }

    @Test func oneOverEitherCapIsRejectedWithTheNumbers() {
        let budget = LintPatchBudget(maxHunks: 4, maxChangedBytes: 100)
        let overHunks = budget.check(request: .init(hunks: 5, changedBytes: 10), alreadySpent: .zero)
        #expect(overHunks == .exceeded(.init(
            requested: .init(hunks: 5, changedBytes: 10), alreadySpent: .zero, budget: budget)))
        let spent = LintPatchBudget.Usage(hunks: 1, changedBytes: 90)
        guard case .exceeded(let rejection) = budget.check(
            request: .init(hunks: 1, changedBytes: 11), alreadySpent: spent) else {
            Issue.record("101 changed bytes must exceed a 100-byte cap")
            return
        }
        #expect(rejection.summary.contains("budget_exceeded"))
        #expect(rejection.summary.contains("patch requested 1 hunks / 11 changed bytes"))
        #expect(rejection.summary.contains("run already spent 1 hunks / 90 bytes"))
        #expect(rejection.summary.contains("run cap 4 hunks / 100 bytes"))
    }

    @Test func changedBytesCountTheReplacedSpanPlusTheInsertion() {
        #expect(LintPatchBudget.changedBytes(startByte: 10, endByte: 18, newText: "new text") == 16)
        #expect(LintPatchBudget.changedBytes(startByte: 5, endByte: 5, newText: "é") == 2)
        // An inverted span counts as zero replaced bytes.
        #expect(LintPatchBudget.changedBytes(startByte: 9, endByte: 3, newText: "") == 0)
    }

    // MARK: - Total arithmetic (offsets are child-controlled)

    /// The budget math must be callable on RAW wire offsets — before any
    /// range validation — without trapping: extreme offsets cost a
    /// rejection, never a crash.
    @Test func changedBytesIsTotalForExtremeOffsets() {
        // Negative or Int.min-style offsets count zero replaced bytes.
        #expect(LintPatchBudget.changedBytes(startByte: Int.min, endByte: 0, newText: "") == 0)
        #expect(LintPatchBudget.changedBytes(startByte: -1, endByte: 5, newText: "") == 0)
        // A huge ordered span saturates at Int.max instead of overflowing.
        #expect(
            LintPatchBudget.changedBytes(startByte: 0, endByte: Int.max, newText: "") == Int.max)
        #expect(
            LintPatchBudget.changedBytes(startByte: 0, endByte: Int.max, newText: "abcdefgh")
                == Int.max)
    }

    @Test func usageAdditionSaturatesInsteadOfOverflowing() {
        let huge = LintPatchBudget.Usage(hunks: Int.max - 1, changedBytes: Int.max - 1)
        let sum = huge + huge
        #expect(sum.hunks == Int.max)
        #expect(sum.changedBytes == Int.max)
        // The check stays a REJECTION — a wraparound can never read as a pass.
        let budget = LintPatchBudget(maxHunks: 10, maxChangedBytes: 10)
        guard case .exceeded = budget.check(request: huge, alreadySpent: huge) else {
            Issue.record("a saturating sum past the cap must reject")
            return
        }
    }

    @Test func onlyConfirmedRepairableFindingsCount() {
        let snapshot = LintPageSnapshot(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000B"), title: "Budget",
            headVersionID: PageVersionID(rawValue: "01HZHEAD00000000000000000009"),
            body: "# Budget\n\nPlain text with nothing to repair.\n", sourceInputs: [])
        let clean = LintPagePreflight.scan(snapshot: snapshot, resolution: LintResolutionFacts())
        #expect(LintPatchBudget.confirmedRepairableCount(in: clean) == 0)
        #expect(LintPatchBudget(preflight: clean) == LintPatchBudget(confirmedRepairableFindings: 0))
        let expected = clean.sections.flatMap(\.findings).filter {
            $0.confidence == .confirmed && $0.defectClass.repairPolicy == .repairable
        }.count
        #expect(LintPatchBudget.confirmedRepairableCount(in: clean) == expected)
    }
}
