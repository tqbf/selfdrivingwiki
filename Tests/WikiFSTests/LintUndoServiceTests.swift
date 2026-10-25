import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

/// W2b's engine layer: the durable per-page lint record parser
/// (`LintPageRecordFacts`), the Undo batch (`LintUndoService`) over a real
/// store, and the breaker's read-only window status. The parser's inputs are
/// the exact `detail` texts the W2a host accounting writes — the surviving
/// repair, the auto-reverted failure, the flagged refusal, the report-only
/// and budget-rejected demotions — so a producer format drift fails here
/// first.
@Suite("Lint Undo service and record facts")
struct LintUndoServiceTests {

    // MARK: - Fixtures

    /// A temp-dir store plus breaker, one repaired page: `original` (the
    /// run's inspected head) → `repaired` (the run's written head).
    @MainActor
    struct StoreFixture {
        let root: URL
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let key: LintRepairBreakerKey
        let page: WikiPage
        let inspectedHead: PageVersionID
        let writtenHead: PageVersionID

        init(repairedBody: String = "# Repaired\n\nfixed\n") throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lint-undo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("WikiFS.sqlite"))
            breaker = LintRepairBreaker(containerResolver: { root.appendingPathComponent("appgroup") })
            key = LintRepairBreakerKey(
                pipelineDigest: "test-digest", provider: "p", model: "m", effort: "e")
            page = try store.createPage(title: "Undo me")
            try store.updatePage(id: page.id, title: "Undo me", body: "# Original\n\nfirst\n")
            inspectedHead = try #require(try store.pageHeadVersionID(pageID: page.id))
            try store.updatePage(id: page.id, title: "Undo me", body: repairedBody)
            writtenHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        }

        func plan() -> LintUndoService.PagePlan {
            LintUndoService.PagePlan(
                pageID: page.id, inspectedHead: inspectedHead, writtenHead: writtenHead)
        }
    }

    /// A target record whose detail matches the W2a accounting's shape.
    static func record(
        pageID: PageID, title: String = "P", state: QueueReportTargetState,
        detail: String
    ) -> QueueReportTargetRecord {
        QueueReportTargetRecord(
            target: .page(pageID), displayName: title, state: state, detail: detail)
    }

    /// The detail the host accounting writes for a passed shipped-approval
    /// repair (trace labels first, then the audit detail: audited head,
    /// coverage, verification, written head, authority labels again).
    static func survivingRepairDetail(
        inspected: PageVersionID, written: PageVersionID
    ) -> String {
        "authority_tier=shippedApproval; approval_id=apr-2026-10; "
            + "audited head \(inspected.rawValue); run-report coverage complete; "
            + "verification verified on the written head; "
            + "written_head=\(written.rawValue); "
            + "authority_tier=shippedApproval; approval_id=apr-2026-10"
    }

    // MARK: - Parser: surviving repair

    @Test func parsesSurvivingRepairRecord() throws {
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "Fix me", state: .succeeded,
            detail: Self.survivingRepairDetail(
                inspected: PageVersionID(rawValue: "v1"),
                written: PageVersionID(rawValue: "v2")))))
        #expect(facts.tier == .shippedApproval)
        #expect(facts.approvalID == LintApprovalID(rawValue: "apr-2026-10"))
        #expect(facts.inspectedHead == PageVersionID(rawValue: "v1"))
        #expect(facts.writtenHead == PageVersionID(rawValue: "v2"))
        #expect(facts.wasAutoReverted == false)
        #expect(facts.isFlagged == false)
        #expect(facts.verificationFailureReasons.isEmpty)
        #expect(facts.wroteSurvivingRepair, "a passed shipped-approval repair is undoable")
    }

    // MARK: - Parser: verification failure, auto-reverted

    @Test func parsesAutoRevertedFailureRecordWithReasons() throws {
        let detail = "authority_tier=shippedApproval; approval_id=apr-2026-10; "
            + "revert=reverted to v1 from v2; "
            + "audited head v1; run-report coverage complete; "
            + "verification failed: claimed repair for D03|line-3#1 but the finding persists on the written head; "
            + "new finding D09|line-9#1 on the written head: broken link; "
            + "written_head=v2; revert=reverted to v1 from v2; "
            + "authority_tier=shippedApproval; approval_id=apr-2026-10"
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "F", state: .failed(reason: "x"),
            detail: detail)))
        #expect(facts.wasAutoReverted)
        #expect(facts.isFlagged == false)
        #expect(facts.inspectedHead == PageVersionID(rawValue: "v1"))
        #expect(facts.writtenHead == PageVersionID(rawValue: "v2"))
        #expect(facts.verificationFailureReasons == [
            "claimed repair for D03|line-3#1 but the finding persists on the written head",
            "new finding D09|line-9#1 on the written head: broken link",
        ])
        #expect(facts.wroteSurvivingRepair == false, "an auto-reverted write is not surviving")
    }

    @Test func parsesFlaggedRefusalRecord() throws {
        let detail = "authority_tier=shippedApproval; approval_id=apr-x; "
            + "revert=refused (current head v3 diverged from written head v2); FLAGGED for review; "
            + "audited head v1; run-report coverage complete; "
            + "verification failed: claimed repair for D03|l1#1 but the finding persists on the written head; "
            + "written_head=v2; revert=refused (current head v3 diverged from written head v2); FLAGGED for review; "
            + "authority_tier=shippedApproval; approval_id=apr-x"
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "F", state: .failed(reason: "x"),
            detail: detail)))
        #expect(facts.wasAutoReverted)
        #expect(facts.isFlagged, "a refused revert flags the page for manual review")
        #expect(facts.wroteSurvivingRepair == false)
    }

    // MARK: - Parser: tiers that never wrote

    @Test func reportOnlyRecordIsNeverUndoable() throws {
        let detail = "authority_tier=reportOnly; authority_reason=gate components not fully resolved; "
            + "audited head v1; no run scratch to read the run report from; "
            + "authority_tier=reportOnly; authority_reason=gate components not fully resolved"
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "R", state: .failed(reason: "x"),
            detail: detail)))
        #expect(facts.tier == .reportOnly)
        #expect(facts.writtenHead == nil)
        #expect(facts.wroteSurvivingRepair == false)
    }

    @Test func budgetExceededRecordIsNeverUndoable() throws {
        let detail = "authority_tier=budgetExceeded; authority_reason=hunks=9/6; bytes=5200/4000; "
            + "audited head v1; write phase not performed — patch rejected whole: hunks=9/6; bytes=5200/4000; "
            + "written_head=v1; authority_tier=budgetExceeded; authority_reason=hunks=9/6; bytes=5200/4000"
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "B", state: .failed(reason: "x"),
            detail: detail)))
        #expect(facts.tier == .budgetExceeded)
        #expect(facts.wroteSurvivingRepair == false, "a rejected patch wrote nothing")
    }

    @Test func emptyDetailParsesToUnknownFacts() throws {
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "L", state: .succeeded, detail: "")))
        #expect(facts.tier == nil)
        #expect(facts.inspectedHead == nil)
        #expect(facts.writtenHead == nil)
        #expect(facts.wroteSurvivingRepair == false)
    }

    // MARK: - Parser: tier-2 staged proposals (W5a)

    /// A tier-2 record carries the proposal count and the staged record
    /// references host accounting folded in from the daemon's audit
    /// entries — the review UI's "N proposed" data source.
    @Test func parsesStagedProposalRecordLabels() throws {
        let detail = "authority_tier=stagedProposal; "
            + "authority_reason=configuration not yet evaluated — repairs staged for your review; "
            + "audited head v1; run-report coverage complete; "
            + "proposals=2; staged_proposal=01HZPROP0000000000000000001; "
            + "staged_proposal=01HZPROP0000000000000000002; "
            + "written_head=v1; authority_tier=stagedProposal"
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "S", state: .succeeded,
            detail: detail)))
        #expect(facts.tier == .stagedProposal)
        #expect(facts.proposalCount == 2)
        #expect(facts.stagedProposalIDs == [
            "01HZPROP0000000000000000001", "01HZPROP0000000000000000002",
        ])
        #expect(facts.wroteSurvivingRepair == false,
                "a staged proposal writes nothing — there is no surviving repair to undo")
    }

    @Test func recordWithoutProposalLabelsParsesNilCount() throws {
        let facts = try #require(LintPageRecordFacts.parse(record: Self.record(
            pageID: PageID(rawValue: "p1"), title: "P", state: .succeeded,
            detail: "authority_tier=reportOnly; audited head v1")))
        #expect(facts.proposalCount == nil)
        #expect(facts.stagedProposalIDs.isEmpty)
    }

    /// The staged-note audit vocabulary round-trips (producer + parser).
    @Test func stagedProposalAuditNoteRoundTrips() throws {
        let note = LintProposalAudit.stagedNote(
            proposalID: "01HZPROP0000000000000000009",
            inspectedHead: PageVersionID(rawValue: "v7"),
            bodyFingerprint: "abc123", hunkCount: 3)
        let parsed = try #require(LintProposalAudit.parseStagedNote(note))
        #expect(parsed.proposalID == "01HZPROP0000000000000000009")
        #expect(parsed.inspectedHead == PageVersionID(rawValue: "v7"))
        #expect(parsed.bodyFingerprint == "abc123")
        #expect(parsed.hunkCount == 3)

        // The record labels render count + references; empty is empty.
        #expect(LintProposalAudit.recordLabels(proposals: [parsed])
            == "proposals=1; staged_proposal=01HZPROP0000000000000000009")
        #expect(LintProposalAudit.recordLabels(proposals: []).isEmpty)
        // A note without a proposal id parses to nothing (lenient).
        #expect(LintProposalAudit.parseStagedNote("hunks=2") == nil)
        #expect(LintProposalAudit.parseStagedNote(nil) == nil)
    }

    @Test func sourceRecordParsesToNil() {
        let source = QueueReportTargetRecord(
            target: .source(SourceID(rawValue: "s1")), displayName: "s",
            state: .succeeded, detail: "audited head v1")
        #expect(LintPageRecordFacts.parse(record: source) == nil)
    }

    // MARK: - Undo batch over a real store

    @MainActor
    @Test func undoRevertsSurvivingRepairAndRecordsBreakerUndo() throws {
        let fixture = try StoreFixture()
        let result = LintUndoService.undoRepairedPages(
            store: fixture.store, pages: [fixture.plan()],
            breaker: fixture.breaker, breakerKey: fixture.key)

        #expect(result.pages == [
            LintUndoService.PageResult(pageID: fixture.page.id, outcome: .reverted)
        ])
        #expect(result.revertedCount == 1)
        let head = try #require(try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        #expect(head == fixture.inspectedHead, "the page is back at the run's inspected head")

        let status = fixture.breaker.windowStatus(for: fixture.key)
        #expect(status.userUndos == 1, "one batch is ONE user undo for the configuration")
        #expect(status.verificationFailures == 0)
        #expect(status.isTripped == false)
        #expect(result.breakerVerdict != nil)
    }

    @MainActor
    @Test func undoRefusesMovedHeadAndDoesNotRevert() throws {
        let fixture = try StoreFixture()
        // A concurrent writer advances the page after the run.
        try fixture.store.updatePage(id: fixture.page.id, title: "Undo me", body: "# Edited by hand\n")
        let currentHead = try #require(try fixture.store.pageHeadVersionID(pageID: fixture.page.id))

        let result = LintUndoService.undoRepairedPages(
            store: fixture.store, pages: [fixture.plan()],
            breaker: fixture.breaker, breakerKey: fixture.key)

        guard case .headMoved(let head) = result.pages.first?.outcome else {
            Issue.record("expected headMoved, got \(String(describing: result.pages.first?.outcome))")
            return
        }
        #expect(head == currentHead, "the outcome carries the page's actual head")
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == currentHead,
                "the CAS revert wrote nothing")
        #expect(result.headMovedCount == 1)
        // The undo still counts: the user asked to undo this configuration's work.
        #expect(fixture.breaker.windowStatus(for: fixture.key).userUndos == 1)
    }

    @MainActor
    @Test func mixedBatchRecordsOneBreakerUndoAndAggregatesHonestly() throws {
        let fixture = try StoreFixture()
        // A second page the run repaired, whose head then moved.
        let movedPage = try fixture.store.createPage(title: "Moved")
        try fixture.store.updatePage(id: movedPage.id, title: "Moved", body: "orig\n")
        let movedInspected = try #require(try fixture.store.pageHeadVersionID(pageID: movedPage.id))
        try fixture.store.updatePage(id: movedPage.id, title: "Moved", body: "repaired\n")
        let movedWritten = try #require(try fixture.store.pageHeadVersionID(pageID: movedPage.id))
        try fixture.store.updatePage(id: movedPage.id, title: "Moved", body: "edited after\n")

        let plans = [
            fixture.plan(),
            LintUndoService.PagePlan(
                pageID: movedPage.id, inspectedHead: movedInspected, writtenHead: movedWritten),
        ]
        let result = LintUndoService.undoRepairedPages(
            store: fixture.store, pages: plans,
            breaker: fixture.breaker, breakerKey: fixture.key)

        #expect(result.revertedCount == 1)
        #expect(result.headMovedCount == 1)
        #expect(fixture.breaker.windowStatus(for: fixture.key).userUndos == 1,
                "the batch records ONE undo, not one per page")
    }

    @MainActor
    @Test func secondUndoTripsBreakerAndCarriesPlainLanguageMessage() throws {
        let fixture = try StoreFixture()
        // First run's undo: within tolerance.
        let first = LintUndoService.undoRepairedPages(
            store: fixture.store, pages: [fixture.plan()],
            breaker: fixture.breaker, breakerKey: fixture.key)
        #expect(LintUndoService.breakerTripMessage(first.breakerVerdict ?? .clean) == nil)

        // Re-repair (a second run), then undo it: the second undo trips.
        try fixture.store.updatePage(id: fixture.page.id, title: "Undo me", body: "# Repaired again\n")
        let secondWritten = try #require(try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        let second = LintUndoService.undoRepairedPages(
            store: fixture.store,
            pages: [LintUndoService.PagePlan(
                pageID: fixture.page.id,
                inspectedHead: fixture.inspectedHead, writtenHead: secondWritten)],
            breaker: fixture.breaker, breakerKey: fixture.key)

        guard case .tripped(let reason) = second.breakerVerdict ?? .clean else {
            Issue.record("expected the second undo to trip the breaker")
            return
        }
        #expect(reason.contains("undos"))
        let message = try #require(LintUndoService.breakerTripMessage(second.breakerVerdict ?? .clean))
        #expect(message.hasPrefix("Auto-repair paused for this configuration"))
        #expect(message.contains(reason))
        // The trip persists: a later consult reports it too.
        #expect(fixture.breaker.windowStatus(for: fixture.key).isTripped)
    }

    @MainActor
    @Test func nilBreakerOrKeySkipsRecordingWithoutBlockingReverts() throws {
        let fixture = try StoreFixture()
        let result = LintUndoService.undoRepairedPages(
            store: fixture.store, pages: [fixture.plan()],
            breaker: fixture.breaker, breakerKey: nil)
        #expect(result.revertedCount == 1)
        #expect(result.breakerVerdict == nil)
        #expect(fixture.breaker.windowStatus(for: fixture.key).userUndos == 0)
    }

    // MARK: - Breaker key reconstruction

    @Test func breakerKeyForUnknownApprovalIsNil() {
        #expect(LintUndoService.breakerKey(
            forApprovalID: LintApprovalID(rawValue: "not-a-shipped-row")) == nil)
    }

    /// The shipped manifest carries the rollout's approval rows; when it has
    /// none yet, no run's approval id can resolve a configuration and the
    /// undo records no breaker outcome (reverts still work).
    @Test func breakerKeyResolvesFromManifestRow() throws {
        let live = try LintAcceptanceManifest.Pipeline.live()
        let manifest = LintAcceptanceManifest(
            pipeline: live, evidence: nil,
            approvals: [LintAcceptanceManifest.Approval(
                id: "apr-1", provider: "anthropic", model: "claude-opus",
                effort: "high", evaluatedRevision: nil, acceptanceKeySHA256: nil)])
        let key = try #require(
            LintUndoService.breakerKey(
                forApprovalID: LintApprovalID(rawValue: "apr-1"), manifest: manifest))
        #expect(key.provider == "anthropic")
        #expect(key.model == "claude-opus")
        #expect(key.effort == "high")
        #expect(key.pipelineDigest == LintRepairBreakerKey.digest(of: live))

        // An id outside the manifest's rows resolves to nothing.
        #expect(LintUndoService.breakerKey(
            forApprovalID: LintApprovalID(rawValue: "apr-other"), manifest: manifest) == nil)
    }

    @Test func shippedManifestCurrentlyNamesNoRows() throws {
        let manifest = try LintAcceptanceManifest.decode(LintAcceptanceManifest.shippedData())
        #expect(manifest.approvals.isEmpty,
                "the rollout ships no approval rows yet — undo recording waits for a shipped row")
    }

    // MARK: - Window status reads without mutating

    @MainActor
    @Test func windowStatusAnswersEmptyForMissingStateAndStalePipeline() throws {
        let fixture = try StoreFixture()
        let missing = fixture.breaker.windowStatus(for: fixture.key)
        #expect(missing.userUndos == 0 && missing.verificationFailures == 0)
        #expect(missing.isTripped == false)

        // A different pipeline digest reads as the reset it will become.
        let staleKey = LintRepairBreakerKey(
            pipelineDigest: "other-pipeline", provider: "p", model: "m", effort: "e")
        _ = fixture.breaker.recordUserUndo(for: staleKey)
        let fresh = fixture.breaker.windowStatus(for: fixture.key)
        #expect(fresh.userUndos == 0, "the stale-pipeline file never answers this key's window")
    }
}
