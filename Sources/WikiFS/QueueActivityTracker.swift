import Foundation
import Observation
import WikiFSCore
import WikiFSEngine

/// A mutable box for a `@Sendable` progress-emit closure. Used to break the
/// circular dependency between `QueueExtractionWorkerFactory` (needs the
/// closure) and `QueueEngine` (needs the factory but provides the closure).
final class ProgressEmitBox: @unchecked Sendable {
    var emit: (@Sendable (QueueItem.ID, String) -> Void)?
}

/// Observes `QueueEngine.events` and maintains `@Observable` UI state for
/// extraction activity. Replaces the launcher's extraction slot machinery
/// (`isExtracting`, `extractionLog`, `extractionPID`,
/// `extractingSourceIDs`, `extractTask`, `stopExtraction`) with a
/// queue-event-driven model.
///
/// The tracker maps `QueueItem.ID` → `Set<PageID>` so it knows which source
/// IDs are being extracted, and exposes:
/// - `isExtracting` / `extractingSourceIDs` — drives per-row "Extracting…"
///   labels and the sidebar spinner.
/// - `extractionLog` — accumulated progress output for the currently-visible
///   extraction, driven by `.progress` events.
/// - `cancelExtraction()` — calls `queueEngine.cancelItem(...)` for the
///   current extraction item (replaces `stopExtraction()`).
///
/// Lives in `WikiFS` (not `WikiFSEngine`) because it is SwiftUI-observable UI
/// state — the engine itself is headless and knows nothing about it.
@MainActor
@Observable
final class QueueActivityTracker {

    // MARK: - Observable state (drives SwiftUI)

    /// Source IDs currently being extracted (any extraction queue item in
    /// `.running` state). Drives per-file "Extracting…" labels and the
    /// standalone Extract button's per-file disable.
    private(set) var extractingSourceIDs: Set<PageID> = []

    /// True while any extraction is running. Drives the sidebar spinner.
    var isExtracting: Bool { !extractingSourceIDs.isEmpty }

    /// Accumulated progress log for the most recent extraction. Cleared on
    /// `.started`, appended on `.progress`. Drives the sidebar log text.
    private(set) var extractionLog: String = ""

    /// PID of the extraction subprocess (parsed from progress lines if the
    /// local pdf2md backend reports it). `nil` for remote backends.
    private(set) var extractionPID: Int32? = nil

    // MARK: - Internal tracking

    /// Maps queue item ID → source IDs, so we can remove source IDs from
    /// `extractingSourceIDs` when items finish.
    private var itemToSourceIDs: [QueueItem.ID: Set<PageID>] = [:]

    /// The currently running extraction item ID, for cancellation via
    /// `cancelExtraction()`.
    private var currentExtractionItemID: QueueItem.ID?

    /// The queue engine — held weakly to avoid a retain cycle (the engine
    /// does not retain the tracker).
    private weak var queueEngine: QueueEngine?

    /// The stream consumer task.
    private var streamTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Attach to a queue engine and start consuming its events. Idempotent —
    /// calling again replaces the previous attachment.
    func attach(engine: QueueEngine) {
        queueEngine = engine
        start(events: engine.events)
    }

    /// Start consuming `events`. Spawns a `@MainActor` Task that iterates the
    /// stream and dispatches each event to `handle(_:)`.
    func start(events: AsyncStream<QueueEvent>) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Stop consuming events and clear state.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        queueEngine = nil
        extractingSourceIDs = []
        extractionLog = ""
        extractionPID = nil
        currentExtractionItemID = nil
        itemToSourceIDs.removeAll()
    }

    // MARK: - Public API

    /// Cancel the currently running extraction (if any). Calls
    /// `queueEngine.cancelItem(itemID)` which cancels the worker's `Task`
    /// and transitions the item to `.cancelled`.
    func cancelExtraction() async {
        guard let itemID = currentExtractionItemID, let engine = queueEngine else { return }
        await engine.cancelItem(itemID)
    }

    /// True if an extraction is running but NOT for this specific source.
    /// Used to disable the Extract button when another file holds the
    /// extraction slot (local pdf2md is limit 1).
    func isSlotBusyForOtherSource(_ id: PageID) -> Bool {
        !extractingSourceIDs.isEmpty && !extractingSourceIDs.contains(id)
    }

    // MARK: - Event handling

    private func handle(_ event: QueueEvent) {
        switch event {
        case .enqueued(let item):
            // Track the mapping so we can clean up on completion.
            if item.queue == .extraction {
                let sourceIDs = Set(item.payload.sourceIDs)
                itemToSourceIDs[item.id] = sourceIDs
            }

        case .started(let item):
            if item.queue == .extraction {
                let sourceIDs = Set(item.payload.sourceIDs)
                itemToSourceIDs[item.id] = sourceIDs
                extractingSourceIDs.formUnion(sourceIDs)
                extractionLog = ""
                extractionPID = nil
                currentExtractionItemID = item.id
            }

        case .progress(let id, let line):
            // Only accumulate for extraction items we know about.
            if itemToSourceIDs[id] != nil {
                if extractionLog.isEmpty {
                    extractionLog = line
                } else {
                    extractionLog += "\n" + line
                }
                parsePIDIfPresent(line)
            }

        case .completed(let item):
            if item.queue == .extraction {
                removeItem(item)
            }

        case .failed(let item, let error):
            if item.queue == .extraction {
                removeItem(item)
                if extractionLog.isEmpty {
                    extractionLog = "Extraction failed: \(error)"
                }
            }

        case .cancelled(let item):
            if item.queue == .extraction {
                removeItem(item)
            }

        case .runStateChanged:
            // Not relevant to extraction-activity tracking.
            break
        }
    }

    /// Remove an item from the active set and clean up its mapping.
    private func removeItem(_ item: QueueItem) {
        if let sourceIDs = itemToSourceIDs.removeValue(forKey: item.id) {
            extractingSourceIDs.subtract(sourceIDs)
        }
        if currentExtractionItemID == item.id {
            currentExtractionItemID = nil
        }
    }

    /// Parse a PID from a progress line if the local backend reports one.
    /// pdf2md reports its PID in a line like `"pid:12345"`.
    private func parsePIDIfPresent(_ line: String) {
        guard line.contains("pid:") else { return }
        let cleaned = line.replacingOccurrences(of: "pid:", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let pid = Int32(cleaned) {
            extractionPID = pid
        }
    }
}
