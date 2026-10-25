import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// The staged-proposal review section's SwiftUI-drawn strings and visibility
/// rules, pinned as pure values (the hosted suite pins the AppKit wiring;
/// these pin the words). The inputs are the durable record texts the W5a
/// accounting writes and the audit entries the apply service appends.
@Suite("Lint proposal section values")
@MainActor
struct LintProposalSectionValueTests {

    private let v1 = PageVersionID(rawValue: "v1")
    private let v2 = PageVersionID(rawValue: "v2")
    private let pageA = PageID(rawValue: "pa")
    private let pageB = PageID(rawValue: "pb")
    private let wikiID = WikiID(rawValue: "w")

    // MARK: - Builders

    private func proposal(
        _ id: String, page: PageID, head: PageVersionID = PageVersionID(rawValue: "v1"),
        hunks: [PagePatchHunk] = []
    ) -> QueueLintStagedProposal {
        QueueLintStagedProposal(
            id: id, pageID: page, stagedAt: Date(timeIntervalSince1970: 100),
            inspectedHead: head, bodyFingerprint: "fp-\(id)",
            hunks: hunks.isEmpty
                ? [PagePatchHunk(startByte: 0, endByte: 2, oldText: "ab", newText: "cd", reason: "D03")]
                : hunks,
            perHunkClasses: [.tableDamage])
    }

    private func tier2Record(
        _ pageID: PageID, title: String, proposalIDs: [String]
    ) -> QueueReportTargetRecord {
        let labels = LintProposalAudit.recordLabels(
            proposals: proposalIDs.map {
                LintProposalAudit.parseStagedNote(
                    LintProposalAudit.stagedNote(
                        proposalID: $0, inspectedHead: PageVersionID(rawValue: "v1"),
                        bodyFingerprint: "fp", hunkCount: 1))!
            })
        return QueueReportTargetRecord(
            target: .page(pageID), displayName: title, state: .succeeded,
            detail: "authority_tier=stagedProposal; authority_reason=not evaluated; "
                + "audited head \(PageVersionID(rawValue: "v1").rawValue); "
                + "run-report coverage complete; verification none; " + labels)
    }

    private func report(
        records: [QueueReportTargetRecord]
    ) -> QueueAttemptReport {
        QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: QueueItem.ID(rawValue: "i"), attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 1),
            operation: .lint,
            scope: .targets(records),
            phase: .finished,
            provider: ProviderID(rawValue: "anthropic"),
            model: QueueReportModelName(rawValue: "claude-opus"),
            availability: .available,
            resultSummary: nil, usage: nil, outputs: nil,
            targets: records)
    }

    private func appliedNote(
        proposalID: String, outcome: String, tail: String = ""
    ) -> LogEntry {
        var note = "proposal_id=\(proposalID); outcome=\(outcome)"
        if tail.isEmpty == false { note += "; \(tail)" }
        return LogEntry(
            id: pageA, timestamp: Date(timeIntervalSince1970: 200), kind: .lint,
            title: LintProposalAudit.appliedAuditTitlePrefix + "Gate page", note: note)
    }

    /// The composed preview body, or nil when composition refused.
    private func projected(
        _ proposal: QueueLintStagedProposal, before: String
    ) -> String? {
        guard case .success(let body) =
            QueueRunDetailsLintProposals.projectedBody(proposal: proposal, before: before)
        else { return nil }
        return body
    }

    // MARK: - Visibility rules

    @Test func sectionRendersOnlyForTier2Runs() throws {
        // No staged proposals in the records → no section at all.
        #expect(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: []),
            ]), wikiID: wikiID) == nil)

        // A whole-wiki (report-only) run → no section.
        #expect(QueueRunDetailsLintProposals.make(
            report: QueueAttemptReport(
                attemptID: QueueAttemptID(itemID: QueueItem.ID(rawValue: "i"), attempt: 0),
                executionID: QueueExecutionID(rawValue: UUID()),
                revision: QueueReportRevision(rawValue: 1),
                operation: .lint, scope: .wholeWiki, phase: .finished,
                provider: nil, model: nil, availability: .available,
                resultSummary: nil, usage: nil, outputs: nil, targets: []),
            wikiID: wikiID) == nil)

        // A tier-2 run with one staged proposal → the section shows the
        // pending row with its review controls.
        let section = try #require(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: ["p1"]),
            ]),
            wikiID: wikiID,
            resolved: [proposal("p1", page: pageA)]))
        #expect(section.showsSection)
        #expect(section.showsReviewControls)
        #expect(section.pendingProposals.count == 1)
        #expect(section.pendingProposals.first?.title == "Gate page")
        #expect(section.pendingProposals.first?.proposal.hunkCount == 1)
        #expect(section.recordedProposalCount == 1)
    }

    @Test func allResolvedCollapsesToOutcomeSummary() throws {
        let outcomes = [
            QueueLintProposalOutcome(proposalID: "p1", kind: .applied, detail: nil),
            QueueLintProposalOutcome(proposalID: "p2", kind: .stale, detail: nil),
        ]
        let section = try #require(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: ["p1"]),
                tier2Record(pageB, title: "Other page", proposalIDs: ["p2"]),
            ]),
            wikiID: wikiID,
            resolved: [proposal("p3", page: pageA)],
            outcomes: outcomes))
        #expect(section.showsSection, "the section stays for the honest summary")
        #expect(section.showsReviewControls == false, "every proposal resolved — no buttons")
        #expect(section.pendingProposals.isEmpty)
        #expect(section.outcomeSummary == "Proposals: 1 applied, 1 stale.")
    }

    @Test func unresolvableStagedIDRendersAsNeither() throws {
        // The daemon's in-memory record is gone and no outcome is durable:
        // the id renders as neither pending nor terminal — nothing pretends
        // to be reviewable, nothing is invented.
        let section = try #require(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: ["gone"]),
            ]),
            wikiID: wikiID))
        #expect(section.pendingProposals.isEmpty)
        #expect(section.outcomeRows.isEmpty)
        #expect(section.showsSection == false)
        #expect(section.recordedProposalCount == 1)
    }

    // MARK: - Aggregate honesty

    @Test func outcomeSummaryCountsEveryKindOnce() {
        let outcomes = [
            QueueLintProposalOutcome(proposalID: "p1", kind: .applied, detail: nil),
            QueueLintProposalOutcome(proposalID: "p2", kind: .applied, detail: nil),
            QueueLintProposalOutcome(proposalID: "p3", kind: .rejected, detail: nil),
            QueueLintProposalOutcome(proposalID: "p4", kind: .failed, detail: "budget"),
        ]
        let section = QueueRunDetailsLintProposals(
            pendingProposals: [], outcomeRows: outcomes,
            recordedProposalCount: 4, wikiID: wikiID)
        #expect(section.outcomeSummary == "Proposals: 2 applied, 1 rejected, 1 failed.")
        #expect(section.showsApproveAll == false)
    }

    @Test func approveAllShowsForMultiplePendingOnly() throws {
        let one = try #require(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: ["p1"]),
            ]),
            wikiID: wikiID, resolved: [proposal("p1", page: pageA)]))
        #expect(one.showsApproveAll == false)

        let two = try #require(QueueRunDetailsLintProposals.make(
            report: report(records: [
                tier2Record(pageA, title: "Gate page", proposalIDs: ["p1"]),
                tier2Record(pageB, title: "Other page", proposalIDs: ["p2"]),
            ]),
            wikiID: wikiID,
            resolved: [proposal("p1", page: pageA), proposal("p2", page: pageB)]))
        #expect(two.showsApproveAll)
    }

    // MARK: - Projected diff composition

    @Test func projectedBodyComposesHunksInMemory() throws {
        let before = "# Title\n\nbroken table\n"
        let tableStart = before.utf8.count - "broken table\n".utf8.count
        let hunk = PagePatchHunk(
            startByte: tableStart, endByte: tableStart + "broken table".utf8.count,
            oldText: "broken table", newText: "fixed table", reason: "D03")
        let staged = proposal("p1", page: pageA, hunks: [hunk])
        let projected = try #require(self.projected(staged, before: before))
        #expect(projected == "# Title\n\nfixed table\n")
    }

    @Test func projectedBodyRejectsMismatchedOldText() {
        let staged = proposal("p1", page: pageA)
        if case .success(let body) = QueueRunDetailsLintProposals.projectedBody(
            proposal: staged, before: "zz") {
            Issue.record("a mismatched oldText must not compose: \(body)")
        }
    }

    @Test func projectedBodyPreviewsNoOpAsUnchanged() throws {
        let before = "ab"
        let hunk = PagePatchHunk(
            startByte: 0, endByte: 2, oldText: "ab", newText: "ab", reason: "D03")
        let staged = proposal("p1", page: pageA, hunks: [hunk])
        let projected = try #require(self.projected(staged, before: before))
        #expect(projected == before, "a no-op proposal previews as the unchanged body")
    }

    // MARK: - Durable outcome re-read

    @Test func parseAppliedOutcomeReadsTheLatestEntryByID() throws {
        let entries = [
            appliedNote(proposalID: "other", outcome: "applied"),
            appliedNote(proposalID: "p1", outcome: "stale",
                        tail: "current_head=\(v2.rawValue)"),
            appliedNote(proposalID: "p1", outcome: "failed",
                        tail: "reason=budget rejected at apply: too many hunks"),
        ]
        let outcome = try #require(
            QueueRunDetailsLintProposals.parseAppliedOutcome(entries: entries, proposalID: "p1"))
        #expect(outcome.kind == .failed, "the LATEST matching entry wins")
        #expect(outcome.detail == "reason=budget rejected at apply: too many hunks")

        let stale = try #require(
            QueueRunDetailsLintProposals.parseAppliedOutcome(
                entries: Array(entries.dropLast()), proposalID: "p1"))
        #expect(stale.kind == .stale)
    }

    @Test func parseAppliedOutcomeMissesGracefully() {
        #expect(QueueRunDetailsLintProposals.parseAppliedOutcome(
            entries: [], proposalID: "p1") == nil)
        #expect(QueueRunDetailsLintProposals.parseAppliedOutcome(
            entries: [appliedNote(proposalID: "p2", outcome: "applied")],
            proposalID: "p1") == nil)
        // A staged entry (not an applied one) is never parsed as an outcome.
        let staged = LogEntry(
            id: pageA, timestamp: Date(), kind: .lint,
            title: LintProposalAudit.stagedAuditTitlePrefix + "Gate page",
            note: LintProposalAudit.stagedNote(
                proposalID: "p1", inspectedHead: v1, bodyFingerprint: "fp", hunkCount: 1))
        #expect(QueueRunDetailsLintProposals.parseAppliedOutcome(
            entries: [staged], proposalID: "p1") == nil)
    }

    @Test func serviceOutcomeMapsToRows() {
        let applied = QueueRunDetailsLintProposals.outcome(
            from: .applied(writtenHead: v2), proposalID: "p1")
        #expect(applied.kind == .applied)
        let stale = QueueRunDetailsLintProposals.outcome(
            from: .stale(currentHead: v2), proposalID: "p1")
        #expect(stale.kind == .stale)
        let failed = QueueRunDetailsLintProposals.outcome(
            from: .failed(reason: "no hunks approved — nothing to apply"), proposalID: "p1")
        #expect(failed.kind == .failed)
        #expect(failed.detail == "no hunks approved — nothing to apply")
    }

    // MARK: - Row words

    @Test func classLabelsAndStaleMessageAreStable() {
        let staged = QueueLintStagedProposal(
            id: "p1", pageID: pageA, stagedAt: Date(),
            inspectedHead: v1, bodyFingerprint: "fp",
            hunks: [
                PagePatchHunk(startByte: 0, endByte: 1, oldText: "a", newText: "b", reason: "D03"),
                PagePatchHunk(startByte: 2, endByte: 3, oldText: "c", newText: "d", reason: "D09"),
            ],
            perHunkClasses: [.tableDamage, .citationFragmentDamage])
        #expect(staged.classLabels == "D03, D09")
        #expect(staged.hunkCount == 2)
        #expect(QueueRunDetailsLintProposals.staleMessage
            == "Page changed since this proposal — re-run lint.")
    }
}
