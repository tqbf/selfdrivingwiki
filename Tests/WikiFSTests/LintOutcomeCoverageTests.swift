import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// AC.10 (coverage half): the strict per-item accounting contract — omitted,
/// duplicated, unknown, wrong-head, and contradictory outcomes are rejected;
/// every named audit step is required; the verification gate compares the
/// WRITTEN head, never the moving head.
struct LintOutcomeCoverageTests {

    // MARK: - Fixtures

    private let pageID = PageID(rawValue: "01HZPAGE00000000000000000A")
    private let head = PageVersionID(rawValue: "01HZHEAD00000000000000000001")

    private var snapshot: LintPageSnapshot {
        LintPageSnapshot(
            pageID: pageID, title: "Calvin Cycle", headVersionID: head,
            body: "# Calvin Cycle\n\nSee [[source:Smith2023]].\n", sourceInputs: [])
    }

    /// A tiny deterministic pre-flight: one citation inventory item, one
    /// D08 finding (repairable), one D18 finding (report-only).
    private var preflight: LintPreflightReport {
        let body = "# Calvin Cycle\n\nSee [[source:Smith2023]] and <a onclick=\"x()\">y</a>.\n"
        let snap = LintPageSnapshot(
            pageID: pageID, title: "Calvin Cycle", headVersionID: head, body: body, sourceInputs: [])
        var resolution = LintResolutionFacts()
        resolution.knownSourceIDs = [sourceID.rawValue]
        resolution.sourceIDsByLooseName["smith2023"] = [sourceID]
        return LintPagePreflight.scan(snapshot: snap, resolution: resolution)
    }

    private let sourceID = SourceID(rawValue: "01HZSRC1000000000000000001")

    // MARK: - REQ-29 checklist

    @Test func checklistCoversAllTenSteps() {
        #expect(LintAuditStep.allCases.count == 10, "the approved list has ten numbered checks")
        #expect(Set(LintAuditStep.allCases.map(\.rawValue)).count == 10)
        for step in LintAuditStep.allCases {
            #expect(step.instruction.isEmpty == false)
        }
        // A step can never claim `repaired`; reason-bearing outcomes need one.
        #expect(LintAuditStepOutcome(step: .writeAndVerify, outcome: .repaired).isValid == false)
        #expect(LintAuditStepOutcome(step: .auditMetadata, outcome: .validAsWritten(reason: ""))
            .isValid == false)
        #expect(LintAuditStepOutcome(step: .auditMetadata, outcome: .validAsWritten(reason: "no contract in v1"))
            .isValid)
        #expect(LintAuditStepOutcome(step: .logAndReport, outcome: .checkBlocked(reason: "log write failed"))
            .isValid)
    }

    // MARK: - Render + parse

    @Test func renderListsEveryItemFindingAndCheck() {
        let text = LintRunReportText.render(snapshot: snapshot, preflight: preflight)
        #expect(text.hasPrefix(LintRunReportText.formatMarker))
        #expect(text.contains("page \(pageID.rawValue)"))
        #expect(text.contains("head \(head.rawValue)"))
        #expect(text.contains("inventory source-citations 1"))
        #expect(text.contains("check read-body-and-head pending"))
        #expect(text.contains("finding D08-1 pending"))
        #expect(text.contains("finding D18-1 pending"))
        #expect(text.contains("verification none pending"))
    }

    @Test func parserRoundTripsFilledReport() throws {
        let rendered = LintRunReportText.render(snapshot: snapshot, preflight: preflight)
        var filled = rendered
            .replacingOccurrences(of: "check read-body-and-head pending",
                                  with: "check read-body-and-head valid-as-written|snapshot recorded")
            .replacingOccurrences(of: "finding D08-1 pending",
                                  with: "finding D08-1 repaired")
            .replacingOccurrences(of: "finding D18-1 pending",
                                  with: "finding D18-1 unresolved|needs human judgment")
            .replacingOccurrences(of: "verification none pending",
                                  with: "verification none clean")
        filled = filled
            .replacingOccurrences(of: "item sourceCitation-1 pending",
                                  with: "item sourceCitation-1 repaired")
        let parsed = try LintRunReportParser.parse(filled)
        #expect(parsed.pageID == pageID)
        #expect(parsed.headVersionID == head)
        #expect(parsed.inventoryCounts.sourceCitations == 1)
        #expect(parsed.verification?.verdict == "clean")
        #expect(parsed.entries.contains { entry in
            if case .finding(let id) = entry.kind { return id == "D08-1" && entry.outcome == .repaired }
            return false
        })
        #expect(parsed.entries.contains { entry in
            if case .item(let id) = entry.kind { return id == "sourceCitation-1" }
            return false
        })
    }

    @Test func parserRejectsMalformedReports() {
        // Missing marker.
        #expect(throws: LintRunReportParseError.missingFormatMarker.self) {
            try LintRunReportParser.parse("page x\n")
        }
        // Unknown line label.
        let rendered = LintRunReportText.render(snapshot: snapshot, preflight: preflight)
        #expect(throws: LintRunReportParseError.self) {
            try LintRunReportParser.parse(rendered + "free-form prose\n")
        }
        // Duplicate structural lines are parse errors; duplicate CHECKS and
        // FINDINGS parse and are rejected by the coverage validator instead
        // (see rejectsMissingDuplicateUnknownAndStaleItems).
        #expect(throws: LintRunReportParseError.self) {
            try LintRunReportParser.parse(rendered + "head 01HZDUP00000000000000000009\n")
        }
    }

    // MARK: - Coverage validation (REQ-31/32)

    /// Build a fully-covered report text from the skeleton, applying
    /// per-line overrides.
    private func filledReport(
        overrides: [String: String] = [:],
        dropLines: [String] = [],
        extraLines: [String] = [],
        page: PageID? = nil,
        headLine: String? = nil
    ) -> String {
        let rendered = LintRunReportText.render(
            snapshot: page.map { LintPageSnapshot(pageID: $0, title: "t", headVersionID: head, body: "b", sourceInputs: []) } ?? snapshot,
            preflight: preflight)
        var lines = rendered.split(separator: "\n").map(String.init)
        if let headLine {
            lines = lines.map { $0.hasPrefix("head ") ? headLine : $0 }
        }
        for (prefix, replacement) in overrides {
            lines = lines.map { line in
                line.hasPrefix(prefix) ? replacement : line
            }
        }
        lines.removeAll { line in dropLines.contains { line.hasPrefix($0) } }
        lines.append(contentsOf: extraLines)
        return lines.joined(separator: "\n") + "\n"
    }

    private func verdict(for text: String) -> LintCoverageVerdict {
        do {
            let parsed = try LintRunReportParser.parse(text)
            return LintCoverageValidator.validate(parsed: parsed, snapshot: snapshot, preflight: preflight)
        } catch {
            Issue.record("fixture report failed to parse: \(error) — text:\n\(text)")
            return .rejected(reasons: ["fixture unparseable"])
        }
    }

    @Test func completeReportIsAccepted() {
        guard case .complete = verdict(for: filledReport(overrides: [
            "finding D08-1": "finding D08-1 repaired",
            "finding D18-1": "finding D18-1 unresolved|needs human judgment",
            "check audit-metadata": "check audit-metadata valid-as-written|no contract in v1",
            "check write-and-verify": "check write-and-verify valid-as-written|no hunks needed",
            "verification": "verification none clean",
        ])) else {
            Issue.record("a fully covered report must be accepted")
            return
        }
    }

    @Test func rejectsMissingDuplicateUnknownAndStaleItems() {
        // MISSING — an item without an outcome.
        if case .rejected(let reasons) = verdict(for: filledReport(dropLines: ["item sourceCitation-1"])) {
            #expect(reasons.contains { $0.contains("no outcome for sourceCitation-1") })
        } else {
            Issue.record("a dropped item outcome must be rejected")
        }
        // DUPLICATE — the same finding reported twice.
        if case .rejected(let reasons) = verdict(for: filledReport(
            overrides: ["finding D08-1": "finding D08-1 repaired"],
            extraLines: ["finding D08-1 repaired"])) {
            #expect(reasons.contains { $0.contains("duplicate outcome for D08-1") })
        } else {
            Issue.record("a duplicated outcome must be rejected")
        }
        // UNKNOWN — an occurrence the inventory never emitted.
        if case .rejected(let reasons) = verdict(for: filledReport(
            extraLines: ["finding fence-99 repaired"])) {
            #expect(reasons.contains { $0.contains("unknown occurrence fence-99") })
        } else {
            Issue.record("an unknown occurrence must be rejected")
        }
        // STALE — the report names the wrong head.
        if case .rejected(let reasons) = verdict(for: filledReport(
            headLine: "head 01HZSTALE0000000000000000009")) {
            #expect(reasons.contains { $0.contains("not the inspected") })
        } else {
            Issue.record("a stale head must be rejected")
        }
        // WRONG PAGE.
        if case .rejected(let reasons) = verdict(for: filledReport(
            page: PageID(rawValue: "01HZOTHER000000000000000000B"))) {
            #expect(reasons.contains { $0.contains("not the audited") })
        } else {
            Issue.record("a wrong-page report must be rejected")
        }
    }

    @Test func rejectsContradictoryOutcomesAndMissingSteps() {
        // repaired on a report-only class.
        if case .rejected(let reasons) = verdict(for: filledReport(overrides: [
            "finding D18-1": "finding D18-1 repaired",
            "finding D08-1": "finding D08-1 unresolved|no safe repair",
        ])) {
            #expect(reasons.contains { $0.contains("report-only") && $0.contains("D18-1") })
        } else {
            Issue.record("repaired on a report-only finding must be rejected")
        }
        // A dropped audit step.
        if case .rejected(let reasons) = verdict(for: filledReport(dropLines: ["check audit-content-integrity"])) {
            #expect(reasons.contains { $0.contains("audit-content-integrity reported 0 times") })
        } else {
            Issue.record("a missing audit step must be rejected")
        }
        // A step claiming repaired.
        if case .rejected(let reasons) = verdict(for: filledReport(
            overrides: ["check write-and-verify": "check write-and-verify repaired"])) {
            #expect(reasons.contains { $0.contains("cannot claim repaired") })
        } else {
            Issue.record("a repaired check outcome must be rejected")
        }
        // Inventory counts that disagree with the pre-flight.
        if case .rejected(let reasons) = verdict(for: filledReport(
            overrides: ["inventory tables": "inventory tables 5"])) {
            #expect(reasons.contains { $0.contains("do not match the pre-flight inventory") })
        } else {
            Issue.record("wrong inventory counts must be rejected")
        }
    }

    // MARK: - Verification gate (REQ-54)

    private func rescan(of body: String) -> LintPreflightReport {
        let snap = LintPageSnapshot(
            pageID: pageID, title: "Calvin Cycle", headVersionID: head, body: body, sourceInputs: [])
        var resolution = LintResolutionFacts()
        resolution.knownSourceIDs = [sourceID.rawValue]
        resolution.sourceIDsByLooseName["smith2023"] = [sourceID]
        return LintPagePreflight.scan(snapshot: snap, resolution: resolution)
    }

    @Test func writtenHeadIsWhatVerifiesNotTheMovingHead() {
        let before = preflight
        // The D08 citation canonicalization repaired; D18 untouched.
        let writtenBody = "# Calvin Cycle\n\nSee [[source:01HZSRC1000000000000000001]] and <a onclick=\"x()\">y</a>.\n"
        let written = rescan(of: writtenBody)
        // The hunk covers the citation span in the PRE body (bytes 20..40).
        let hunk = PagePatchHunk(
            startByte: 20, endByte: 40, oldText: "old", newText: "new", reason: "test")
        // Current head has moved past the written one.
        let movingHead = PageVersionID(rawValue: "01HZNEWHEAD000000000000000001")
        let verdict = LintVerification.compare(
            before: before, written: written, appliedHunks: [hunk],
            claimedRepairFindingIDs: ["D08-1"],
            writtenHead: head, currentHead: movingHead, requiredChecksAvailable: true)
        if case .verifiedWrittenHeadDiverged(let current) = verdict.status {
            #expect(current == movingHead)
        } else {
            Issue.record("a verified written head under a moving head must be recorded as divergence, got \(verdict.status)")
        }
    }

    @Test func boundaryRepairExposesLaterDefectCountsAsNewFinding() {
        let before = preflight
        // A repair rewrites text and exposes a new defect the before-scan
        // never saw.
        let written = rescan(of: "# Calvin Cycle\n\nBroken [[table:shape here.\n")
        let hunk = PagePatchHunk(startByte: 20, endByte: 40, oldText: "old", newText: "new", reason: "test")
        let verdict = LintVerification.compare(
            before: before, written: written, appliedHunks: [hunk],
            claimedRepairFindingIDs: ["D08-1"],
            writtenHead: head, currentHead: head, requiredChecksAvailable: true)
        if case .failed(let reasons) = verdict.status {
            #expect(reasons.contains { $0.contains("new finding") })
        } else {
            Issue.record("an exposed defect must prevent verified success")
        }
    }

    @Test func claimedRepairThatPersistsFails() {
        let before = preflight
        // Identical bytes to the pre-scan: nothing actually changed.
        let written = rescan(
            of: "# Calvin Cycle\n\nSee [[source:Smith2023]] and <a onclick=\"x()\">y</a>.\n")
        let verdict = LintVerification.compare(
            before: before, written: written, appliedHunks: [],
            claimedRepairFindingIDs: ["D08-1"],
            writtenHead: head, currentHead: head, requiredChecksAvailable: true)
        // The D08 finding persists untouched — the claimed repair cannot hold.
        guard case .failed(let reasons) = verdict.status else {
            Issue.record("a claimed repair over unchanged bytes cannot verify")
            return
        }
        #expect(reasons.contains { $0.contains("claimed repair for D08-1") })
    }

    @Test func unavailableRequiredCheckPreventsVerifiedSuccess() {
        let before = preflight
        let written = rescan(of: "# Calvin Cycle\n\nSee [[source:01HZSRC1000000000000000001]] clean.\n")
        let hunk = PagePatchHunk(startByte: 20, endByte: 40, oldText: "old", newText: "new", reason: "test")
        let verdict = LintVerification.compare(
            before: before, written: written, appliedHunks: [hunk],
            claimedRepairFindingIDs: ["D08-1"],
            writtenHead: head, currentHead: head, requiredChecksAvailable: false)
        if case .failed(let reasons) = verdict.status {
            #expect(reasons.contains { $0.contains("unavailable") })
        } else {
            Issue.record("an unavailable required check must prevent verified success")
        }
    }

    @Test func cleanPassVerifies() {
        let before = preflight
        // The written body has neither finding; the hunk covers the citation.
        let written = rescan(of: "# Calvin Cycle\n\nSee [[source:01HZSRC1000000000000000001]] safely.\n")
        let hunk = PagePatchHunk(startByte: 20, endByte: 40, oldText: "old", newText: "new", reason: "test")
        let verdict = LintVerification.compare(
            before: before, written: written, appliedHunks: [hunk],
            claimedRepairFindingIDs: ["D08-1"],
            writtenHead: head, currentHead: head, requiredChecksAvailable: true)
        guard case .verified = verdict.status else {
            Issue.record("expected a verified verdict, got \(verdict.status)")
            return
        }
        #expect(verdict.remainingFindings.isEmpty)
    }
}
