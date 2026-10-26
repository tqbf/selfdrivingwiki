import Foundation
import Observation
import WikiFSCore
import WikiFSEngine

// pattern: Mixed (unavoidable)

/// The window that started an interactive lint. The results sheet presents
/// on that window only — two windows can show the same wiki, and the sheet
/// belongs to the one the person clicked Lint in.
struct InteractiveLintHostID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// The one page an interactive lint checks, and where its results present.
struct InteractiveLintTarget: Equatable, Sendable {
    let wikiID: WikiID
    let pageID: PageID
    let title: String
    let hostID: InteractiveLintHostID
}

/// How a queue item ended, as the engine reports it after settlement.
struct InteractiveLintSettlement: Equatable, Sendable {
    let state: QueueItemState
    let error: String?
}

/// The execution seam of the interactive lint: the daemon's queue engine in
/// production (the only host that runs lint under the coordinator — the
/// scoped lease, the CAS receipts, the written-version records, and the
/// durable per-page records the dialog reads). Tests drive a fake.
protocol InteractiveLintBackend: Sendable {
    /// Submit one item; returns its ID.
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID
    /// Ask the engine to cancel one item.
    func cancel(_ itemID: QueueItem.ID) async throws
    /// Wait until the item is terminal and return how it ended.
    func awaitSettlement(of itemID: QueueItem.ID) async throws -> InteractiveLintSettlement
    /// The item's durable report.
    func loadReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult
}

/// The production backend over the app's queue engine client (the daemon
/// proxy). Settlement is read back from the engine's snapshot, because the
/// completion wait is bounded (a wait timeout is not an item failure) and
/// does not name cancellation.
struct QueueEngineInteractiveLintBackend: InteractiveLintBackend {
    let client: any QueueEngineClient

    /// The pause before re-observing an item the wait returned on while it
    /// was still active (the WAIT timed out, not the work).
    static let reobserveInterval: Duration = .seconds(2)

    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        try await client.enqueue(request)
    }

    func cancel(_ itemID: QueueItem.ID) async throws {
        try await client.cancelItem(itemID)
    }

    func awaitSettlement(of itemID: QueueItem.ID) async throws -> InteractiveLintSettlement {
        while true {
            try Task.checkCancellation()
            let waited = try await client.waitForCompletion(of: itemID)
            let snapshot = try await client.snapshot()
            guard let item = (snapshot.activeItems + snapshot.recentItems)
                .first(where: { $0.id == itemID }) else {
                // The item left the snapshot's window: the wait's own
                // answer is all the engine still states.
                switch waited {
                case .success:
                    return InteractiveLintSettlement(state: .completed, error: nil)
                case .failure(let error):
                    return InteractiveLintSettlement(state: .failed, error: error.localizedDescription)
                }
            }
            switch item.state {
            case .completed, .failed, .cancelled:
                return InteractiveLintSettlement(state: item.state, error: item.error)
            case .queued, .running:
                try await Task.sleep(for: Self.reobserveInterval)
            }
        }
    }

    func loadReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult {
        await client.loadQueueReport(for: itemID)
    }
}

/// What an interactive lint found, as the results dialog states it.
enum InteractiveLintOutcome: Equatable, Sendable {
    /// The run's durable record lists findings for the page. `runFailure`
    /// is set when the run ended with an error after recording them.
    case findings(QueueRunDetailsLintFindings, runFailure: String?)
    /// The run's durable record states zero findings — a clean bill of
    /// health. `reportOnlyReason` is the recorded reason the run did not
    /// repair, when its record names a report-only tier.
    case clean(reportOnlyReason: String?)
    /// The run produced no findings record for the page.
    case failed(reason: String)

    /// Map one settled lint run into the dialog's outcome, or nil for a run
    /// the person cancelled (cancellation ends without a dialog).
    ///
    /// Only the durable per-page record speaks for the run (the W5c data
    /// path): a clean bill needs a record that states `findings=0`, and a
    /// failed run never reads as clean.
    static func make(
        settlement: InteractiveLintSettlement,
        report: QueueReportLoadResult?,
        pageID: PageID
    ) -> InteractiveLintOutcome? {
        if settlement.state == .cancelled { return nil }
        let runFailure: String? = settlement.state == .failed
            ? (settlement.error ?? "the lint run failed")
            : nil
        let section: QueueRunDetailsLintFindings?
        switch report {
        case .loaded(let attempt):
            section = QueueRunDetailsLintFindings.make(report: attempt).flatMap {
                pageSection($0, pageID: pageID)
            }
        case .notReported, .unavailable, .none:
            section = nil
        }
        guard let section else {
            if let runFailure { return .failed(reason: runFailure) }
            if case .unavailable(let reason) = report {
                return .failed(reason: "the run's report could not be read (\(reason))")
            }
            return .failed(reason: "the run recorded no findings for this page")
        }
        if section.totalCount > 0 {
            return .findings(section, runFailure: runFailure)
        }
        if let runFailure { return .failed(reason: runFailure) }
        return .clean(reportOnlyReason: section.reportOnlyReason)
    }

    /// The section narrowed to the linted page.
    private static func pageSection(
        _ section: QueueRunDetailsLintFindings, pageID: PageID
    ) -> QueueRunDetailsLintFindings? {
        let pages = section.pages.filter { $0.pageID == pageID }
        guard pages.isEmpty == false else { return nil }
        return QueueRunDetailsLintFindings(pages: pages, reportOnlyReason: section.reportOnlyReason)
    }
}

/// One in-flight interactive lint.
struct InteractiveLintRun: Equatable, Sendable {
    /// Where the run is in its lifecycle.
    enum Phase: Equatable, Sendable {
        /// The lint item is being submitted.
        case submitting
        /// The lint item runs.
        case linting(QueueItem.ID)
        /// The person cancelled; the item ID is nil when the cancel came
        /// before the submission returned.
        case cancelling(QueueItem.ID?)
    }

    /// Identifies this run, so a late completion of an abandoned run is
    /// ignored.
    let token: UUID
    let target: InteractiveLintTarget
    var phase: Phase

    var isCancelling: Bool {
        if case .cancelling = phase { return true }
        return false
    }
}

/// The results dialog's state: the outcome plus the per-finding fixes
/// started from it.
struct InteractiveLintPresentation: Equatable, Sendable, Identifiable {
    let target: InteractiveLintTarget
    /// The lint run's queue item — the origin every fix names.
    let lintItemID: QueueItem.ID
    let outcome: InteractiveLintOutcome
    /// The fix runs started from this dialog, oldest first.
    var fixRuns: [QueueLintFindingFixState.FixRun] = []
    /// Fix clicks whose submission has not returned yet.
    var fixEnqueueing: Set<QueueLintFindingKey> = []
    /// Fix clicks whose submission failed — the honest reason.
    var fixEnqueueProblems: [QueueLintFindingKey: String] = [:]

    var id: QueueItem.ID { lintItemID }

    /// Whether a fix started from this dialog is still in flight. The
    /// dialog stays open (and Lint stays disabled) until it settles.
    var isFixInFlight: Bool {
        fixEnqueueing.isEmpty == false || fixRuns.contains(where: \.isActive)
    }

    /// The findings with every row's fix state derived from this dialog's
    /// fix runs (the same derivation Run Details uses), or nil when the
    /// outcome lists no findings.
    var findings: QueueRunDetailsLintFindings? {
        guard case .findings(var findings, _) = outcome else { return nil }
        for page in findings.pages {
            let pageEnqueueing = fixEnqueueing.contains { $0.pageID == page.pageID }
            for finding in page.findings {
                let key = QueueLintFindingKey(pageID: page.pageID, findingID: finding.occurrenceID)
                findings.fixStates[key] = QueueLintFindingFixState.derive(
                    finding: finding, pageID: page.pageID,
                    inspectedHead: page.inspectedHead, fixRuns: fixRuns,
                    enqueueing: fixEnqueueing.contains(key),
                    enqueueProblem: fixEnqueueProblems[key],
                    pageEnqueueing: pageEnqueueing)
            }
        }
        return findings
    }

    /// The dialog's headline.
    var headline: String {
        switch outcome {
        case .findings(let findings, _):
            return findings.totalCount == 1
                ? "1 validity defect detected"
                : "\(findings.totalCount) validity defects detected"
        case .clean:
            return InteractiveLintPresentation.cleanHeadline
        case .failed:
            return "Lint did not finish"
        }
    }

    static let cleanHeadline = "No validity defects detected."

    /// The run-level line: the outcome stated honestly, with the recorded
    /// report-only reason when the run was report-only.
    var runLine: String {
        switch outcome {
        case .findings(let findings, let runFailure):
            if let runFailure {
                return "The lint run ended with an error: \(runFailure). "
                    + "The findings below were recorded before it stopped."
            }
            return findings.reportOnlyLine
                ?? "Choose Fix on a finding to repair only that finding, or Edit the page manually."
        case .clean(let reportOnlyReason):
            guard let reportOnlyReason else { return "The page passed every validity check." }
            return "Report-only run — \(reportOnlyReason). Findings are reported, not repaired."
        case .failed(let reason):
            return "No findings were recorded: \(reason)."
        }
    }
}

/// The app's interactive lint (W7): the person lints the page they are on,
/// exactly one lint runs at a time app-wide, and every run ends in a modal
/// results dialog — the findings with per-finding Fix / Edit Manually, or a
/// clean bill of health.
///
/// The lifecycle is one finite state machine — `idle → running(page) →
/// presenting(result) → idle` — never a cluster of flags. The lint runs as
/// a detection pass: the selected-page lint under the production gate,
/// which is report-only. Fixes happen afterward, per finding, through the
/// W6 per-finding repair item (verification, auto-revert, breaker).
///
/// The run itself executes on the daemon's queue engine — the host that
/// owns the lint coordinator and the durable records. The queue is the
/// transport, not the user's entry point: the service owns the item from
/// submission to dialog, and the item stays in the Activity history as the
/// durable record.
@MainActor
@Observable
final class InteractiveLintService {

    enum State: Equatable, Sendable {
        case idle
        case running(InteractiveLintRun)
        case presenting(InteractiveLintPresentation)
    }

    /// Why a start was refused.
    enum StartRefusal: Error, Equatable {
        /// A lint, or a fix from its dialog, is already in flight.
        case busy
    }

    /// The single source of truth.
    private(set) var state: State = .idle

    /// How long a cancelled run may take to settle before the service stops
    /// waiting and returns to idle (bounded termination: the engine's
    /// cancel is asynchronous, and the service never waits on it forever).
    let cancelGrace: Duration

    /// Bounded retries for a settled fix run's report (the report commits
    /// just after the item settles).
    static let fixReportAttempts = 3
    static let fixReportRetryInterval: Duration = .seconds(1)

    /// The backend of the current run and its dialog's fixes.
    @ObservationIgnored private var backend: (any InteractiveLintBackend)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    init(cancelGrace: Duration = .seconds(15)) {
        self.cancelGrace = cancelGrace
    }

    // MARK: - Derived

    /// Whether a new lint may start: only from idle.
    var canStart: Bool { state == .idle }

    /// The in-flight run, if any.
    var run: InteractiveLintRun? {
        if case .running(let run) = state { return run }
        return nil
    }

    /// The dialog's state, if one presents.
    var presentation: InteractiveLintPresentation? {
        if case .presenting(let presentation) = state { return presentation }
        return nil
    }

    /// The dialog for one window, or nil.
    func presentation(for hostID: InteractiveLintHostID) -> InteractiveLintPresentation? {
        guard let presentation, presentation.target.hostID == hostID else { return nil }
        return presentation
    }

    /// The in-flight run for one page, or nil.
    func run(for pageID: PageID) -> InteractiveLintRun? {
        guard let run, run.target.pageID == pageID else { return nil }
        return run
    }

    // MARK: - Lint

    /// Start the interactive lint of one page. Refused (nothing submitted)
    /// unless the service is idle.
    func start(
        _ target: InteractiveLintTarget,
        backend: any InteractiveLintBackend
    ) -> Result<Void, StartRefusal> {
        guard state == .idle else {
            DebugLog.ingest("interactive lint: start refused for \(target.pageID.rawValue) — busy")
            return .failure(.busy)
        }
        let run = InteractiveLintRun(token: UUID(), target: target, phase: .submitting)
        self.backend = backend
        state = .running(run)
        DebugLog.ingest("interactive lint: start \(target.pageID.rawValue) in wiki \(target.wikiID.rawValue.prefix(8))")
        let request = QueueItemRequest(
            queue: .ingestion,
            wikiID: target.wikiID,
            payload: QueueItemPayload(
                sourceIDs: [],
                lintPageIDs: [target.pageID],
                recordedNames: [target.pageID.rawValue: target.title]))
        runTask = Task { @MainActor [weak self] in
            await self?.drive(run, request: request, backend: backend)
        }
        return .success(())
    }

    /// Cancel the in-flight lint. The engine's cancel is asynchronous; the
    /// service returns to idle when the run settles, or after
    /// `cancelGrace` at the latest.
    func cancel() {
        guard var run, run.isCancelling == false else { return }
        let itemID: QueueItem.ID?
        switch run.phase {
        case .submitting: itemID = nil
        case .linting(let id): itemID = id
        case .cancelling: return
        }
        run.phase = .cancelling(itemID)
        state = .running(run)
        DebugLog.ingest("interactive lint: cancel requested for \(run.target.pageID.rawValue)")
        if let itemID { requestEngineCancel(itemID) }
        let token = run.token
        let grace = cancelGrace
        graceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return // the run settled first and cancelled the timer
            }
            self?.abandonRun(token: token)
        }
    }

    /// Close the dialog. Refused while a fix from it is in flight.
    func dismiss() {
        guard let presentation, presentation.isFixInFlight == false else { return }
        DebugLog.ingest("interactive lint: dialog closed for \(presentation.target.pageID.rawValue)")
        reset()
    }

    /// The window that started the lint went away (closed, or switched to
    /// another wiki). A running lint is cancelled; a dialog is dropped. Fix
    /// runs already submitted keep running in the engine — their durable
    /// records stay in the fix runs' Run Details.
    func hostDidDisappear(_ hostID: InteractiveLintHostID) {
        switch state {
        case .idle:
            return
        case .running(let run):
            guard run.target.hostID == hostID else { return }
            cancel()
        case .presenting(let presentation):
            guard presentation.target.hostID == hostID else { return }
            DebugLog.ingest("interactive lint: host closed; dropping the dialog for \(presentation.target.pageID.rawValue)")
            reset()
        }
    }

    // MARK: - Fix (the W6 per-finding repair, from the dialog)

    /// A person's Fix click on one finding in the dialog: submit the W6
    /// per-finding repair item, then follow it to its durable record. One
    /// fix per page at a time, held from the click on.
    func fix(
        page: QueueRunDetailsLintFindings.PageFindings,
        finding: LintPageRecordFacts.RecordFinding
    ) {
        guard var presentation, let backend, let inspectedHead = page.inspectedHead else { return }
        let key = QueueLintFindingKey(pageID: page.pageID, findingID: finding.occurrenceID)
        guard presentation.findings?.fixStates[key] == .available else { return }
        presentation.fixEnqueueing.insert(key)
        presentation.fixEnqueueProblems[key] = nil
        state = .presenting(presentation)
        let request = QueueLintFindingFixState.fixRequest(
            wikiID: presentation.target.wikiID, page: page, finding: finding,
            inspectedHead: inspectedHead, originItemID: presentation.lintItemID)
        let lintItemID = presentation.lintItemID
        Task { @MainActor [weak self] in
            await self?.driveFix(
                key: key, request: request, lintItemID: lintItemID, backend: backend)
        }
    }

    // MARK: - Private

    private func drive(
        _ run: InteractiveLintRun,
        request: QueueItemRequest,
        backend: any InteractiveLintBackend
    ) async {
        let itemID: QueueItem.ID
        do {
            itemID = try await backend.enqueue(request)
        } catch {
            DebugLog.ingest("interactive lint: submit failed for \(run.target.pageID.rawValue): \(error)")
            guard isCurrent(run.token) else { return }
            if self.run?.isCancelling == true {
                reset()
            } else {
                // No item exists, so there is no lint item to anchor fixes.
                present(InteractiveLintPresentation(
                    target: run.target, lintItemID: QueueItem.ID(rawValue: ""),
                    outcome: .failed(reason: "the lint could not start (\(error.localizedDescription))")))
            }
            return
        }
        guard isCurrent(run.token), var current = self.run else {
            // Abandoned while submitting: the item still exists — cancel it.
            requestEngineCancel(itemID, on: backend)
            return
        }
        if current.isCancelling {
            current.phase = .cancelling(itemID)
            state = .running(current)
            requestEngineCancel(itemID)
        } else {
            current.phase = .linting(itemID)
            state = .running(current)
        }

        let settlement: InteractiveLintSettlement
        do {
            settlement = try await backend.awaitSettlement(of: itemID)
        } catch {
            DebugLog.ingest("interactive lint: settlement wait failed for \(itemID.rawValue): \(error)")
            guard isCurrent(run.token) else { return }
            if self.run?.isCancelling == true {
                reset()
            } else {
                present(InteractiveLintPresentation(
                    target: run.target, lintItemID: itemID,
                    outcome: .failed(reason: "the run's outcome could not be read (\(error.localizedDescription))")))
            }
            return
        }
        guard isCurrent(run.token) else { return }
        let report: QueueReportLoadResult? = settlement.state == .cancelled
            ? nil : await backend.loadReport(for: itemID)
        guard isCurrent(run.token) else { return }
        guard let outcome = InteractiveLintOutcome.make(
            settlement: settlement, report: report, pageID: run.target.pageID) else {
            DebugLog.ingest("interactive lint: run \(itemID.rawValue) cancelled — no dialog")
            reset()
            return
        }
        if self.run?.isCancelling == true, settlement.state != .cancelled {
            // The run finished before the cancel landed: the result is real,
            // so it presents like any other.
            DebugLog.ingest("interactive lint: run \(itemID.rawValue) settled before the cancel landed")
        }
        present(InteractiveLintPresentation(
            target: run.target, lintItemID: itemID, outcome: outcome))
    }

    private func driveFix(
        key: QueueLintFindingKey,
        request: QueueItemRequest,
        lintItemID: QueueItem.ID,
        backend: any InteractiveLintBackend
    ) async {
        let fixItemID: QueueItem.ID
        do {
            fixItemID = try await backend.enqueue(request)
        } catch {
            DebugLog.ingest("interactive lint: fix submit failed for \(key.findingID): \(error)")
            updatePresentation(lintItemID) {
                $0.fixEnqueueing.remove(key)
                $0.fixEnqueueProblems[key] = error.localizedDescription
            }
            return
        }
        DebugLog.ingest("interactive lint: fix run \(fixItemID.rawValue) for \(key.findingID) on \(key.pageID.rawValue)")
        updatePresentation(lintItemID) {
            $0.fixEnqueueing.remove(key)
            $0.fixRuns.append(QueueLintFindingFixState.FixRun(
                itemID: fixItemID, pageID: key.pageID, findingID: key.findingID,
                state: .running, error: nil, record: nil))
        }
        let settlement: InteractiveLintSettlement
        do {
            settlement = try await backend.awaitSettlement(of: fixItemID)
        } catch {
            DebugLog.ingest("interactive lint: fix settlement wait failed for \(fixItemID.rawValue): \(error)")
            settlement = InteractiveLintSettlement(
                state: .failed, error: "the fix run's outcome could not be read (\(error.localizedDescription))")
        }
        var record: LintPageRecordFacts?
        if settlement.state != .cancelled {
            record = await loadFixRecord(fixItemID, pageID: key.pageID, backend: backend)
        }
        updatePresentation(lintItemID) { presentation in
            guard let index = presentation.fixRuns.firstIndex(where: { $0.itemID == fixItemID }) else { return }
            var state = settlement.state
            if record == nil, state == .completed {
                // Settled, but its record never loaded: name the gap
                // instead of leaving the row "Fixing…" forever.
                state = .failed
            }
            presentation.fixRuns[index] = QueueLintFindingFixState.FixRun(
                itemID: fixItemID, pageID: key.pageID, findingID: key.findingID,
                state: state,
                error: record == nil && settlement.state == .completed
                    ? "the fix run's record did not load — open its Run Details"
                    : settlement.error,
                record: record)
        }
    }

    /// The settled fix run's durable page record, with bounded retries.
    private func loadFixRecord(
        _ itemID: QueueItem.ID, pageID: PageID, backend: any InteractiveLintBackend
    ) async -> LintPageRecordFacts? {
        for attempt in 1...Self.fixReportAttempts {
            if case .loaded(let report) = await backend.loadReport(for: itemID),
               let facts = ActivityWindowView.pageRecordFacts(in: report, pageID: pageID) {
                return facts
            }
            guard attempt < Self.fixReportAttempts else { break }
            do {
                try await Task.sleep(for: Self.fixReportRetryInterval)
            } catch {
                return nil
            }
        }
        DebugLog.ingest("interactive lint: no record for fix run \(itemID.rawValue)")
        return nil
    }

    private func updatePresentation(
        _ lintItemID: QueueItem.ID, _ update: (inout InteractiveLintPresentation) -> Void
    ) {
        guard var presentation, presentation.lintItemID == lintItemID else { return }
        update(&presentation)
        state = .presenting(presentation)
    }

    private func present(_ presentation: InteractiveLintPresentation) {
        graceTask?.cancel()
        graceTask = nil
        runTask = nil
        DebugLog.ingest("interactive lint: presenting \(presentation.headline) for \(presentation.target.pageID.rawValue)")
        state = .presenting(presentation)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        run?.token == token
    }

    /// The cancel grace expired: stop waiting on the run.
    private func abandonRun(token: UUID) {
        guard isCurrent(token) else { return }
        DebugLog.ingest("interactive lint: cancelled run did not settle within the grace — returning to idle")
        runTask?.cancel()
        reset()
    }

    private func reset() {
        graceTask?.cancel()
        graceTask = nil
        runTask = nil
        backend = nil
        state = .idle
    }

    private func requestEngineCancel(_ itemID: QueueItem.ID) {
        guard let backend else { return }
        requestEngineCancel(itemID, on: backend)
    }

    private func requestEngineCancel(_ itemID: QueueItem.ID, on backend: any InteractiveLintBackend) {
        Task {
            do {
                try await backend.cancel(itemID)
            } catch {
                DebugLog.ingest("interactive lint: engine cancel failed for \(itemID.rawValue): \(error)")
            }
        }
    }
}
