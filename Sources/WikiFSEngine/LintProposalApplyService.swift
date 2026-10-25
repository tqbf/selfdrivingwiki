import Foundation
import WikiFSCore

/// The apply-on-approve service for staged repair proposals (W5a §4): the
/// trusted app side turns an approved proposal (or an approved subset of its
/// hunks) into the exact page write — through the SAME enforcement net the
/// tier-1 path uses, never around it.
///
/// Behavior, in order:
/// 1. Re-read the page's CURRENT head. Head ≠ the proposal's inspected head
///    → `.stale` ("page changed since this proposal — re-run lint"): nothing
///    is written and the breaker is untouched.
/// 2. Budget re-check (belt and braces — staging already enforced it), then
///    apply the approved hunks through the EXISTING
///    `WikiStore.patchPage` exact-body path with CAS expect-head = the
///    inspected head. No new store mutator: the `mutate()` event emission
///    comes free from `patchPage`.
/// 3. Post-apply: the W2a written-head verification machinery — re-scan the
///    written bytes with the same fact set and compare against the
///    pre-apply scan using store-observed change regions. A verification
///    failure triggers ONE CAS-guarded auto-revert to the inspected head,
///    records `verificationFailure` with the tier-2 breaker key, and the
///    outcome RETAINS the disclosure data (reasons + both head versions).
/// 4. Every terminal outcome is appended as a trusted `--kind lint` audit
///    entry (`Lint proposal applied — <title>`), so it lands in the run's
///    durable record for the review UI. A human REJECTION is recorded by
///    `recordRejection` — repeated rejections trip the breaker with the
///    same thresholds as undos.
///
/// Concurrency: static, synchronous, store-method-atomic per call — the
/// same shape as `LintUndoService`. The caller (the review UI) owns the
/// actor context.
public enum LintProposalApplyService {

    /// The apply input: the staged proposal's fields, mapped from the
    /// daemon's `DaemonLintStagedProposal` record (the review UI's contract
    /// — `id`/`runID`/`status` stay daemon-side; these are the fields the
    /// write and its verification need).
    public struct Proposal: Equatable, Sendable {
        public let id: String
        public let pageID: PageID
        public let inspectedHead: PageVersionID
        public let bodyFingerprint: String
        public let hunks: [PagePatchHunk]
        public let perHunkClasses: [LintDefectClass]

        public init(
            id: String, pageID: PageID, inspectedHead: PageVersionID,
            bodyFingerprint: String, hunks: [PagePatchHunk],
            perHunkClasses: [LintDefectClass]
        ) {
            self.id = id
            self.pageID = pageID
            self.inspectedHead = inspectedHead
            self.bodyFingerprint = bodyFingerprint
            self.hunks = hunks
            self.perHunkClasses = perHunkClasses
        }
    }

    /// What happened. `appliedThenReverted` RETAINS the disclosure data
    /// (verification reasons, written + inspected heads) exactly like the
    /// W2a path.
    public enum Outcome: Equatable, Sendable {
        /// The approved hunks were applied and verified on the written head.
        case applied(writtenHead: PageVersionID)
        /// Applied, verification failed, and the CAS auto-revert put the
        /// inspected head back (or flagged the page if it could not).
        case appliedThenReverted(
            writtenHead: PageVersionID, revert: LintRevertOutcome, reasons: [String])
        /// The page changed since the proposal was staged — nothing written,
        /// breaker untouched. Re-run lint.
        case stale(currentHead: PageVersionID?)
        /// The apply could not run (budget refused at apply time, store
        /// error). Nothing written.
        case failed(reason: String)

        public var isTerminalWrite: Bool {
            switch self {
            case .applied, .appliedThenReverted: return true
            case .stale, .failed: return false
            }
        }
    }

    /// Apply the approved hunk subset (or ALL when `approvedIndices` is
    /// nil) of `proposal`. `breaker`/`breakerKey` are the tier-2
    /// configuration (live pipeline + provider/model/effort — no approval
    /// row); nil means the caller could not resolve the configuration, so a
    /// verification failure cannot be recorded (the apply itself is not
    /// gated on it).
    public static func apply(
        proposal: Proposal,
        approvedIndices: IndexSet? = nil,
        store: WikiStore,
        breaker: LintRepairBreaker?,
        breakerKey: LintRepairBreakerKey?
    ) -> Outcome {
        // 1. The stale gate: the page must still be at the head the hunks
        // were composed against. Nothing here writes.
        let preRead: PageCoherentRead
        do {
            preRead = try store.readPageCoherent(id: proposal.pageID)
        } catch {
            return finish(proposal: proposal, outcome: .failed(reason: "\(error)"), store: store)
        }
        guard preRead.headVersionID == proposal.inspectedHead else {
            return finish(
                proposal: proposal,
                outcome: .stale(currentHead: preRead.headVersionID), store: store)
        }

        // The approved subset keeps its per-hunk classes (parallel arrays).
        let hunks: [PagePatchHunk]
        let classes: [LintDefectClass]
        if let approvedIndices {
            hunks = approvedIndices.sorted().compactMap { index in
                proposal.hunks.indices.contains(index) ? proposal.hunks[index] : nil
            }
            classes = approvedIndices.sorted().compactMap { index in
                proposal.perHunkClasses.indices.contains(index)
                    ? proposal.perHunkClasses[index] : nil
            }
        } else {
            hunks = proposal.hunks
            classes = proposal.perHunkClasses
        }
        guard hunks.count == classes.count else {
            return finish(
                proposal: proposal,
                outcome: .failed(reason: "approved hunk subset is not paired with defect classes"),
                store: store)
        }
        guard hunks.isEmpty == false else {
            return finish(
                proposal: proposal,
                outcome: .failed(reason: "no hunks approved — nothing to apply"),
                store: store)
        }

        // 2. Budget re-check at apply time, scaled the same way the daemon
        // scales it: the CURRENT page's confirmed repairable findings fix
        // the cap (the same computation the staging read used).
        let preflight = Self.scan(store: store, read: preRead)
        let budget = LintPatchBudget(preflight: preflight)
        let requested = LintPatchBudget.Usage(
            hunks: hunks.count,
            changedBytes: hunks.reduce(0) { total, hunk in
                total + LintPatchBudget.changedBytes(
                    startByte: hunk.startByte, endByte: hunk.endByte, newText: hunk.newText)
            })
        if case .exceeded(let rejection) = budget.check(request: requested, alreadySpent: .zero) {
            return finish(
                proposal: proposal,
                outcome: .failed(reason: "budget rejected at apply: \(rejection.summary)"),
                store: store)
        }

        // 3. The write: the EXISTING exact-body CAS path — the same
        // enforcement net (validator, transaction, mutate() emission) a
        // tier-1 repair uses. No new store mutator.
        let outcome: PagePatchOutcome
        do {
            outcome = try store.patchPage(
                PagePatch(
                    pageID: proposal.pageID, expectHead: proposal.inspectedHead,
                    hunks: hunks, defectClasses: classes),
                author: "lint-proposal:\(proposal.id)")
        } catch let conflict as PageConflictError {
            // A concurrent writer moved the head between the stale gate and
            // the write — the same refusal semantics as `.stale`.
            return finish(
                proposal: proposal,
                outcome: .stale(currentHead: conflict.actualVersionID),
                store: store)
        } catch {
            return finish(
                proposal: proposal, outcome: .failed(reason: "\(error)"), store: store)
        }

        // 4. Post-apply verification: the W2a written-head machinery, run
        // against the IMMUTABLE version at the written head. A concurrent
        // writer that moves the head between the commit and the scan gets
        // its content neither labeled as this write nor verified as
        // repaired — the current head is read separately, for divergence
        // reporting only. The pre-apply scan is the `before`; the applied
        // hunks are the ones just written. The proposal carries no
        // per-finding claims, so the claimed set is empty — every surviving
        // finding is reported, none accused.
        do {
            let verification = try Self.verifyWrittenVersion(
                proposal: proposal, preRead: preRead, preflight: preflight,
                writtenHead: outcome.writtenHead, store: store)
            switch verification.status {
            case .verified, .verifiedWrittenHeadDiverged:
                return finish(
                    proposal: proposal,
                    outcome: .applied(writtenHead: outcome.writtenHead),
                    store: store)
            case .failed(let reasons):
                // Never leave a bad write in place silently, never clobber a
                // concurrent edit: ONE CAS-guarded revert to the inspected
                // head.
                let revert = AgentOperationRunner.revertFailedLintWrite(
                    store: store, pageID: proposal.pageID,
                    inspectedHead: proposal.inspectedHead,
                    writtenHead: outcome.writtenHead)
                // Tier-2 recording is ACTIVE: a post-apply verification
                // failure is breaker evidence for this configuration.
                if let breaker, let breakerKey {
                    breaker.record(.verificationFailure, for: breakerKey)
                }
                return finish(
                    proposal: proposal,
                    outcome: .appliedThenReverted(
                        writtenHead: outcome.writtenHead, revert: revert, reasons: reasons),
                    store: store)
            }
        } catch {
            // The write committed but verification could not run — this is
            // the W2a posture: the run stays a failure, flagged for review.
            return finish(
                proposal: proposal,
                outcome: .appliedThenReverted(
                    writtenHead: outcome.writtenHead,
                    revert: .notAttempted(reason: "verification could not run: \(error)"),
                    reasons: ["written-version verification could not run: \(error)"]),
                store: store)
        }
    }

    /// Record a human REJECTION of a staged proposal with the tier-2
    /// breaker configuration. Repeated rejections trip the breaker with the
    /// same thresholds as undos. Returns nil when the caller could not
    /// resolve the configuration (nothing is recorded rather than guessed).
    public static func recordRejection(
        breaker: LintRepairBreaker?, breakerKey: LintRepairBreakerKey?
    ) -> LintBreakerVerdict? {
        guard let breaker, let breakerKey else { return nil }
        return breaker.recordUserRejected(for: breakerKey)
    }

    // MARK: - Internals

    /// The written-version verification result, including the fingerprint of
    /// the bytes the scan actually read (tests pin that the scan ran on the
    /// immutable written version, not the current head).
    struct WrittenVerificationOutcome: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case verified
            case verifiedWrittenHeadDiverged(currentHead: PageVersionID)
            case failed(reasons: [String])
        }

        let status: Status
        let scannedFingerprint: String
    }

    /// The written version's row is gone — the immutable history was
    /// violated. Verification cannot run.
    struct WrittenVersionUnavailable: Error, CustomStringConvertible {
        let versionID: PageVersionID
        var description: String { "the written version \(versionID.rawValue) is no longer readable" }
    }

    /// The W2a written-head verification, against the IMMUTABLE version at
    /// `writtenHead`: a concurrent writer that moves the head after the
    /// commit gets its content neither labeled as this write nor verified as
    /// repaired. The current head is read separately, for divergence
    /// reporting only. Throws when the written version cannot be read (the
    /// caller keeps the W2a posture: failed write, flagged for review).
    static func verifyWrittenVersion(
        proposal: Proposal, preRead: PageCoherentRead, preflight: LintPreflightReport,
        writtenHead: PageVersionID, store: WikiStore
    ) throws -> WrittenVerificationOutcome {
        guard let writtenBody = try store.pageVersionBody(versionID: writtenHead) else {
            throw WrittenVersionUnavailable(versionID: writtenHead)
        }
        let currentRead = try store.readPageCoherent(id: proposal.pageID)
        // The written version's own identity and bytes; the title and
        // carried-forward provenance ride from the pre-apply read (the write
        // preserved them).
        let writtenSnapshot = LintPageSnapshot(
            pageID: proposal.pageID, title: preRead.title,
            headVersionID: writtenHead, body: writtenBody,
            sourceInputs: preRead.headSourceInputs)
        let writtenScan = Self.scan(store: store, snapshot: writtenSnapshot)
        let observed = AgentOperationRunner.observedChangeRanges(
            before: preRead.body, after: writtenSnapshot.body)
        let verdict = LintVerification.compare(
            before: preflight,
            written: writtenScan,
            appliedHunks: observed,
            claimedRepairFindingIDs: [],
            writtenHead: writtenHead,
            currentHead: currentRead.headVersionID,
            requiredChecksAvailable: true)
        let status: WrittenVerificationOutcome.Status
        switch verdict.status {
        case .verified:
            status = .verified
        case .verifiedWrittenHeadDiverged(let currentHead):
            status = .verifiedWrittenHeadDiverged(currentHead: currentHead)
        case .failed(let reasons):
            status = .failed(reasons: reasons)
        }
        return WrittenVerificationOutcome(
            status: status, scannedFingerprint: writtenSnapshot.bodyFingerprint)
    }

    /// The preflight scan with the same fact set the W2a written-head
    /// verification uses (M3(a)): resolution, citation, and origin facts
    /// load from the store; a facts failure records its limit instead of
    /// crashing the scan.
    static func scan(store: WikiStore, read: PageCoherentRead) -> LintPreflightReport {
        scan(store: store, snapshot: LintPageSnapshot(read))
    }

    private static func scan(store: WikiStore, snapshot: LintPageSnapshot) -> LintPreflightReport {
        let resolution: LintResolutionFacts
        do {
            resolution = try LintResolutionFacts.load(from: store)
        } catch {
            DebugLog.agent("lint proposal apply: resolution facts unavailable: \(error)")
            resolution = LintResolutionFacts()
        }
        let citations: LintCitationFacts?
        do {
            citations = try LintCitationFacts.load(from: store, body: snapshot.body)
        } catch {
            DebugLog.agent("lint proposal apply: citation facts unavailable: \(error)")
            citations = nil
        }
        let origins: LintOriginURLFacts?
        do {
            origins = try LintOriginURLFacts.load(from: store, body: snapshot.body)
        } catch {
            DebugLog.agent("lint proposal apply: origin facts unavailable: \(error)")
            origins = nil
        }
        let history = LintHistoryFacts.load(from: store, snapshot: snapshot)
        return LintPagePreflight.scan(
            snapshot: snapshot, resolution: resolution,
            citations: citations, originURLs: origins, history: history)
    }

    /// The durable audit record for a terminal outcome (the run's durable
    /// record for the review UI), then the outcome back to the caller.
    private static func finish(
        proposal: Proposal, outcome: Outcome, store: WikiStore
    ) -> Outcome {
        let title: String
        do {
            title = try store.readPageCoherent(id: proposal.pageID).title
        } catch {
            // The audit entry needs the page's title; without it the entry
            // cannot be title-matched, so the outcome still returns.
            DebugLog.agent("lint proposal apply: title read failed for \(proposal.pageID.rawValue): \(error)")
            return outcome
        }
        let summary: String
        switch outcome {
        case .applied(let writtenHead):
            summary = "outcome=applied; written_head=\(writtenHead.rawValue)"
        case .appliedThenReverted(let writtenHead, let revert, let reasons):
            summary = "outcome=applied-then-reverted; written_head=\(writtenHead.rawValue); "
                + "\(revert.auditLabel); verification failed: "
                + reasons.prefix(3).joined(separator: "; ")
        case .stale(let currentHead):
            summary = "outcome=stale; current_head=\(currentHead?.rawValue ?? "none")"
        case .failed(let reason):
            summary = "outcome=failed; reason=\(reason)"
        }
        do {
            try store.appendLog(
                kind: .lint,
                title: LintProposalAudit.appliedAuditTitlePrefix + title,
                note: "proposal_id=\(proposal.id); \(summary)")
        } catch {
            DebugLog.agent("lint proposal apply: audit append failed for \(proposal.pageID.rawValue): \(error)")
        }
        return outcome
    }
}
