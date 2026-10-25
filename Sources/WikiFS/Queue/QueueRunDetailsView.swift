import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The Run Details inspector panel — the selected job's labeled run facts in
/// an optional trailing panel inside the detail column (plan §1's fact list:
/// "enqueue/start/finish time, duration, attempt, actual provider/model,
/// usage and cost"). The panel's open/close lives in the window toolbar's
/// labeled toggle; this view is only the panel's content, so facts render
/// expanded — there is no secondary disclosure inside the panel.
///
/// Values come pre-mapped in `QueueRunDetailsFacts`; the omit-vs-"Not
/// Reported" rules live in `QueueRunDetailsFacts.entries` and are covered by
/// pure tests. The capacity bucket must never arrive as the agent identity's
/// provider — that is the caller's mapping responsibility, documented on the
/// field.
///
/// Facts render as a native List of labeled rows (not a bare Grid) so the
/// panel scrolls, rows stay a stable height, and hosted layout tests can
/// assert through the bridged `NSTableView` row count.
///
/// W2b extends the same List with the lint repair section when the caller
/// supplies `QueueRunDetailsLintRepair`: the "N applied" fixes row, the
/// one-click **Undo lint fixes** button (no confirmation sheet — the undo is
/// itself a reversible history operation), the honest partial aggregate, and
/// the expandable "What went wrong" disclosure rendering already-persisted
/// verification findings plus the reverted diff (`SplitDiffView`, reused
/// verbatim from the page-versions presentation).
struct QueueRunDetailsView: View {
    /// The selected job's run facts; `nil` renders the panel's empty state
    /// (legacy jobs with nothing recorded).
    private let facts: QueueRunDetailsFacts?
    /// The selected lint run's repair section, when it has surviving written
    /// repairs or failure records. `nil` renders nothing extra.
    private let lintRepair: QueueRunDetailsLintRepair?
    /// The selected lint run's staged-proposal review section (W5b), when
    /// its records name proposals. `nil` renders nothing extra.
    private let lintProposals: QueueRunDetailsLintProposals?
    /// The undo action, owned by the caller (the Activity window's store
    /// path). `nil` renders the section read-only.
    private let onUndo: (() -> Void)?
    /// Approve / Reject / Approve-all actions for pending proposals, owned
    /// by the caller. `nil` renders the section without controls.
    private let onApproveProposal: ((QueueLintStagedProposal) -> Void)?
    private let onRejectProposal: ((QueueLintStagedProposal) -> Void)?
    private let onApproveAllProposals: (() -> Void)?
    /// Resolves a page version's body from the wiki store for the reverted
    /// diffs and the proposals' projected diffs. `nil` (or a nil answer)
    /// degrades the disclosure to findings text without the diff, and a
    /// proposal to the stale state.
    private let versionBody: (@MainActor (_ versionID: PageVersionID) -> String?)?
    /// Resolves a page's CURRENT head for the proposals' stale gate (the
    /// head moved → the stale state, no buttons). `nil` degrades to the
    /// stale state — without a live head answer nothing can be applied.
    private let currentHead: (@MainActor (_ pageID: PageID) -> PageVersionID?)?

    @Environment(\.openWindow) private var openWindow

    init(
        _ facts: QueueRunDetailsFacts?,
        lintRepair: QueueRunDetailsLintRepair? = nil,
        lintProposals: QueueRunDetailsLintProposals? = nil,
        onUndo: (() -> Void)? = nil,
        onApproveProposal: ((QueueLintStagedProposal) -> Void)? = nil,
        onRejectProposal: ((QueueLintStagedProposal) -> Void)? = nil,
        onApproveAllProposals: (() -> Void)? = nil,
        versionBody: (@MainActor (_ versionID: PageVersionID) -> String?)? = nil,
        currentHead: (@MainActor (_ pageID: PageID) -> PageVersionID?)? = nil
    ) {
        self.facts = facts
        self.lintRepair = lintRepair
        self.lintProposals = lintProposals
        self.onUndo = onUndo
        self.onApproveProposal = onApproveProposal
        self.onRejectProposal = onRejectProposal
        self.onApproveAllProposals = onApproveAllProposals
        self.versionBody = versionBody
        self.currentHead = currentHead
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            factsRegion
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run Details")
    }

    /// The panel's quiet header — names the surface for VoiceOver and for
    /// the window's visual hierarchy (the toolbar toggle controls it).
    private var panelHeader: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.sm) {
            Text("Run Details")
                .font(.headline)
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    @ViewBuilder
    private var factsRegion: some View {
        if let facts {
            entriesList(facts)
        } else {
            ContentUnavailableView {
                Label("No Run Details", systemImage: "info.circle")
            } description: {
                Text("Nothing recorded for this job.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Labeled values in a native List: secondary labels, selectable values,
    /// placeholders ("Not Reported") in tertiary so absent facts never read
    /// as reported ones. The job id row renders fully monospaced (a copyable
    /// identifier); every other value — timestamps, token counts, cost —
    /// stays monospaced-digit so numbers align without letter-spacing the
    /// text. Usage is one labeled row per present field (Input / Output /
    /// Cached / Thought / Cost), so every row carries its own label.
    private func entriesList(_ facts: QueueRunDetailsFacts) -> some View {
        List {
            ForEach(Array(facts.entries.enumerated()), id: \.offset) { _, entry in
                LabeledContent {
                    Text(entry.value)
                        .font(entry.isMonospaced
                            ? Font.callout.monospaced()
                            : Font.callout.monospacedDigit())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(
                            entry.isPlaceholder
                                ? Color(nsColor: .tertiaryLabelColor)
                                : Color.primary)
                } label: {
                    Text(verbatim: entry.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.label)
            }
            if let lintRepair {
                lintRepairRows(lintRepair)
            }
            if let lintProposals {
                lintProposalRows(lintProposals)
            }
        }
        .listStyle(.plain)
        .accessibilityLabel("Run Details facts")
    }

    // MARK: - Lint repair section (W2b)

    @ViewBuilder
    private func lintRepairRows(_ repair: QueueRunDetailsLintRepair) -> some View {
        if repair.appliedFixCount > 0 {
            fixesRow(repair)
        }
        if repair.showsUndoButton {
            undoButtonRow(repair)
        }
        if let summary = repair.undoSummary {
            undoSummaryRow(summary)
        }
        ForEach(repair.headMovedResults, id: \.pageID) { result in
            headMovedRow(repair, result: result)
        }
        if repair.showsDisclosure {
            failureDisclosure(repair)
        }
    }

    /// The "N fixes applied" row — the count of the run's surviving written
    /// repairs, the same set the undo would revert.
    private func fixesRow(_ repair: QueueRunDetailsLintRepair) -> some View {
        LabeledContent {
            Text("\(repair.appliedFixCount) applied")
                .font(.callout.monospacedDigit())
        } label: {
            Text("Lint fixes")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lint fixes")
    }

    /// The one-click undo. Deliberately NOT disabled by a moved head — the
    /// batch reports per-page outcomes honestly — and hidden entirely once
    /// an undo ran (the repairs are gone; a second click would record a
    /// second breaker undo for the same decision).
    private func undoButtonRow(_ repair: QueueRunDetailsLintRepair) -> some View {
        HStack {
            Button {
                onUndo?()
            } label: {
                Label("Undo lint fixes", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(repair.undoInFlight)
            .help("Revert every page this run repaired to the version it inspected. Pages changed since the run are left alone.")
            .accessibilityLabel("Undo lint fixes")
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func undoSummaryRow(_ summary: String) -> some View {
        Text(verbatim: summary)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(summary)
    }

    /// One page the batch could not revert: the run's repair is still in
    /// place, and the established page-history window is the manual path.
    private func headMovedRow(_ repair: QueueRunDetailsLintRepair, result: LintUndoService.PageResult) -> some View {
        let title = Self.pageTitle(for: result.pageID, in: repair)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(title): page changed since this run — revert manually from page history")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                openWindow(value: PageVersionCompareContext(
                    pageID: result.pageID, title: title, wikiID: repair.wikiID))
            } label: {
                Label("Open page history", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Compare and restore versions for this page")
            .accessibilityLabel("Open page history for \(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// The "What went wrong" disclosure for failed-verification and undone
    /// runs: a button row (a real button, not a DisclosureGroup, so the
    /// hosted tests can press it and VoiceOver reads one stable label), then
    /// the persisted findings and the reverted diffs when expanded.
    private func failureDisclosure(_ repair: QueueRunDetailsLintRepair) -> some View {
        DisclosureContent(
            repair: repair,
            versionBody: versionBody)
    }

    /// The expanded disclosure's rows: per-page findings from the run's
    /// persisted record, the reverted diffs (written version vs the version
    /// the run inspected — both in page history), and the breaker context.
    private struct DisclosureContent: View {
        let repair: QueueRunDetailsLintRepair
        let versionBody: (@MainActor (_ versionID: PageVersionID) -> String?)?

        @State private var isExpanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        isExpanded ? "Hide what went wrong" : "What went wrong",
                        systemImage: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("What went wrong")
                if isExpanded {
                    findingsRows
                    if let context = repair.breakerContext {
                        Text(verbatim: context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let notice = repair.breakerNotice {
                        Text(verbatim: notice)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }

        @ViewBuilder
        private var findingsRows: some View {
            ForEach(repair.failurePages) { page in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: page.title)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                    if page.reasons.isEmpty {
                        Text("The page was reverted automatically after this run's write failed verification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        ForEach(Array(page.reasons.enumerated()), id: \.offset) { _, reason in
                            Text("• \(reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    diffPane(for: page)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Verification findings for \(page.title)")
            }
        }

        @ViewBuilder
        private func diffPane(for page: QueueRunDetailsLintRepair.FailurePage) -> some View {
            if let inspected = page.inspectedHead, let written = page.writtenHead,
               inspected != written {
                RevertedDiffPane(
                    pageID: page.pageID,
                    inspectedHead: inspected,
                    writtenHead: written,
                    versionBody: versionBody)
            }
        }
    }

    /// One reverted page's before/after diff: the version the run inspected
    /// (left) against the version the run wrote (right) — the same two
    /// versions the auto-revert (or the undo) moved between, both durable in
    /// page history. Bodies load lazily through the caller's store closure;
    /// the reused `SplitDiffView` computes the alignment off the main thread.
    private struct RevertedDiffPane: View {
        let pageID: PageID
        let inspectedHead: PageVersionID
        let writtenHead: PageVersionID
        let versionBody: (@MainActor (_ versionID: PageVersionID) -> String?)?

        @State private var inspectedBody: String?
        @State private var writtenBody: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reverted diff")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let inspectedBody, let writtenBody {
                    SplitDiffView(
                        leftLabel: "Before this run",
                        rightLabel: "The run's write (reverted)",
                        left: inspectedBody,
                        right: writtenBody)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor)))
                } else {
                    Text("Version bodies unavailable for this diff.")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.top, 2)
            .task(id: "\(pageID.rawValue)\u{0}\(inspectedHead.rawValue)\u{0}\(writtenHead.rawValue)") {
                loadBodies()
            }
        }

        private func loadBodies() {
            guard let versionBody else { return }
            if inspectedBody == nil {
                inspectedBody = versionBody(inspectedHead)
            }
            if writtenBody == nil {
                writtenBody = versionBody(writtenHead)
            }
        }
    }

    // MARK: - Staged-proposal review section (W5b)

    /// The tier-2 review rows: one row per pending proposal (summary,
    /// projected diff, Approve/Reject), an Approve-all row, the breaker
    /// lines, and the collapsed outcome summary. After every proposal
    /// resolves, only the summary (and the breaker lines) render — the
    /// controls disappear rather than staying enabled.
    @ViewBuilder
    private func lintProposalRows(_ proposals: QueueRunDetailsLintProposals) -> some View {
        if proposals.showsSection {
            proposalsHeaderRow(proposals)
            ForEach(proposals.pendingProposals) { pending in
                ProposalReviewRow(
                    pending: pending,
                    section: proposals,
                    versionBody: versionBody,
                    currentHead: currentHead,
                    onApprove: onApproveProposal.map { action in
                        { action(pending.proposal) }
                    },
                    onReject: onRejectProposal.map { action in
                        { action(pending.proposal) }
                    })
            }
            if proposals.showsApproveAll {
                approveAllRow(proposals)
            }
            if let notice = proposals.breakerNotice {
                breakerNoticeRow(notice)
            }
            if let reason = proposals.actionUnavailableReason {
                actionUnavailableRow(reason)
            }
            if let summary = proposals.outcomeSummary {
                outcomeSummaryRow(summary)
            }
            if let context = proposals.breakerContext, proposals.showsReviewControls {
                breakerContextRow(context)
            }
        }
    }

    /// The section's quiet header: the recorded proposal count ("N
    /// proposed"), the same label vocabulary the per-page records use.
    private func proposalsHeaderRow(_ proposals: QueueRunDetailsLintProposals) -> some View {
        LabeledContent {
            Text("\(proposals.recordedProposalCount) proposed")
                .font(.callout.monospacedDigit())
        } label: {
            Text("Repair proposals")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repair proposals")
    }

    /// The Approve-all batch: one click, every pending proposal, the honest
    /// aggregate afterwards (the outcome summary row).
    private func approveAllRow(_ proposals: QueueRunDetailsLintProposals) -> some View {
        HStack {
            Button {
                onApproveAllProposals?()
            } label: {
                Label("Approve all", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(proposals.isDisabled(""))
            .help("Apply every pending proposal. Each one is checked against the page's current state and reported individually.")
            .accessibilityLabel("Approve all proposals")
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// The breaker's plain trip message after a rejection or verification
    /// failure — the same presentation as the W2b undo section's.
    private func breakerNoticeRow(_ notice: String) -> some View {
        Text(verbatim: notice)
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(notice)
    }

    /// Why the review actions are unavailable — the tier-2 breaker
    /// configuration could not be resolved, so nothing may be recorded.
    private func actionUnavailableRow(_ reason: String) -> some View {
        Text(verbatim: reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(reason)
    }

    /// The collapsed aggregate ("Proposals: 2 applied, 1 stale.") — the
    /// section's shape after every proposal resolved.
    private func outcomeSummaryRow(_ summary: String) -> some View {
        Text(verbatim: summary)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(summary)
    }

    /// The breaker window's read-only status line while review controls
    /// render ("1 of 2 allowed user rejections used…").
    private func breakerContextRow(_ context: String) -> some View {
        Text(verbatim: context)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(context)
    }

    /// One pending proposal's review row: the staging-time title, the hunk
    /// count and classes, the projected before/after diff (or the stale
    /// state with NO buttons), and the Approve/Reject controls. Buttons are
    /// hidden once the page head moved (the apply would refuse as stale
    /// anyway) and disabled while any apply is in flight or the breaker
    /// configuration is unresolvable.
    private struct ProposalReviewRow: View {
        let pending: QueueRunDetailsLintProposals.PendingProposal
        let section: QueueRunDetailsLintProposals
        let versionBody: (@MainActor (_ versionID: PageVersionID) -> String?)?
        let currentHead: (@MainActor (_ pageID: PageID) -> PageVersionID?)?
        let onApprove: (() -> Void)?
        let onReject: (() -> Void)?

        @State private var isStale = false
        @State private var beforeBody: String?
        @State private var afterBody: String?

        private var proposal: QueueLintStagedProposal { pending.proposal }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(pending.title) — \(proposal.hunkCount) hunks proposed")
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                if proposal.classLabels.isEmpty == false {
                    Text(verbatim: "Defect classes: \(proposal.classLabels)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                diffRegion
                if isStale == false {
                    controls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Proposed repairs for \(pending.title)")
            .task(id: "\(proposal.id)\u{0}\(proposal.inspectedHead.rawValue)") {
                load()
            }
        }

        @ViewBuilder
        private var diffRegion: some View {
            if isStale {
                Text(verbatim: QueueRunDetailsLintProposals.staleMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let beforeBody, let afterBody {
                SplitDiffView(
                    leftLabel: "Inspected",
                    rightLabel: "After approval",
                    left: beforeBody,
                    right: afterBody)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor)))
            } else {
                Text("Loading the projected diff…")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }

        private var controls: some View {
            HStack(spacing: QueueWorkspaceMetrics.Spacing.sm) {
                Button {
                    onApprove?()
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(section.isDisabled(proposal.id))
                .help("Write these hunks to the page. The write is verified and reverted automatically if it does not check out.")
                .accessibilityLabel("Approve proposal for \(pending.title)")
                Button {
                    onReject?()
                } label: {
                    Label("Reject", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(section.isDisabled(proposal.id))
                .help("Discard this proposal without writing anything. Repeated rejections pause auto-repair for this configuration.")
                .accessibilityLabel("Reject proposal for \(pending.title)")
                if section.isDisabled(proposal.id), section.actionUnavailableReason == nil {
                    Text("Applying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        /// The stale gate + diff load. The page head must still be the head
        /// the hunks were composed against, and the inspected body must be
        /// readable — otherwise the stale state renders with no buttons.
        private func load() {
            let head = currentHead?(proposal.pageID)
            guard head == proposal.inspectedHead else {
                isStale = true
                return
            }
            guard let before = versionBody?(proposal.inspectedHead) else {
                isStale = true
                return
            }
            guard case .success(let after) =
                QueueRunDetailsLintProposals.projectedBody(
                    proposal: proposal, before: before)
            else {
                isStale = true
                return
            }
            beforeBody = before
            afterBody = after
        }
    }

    /// The display title for a page result, resolved from the section's own
    /// records (the report preserved the staging-time name), falling back to
    /// the raw id.
    static func pageTitle(for pageID: PageID, in repair: QueueRunDetailsLintRepair) -> String {
        if let repairPage = repair.repairPages.first(where: { $0.pageID == pageID }) {
            return repairPage.title
        }
        if let failurePage = repair.failurePages.first(where: { $0.pageID == pageID }) {
            return failurePage.title
        }
        return pageID.rawValue
    }
}
