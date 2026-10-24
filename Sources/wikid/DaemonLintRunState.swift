#if os(macOS)
import Foundation
import WikiFSCore

// Per-run CAS-conflict state for managed lint runs (plan Phase 2.8).
//
// The TRUSTED daemon owns this state; the child only ever sees an opaque
// receipt token. The budget is the requirements' bounded recovery (REQ-15/
// REQ-16): one conflict allows a fresh read and recomposition; a SECOND
// conflict closes every further patch for the run. A receipt is minted only
// by a fresh selected-page JSON read, ties to the head AND the body
// fingerprint (an old body cannot pass with a refreshed head), and dies the
// moment a patch commits — so a stale receipt can never replay an old body.

/// One snapshot receipt: the opaque token a patch request must present, plus
/// the head and body fingerprint it was minted from (diagnostics/tests — the
/// child sees only the token).
public struct DaemonLintSnapshotReceipt: Hashable, Sendable {
    public let token: String
    public let headVersionID: PageVersionID
    public let bodyFingerprint: String
}

/// The daemon's own verification record for one committed lint patch
/// (plan §5.8): the trusted side scanned the WRITTEN immutable version right
/// after its commit — never whichever head happens to be current later.
public struct DaemonLintVerificationRecord: Hashable, Sendable {
    public let pageID: PageID
    public let writtenHead: PageVersionID
    public let appliedClasses: [LintDefectClass]
    public let writtenFingerprint: String
    /// The written-version scan's finding ids (class@range summaries).
    public let remainingFindings: [String]
    public let recordedAt: Date
}

/// The CAS budget and receipt bookkeeping for one daemon's lint runs.
/// Actor-isolated; entries live only for the daemon process.
public actor DaemonLintRunState {

    enum LintCASBudgetError: Error, Equatable {
        /// The presented receipt token is not the run's current receipt (a
        /// stale receipt after a conflict, an old body's receipt, or a
        /// fabricated one).
        case staleReceipt
        /// Two conflicts already happened: every further patch for this run
        /// is rejected (REQ-16).
        case conflictBudgetExhausted
    }

    /// The conflict budget: initial attempt + ONE recomposition.
    private static let maxConflicts = 2

    private var receipts: [DaemonRunID: DaemonLintSnapshotReceipt] = [:]
    private var conflictCounts: [DaemonRunID: Int] = [:]
    private var closedRuns: Set<DaemonRunID> = []
    private var verificationRecords: [DaemonRunID: DaemonLintVerificationRecord] = [:]

    public init() {}

    // MARK: - Receipts

    /// Mint the receipt for one fresh selected-page read. Any previous
    /// receipt for the run dies — a new read is the ONLY way to hold a
    /// current receipt.
    public func issueReceipt(
        runID: DaemonRunID,
        head: PageVersionID,
        bodyFingerprint: String
    ) -> DaemonLintSnapshotReceipt {
        let receipt = DaemonLintSnapshotReceipt(
            token: UUID().uuidString,
            headVersionID: head,
            bodyFingerprint: bodyFingerprint)
        receipts[runID] = receipt
        return receipt
    }

    /// Validate that a patch request presents the run's CURRENT receipt AND
    /// that the receipt's head matches the patch's `expectHead` (review M4:
    /// an old body cannot pass with a refreshed head — a receipt minted
    /// from H1 cannot authorize hunks declared against H2). Throws
    /// `staleReceipt` for anything else.
    public func validateReceipt(
        runID: DaemonRunID, token: String, expectedHead: PageVersionID
    ) throws {
        guard let current = receipts[runID], current.token == token else {
            throw LintCASBudgetError.staleReceipt
        }
        guard current.headVersionID == expectedHead else {
            throw LintCASBudgetError.staleReceipt
        }
    }

    /// The run's current receipt, if one was minted (tests/diagnostics).
    public func currentReceipt(runID: DaemonRunID) -> DaemonLintSnapshotReceipt? {
        receipts[runID]
    }

    /// A patch committed: the old receipt is dead. The next write needs a
    /// fresh read (and a fresh receipt) even though the head this run wrote
    /// is now current.
    public func invalidateReceipt(runID: DaemonRunID) {
        receipts.removeValue(forKey: runID)
    }

    // MARK: - Conflict budget

    /// Record one CAS conflict on a patch. Returns `true` while the budget
    /// allows the ONE recomposition; `false` (with the run CLOSED) when the
    /// second conflict landed — every further patch for the run rejects.
    public func recordConflict(runID: DaemonRunID) -> Bool {
        let count = (conflictCounts[runID] ?? 0) + 1
        conflictCounts[runID] = count
        guard count < Self.maxConflicts else {
            closedRuns.insert(runID)
            return false
        }
        return true
    }

    /// `true` once the run exhausted its conflict budget — every further
    /// patch rejects until the run ends.
    public func isClosed(runID: DaemonRunID) -> Bool {
        closedRuns.contains(runID)
    }

    // MARK: - Verification records (plan §5.8)

    /// Publish the written-version verification record for a committed lint
    /// patch (the latest one wins — a second patch replaces it).
    public func recordVerification(runID: DaemonRunID, record: DaemonLintVerificationRecord) {
        verificationRecords[runID] = record
    }

    /// The run's latest written-version verification record, if any.
    public func verificationRecord(runID: DaemonRunID) -> DaemonLintVerificationRecord? {
        verificationRecords[runID]
    }

    /// The latest written-version verification record for one page across
    /// every run this state serves — the queue host's summary lookup (it
    /// knows the page, not the child's run id).
    public func latestVerificationRecord(pageID: PageID) -> DaemonLintVerificationRecord? {
        verificationRecords.values
            .filter { $0.pageID == pageID }
            .max { $0.recordedAt < $1.recordedAt }
    }

    /// Tear down a run's state (the lease revocation path).
    public func forget(runID: DaemonRunID) {
        receipts.removeValue(forKey: runID)
        conflictCounts.removeValue(forKey: runID)
        closedRuns.remove(runID)
    }
}
#endif
