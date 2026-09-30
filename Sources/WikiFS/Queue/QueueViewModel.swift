import SwiftUI
import WikiFSCore
import WikiFSEngine

/// A view-model for the Activity window. Fetches snapshots from the engine
/// and updates on every queue event.
@MainActor
@Observable
final class QueueViewModel {
    var snapshot: QueueSnapshot = QueueSnapshot()
    private var streamTask: Task<Void, Never>?

    private weak var queueEngine: (any QueueEngineClient)?

    // MARK: Selected-job report (Overview surface)

    /// Load state of the selected job's durable attempt report. Loaded via
    /// ``loadReport(for:attempt:)``; the Overview maps it to presentation
    /// values. Report truth rules: a `.notReported` load is a truthful
    /// "no report recorded", and `.unavailable` labels reporting unavailable
    /// without inventing outcomes.
    enum SelectedReportState: Equatable {
        case idle
        case loading
        /// No report exists for the item's current attempt (legacy jobs, or
        /// the producer never began one).
        case notReported
        case loaded(QueueAttemptReport)
        /// Store/transport/capability failure — keep lifecycle presentation,
        /// label reporting unavailable.
        case unavailable(reason: String)
    }

    /// Which item the report state below describes. Doubles as the stale-
    /// selection guard: any load that finishes after the selection moved on
    /// is discarded instead of writing another job's report into this pane.
    private(set) var selectedReportItemID: QueueItem.ID?
    private(set) var selectedReport: SelectedReportState = .idle

    func attach(engine: any QueueEngineClient) {
        queueEngine = engine
        streamTask?.cancel()
        // Subscribe before loading so events during the initial read are buffered.
        let events = engine.events
        streamTask = Task { @MainActor [weak self] in
            await self?.refresh()
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func detach() {
        streamTask?.cancel()
        streamTask = nil
        queueEngine = nil
        selectedReportItemID = nil
        selectedReport = .idle
    }

    func refresh() async {
        guard let engine = queueEngine else { return }
        do {
            let next = try await engine.snapshot()
            guard !Task.isCancelled, queueEngine === engine else { return }
            snapshot = next
        } catch {
            DebugLog.store("QueueViewModel: snapshot failed: \(error)")
        }
    }

    /// Load the selected job's durable report (plan §3: subscribe before load
    /// — the tracker's event stream is already live before this runs).
    ///
    /// Stale-selection guard: after the awaited load, the write only lands if
    /// the window is still attached to this engine AND this item is still the
    /// requested selection. `.task(id:)` cancellation is cooperative only, so
    /// the explicit identity check is what actually prevents a slow daemon
    /// load from writing a previous selection's report into the pane.
    ///
    /// Stale-attempt guard: a load that raced a retry carries the previous
    /// attempt's report (`report.attemptID.attempt != attempt`) and is
    /// discarded — the caller re-invokes with the new attempt.
    func loadReport(for itemID: QueueItem.ID, attempt: Int) async {
        guard let engine = queueEngine else { return }
        selectedReportItemID = itemID
        selectedReport = .loading
        let result = await engine.loadQueueReport(for: itemID)
        guard !Task.isCancelled, queueEngine === engine,
              selectedReportItemID == itemID else { return }
        switch result {
        case .loaded(let report):
            guard report.attemptID.attempt == attempt else {
                selectedReport = .notReported
                return
            }
            selectedReport = .loaded(report)
        case .notReported:
            selectedReport = .notReported
        case .unavailable(let reason):
            selectedReport = .unavailable(reason: reason)
        }
    }

    /// The selected job's recorded output page IDs, when its loaded report
    /// matches the item (right item, right attempt) and carries outputs.
    /// Feeds the Activity tracker's read-only name planning so output rows
    /// link even while the wiki's live session is stale after daemon-run
    /// writes. `nil` for no match / no report / legacy reports without
    /// outputs — callers treat that as "clear the note".
    func recordedOutputPageIDs(for item: QueueItem) -> [PageID]? {
        guard case .loaded(let report) = selectedReport,
              report.attemptID.itemID == item.id,
              report.attemptID.attempt == item.attempt else { return nil }
        return report.outputs?.map(\.pageID)
    }
}
