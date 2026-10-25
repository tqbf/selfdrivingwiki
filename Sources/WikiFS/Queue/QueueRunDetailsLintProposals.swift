import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

/// One staged repair proposal resolved for review (W5b): the app-side value
/// mirror of the daemon's staged record — exactly the fields the review UI
/// renders and `LintProposalApplyService` consumes. The daemon's own record
/// type lives in the `wikid` target, which the app does not link; the wire
/// record (the daemon→app read seam) maps onto this value.
struct QueueLintStagedProposal: Identifiable, Sendable, Equatable {
    let id: String
    let pageID: PageID
    let stagedAt: Date
    /// The head the hunks were composed against — the CAS expect-head at
    /// apply time and the diff's "before" version.
    let inspectedHead: PageVersionID
    /// The inspected body's fingerprint (diff provenance).
    let bodyFingerprint: String
    /// The exact ranged edits, in submission order.
    let hunks: [PagePatchHunk]
    /// One defect class per hunk, parallel to `hunks`.
    let perHunkClasses: [LintDefectClass]
    /// The run's tier-2 breaker key, when the daemon recorded one for the
    /// run that staged this proposal.
    let breakerKey: LintRepairBreakerKey?

    /// The "N hunks proposed" count.
    var hunkCount: Int { hunks.count }

    /// The per-hunk defect-class labels ("D03, D09") for the row's summary.
    var classLabels: String {
        perHunkClasses.map(\.rawValue).joined(separator: ", ")
    }

    /// Map the wire record onto the app value. A record whose defect class
    /// is unknown to this build (an older/newer class vocabulary) maps to
    /// nil — the review UI renders only classes it can apply.
    init?(record: LintStagedProposalRecord) {
        var classes: [LintDefectClass] = []
        for raw in record.perHunkClasses {
            guard let defectClass = LintDefectClass(rawValue: raw) else { return nil }
            classes.append(defectClass)
        }
        guard classes.count == record.hunks.count else { return nil }
        self.init(
            id: record.id, pageID: PageID(rawValue: record.pageID),
            stagedAt: record.stagedAt,
            inspectedHead: PageVersionID(rawValue: record.inspectedHead),
            bodyFingerprint: record.bodyFingerprint,
            hunks: record.hunks.map { hunk in
                PagePatchHunk(
                    startByte: hunk.startByte, endByte: hunk.endByte,
                    oldText: hunk.oldText, newText: hunk.newText,
                    reason: hunk.reason)
            },
            perHunkClasses: classes,
            breakerKey: record.breakerKey.map { key in
                LintRepairBreakerKey(
                    pipelineDigest: key.pipelineDigest, provider: key.provider,
                    model: key.model, effort: key.effort)
            })
    }

    init(
        id: String, pageID: PageID, stagedAt: Date, inspectedHead: PageVersionID,
        bodyFingerprint: String, hunks: [PagePatchHunk],
        perHunkClasses: [LintDefectClass], breakerKey: LintRepairBreakerKey? = nil
    ) {
        self.id = id
        self.pageID = pageID
        self.stagedAt = stagedAt
        self.inspectedHead = inspectedHead
        self.bodyFingerprint = bodyFingerprint
        self.hunks = hunks
        self.perHunkClasses = perHunkClasses
        self.breakerKey = breakerKey
    }
}

/// The terminal outcome of one reviewed proposal. `applied` /
/// `appliedThenReverted` / `stale` / `failed` come from the durable audit
/// trail (`Lint proposal applied — <title>`, re-read after each apply);
/// `rejected` is presentation-local — a rejection records only breaker
/// evidence, no audit entry.
struct QueueLintProposalOutcome: Sendable, Equatable {
    enum Kind: String, Sendable {
        case applied
        case appliedThenReverted
        case stale
        case failed
        case rejected
    }

    let proposalID: String
    let kind: Kind
    /// The failed reason or the verification-failure summary, when the
    /// durable record carries one.
    let detail: String?
}

/// The Run Details panel's staged-proposal review section (W5b) — the value
/// model the panel renders: a tier-2 run's pending proposals with their
/// Approve/Reject controls, the "Approve all" batch, and the honest outcome
/// summary after proposals resolve.
///
/// Everything derives from ALREADY-PERSISTED data plus the caller-resolved
/// proposal values: the durable queue report's per-page records
/// (`LintPageRecordFacts` re-parses the accounting text, W5a's
/// `proposals=N; staged_proposal=<id>` labels) and the applied outcomes
/// re-read from the trusted audit trail. Nothing here mutates state — the
/// actions live with the caller (the Activity window), which owns the store
/// path and the tier-2 breaker, exactly like W2b's undo.
///
/// Visibility rules: the section renders only for selected-page lint runs
/// whose records name staged proposals; the review controls render only
/// while at least one staged proposal is still pending. After every
/// proposal resolves, the section collapses to the outcome summary (like
/// the undo aggregate) — buttons gone, never stuck enabled.
struct QueueRunDetailsLintProposals: Sendable, Equatable {

    /// One pending proposal with its page's staging-time title (from the
    /// durable record, so a renamed page still reads as the reviewed one).
    struct PendingProposal: Identifiable, Sendable, Equatable {
        let proposal: QueueLintStagedProposal
        let title: String

        var id: String { proposal.id }
        var pageID: PageID { proposal.pageID }
        var inspectedHead: PageVersionID { proposal.inspectedHead }
    }

    /// The still-pending proposals, in the durable records' order.
    let pendingProposals: [PendingProposal]
    /// The terminal outcomes, in the durable records' order. `var` (like
    /// the presentation fields below) so a caller that owns the section as
    /// one value can append a resolved outcome in place; production wiring
    /// keeps its own @State array and passes a fresh value instead.
    var outcomeRows: [QueueLintProposalOutcome]
    /// How many proposals the run staged per its durable records — the
    /// visibility anchor ("N proposed") that survives daemon restarts.
    let recordedProposalCount: Int
    /// The wiki whose pages the proposals target (drives version reads).
    let wikiID: WikiID

    // MARK: Presentation state (owned by the caller, reset on selection)

    /// Per-proposal apply/reject in flight (the row's buttons are disabled,
    /// never re-entrant).
    var inFlightProposalIDs: Set<String> = []
    /// The Approve-all batch is running.
    var approveAllInFlight: Bool = false
    /// The breaker's read-only window status line for the run's tier-2
    /// configuration ("1 of 2 allowed user rejections used…").
    var breakerContext: String?
    /// The breaker's plain trip message after a rejection or a verification
    /// failure tripped it ("Auto-repair paused for this configuration: …").
    var breakerNotice: String?
    /// Why the actions are unavailable — the tier-2 breaker configuration
    /// could not be resolved, so nothing may be recorded on the caller's
    /// behalf. Disables the buttons with this explanation rather than
    /// guessing a key.
    var actionUnavailableReason: String?

    /// Whether the section renders at all: the records name staged proposals
    /// AND something is renderable — a still-pending proposal or a recorded
    /// outcome. A run whose staged records all became unresolvable (daemon
    /// restarted before any outcome was durable) has nothing to show.
    var showsSection: Bool {
        recordedProposalCount > 0
            && (pendingProposals.isEmpty == false || outcomeRows.isEmpty == false)
    }

    /// Whether the review controls (per-proposal buttons, Approve all)
    /// render: only while a proposal is still pending. After all resolve,
    /// the section collapses to the outcome summary.
    var showsReviewControls: Bool { pendingProposals.isEmpty == false }

    /// "Approve all" needs more than one pending proposal to be worth a
    /// control of its own.
    var showsApproveAll: Bool { pendingProposals.count > 1 }

    /// Any apply/reject is in flight (the batch included) — disables every
    /// control so the store never sees concurrent applies.
    var isBusy: Bool { approveAllInFlight || inFlightProposalIDs.isEmpty == false }

    /// Whether one proposal's controls are disabled: busy, or the actions
    /// are unavailable.
    func isDisabled(_ id: String) -> Bool { isBusy || actionUnavailableReason != nil }

    /// The honest aggregate ("Proposals: 2 applied, 1 stale.") — non-zero
    /// parts only, in outcome order. Nil while nothing has resolved.
    /// Applied-then-reverted rows split by their ACTUAL revert facet: a
    /// refused or not-attempted revert is a different fact from a clean
    /// revert — the bad write may still be in place.
    var outcomeSummary: String? {
        guard outcomeRows.isEmpty == false else { return nil }
        var parts: [String] = []
        func append(_ count: Int, _ word: String) {
            guard count > 0 else { return }
            parts.append("\(count) \(word)")
        }
        append(outcomeRows.filter { $0.kind == .applied }.count, "applied")
        let reverts = outcomeRows.filter { $0.kind == .appliedThenReverted }
        append(reverts.filter { Self.facet(ofDetail: $0.detail) == .reverted }.count,
               "applied then reverted")
        append(reverts.filter { Self.facet(ofDetail: $0.detail) == .refused }.count,
               "applied with revert refused (flagged)")
        append(reverts.filter { Self.facet(ofDetail: $0.detail) == .notAttempted }.count,
               "applied with revert not attempted")
        append(reverts.filter { Self.facet(ofDetail: $0.detail) == nil }.count,
               "applied then reverted")
        append(outcomeRows.filter { $0.kind == .rejected }.count, "rejected")
        append(outcomeRows.filter { $0.kind == .stale }.count, "stale")
        append(outcomeRows.filter { $0.kind == .failed }.count, "failed")
        guard parts.isEmpty == false else { return nil }
        return "Proposals: " + parts.joined(separator: ", ") + "."
    }

    /// The revert facet an outcome row's `revert=` audit label names, or nil
    /// for a legacy detail without the label (rendered as the generic
    /// "applied then reverted").
    enum RevertFacet: Equatable, Sendable {
        case reverted
        case refused
        case notAttempted
    }

    static func facet(ofDetail detail: String?) -> RevertFacet? {
        guard let detail else { return nil }
        for segment in detail.components(separatedBy: "; ") {
            if segment.hasPrefix("revert=reverted") { return .reverted }
            if segment.hasPrefix("revert=refused") || segment.hasPrefix("revert=failed") {
                return .refused
            }
            if segment.hasPrefix("revert=not attempted") { return .notAttempted }
        }
        return nil
    }

    /// The row title for a pending proposal: the staging-time name.
    func title(for proposalID: String) -> String {
        pendingProposals.first { $0.id == proposalID }?.title ?? proposalID
    }

    // MARK: - Mapping from the durable report

    /// Map a lint attempt's durable report into the review section, or nil
    /// when nothing here applies (a non-lint run, a whole-wiki report-only
    /// run, or a run whose records name no staged proposals).
    ///
    /// `resolved` carries the caller-fetched staged records joined by id;
    /// `outcomes` the durable (or presentation-local) terminal outcomes.
    /// A record's `staged_proposal` id that has an outcome is terminal; one
    /// that resolves to a staged record is pending; one with neither is
    /// unresolvable (the daemon's in-memory record is gone) and renders as
    /// neither — noted honestly by `recordedProposalCount` staying the
    /// anchor while nothing pretends to be reviewable.
    static func make(
        report: QueueAttemptReport,
        wikiID: WikiID,
        resolved: [QueueLintStagedProposal] = [],
        outcomes: [QueueLintProposalOutcome] = []
    ) -> QueueRunDetailsLintProposals? {
        guard report.operation == .lint else { return nil }
        // A whole-wiki lint run is the report-only marker — it stages
        // nothing and its records carry no per-page accounting.
        guard case .targets(let records) = report.scope else { return nil }

        let outcomeByID = Dictionary(outcomes.map { ($0.proposalID, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let resolvedByID = Dictionary(resolved.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        var pending: [PendingProposal] = []
        var rows: [QueueLintProposalOutcome] = []
        var recorded = 0
        for record in records {
            guard let facts = LintPageRecordFacts.parse(record: record) else { continue }
            recorded += facts.proposalCount ?? 0
            for id in facts.stagedProposalIDs {
                if let outcome = outcomeByID[id] {
                    rows.append(outcome)
                } else if let proposal = resolvedByID[id] {
                    pending.append(PendingProposal(proposal: proposal, title: facts.title))
                }
            }
        }
        guard recorded > 0 else { return nil }
        return QueueRunDetailsLintProposals(
            pendingProposals: pending, outcomeRows: rows,
            recordedProposalCount: recorded, wikiID: wikiID)
    }

    // MARK: - Projected diff

    /// The proposal's "after" body: the hunks composed IN MEMORY against
    /// the inspected body — the SAME composition rules the validator and
    /// the store's exact-body path use
    /// (`PagePatchValidator.composedBody`, reverse-range-safe by
    /// construction). No second applier exists. A no-op composition (every
    /// hunk's new text equals its old text) previews as the unchanged body
    /// — the apply service is the component that refuses it for real.
    static func projectedBody(
        proposal: QueueLintStagedProposal, before: String
    ) -> Result<String, PagePatchValidationError> {
        let patch = PagePatch(
            pageID: proposal.pageID, expectHead: proposal.inspectedHead,
            hunks: proposal.hunks, defectClasses: proposal.perHunkClasses)
        do {
            return .success(try PagePatchValidator.composedBody(applying: patch, to: before))
        } catch let error as PagePatchValidationError {
            if case .noOpPatch = error { return .success(before) }
            return .failure(error)
        } catch {
            return .failure(.emptyOrUnpaired(
                defectCount: proposal.perHunkClasses.count, hunkCount: proposal.hunks.count))
        }
    }

    // MARK: - Durable outcome re-read

    /// Re-read one proposal's outcome from the trusted audit trail: the
    /// latest `--kind lint` entry titled `Lint proposal applied — …` whose
    /// note names `proposal_id`. The apply service appends one entry per
    /// terminal outcome, so the audit trail — not the in-flight return
    /// value — is the durable truth the UI renders. Matching is by the
    /// proposal-id label, not the title, so a renamed page still matches.
    static func parseAppliedOutcome(
        entries: [LogEntry], proposalID: String
    ) -> QueueLintProposalOutcome? {
        let label = "proposal_id=\(proposalID)"
        for entry in entries.reversed() {
            guard entry.kind == .lint,
                  entry.title.hasPrefix(LintProposalAudit.appliedAuditTitlePrefix),
                  let note = entry.note,
                  note.components(separatedBy: "; ").contains(label)
            else { continue }
            return parseAppliedNote(note, proposalID: proposalID)
        }
        return nil
    }

    /// Parse one applied-entry note's `outcome=` label and reason tail into
    /// an outcome row. Lenient: a note without an outcome label parses to
    /// nil (the entry still proves something was recorded; the caller keeps
    /// its in-flight answer).
    static func parseAppliedNote(
        _ note: String, proposalID: String
    ) -> QueueLintProposalOutcome? {
        let segments = note.components(separatedBy: "; ")
        var kind: QueueLintProposalOutcome.Kind?
        var detailSegments: [String] = []
        var outcomeSeen = false
        for segment in segments {
            if segment.hasPrefix("outcome=") {
                switch segment.dropFirst("outcome=".count) {
                case "applied": kind = .applied
                case "applied-then-reverted": kind = .appliedThenReverted
                case "stale": kind = .stale
                case "failed": kind = .failed
                default: break
                }
                outcomeSeen = true
                continue
            }
            if outcomeSeen, segment.hasPrefix("proposal_id=") == false {
                detailSegments.append(segment)
            }
        }
        guard let kind else { return nil }
        let detail = detailSegments.joined(separator: "; ")
        return QueueLintProposalOutcome(
            proposalID: proposalID, kind: kind,
            detail: detail.isEmpty ? nil : String(detail.prefix(300)))
    }

    /// Map the apply service's in-flight return to an outcome row — the
    /// fallback when the durable re-read cannot answer (a log read failure
    /// must not lose the outcome the caller just observed).
    static func outcome(from serviceOutcome: LintProposalApplyService.Outcome, proposalID: String) -> QueueLintProposalOutcome {
        switch serviceOutcome {
        case .applied:
            return QueueLintProposalOutcome(proposalID: proposalID, kind: .applied, detail: nil)
        case .appliedThenReverted(_, let revert, let reasons):
            // The revert label LEADS the detail: the summary splits these
            // rows by their actual revert facet, and a refused or not-
            // attempted revert must never read as a clean revert.
            return QueueLintProposalOutcome(
                proposalID: proposalID, kind: .appliedThenReverted,
                detail: ([revert.auditLabel] + reasons).prefix(3).joined(separator: "; "))
        case .stale:
            return QueueLintProposalOutcome(proposalID: proposalID, kind: .stale, detail: nil)
        case .failed(let reason):
            return QueueLintProposalOutcome(
                proposalID: proposalID, kind: .failed, detail: reason)
        }
    }

/// The stale state's fixed sentence — the same words the pane and the
/// tests pin ("page changed since this proposal — re-run lint").
static let staleMessage = "Page changed since this proposal — re-run lint."
}

/// The review section's data source (W5b): the caller-resolved staged
/// records for a page plus the run's tier-2 breaker configuration.
///
/// The daemon owns the staged records (`DaemonLintRunState`, W5a's read
/// seams), and this build ships NO daemon→app transport that can serve
/// them — so production wiring passes `nil` and the section simply does
/// not render rather than guessing. Hosted tests inject a source over a
/// real `DaemonLintRunState`. `breakerKey` is the tier-2 key (live
/// pipeline digest + provider/model/effort, no approval row); nil means
/// the configuration cannot be named — the UI disables the buttons with
/// an explanation instead of recording against a guessed key.
struct QueueStagedProposalSource: Sendable {
    var proposals: @Sendable (PageID) async -> [QueueLintStagedProposal]
    var breakerKey: @Sendable () async -> LintRepairBreakerKey?

    /// Why the actions are unavailable when the key cannot be resolved.
    static let unavailableReason =
        "Review actions are unavailable — the run's repair-breaker configuration could not be resolved."

    /// The production source: proposals resolve through the queue engine's
    /// daemon read seam (the staged records' live values), and the breaker
    /// key is the run configuration identity the daemon recorded — carried
    /// by the resolved records themselves, so the review actions account
    /// against the SAME breaker window the run used. A run whose key was
    /// never recorded resolves `breakerKey` to nil: the actions stay
    /// disabled with ``unavailableReason`` rather than guessing a key.
    static func production(engine: any QueueEngineClient) -> QueueStagedProposalSource {
        let keyBox = ProductionBreakerKeyBox()
        return QueueStagedProposalSource(
            proposals: { pageID in
                let records = await engine.loadLintStagedProposals(for: pageID)
                let mapped = records.compactMap(QueueLintStagedProposal.init(record:))
                keyBox.storeIfEmpty(mapped.compactMap(\.breakerKey).first)
                return mapped
            },
            breakerKey: { keyBox.load() })
    }

    /// The production source's breaker-key carrier: the proposals closure
    /// stores the first recorded key of a load; the breakerKey closure reads
    /// it back. The single `key` field is covered by `lock` on every access,
    /// which is the invariant that makes the unchecked Sendable safe.
    // swiftlint:disable:next unchecked_sendable
    private final class ProductionBreakerKeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: LintRepairBreakerKey?

        func storeIfEmpty(_ newKey: LintRepairBreakerKey?) {
            guard let newKey else { return }
            lock.lock()
            defer { lock.unlock() }
            if key == nil { key = newKey }
        }

        func load() -> LintRepairBreakerKey? {
            lock.lock()
            defer { lock.unlock() }
            return key
        }
    }
}
