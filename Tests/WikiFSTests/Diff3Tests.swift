import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure diff3 merge engine (W2, PR #312).
struct Diff3Tests {

    @Test func mergeBothSidesChangedDifferentRegions() {
        // Base: A\nB\nC. Ours added X at top. Theirs added Y at bottom.
        let result = Diff3.merge(
            base: "A\nB\nC",
            ours: "X\nA\nB\nC",
            theirs: "A\nB\nC\nY")
        if case .clean(let merged) = result {
            #expect(merged.contains("X"))
            #expect(merged.contains("A"))
            #expect(merged.contains("B"))
            #expect(merged.contains("C"))
            #expect(merged.contains("Y"))
        } else {
            Issue.record("expected clean merge, got conflict")
        }
    }

    @Test func mergeBothSidesMadeSameChange() {
        let result = Diff3.merge(
            base: "A\nB\nC",
            ours: "A\nB2\nC",
            theirs: "A\nB2\nC")
        if case .clean(let merged) = result {
            #expect(merged == "A\nB2\nC")
        } else {
            Issue.record("expected clean merge, got conflict")
        }
    }

    @Test func mergeOnlyOursChanged() {
        let result = Diff3.merge(
            base: "A\nB\nC",
            ours: "A\nB\nC\nD",
            theirs: "A\nB\nC")
        if case .clean(let merged) = result {
            #expect(merged == "A\nB\nC\nD")
        } else {
            Issue.record("expected clean merge")
        }
    }

    @Test func mergeOnlyTheirsChanged() {
        let result = Diff3.merge(
            base: "A\nB\nC",
            ours: "A\nB\nC",
            theirs: "A\nB\nD")
        if case .clean(let merged) = result {
            #expect(merged == "A\nB\nD")
        } else {
            Issue.record("expected clean merge")
        }
    }

    @Test func mergeConflictWhenBothChangedSameLineDifferently() {
        let result = Diff3.merge(
            base: "A\nB\nC",
            ours: "A\nOURS\nC",
            theirs: "A\nTHEIRS\nC")
        #expect(result == .conflict)
    }

    @Test func mergeNoChanges() {
        let result = Diff3.merge(base: "A\nB", ours: "A\nB", theirs: "A\nB")
        if case .clean(let merged) = result {
            #expect(merged == "A\nB")
        } else {
            Issue.record("expected clean merge")
        }
    }

    @Test func mergeEmptyBase() {
        // Both sides add content to an empty base → conflict (both changed
        // the same region differently).
        let result = Diff3.merge(base: "", ours: "ours content", theirs: "theirs content")
        #expect(result == .conflict)
    }

    @Test func mergeEmptyBaseSameContent() {
        let result = Diff3.merge(base: "", ours: "same", theirs: "same")
        if case .clean(let merged) = result {
            #expect(merged == "same")
        } else {
            Issue.record("expected clean merge")
        }
    }

    @Test func mergeLargeFileWithOverlappingChanges() {
        // 10 lines, ours changes line 3, theirs changes line 7.
        let base = (0..<10).map { "line\($0)" }.joined(separator: "\n")
        var oursLines = base.components(separatedBy: "\n")
        oursLines[2] = "ours-line3"
        var theirsLines = base.components(separatedBy: "\n")
        theirsLines[6] = "theirs-line7"

        let result = Diff3.merge(
            base: base,
            ours: oursLines.joined(separator: "\n"),
            theirs: theirsLines.joined(separator: "\n"))

        if case .clean(let merged) = result {
            #expect(merged.contains("ours-line3"))
            #expect(merged.contains("theirs-line7"))
            #expect(merged.contains("line0"))
            #expect(merged.contains("line9"))
        } else {
            Issue.record("expected clean merge")
        }
    }
}
