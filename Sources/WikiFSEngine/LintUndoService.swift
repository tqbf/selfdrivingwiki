import Foundation
import WikiFSCore

/// The Undo lint fixes action (W2b): put every page a completed run
/// repaired back to the run's inspected head, then record the undo with the
/// lint repair breaker.
///
/// The reverts use the SAME seam as the host's post-verification auto-revert
/// — `WikiStore.revertPage(pageID:to:expectingHead:)`, the expected-head CAS
/// form — so a page whose head moved after the run is never clobbered: the
/// store refuses the revert and the page is reported for manual revert from
/// page history. One undo click is ONE `userUndo` outcome for the run's
/// configuration tuple, recorded after the batch (mirroring the engine's
/// shipped-approval-only accounting: runs that wrote nothing under another
/// tier are not breaker evidence).
public enum LintUndoService {

    /// One page's undo input: the heads the run recorded (parsed from the
    /// durable queue report by `LintPageRecordFacts`).
    public struct PagePlan: Equatable, Sendable {
        public let pageID: PageID
        public let inspectedHead: PageVersionID
        public let writtenHead: PageVersionID

        public init(pageID: PageID, inspectedHead: PageVersionID, writtenHead: PageVersionID) {
            self.pageID = pageID
            self.inspectedHead = inspectedHead
            self.writtenHead = writtenHead
        }
    }

    /// What happened to one page in the batch.
    public enum PageOutcome: Equatable, Sendable {
        /// The store repointed the page to the run's inspected head.
        case reverted
        /// The page's head moved after the run — the CAS revert refused and
        /// wrote nothing. The page keeps the run's repair; the user reverts
        /// it manually from page history if wanted.
        case headMoved(current: PageVersionID?)
        /// The store refused the revert for another reason.
        case failed(reason: String)
    }

    /// One page's undo result.
    public struct PageResult: Equatable, Sendable {
        public let pageID: PageID
        public let outcome: PageOutcome

        public init(pageID: PageID, outcome: PageOutcome) {
            self.pageID = pageID
            self.outcome = outcome
        }
    }

    /// The batch's aggregate: per-page outcomes plus the breaker's verdict
    /// AFTER the undo was recorded (`nil` when the run's configuration could
    /// not be resolved, so nothing was recorded).
    public struct BatchResult: Equatable, Sendable {
        public let pages: [PageResult]
        public let breakerVerdict: LintBreakerVerdict?

        public var revertedCount: Int {
            pages.filter { $0.outcome == .reverted }.count
        }
        public var headMovedCount: Int {
            pages.filter {
                if case .headMoved = $0.outcome { return true }
                return false
            }.count
        }

        public init(pages: [PageResult], breakerVerdict: LintBreakerVerdict?) {
            self.pages = pages
            self.breakerVerdict = breakerVerdict
        }
    }

    /// Run the batch: revert each page, then record one `userUndo` with the
    /// breaker. Sequential on purpose — a lint run's scope is small and the
    /// store is method-atomic per call.
    public static func undoRepairedPages(
        store: WikiStore,
        pages: [PagePlan],
        breaker: LintRepairBreaker?,
        breakerKey: LintRepairBreakerKey?
    ) -> BatchResult {
        var results: [PageResult] = []
        results.reserveCapacity(pages.count)
        for plan in pages {
            results.append(PageResult(pageID: plan.pageID, outcome: revertOne(store: store, plan: plan)))
        }
        var verdict: LintBreakerVerdict?
        if let breaker, let breakerKey {
            verdict = breaker.recordUserUndo(for: breakerKey)
        }
        return BatchResult(pages: results, breakerVerdict: verdict)
    }

    /// One page's CAS revert, mapped to a page outcome. Refused CAS reverts
    /// carry the page's actual head so the UI can say the page changed.
    static func revertOne(store: WikiStore, plan: PagePlan) -> PageOutcome {
        do {
            try store.revertPage(
                pageID: plan.pageID, to: plan.inspectedHead,
                expectingHead: plan.writtenHead)
            return .reverted
        } catch let conflict as PageConflictError {
            return .headMoved(current: conflict.actualVersionID)
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    /// The breaker configuration tuple for a run whose record names the
    /// shipped approval row that authorized it: the row supplies the
    /// provider/model/effort, the live build supplies the pipeline digest
    /// (the same key construction a run's plan used — a pipeline change
    /// resets the breaker state in place). `nil` when the row is not in this
    /// build's shipped manifest or the live pipeline cannot be computed —
    /// the caller records nothing rather than guessing a configuration.
    public static func breakerKey(forApprovalID approvalID: LintApprovalID) -> LintRepairBreakerKey? {
        let manifest: LintAcceptanceManifest
        do {
            manifest = try LintAcceptanceManifest.decode(LintAcceptanceManifest.shippedData())
        } catch {
            DebugLog.agent("lint undo: shipped manifest unavailable, no breaker recording: \(error)")
            return nil
        }
        return breakerKey(forApprovalID: approvalID, manifest: manifest)
    }

    /// The same resolution over an explicit manifest (tests, tooling).
    static func breakerKey(
        forApprovalID approvalID: LintApprovalID,
        manifest: LintAcceptanceManifest
    ) -> LintRepairBreakerKey? {
        guard let row = manifest.approvals.first(where: { $0.id == approvalID.rawValue }) else {
            return nil
        }
        do {
            return LintRepairBreakerKey(
                pipeline: try .live(),
                provider: row.provider, model: row.model, effort: row.effort)
        } catch {
            DebugLog.agent("lint undo: live pipeline unavailable, no breaker recording: \(error)")
            return nil
        }
    }

    /// The breaker's plain-language message after an undo trips it, or nil
    /// while it stays clean.
    public static func breakerTripMessage(_ verdict: LintBreakerVerdict) -> String? {
        guard case .tripped(let reason) = verdict else { return nil }
        return "Auto-repair paused for this configuration: \(reason)."
    }
}
