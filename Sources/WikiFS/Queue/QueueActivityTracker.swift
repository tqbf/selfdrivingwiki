import Foundation
import Observation
import WikiFSCore
import WikiFSEngine

/// Observes `QueueEngine.events` and maintains `@Observable` UI state for
/// extraction activity. Replaces the launcher's extraction slot machinery
/// (`isExtracting`, `extractionLog`, `extractionPID`,
/// `extractingSourceIDs`, `extractTask`, `stopExtraction`) with a
/// queue-event-driven model.
///
/// The tracker maps `QueueItem.ID` → `Set<SourceID>` so it knows which source
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
    private(set) var extractingSourceIDs: Set<SourceID> = []

    /// Source IDs currently being ingested (any ingestion queue item in
    /// `.running` state). Drives per-file "Ingesting…" labels and cross-file
    /// Ingest button disable. Replaces `launcher.ingestingSourceIDs`.
    private(set) var ingestingSourceIDs: Set<SourceID> = []

    /// Queue item IDs currently running a lint (`.ingestion` items with
    /// `lintPageIDs != nil`). Lint items have empty `sourceIDs`, so they
    /// don't show up in `ingestingSourceIDs` — this set ensures
    /// `isIngesting` covers lint-only runs.
    private(set) var lintingItemIDs: Set<QueueItem.ID> = []

    /// Page IDs currently being linted by a page-level lint (`.ingestion`
    /// items with non-empty `lintPageIDs`). Page IDs are ULIDs — globally
    /// unique across wikis — so this set is wiki-agnostic like
    /// `extractingSourceIDs` / `ingestingSourceIDs`. Used to reflect the
    /// running state on a page's "Lint" button.
    private(set) var lintingPageIDs: Set<PageID> = []

    /// Wiki IDs with an active whole-wiki lint (`.ingestion` items with
    /// `lintPageIDs == []`). A whole-wiki lint covers every page in that
    /// wiki, so every page-detail "Lint" button in that wiki should reflect
    /// the running state. Wiki-scoped (not page-scoped) so a whole-wiki
    /// lint on one wiki doesn't mark another wiki's pages as linting.
    private(set) var wholeWikiLintingWikiIDs: Set<WikiID> = []

    /// Maps a lint item ID → the page IDs it lints (empty = whole-wiki).
    /// Used by ``lintItemID(for:wikiID:)`` to resolve which running lint job
    /// covers a given page, so the Lint button can navigate to that specific
    /// job in the Activity window (#837). Mirrors the `itemToSourceIDs`
    /// mapping that exists for extraction items.
    private var itemToLintPageIDs: [QueueItem.ID: [PageID]] = [:]

    /// Maps a lint item ID → its wiki ID. Needed so
    /// ``lintItemID(for:wikiID:)`` can distinguish a whole-wiki lint (empty
    /// `lintPageIDs`) that covers EVERY page in its wiki from a page-level
    /// lint in a different wiki. Whole-wiki lints match by wiki ID; page-level
    /// lints match by page ID (ULIDs are globally unique across wikis).
    private var itemToLintWikiID: [QueueItem.ID: WikiID] = [:]

    /// A pending item selection requested from outside the Activity window —
    /// e.g. PageDetailView's "View Lint" button (#837) or SourceDetailView's
    /// "View Transcription" button (#842 PR2). Set before calling the
    /// `openActivityWindow` environment closure; consumed by
    /// `ActivityWindowView` on appear / change, which sets `selectedItemID`
    /// and clears this back to nil. Drives "open Activity window focused on a
    /// SPECIFIC queue item" without changing the closure's signature.
    var pendingSelectionItemID: QueueItem.ID? = nil

    /// The queue kind the pending selection belongs to (#842 PR2 C4). Set
    /// alongside `pendingSelectionItemID` so `ActivityWindowView` can verify
    /// the item belongs to the consuming window's queue — prevents a
    /// cross-window race when both `.transcription` and `.ingestion` windows
    /// exist (a lint pending-selection must not be consumed by the
    /// transcription window, and vice versa). `nil` means "no queue guard"
    /// (backward-compat for any future caller that doesn't set it).
    var pendingSelectionQueue: QueueKind? = nil

    /// True while any extraction is running. Drives the sidebar spinner.
    var isExtracting: Bool { !extractingSourceIDs.isEmpty }

    /// True while any ingestion or lint is running.
    var isIngesting: Bool { !ingestingSourceIDs.isEmpty || !lintingItemIDs.isEmpty }

    /// True while any extraction is running (includes transcript fetches,
    /// which merged into `.extraction`). Drives nothing in the sidebar
    /// spinner today, but kept for parity with `isExtracting`/`isIngesting`.
    var isTranscribingAny: Bool { !extractingSourceIDs.isEmpty }

    /// True if an extraction job (PDF or transcript) is actively processing
    /// `sourceID`. Used by `SourceDetailView` to disable its Transcribe button
    /// and reflect the running state (the button reads "Transcribing…").
    /// Since transcription merged into `.extraction`, transcript items are
    /// tracked in `extractingSourceIDs` alongside PDF extractions.
    func isTranscribing(sourceID: SourceID) -> Bool {
        extractingSourceIDs.contains(sourceID)
    }

    /// True if a lint job (page-level or whole-wiki) is actively processing
    /// `pageID` in `wikiID`. A whole-wiki lint (`lintPageIDs == []`) covers
    /// every page in its wiki. Used by `PageDetailView` to disable its Lint
    /// button and reflect the running state. Page IDs are ULIDs (globally
    /// unique), so the page-level branch needs no wiki check.
    func isLinting(pageID: PageID, wikiID: WikiID) -> Bool {
        lintingPageIDs.contains(pageID) || wholeWikiLintingWikiIDs.contains(wikiID)
    }

    /// Returns the queue item ID of the lint job (page-level or whole-wiki)
    /// currently running for `pageID` in `wikiID`, or `nil` if no lint is in
    /// flight. Used by `PageDetailView`'s Lint button to navigate to the
    /// specific job in the Activity window when a lint is already running
    /// (#837). Page-level lints match by page ID (ULIDs are globally unique);
    /// whole-wiki lints match by wiki ID (empty `lintPageIDs` covers every
    /// page in that wiki).
    func lintItemID(for pageID: PageID, wikiID: WikiID) -> QueueItem.ID? {
        for (itemID, lintPageIDs) in itemToLintPageIDs {
            guard itemToLintWikiID[itemID] == wikiID else { continue }
            if lintPageIDs.isEmpty {
                return itemID
            }
            if lintPageIDs.contains(pageID) {
                return itemID
            }
        }
        return nil
    }

    /// Returns the queue item ID of the extraction job currently running
    /// for `sourceID`, or `nil` if no extraction is in flight. Used by
    /// `SourceDetailView`'s Transcribe button to navigate to the specific job
    /// in the Activity window when a transcription is already running (#842
    /// PR2 C5). Since transcription merged into `.extraction`, transcript
    /// items are tracked in `itemToSourceIDs` alongside PDF extractions.
    /// Mirrors `lintItemID(for:wikiID:)` (#837). Source IDs are
    /// ULIDs (globally unique), so no wiki-scoping is needed.
    func transcriptionItemID(for sourceID: SourceID) -> QueueItem.ID? {
        for (itemID, sourceIDs) in itemToSourceIDs {
            if sourceIDs.contains(sourceID) {
                return itemID
            }
        }
        return nil
    }
    /// Bounded — pruned only when items are pruned from history (not on
    /// terminal state, so users can view completed/failed/cancelled transcripts).
    private(set) var transcripts: [QueueItem.ID: [ChatTranscriptItem]] = [:]
    private var transcriptAttempts: [QueueItem.ID: QueueAttemptID] = [:]
    private var lastTranscriptBatch: [QueueAttemptID: Int] = [:]

    /// Per-item accumulated progress text (for extraction items that produce
    /// progress strings, not typed transcript rows). Keyed by item ID.
    private(set) var progressLogs: [QueueItem.ID: String] = [:]

    /// Per-item cumulative token/cost usage for completed runs (#528 spike).
    /// Keyed by item ID. Set once when a `.usage` event arrives. The Activity
    /// window reads this to append "12.4K in · 3.2K out · $0.34" to completed rows.
    private(set) var itemUsage: [QueueItem.ID: SessionUsage] = [:]

    /// Per-item in-progress token/cost usage for RUNNING runs (#544 live
    /// progress). Keyed by item ID. Updated on each `.liveUsage` event during
    /// the run, cleared on terminal state. The Activity window reads this to
    /// show running token counts + model name before the run completes. The
    /// final cumulative totals come from `itemUsage` via the `.usage` event.
    private(set) var liveUsage: [QueueItem.ID: SessionUsage] = [:]

    /// Today's cumulative token usage across all completed runs (#528 spike).
    /// Persists to UserDefaults with a date key so it survives app restarts
    /// and resets daily. Driven by `.usage` events.
    private(set) var todayUsage: DailyUsage = DailyUsage.load()

    /// Today's per-model token/cost breakdown (#583). Persists to UserDefaults
    /// with a daily-reset key, mirroring `todayUsage`. The menu bar renders one
    /// disabled menu item per entry below the summary line.
    private(set) var todayUsageByModel: DailyUsageByModel = DailyUsageByModel.load()

    /// Per-run per-model usage breakdown (#583). Keyed by item ID, then by
    /// model ID. Populated from `.usage` events (today each run emits one
    /// merged snapshot, so most runs have a single entry — the structure
    /// is ready for future per-phase usage events). The Activity window's
    /// per-item detail reads this to show a model breakdown below the
    /// aggregate line.
    private(set) var itemUsageByModel: [QueueItem.ID: [String: ModelUsageBreakdown]] = [:]

    /// Per-item lightweight log file URL (`run.jsonl`) — the raw stream-json
    /// trace. Set once when `.runPaths` arrives after the run starts.
    private(set) var itemLogURLs: [QueueItem.ID: URL] = [:]

    /// Per-item verbose debug folder URL (`debug/`) — the complete ACP wire
    /// trace (per-turn JSON, permissions, stderr, summary). Set once when
    /// `.runPaths` arrives after the run starts.
    private(set) var itemDebugURLs: [QueueItem.ID: URL] = [:]

    /// Per-item pending permission request surfaced from the launcher's
    /// `pendingPermissions` while a turn is parked on an always-ask prompt
    /// (issue #608). Set/cleared from the `.pendingPermission` queue event:
    /// a non-nil value means the run is blocked waiting for an Approve/
    /// Reject decision (or the S1 auto-reject timeout). The Activity window
    /// renders a yellow "Permission pending: <cmd>" row below the item's
    /// status row. Cleared on terminal state and when the continuation
    /// resolves. Keyed by item ID — ACP agents gate one write at a time, so
    /// at most one entry per item.
    private(set) var pendingPermissions: [QueueItem.ID: PendingPermission] = [:]

    /// Accumulated progress log for the most recent extraction. Cleared on
    /// `.started`, appended on `.progress`. Drives the sidebar log text.
    private(set) var extractionLog: String = ""

    // MARK: Report summary cache (integrated-queue-workspace plan §2)

    /// How the per-item report summary cache currently stands.
    enum ReportSummaryState: Equatable {
        /// A batch load is in flight; result search is labeled incomplete and
        /// rows stay lifecycle-only.
        case loading
        /// Either a store summary or a synthesized `.reportUpdated` summary is
        /// cached in ``reportSummaries``.
        case loaded
        /// The load failed (store/transport/older daemon). Lifecycle-only rows
        /// stay; report-backed search is labeled unavailable. Retried on
        /// reconnect (watchdog reconcile) or explicit refresh.
        case unavailable
    }

    /// Bounded per-item report summaries backing navigator-row progress and
    /// outcome search. Populated by batched `loadQueueReportSummaries` loads
    /// after attach and merged from `.reportUpdated` events — full target
    /// detail never enters this cache (it stays selected-item-only).
    private(set) var reportSummaries: [QueueItem.ID: QueueReportSummary] = [:]

    /// Per-item cache state so the window can label search incomplete while
    /// loading and unavailable after a failure (plan §"How summaries load").
    private(set) var reportSummaryStates: [QueueItem.ID: ReportSummaryState] = [:]

    /// In-flight batch load guard: a repeated request for the same not-yet-
    /// loaded set must not stack duplicate engine calls.
    private var inFlightSummaryLoad = false
    /// Items waiting for the in-flight batch to finish (terminal refreshes
    /// that arrived mid-load).
    private var pendingSummaryRefreshIDs: Set<QueueItem.ID> = []
    /// Last time the reconnect path retried unavailable summaries. Rate-limits
    /// the watchdog-driven retries so a permanently unavailable store logs at
    /// worst once per interval instead of every 5-second reconcile tick.
    private var lastUnavailableSummaryRetryAt: Date?

    // MARK: - Closed-wiki read-only name cache

    /// Per-item load state mirroring ``ReportSummaryState``'s vocabulary,
    /// for the closed-wiki read-only name loads.
    enum ClosedWikiNameLoadState: Equatable, Sendable {
        case loading
        case loaded
        /// The read failed (missing/corrupt database, unresolvable URL).
        /// Names degrade to the live/recorded fallback text; a later
        /// displayed-set change re-attempts the load.
        case unavailable
    }

    /// Display names read-only-resolved from a CLOSED wiki's database,
    /// per wiki (closed-wiki name resolution). Legacy jobs — enqueued before
    /// `QueueItemPayload.recordedNames` existed — have no recorded names, so
    /// when their wiki's window is closed this cache is the only human-
    /// readable source for their target rows. Populated by the batched
    /// `refreshClosedWikiNames` loads; the Activity window overlays it below
    /// the live index and the recorded names.
    private(set) var closedWikiNameIndexes: [WikiID: QueueTargetNameIndex] = [:]

    /// Per-wiki load state so the window can show a neutral resolving
    /// placeholder while a read is pending (never the deletion text) and the
    /// honest fallback after a completed read or a failure.
    private(set) var closedWikiNameLoadStates: [WikiID: ClosedWikiNameLoadState] = [:]

    /// In-flight per-wiki load guard: a repeated refresh must not stack
    /// duplicate read-only connections for one wiki.
    private var closedWikiNameLoadsInFlight: Set<WikiID> = []

    /// Items whose planning landed while their wiki's load was in flight
    /// (review F3). The owner of each in-flight load drains this set once
    /// after its load loop, so a job displayed mid-load is re-planned and
    /// answered without waiting for the next displayed-set key change.
    /// Mirrors ``pendingSummaryRefreshIDs``.
    private var pendingClosedWikiNameRefreshItems: [QueueItem] = []

    /// Target IDs a completed read-only load confirmed ABSENT from the
    /// wiki's database, per wiki (review F4 negative cache). Without it,
    /// every displayed-set key change re-planned these IDs and reopened
    /// the read-only database for rows that can never resolve. Keeping
    /// the set for the session is sound: target IDs are ULIDs (never
    /// reused), and while the wiki is open the live index answers without
    /// consulting this cache at all.
    private var closedWikiKnownMissingIDs: [WikiID: (pages: Set<PageID>, sources: Set<SourceID>)] = [:]

    /// Resolve display names for the given items' CLOSED wikis (open wikis
    /// are skipped — the live session index already answers), bounded to
    /// the target IDs that neither the payload's recorded names, the
    /// existing cache, nor the known-missing negative cache can resolve.
    /// Merges results into ``closedWikiNameIndexes`` and records per-wiki
    /// load state; failures log via `DebugLog.store` and mark the wiki
    /// unavailable instead of surfacing an error row. A load that is
    /// CANCELLED restores `.loading` — cancellation says nothing about the
    /// wiki, and the next `.task(id:)` run retries it (review F5).
    ///
    /// Concurrent refreshes serialize through the pending-set drain loop
    /// (mirrors ``refreshReportSummaries``): items planned while their
    /// wiki's load is in flight are parked in
    /// ``pendingClosedWikiNameRefreshItems`` and re-planned exactly once
    /// after that load finishes (review F3).
    ///
    /// - Parameters:
    ///   - databaseURL: the wiki database URL provider (production passes
    ///     the App Group container location). Returning `nil` marks the load
    ///     unavailable.
    ///   - loader: the read seam, injectable for tests.
    func refreshClosedWikiNames(
        for items: [QueueItem],
        sessions: [WikiID: any WikiSessionProtocol],
        databaseURL: @escaping @Sendable (WikiID) -> URL?,
        loader: @escaping QueueClosedWikiNameLoader.Load = QueueClosedWikiNameLoader.load
    ) async {
        var batch = items
        while batch.isEmpty == false {
            // Plan the per-wiki work: closed wikis only, and only the target
            // IDs nothing above the read-only layer can resolve.
            var planned: [WikiID: (pages: Set<PageID>, sources: Set<SourceID>)] = [:]
            for item in batch {
                let wikiID = item.wikiID
                guard sessions[wikiID] == nil else { continue }
                guard closedWikiNameLoadsInFlight.contains(wikiID) == false else {
                    pendingClosedWikiNameRefreshItems.append(item)
                    continue
                }
                let payload = item.payload
                if let pageIDs = payload.lintPageIDs {
                    let wanted = pageIDs.filter { payload.recordedPageTitle(for: $0) == nil }
                    guard !wanted.isEmpty else { continue }
                    planned[wikiID, default: ([], [])].pages.formUnion(wanted)
                } else {
                    let wanted = payload.sourceIDs.filter { payload.recordedSourceName(for: $0) == nil }
                    guard !wanted.isEmpty else { continue }
                    planned[wikiID, default: ([], [])].sources.formUnion(wanted)
                }
            }
            // IDs the cache already holds — or a prior load proved missing
            // (review F4) — need no re-read.
            for wikiID in Array(planned.keys) {
                guard var targets = planned[wikiID] else { continue }
                if let cached = closedWikiNameIndexes[wikiID] {
                    targets.pages.subtract(cached.pageEntries.map(\.id))
                    targets.sources.subtract(cached.sourceEntries.map(\.id))
                }
                if let missing = closedWikiKnownMissingIDs[wikiID] {
                    targets.pages.subtract(missing.pages)
                    targets.sources.subtract(missing.sources)
                }
                if targets.pages.isEmpty && targets.sources.isEmpty {
                    planned.removeValue(forKey: wikiID)
                } else {
                    planned[wikiID] = targets
                }
            }
            // Nothing this call can load: fully covered by the caches, or
            // every candidate wiki's load is in flight under another call —
            // that owner drains ``pendingClosedWikiNameRefreshItems`` after
            // its own loads (the summary path's "second caller returns"
            // branch). Items this call parked stay parked for it.
            guard planned.isEmpty == false else { return }

            for (wikiID, _) in planned {
                closedWikiNameLoadsInFlight.insert(wikiID)
                closedWikiNameLoadStates[wikiID] = .loading
            }
            // Loads run sequentially on the main actor; each read itself hops
            // off-main through `WikiReadService.asyncRead`, so this only
            // suspends. Loads are bounded (one per closed wiki with unresolved
            // IDs) and rare, so parallelism buys nothing.
            for (wikiID, targets) in planned {
                let url = databaseURL(wikiID)
                guard let url else {
                    DebugLog.store(
                        "Closed-wiki name load: no database URL for wiki \(wikiID.rawValue.prefix(8))")
                    closedWikiNameLoadStates[wikiID] = .unavailable
                    continue
                }
                do {
                    let index = try await loader(
                        wikiID,
                        targets.pages.sorted { $0.rawValue < $1.rawValue },
                        targets.sources.sorted { $0.rawValue < $1.rawValue },
                        url)
                    mergeClosedWikiNames(index, for: wikiID)
                    recordKnownMissing(
                        for: wikiID, planned: targets, loaded: index)
                } catch is CancellationError {
                    // Review F5: a cancelled load is not evidence about the
                    // wiki's database — restore `.loading` so the next
                    // `.task(id:)` run re-plans and retries it. (`.unavailable`
                    // here would pin the deletion fallback text on rows whose
                    // read never answered.)
                    closedWikiNameLoadStates[wikiID] = .loading
                } catch {
                    DebugLog.store(
                        "Closed-wiki name load failed for wiki \(wikiID.rawValue.prefix(8)): \(error)")
                    closedWikiNameLoadStates[wikiID] = .unavailable
                }
            }
            for wikiID in planned.keys {
                closedWikiNameLoadsInFlight.remove(wikiID)
            }
            // Review F3: items that landed mid-load for the wikis THIS call
            // just loaded are re-planned exactly once, inside this loop
            // rather than as a stacked refresh. (Items parked on ANOTHER
            // call's in-flight wiki are drained by that call.)
            batch = pendingClosedWikiNameRefreshItems
            pendingClosedWikiNameRefreshItems.removeAll()
        }
    }

    /// Negative-cache (review F4) the planned IDs a successful load did not
    /// return. The loader skips `notFound` IDs and throws on any other
    /// error, so `planned − loaded` is exactly the confirmed-missing set —
    /// re-planning them would only reopen the read-only database to hear
    /// "gone" again.
    private func recordKnownMissing(
        for wikiID: WikiID,
        planned: (pages: Set<PageID>, sources: Set<SourceID>),
        loaded: QueueTargetNameIndex
    ) {
        let loadedPages = Set(loaded.pageEntries.map(\.id))
        let loadedSources = Set(loaded.sourceEntries.map(\.id))
        var missing = closedWikiKnownMissingIDs[wikiID] ?? ([], [])
        missing.pages.formUnion(planned.pages.subtracting(loadedPages))
        missing.sources.formUnion(planned.sources.subtracting(loadedSources))
        closedWikiKnownMissingIDs[wikiID] = missing
    }

    /// Merge one successful read into the cache. First-match `record*`
    /// semantics keep earlier entries (including a live session's answer
    /// recorded by the view's overlay) authoritative over later merges.
    private func mergeClosedWikiNames(_ index: QueueTargetNameIndex, for wikiID: WikiID) {
        var cache = closedWikiNameIndexes[wikiID] ?? QueueTargetNameIndex()
        for entry in index.pageEntries {
            cache.recordPage(entry.id, title: entry.title)
        }
        for entry in index.sourceEntries {
            cache.recordSource(entry.id, name: entry.name)
        }
        closedWikiNameIndexes[wikiID] = cache
        closedWikiNameLoadStates[wikiID] = .loaded
    }

    /// PID of the extraction subprocess (parsed from progress lines if the
    /// local pdf2md backend reports it). `nil` for remote backends.
    private(set) var extractionPID: Int32? = nil

    // MARK: - Internal tracking

    /// Maximum number of items to retain transcripts for. When exceeded, the
    /// oldest item's transcript is pruned. This prevents unbounded growth when
    /// many items accumulate over a long session.
    private let maxTrackedItems = 200

    /// Maps queue item ID → source IDs, so we can remove source IDs from
    /// `extractingSourceIDs` when items finish. Also used by
    /// ``transcriptionItemID(for:)`` since transcription merged into
    /// `.extraction` — transcript items are tracked here alongside PDF
    /// extractions.
    private var itemToSourceIDs: [QueueItem.ID: Set<SourceID>] = [:]

    /// Maps queue item ID → its `QueueKind`. Populated on `.enqueued`/`.started`
    /// so snapshot reconciliation (#871 self-heal) can clear the correct
    /// running-state set when a terminal event never arrived: a source ID may
    /// be tracked under both extraction and ingestion by different items, so
    /// the queue kind is needed to avoid subtracting from the wrong set.
    private var itemToQueue: [QueueItem.ID: QueueKind] = [:]

    /// The currently running extraction item ID, for cancellation via
    /// `cancelExtraction()`.
    private var currentExtractionItemID: QueueItem.ID?

    /// The queue engine — held weakly to avoid a retain cycle (the engine
    /// does not retain the tracker).
    private weak var queueEngine: (any QueueEngineClient)?

    /// The stream consumer task.
    private var streamTask: Task<Void, Never>?

    /// The periodic snapshot-reconciliation watchdog (#871 self-heal). Polls
    /// the daemon's snapshot and clears running-state for items the daemon no
    /// longer considers active, so a broken event stream can't pin the spinner.
    private var watchdogTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Attach to a queue engine and start consuming its events. Idempotent —
    /// calling again replaces the previous attachment.
    func attach(engine: any QueueEngineClient) {
        queueEngine = engine
        start(events: engine.events)
    }

    /// Rehydrate per-item activity (usage, log/debug URLs, progress logs) from
    /// the persisted store so the Activity window shows completed/failed/
    /// cancelled ingestion + lint runs after an app restart. Called once at
    /// launch after ``attach(engine:)``.
    ///
    /// Only the activity metadata dictionaries are bulk-loaded here. Typed
    /// transcript items are NOT bulk-loaded — the detail view already
    /// lazy-loads each item's transcript via
    /// `engine.loadTranscript(for:)` when opened, which avoids loading all
    /// recent transcript rows into memory at launch.
    /// Transient running-state sets (`extractingSourceIDs`, `ingestingSourceIDs`,
    /// `lintingItemIDs`, …) are deliberately NOT rehydrated — on restart,
    /// `.running` items are reset to `.queued` by `resetRunningToQueued()`, so
    /// these sets rebuild naturally from live `.started` events.
    func rehydrate(from engine: any QueueEngineClient) async {
        let snapshots: [QueueItem.ID: QueueEngine.ActivitySnapshot]
        do {
            snapshots = try await engine.loadAllActivitySnapshots()
        } catch {
            DebugLog.store("QueueActivityTracker: activity rehydration failed: \(error)")
            return
        }
        for (id, snap) in snapshots {
            if let usage = snap.usage { itemUsage[id] = usage }
            if let logURL = snap.logURL { itemLogURLs[id] = logURL }
            if let debugURL = snap.debugURL { itemDebugURLs[id] = debugURL }
            if !snap.progressLog.isEmpty { progressLogs[id] = snap.progressLog }
        }
    }

    /// Reconcile the tracker's notion of "running" against the daemon's
    /// ground-truth snapshot. Any item the tracker treats as active that is
    /// NOT in `snapshot.activeItems` is cleared from the running-state sets —
    /// the daemon finished (or never had) it, but the terminal event was lost.
    ///
    /// This is the #871 self-heal: when the event stream from daemon → app is
    /// broken (sink invalidated, envelope dropped), `isExtracting` /
    /// `isIngesting` would stay `true` forever. A periodic snapshot poll feeds
    /// this method so the spinner clears once the daemon reports the item gone.
    ///
    /// Reconciliation remains removal-only for running-state sets, so a
    /// transient snapshot read can't fabricate activity. It does seed typed
    /// transcript attempt identity for daemon-active items: a reconnect can
    /// otherwise receive a live transcript batch before a repeated `.started`
    /// event. Items still active on the daemon are left untouched; their
    /// terminal event (or a later reconcile) clears them.
    func reconcile(with snapshot: QueueSnapshot) {
        for item in snapshot.activeItems {
            resetTranscriptAttempt(for: item)
        }
        let activeIDs = Set(snapshot.activeItems.map { $0.id })
        let recentByID = Dictionary(
            snapshot.recentItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        // Consider every item the tracker currently believes is running.
        let trackedIDs = Set(itemToSourceIDs.keys).union(lintingItemIDs)
        for id in trackedIDs where !activeIDs.contains(id) {
            if let item = recentByID[id] {
                // The daemon has it as terminal — clean up via the proven
                // `removeItem` path (uses the item's own queue + payload).
                removeItem(item)
            } else {
                // Not active AND not in recent history (pruned / unknown).
                // Fall back to the ID-only cleanup using stored maps.
                forgetRunningItem(id)
            }
        }
        retryUnavailableReportSummaries()
    }

    /// Reconnect/explicit-refresh path for the summary cache (plan: "Loading
    /// retries on reconnect or explicit refresh"). The watchdog reconcile is
    /// the reconnect signal: any item still marked `.unavailable` gets one
    /// forced batch retry so a transient store/transport failure can't pin
    /// report-backed search as unavailable forever. Retries are rate-limited
    /// (30s backoff) so a permanently unavailable store doesn't churn the
    /// engine or spam the log on every reconcile tick.
    func retryUnavailableReportSummaries() {
        let unavailable = reportSummaryStates.filter { $0.value == .unavailable }.map(\.key)
        guard !unavailable.isEmpty else { return }
        if let last = lastUnavailableSummaryRetryAt,
           Date().timeIntervalSince(last) < 30 {
            return
        }
        lastUnavailableSummaryRetryAt = Date()
        Task { @MainActor [weak self] in
            await self?.refreshReportSummaries(itemIDs: unavailable, force: true)
        }
    }

    /// Batch-load report summaries for the displayed item IDs. Called by the
    /// Activity windows after attach (lifecycle-only rows render immediately,
    /// plan §"How summaries load") and whenever the displayed set changes.
    ///
    /// - `force` re-fetches even cached items (terminal transitions, explicit
    ///   refresh). Unforced loads skip already-loaded/loaded-state items so a
    ///   churning `onChange` cannot re-read the whole window every snapshot.
    /// - A `.loaded` result merges per item by attempt, then revision: a
    ///   summary from an earlier attempt — or an older revision of the same
    ///   attempt — never replaces a newer `.reportUpdated`-synthesized one
    ///   (report merge rules).
    /// - `.unavailable` keeps any cached summaries and marks the *missing*
    ///   items unavailable — no error banner, logged via DebugLog. The
    ///   watchdog's reconcile retries unavailable items on reconnect.
    func refreshReportSummaries(itemIDs: [QueueItem.ID], force: Bool = false) async {
        guard let engine = queueEngine else { return }
        var wanted: [QueueItem.ID] = []
        for id in itemIDs {
            let state = reportSummaryStates[id]
            if !force, state == .loaded { continue }
            if force, state == .loading, inFlightSummaryLoad {
                pendingSummaryRefreshIDs.insert(id)
                continue
            }
            wanted.append(id)
        }
        guard !wanted.isEmpty else { return }
        for id in wanted { reportSummaryStates[id] = .loading }

        // Serialize concurrent batches: a caller arriving mid-load defers its
        // IDs to the in-flight loop instead of issuing overlapping reads.
        if inFlightSummaryLoad {
            pendingSummaryRefreshIDs.formUnion(wanted)
            return
        }
        inFlightSummaryLoad = true
        defer { inFlightSummaryLoad = false }

        var batch = wanted
        while !batch.isEmpty {
            let result = await engine.loadQueueReportSummaries(for: batch)
            guard queueEngine === engine else { return }  // detached mid-load
            switch result {
            case .loaded(let summaries):
                merge(summaries: summaries, for: batch)
            case .unavailable(let reason):
                DebugLog.store(
                    "QueueActivityTracker: report summaries unavailable (\(reason)) — \(batch.count) item(s) stay lifecycle-only")
                for id in batch where reportSummaries[id] == nil {
                    reportSummaryStates[id] = .unavailable
                }
            }
            // Terminal transitions that landed mid-load get a follow-up pass
            // inside this loop rather than a stacked engine call.
            batch = Array(pendingSummaryRefreshIDs)
            pendingSummaryRefreshIDs.removeAll()
        }
    }

    /// Merge loaded summaries into the cache. Items with no summary in the
    /// response (legacy jobs) settle at `.loaded` with no entry — a truthful
    /// "no report recorded" rather than a perpetual loading state.
    private func merge(summaries: [QueueItem.ID: QueueReportSummary], for requested: [QueueItem.ID]) {
        for id in requested {
            if let summary = summaries[id] {
                merge(summary: summary)
            } else {
                reportSummaryStates[id] = .loaded
            }
        }
    }

    /// Merge one summary by attempt first, then monotonic revision. A retry
    /// creates a new attempt whose revisions restart at 1, so comparing
    /// revision alone would let the previous attempt's summary pin the cache
    /// and hide the retry's report. Within one attempt, older data never
    /// replaces newer (report merge rules — a delayed batch load loses to a
    /// live `.reportUpdated` event).
    func merge(summary: QueueReportSummary) {
        if let existing = reportSummaries[summary.itemID] {
            if existing.attempt > summary.attempt {
                // A summary from an earlier attempt arrived after the retry
                // already cached its own — reject it outright.
                reportSummaryStates[summary.itemID] = .loaded
                return
            }
            if existing.attempt == summary.attempt,
               existing.revision >= summary.revision {
                reportSummaryStates[summary.itemID] = .loaded
                return
            }
        }
        reportSummaries[summary.itemID] = summary
        reportSummaryStates[summary.itemID] = .loaded
    }

    /// The cached summary for an item, if one is loaded.
    func reportSummary(for itemID: QueueItem.ID) -> QueueReportSummary? {
        reportSummaries[itemID]
    }

    /// The cache state for an item (`.loading` is the default so rows start
    /// lifecycle-only and search starts labeled incomplete).
    func reportSummaryState(for itemID: QueueItem.ID) -> ReportSummaryState {
        reportSummaryStates[itemID] ?? .loading
    }

    /// Start a low-frequency watchdog that polls the daemon's snapshot and
    /// reconciles, so a broken event stream can't pin the spinner forever
    /// (#871). Idempotent — calling again replaces the prior watchdog.
    /// Cancels automatically if the engine is released (the weak ref goes nil).
    func startSnapshotWatchdog(engine: any QueueEngineClient, interval: Duration = .seconds(5)) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self, weak engine] in
            while !Task.isCancelled {
                if Task.isCancelled { return }
                guard let self, let engine else { return }
                do {
                    let snapshot = try await engine.snapshot()
                    if Task.isCancelled { return }
                    self.reconcile(with: snapshot)
                } catch {
                    DebugLog.store("QueueActivityTracker: snapshot failed: \(error)")
                }
                // Task.sleep only throws CancellationError — expected, not actionable.
                // swiftlint:disable:next silent_try_optional
                try? await Task.sleep(for: interval)
            }
        }
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
        watchdogTask?.cancel()
        watchdogTask = nil
        queueEngine = nil
        extractingSourceIDs = []
        ingestingSourceIDs = []
        lintingItemIDs = []
        lintingPageIDs = []
        wholeWikiLintingWikiIDs = []
        itemToLintPageIDs.removeAll()
        itemToLintWikiID.removeAll()
        pendingSelectionItemID = nil
        pendingSelectionQueue = nil
        extractionLog = ""
        extractionPID = nil
        currentExtractionItemID = nil
        itemToSourceIDs.removeAll()
        itemToQueue.removeAll()
        transcripts.removeAll()
        progressLogs.removeAll()
        itemUsage.removeAll()
        liveUsage.removeAll()
        itemUsageByModel.removeAll()
        itemLogURLs.removeAll()
        itemDebugURLs.removeAll()
        pendingPermissions.removeAll()
        transcriptAttempts.removeAll()
        lastTranscriptBatch.removeAll()
        reportSummaries.removeAll()
        reportSummaryStates.removeAll()
        pendingSummaryRefreshIDs.removeAll()
        lastUnavailableSummaryRetryAt = nil
    }

    // MARK: - Public API

    /// Cancel the currently running extraction (if any). Calls
    /// `queueEngine.cancelItem(itemID)` which cancels the worker's `Task`
    /// and transitions the item to `.cancelled`.
    func cancelExtraction() async {
        guard let itemID = currentExtractionItemID, let engine = queueEngine else { return }
        do {
            try await engine.cancelItem(itemID)
        } catch {
            DebugLog.store("QueueActivityTracker: cancel extraction failed: \(error)")
        }
    }

    /// True if the tracker has been attached to a queue engine's event stream.
    /// Used by `appEnvironment` to assert the tracker is live before injection.
    var isAttachedToEngine: Bool {
        streamTask != nil
    }

    /// True if an extraction is running but NOT for this specific source.
    /// Used to disable the Extract button when another file holds the
    /// extraction slot (local pdf2md is limit 1).
    func isSlotBusyForOtherSource(_ id: SourceID) -> Bool {
        !extractingSourceIDs.isEmpty && !extractingSourceIDs.contains(id)
    }

    /// Apply a typed, ordered queue update. The engine owns translation and
    /// reduction. The tracker only rejects stale/out-of-order delivery and
    /// reduces the changed typed rows into its main-actor presentation state.
    func applyTranscriptUpdate(_ update: QueueTranscriptUpdate) {
        let itemID = update.attemptID.itemID
        guard transcriptAttempts[itemID] == update.attemptID else { return }
        let lastAcceptedBatch = lastTranscriptBatch[update.attemptID] ?? -1
        guard update.batchNumber > lastAcceptedBatch else { return }
        transcripts[itemID] = QueueTranscriptCanonicalMerge.merging(
            persisted: transcripts[itemID, default: []],
            live: update.changedItems)
        lastTranscriptBatch[update.attemptID] = update.batchNumber

        if transcripts.count > maxTrackedItems {
            let excess = transcripts.count - maxTrackedItems
            for id in transcripts.keys.prefix(excess) {
                transcripts.removeValue(forKey: id)
                progressLogs.removeValue(forKey: id)
            }
        }
    }

    private func resetTranscriptAttempt(for item: QueueItem) {
        let attemptID = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        guard transcriptAttempts[item.id] != attemptID else { return }
        if let previous = transcriptAttempts[item.id] {
            lastTranscriptBatch.removeValue(forKey: previous)
        }
        transcriptAttempts[item.id] = attemptID
        transcripts.removeValue(forKey: item.id)
    }

    /// Prune the transcript + progress log for an item. Called when items are
    /// pruned from history (the bounded-recent-items path), NOT on terminal
    /// state — so users can view completed/failed/cancelled transcripts.
    func pruneTranscripts(for itemID: QueueItem.ID) {
        transcripts.removeValue(forKey: itemID)
        progressLogs.removeValue(forKey: itemID)
        itemUsage.removeValue(forKey: itemID)
        liveUsage.removeValue(forKey: itemID)
        itemUsageByModel.removeValue(forKey: itemID)
        itemLogURLs.removeValue(forKey: itemID)
        itemDebugURLs.removeValue(forKey: itemID)
        pendingPermissions.removeValue(forKey: itemID)
        itemToQueue.removeValue(forKey: itemID)
        reportSummaries.removeValue(forKey: itemID)
        reportSummaryStates.removeValue(forKey: itemID)
        pendingSummaryRefreshIDs.remove(itemID)
        if let attempt = transcriptAttempts.removeValue(forKey: itemID) {
            lastTranscriptBatch.removeValue(forKey: attempt)
        }
    }

    /// The transcript for a given item ID (may be empty / nil).
    func transcript(for itemID: QueueItem.ID) -> [ChatTranscriptItem] {
        transcripts[itemID] ?? []
    }

    /// The accumulated progress log for a given item ID (may be empty).
    func progressLog(for itemID: QueueItem.ID) -> String {
        progressLogs[itemID] ?? ""
    }

    /// The cumulative token/cost usage for a completed item, or `nil` if the
    /// backend didn't report usage. Read by the Activity window rows.
    func usage(for itemID: QueueItem.ID) -> SessionUsage? {
        itemUsage[itemID]
    }

    /// The in-progress token/cost usage for a running item, or `nil` if no
    /// `usage_update` has arrived yet. Read by the Activity window to render
    /// live token counts + model name during a run (#544 live progress).
    func liveUsage(for itemID: QueueItem.ID) -> SessionUsage? {
        liveUsage[itemID]
    }

    /// The per-model usage breakdown for a completed item (#583). Returns an
    /// empty dict when usage wasn't captured or no model id was reported. Read
    /// by the Activity window's per-item detail to show a model breakdown below
    /// the aggregate line.
    func usageBreakdown(for itemID: QueueItem.ID) -> [String: ModelUsageBreakdown] {
        itemUsageByModel[itemID] ?? [:]
    }

    /// The lightweight `run.jsonl` log file URL for an item, or `nil` if the
    /// run didn't create one. Read by the Activity window for "Reveal Log".
    func logURL(for itemID: QueueItem.ID) -> URL? {
        itemLogURLs[itemID]
    }

    /// The verbose `debug/` folder URL for an item, or `nil` if the run
    /// didn't create one. Read by the Activity window for "Reveal Debug Folder".
    func debugURL(for itemID: QueueItem.ID) -> URL? {
        itemDebugURLs[itemID]
    }

    /// The pending permission request a run is parked on, or `nil` when the
    /// item isn't blocked on an always-ask prompt. Read by the Activity
    /// window to render a yellow "Permission pending: <cmd>" row below the
    /// item's status row (#608). ACP agents gate one write at a time, so
    /// there is at most one pending request per item — the launcher emits
    /// the first (or `nil` once the continuation resolves / auto-rejects).
    func pendingPermission(for itemID: QueueItem.ID) -> PendingPermission? {
        pendingPermissions[itemID]
    }

    // MARK: - Event handling

    @MainActor
    func handle(_ event: QueueEvent) {
        switch event {
        case .enqueued(let item):
            resetTranscriptAttempt(for: item)
            // Track the mapping so we can clean up on completion.
            let sourceIDs = Set(item.payload.sourceIDs)
            itemToSourceIDs[item.id] = sourceIDs
            itemToQueue[item.id] = item.queue
            
            // #622: Optimistically reflect the queued state in the UI spinners
            // immediately, rather than waiting for .started.
            switch item.queue {
            case .extraction, .transcription:
                extractingSourceIDs.formUnion(sourceIDs)
            case .ingestion:
                if item.payload.lintPageIDs == nil {
                    ingestingSourceIDs.formUnion(sourceIDs)
                }
                // Linting items have no sourceIDs, so nothing to add to the 
                // per-source spinner sets.
            }

        case .started(let item):
            resetTranscriptAttempt(for: item)
            let sourceIDs = Set(item.payload.sourceIDs)
            itemToSourceIDs[item.id] = sourceIDs
            itemToQueue[item.id] = item.queue
            switch item.queue {
            case .extraction, .transcription:
                extractingSourceIDs.formUnion(sourceIDs)
                extractionLog = ""
                extractionPID = nil
                currentExtractionItemID = item.id
                progressLogs[item.id] = ""
            case .ingestion:
                if let pageIDs = item.payload.lintPageIDs {
                    // Lint item — track separately (empty sourceIDs).
                    lintingItemIDs.insert(item.id)
                    // Track the lint scope so `lintItemID(for:wikiID:)` can
                    // resolve which running job covers a given page (#837).
                    itemToLintPageIDs[item.id] = pageIDs
                    itemToLintWikiID[item.id] = item.wikiID
                    if pageIDs.isEmpty {
                        // Whole-wiki lint: covers every page in this wiki.
                        wholeWikiLintingWikiIDs.insert(item.wikiID)
                        DebugLog.ingest("LintActivity: started whole-wiki lint for wiki \(item.wikiID.rawValue.prefix(8)) (item \(item.id.rawValue.prefix(8)))")
                    } else {
                        // Page-level lint: track the specific pages.
                        lintingPageIDs.formUnion(pageIDs)
                        DebugLog.ingest("LintActivity: started page-level lint for \(pageIDs.count) page(s) in wiki \(item.wikiID.rawValue.prefix(8)) (item \(item.id.rawValue.prefix(8)))")
                    }
                } else {
                    ingestingSourceIDs.formUnion(sourceIDs)
                }
            }

        case .transcript(let update):
            applyTranscriptUpdate(update)

        case .usage(let id, let usage):
            // #528 spike: store per-item usage for the Activity window, and
            // accumulate today's daily total (persists to UserDefaults).
            itemUsage[id] = usage
            // #583: also accumulate the per-model breakdown. Keyed by model id
            // (or "unknown" when the backend didn't report one — still tracked
            // so the numbers reconcile against the aggregate line). Each `.usage`
            // event bumps the per-model runCount by 1, so a multi-model breakdown
            // across many runs shows realistic counts.
            let modelKey = usage.modelId ?? ModelUsageBreakdown.unknownModelKey
            itemUsageByModel[id, default: [:]][modelKey, default: ModelUsageBreakdown()]
                .add(usage)
            todayUsage.add(usage)
            todayUsageByModel.add(usage)
            DailyUsage.save(todayUsage)
            DailyUsageByModel.save(todayUsageByModel)
            // The run is complete — drop the in-progress snapshot so the
            // Activity window renders the final totals, not a stale live one.
            liveUsage.removeValue(forKey: id)

        case .liveUsage(let id, let usage):
            // #544 live progress: store the latest in-progress usage snapshot
            // for a running item. Overwrites the previous snapshot (each
            // usage_update carries the current cumulative totals + the latest
            // model/cost). Cleared on terminal state in removeItem().
            liveUsage[id] = usage

        case .runPaths(let id, let logURL, let debugURL):
            // Store the run's log/debug URLs so the Activity window can offer
            // "Reveal Log" / "Reveal Debug Folder". Either may be nil if the
            // run didn't create the files (not started, preflight failure).
            if let logURL { itemLogURLs[id] = logURL }
            if let debugURL { itemDebugURLs[id] = debugURL }

        case .pendingPermission(let id, let permission):
            // #608: surface "Permission pending: <cmd>" while a run is parked
            // on an always-ask prompt. The launcher's `pendingPollTask`
            // refreshes `pendingPermissions` from the backend while a turn
            // generates; the AppQueueIngestionProvider forwards changes via
            // the emit closure. `nil` clears the row (resolved / rejected /
            // auto-rejected by the S1 companion timer). Updates replace the
            // prior entry — ACP agents gate one write at a time, so the
            // dictionary never carries more than one entry per item.
            if let permission {
                pendingPermissions[id] = permission
            } else {
                pendingPermissions.removeValue(forKey: id)
            }

        case .progress(let id, let line):
            // Accumulate per-item progress (for extraction items and any
            // item that emits progress lines).
            if let existing = progressLogs[id] {
                progressLogs[id] = existing.isEmpty ? line : "\(existing)\n\(line)"
            } else {
                progressLogs[id] = line
            }
            // Also feed the legacy extractionLog for backward compat.
            if itemToSourceIDs[id] != nil {
                if extractionLog.isEmpty {
                    extractionLog = line
                } else {
                    extractionLog += "\n" + line
                }
                parsePIDIfPresent(line)
            }

        case .completed(let item):
            removeItem(item)
            refreshSummaryAfterTerminal(itemID: item.id)

        case .failed(let item, let error):
            removeItem(item)
            if item.queue == .extraction, extractionLog.isEmpty {
                extractionLog = "Extraction failed: \(error)"
            }
            refreshSummaryAfterTerminal(itemID: item.id)

        case .cancelled(let item):
            removeItem(item)
            refreshSummaryAfterTerminal(itemID: item.id)

        case .runStateChanged:
            // Not relevant to activity tracking.
            break
        case .reordered:
            // Ordering changed but state is unchanged; the next snapshot
            // refresh will pick up the new order. No tracker update needed.
            break

        // Integrated-queue-workspace plan §2: the report events feed the
        // summary cache. Everything else above is unchanged activity behavior.
        case .reportUpdated(_, let report):
            // Persistence committed BEFORE this event published, so the report
            // is durable. Synthesize the bounded summary and merge by revision
            // (an older event never rolls the cache back).
            merge(summary: QueueWorkspaceMapper.summary(from: report))

        case .reportUnavailable(let id, let reason):
            // Report persistence failed: keep the last committed summary (if
            // any), label reporting unavailable, log — never invent outcomes
            // and never change the job's own lifecycle presentation.
            DebugLog.store("QueueActivityTracker: report unavailable for \(id.rawValue.prefix(8)): \(reason)")
            if reportSummaries[id] == nil {
                reportSummaryStates[id] = .unavailable
            }
        }
    }

    /// Re-fetch one item's summary after a terminal lifecycle transition —
    /// report commits can land just before the terminal event publishes, so
    /// the cached mid-run summary (or a legacy no-report state) may be stale.
    /// Contract: "Reload on … terminal lifecycle transitions."
    private func refreshSummaryAfterTerminal(itemID: QueueItem.ID) {
        guard queueEngine != nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshReportSummaries(itemIDs: [itemID], force: true)
        }
    }

    /// Accumulate interactive (Ask/Edit chat) usage into today's daily total.
    ///
    /// Interactive chat sessions don't go through the queue — they use
    /// `AgentLauncher.sendInteractiveMessage`, which reads the ACP backend's
    /// per-session usage and emits the per-turn DELTA (not cumulative) via
    /// `AgentLauncher.onInteractiveUsage`. This method is the receiving end:
    /// the app wires the launcher's callback to it.
    ///
    /// There is no queue item (and thus no `itemUsage` entry) for interactive
    /// sessions — only the daily total (`todayUsage`) is updated, which is
    /// what the menu bar "Today: X tokens" line reads. The queue path's
    /// `.usage` event handler (`itemUsage[id] = usage`) is intentionally NOT
    /// replicated here.
    func recordInteractiveUsage(_ usage: SessionUsage) {
        todayUsage.add(usage)
        DailyUsage.save(todayUsage)
    }

    /// Remove an item from the active set and clean up its mapping.
    private func removeItem(_ item: QueueItem) {
        // Ensure the per-item maps are populated even if `.started` was the
        // event that got dropped (#871) — `forgetRunningItem` reads them.
        itemToQueue[item.id] = item.queue
        if item.queue == .ingestion, let pageIDs = item.payload.lintPageIDs {
            itemToLintPageIDs[item.id] = pageIDs
            itemToLintWikiID[item.id] = item.wikiID
        }
        forgetRunningItem(item.id)
    }

    /// Clear ALL running-state for an item ID using the tracker's stored maps.
    /// Shared by terminal-event handling (via `removeItem`) and by snapshot
    /// reconciliation (#871 self-heal), which calls it directly when the daemon
    /// reports an item is no longer active but no terminal event arrived.
    ///
    /// Queue-kind aware: a source ID can be tracked under both extraction and
    /// ingestion by different items, so `itemToQueue` selects the correct set.
    /// When the queue kind is unknown (an item we never saw `.started` for),
    /// source IDs are left untouched to avoid clearing a sibling item's spinner.
    private func forgetRunningItem(_ id: QueueItem.ID) {
        let queue = itemToQueue.removeValue(forKey: id)
        if let sourceIDs = itemToSourceIDs.removeValue(forKey: id) {
            switch queue {
            case .extraction, .transcription:
                extractingSourceIDs.subtract(sourceIDs)
            case .ingestion:
                ingestingSourceIDs.subtract(sourceIDs)
            case .none:
                // Unknown queue — leave the running sets alone; a sibling item
                // owning the same source ID will clear it on its own terminal
                // event / reconciliation.
                break
            }
        }
        // Lint items are tracked separately — always remove on terminal state.
        lintingItemIDs.remove(id)
        if let pageIDs = itemToLintPageIDs.removeValue(forKey: id) {
            let wikiID = itemToLintWikiID.removeValue(forKey: id)
            if pageIDs.isEmpty {
                // Whole-wiki lint. Safe to remove by wiki ID: the `.ingest`
                // lane limit is 1 per session, so at most one whole-wiki lint
                // runs per wiki at a time — this item was the only one.
                if let wikiID { wholeWikiLintingWikiIDs.remove(wikiID) }
            } else {
                for pageID in pageIDs { lintingPageIDs.remove(pageID) }
            }
        }
        if currentExtractionItemID == id {
            currentExtractionItemID = nil
        }
        // #544: drop the in-progress usage snapshot on terminal state. Failed
        // and cancelled items never emit a `.usage` event, so without this the
        // live snapshot would linger. Completed items have already dropped it
        // in the `.usage` handler (this is a redundant-clear safety net then).
        liveUsage.removeValue(forKey: id)
        // #608: clear any surfaced pending permission on terminal state. The
        // launcher's poller is torn down in `finish()` — a resolved/rejected/
        // auto-rejected request would already have cleared this via the
        // `.pendingPermission(_, nil)` event, but a terminal state arriving
        // first (e.g. cancelled mid-prompt) needs this safety net so the
        // yellow row doesn't linger on a completed/failed/cancelled row.
        pendingPermissions.removeValue(forKey: id)
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

// MARK: - DailyUsage (#528 spike)

/// A lightweight daily token/cost accumulator that persists to UserDefaults
/// and resets at midnight. Stores the date so stale data from a prior day is
/// discarded on load. Not a full `usage_log` table — just enough for the menu
/// bar's "Today: X tokens · $Y" line.
struct DailyUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var cost: Double = 0
    var currency: String? = nil
    /// The calendar day this total covers (yyyy-MM-dd). On load, if this
    /// doesn't match today, the struct is reset.
    var date: String

    private static let storageKey = "sdw_dailyUsage_v1"

    /// Load today's usage from UserDefaults. If the stored date is stale
    /// (yesterday or older), returns a fresh zero total for today.
    static func load() -> DailyUsage {
        let today = Self.todayString()
        guard let dict = UserDefaults.standard.dictionary(forKey: storageKey),
              let storedDate = dict["date"] as? String,
              storedDate == today
        else {
            return DailyUsage(date: today)
        }
        return DailyUsage(
            inputTokens: dict["inputTokens"] as? Int ?? 0,
            outputTokens: dict["outputTokens"] as? Int ?? 0,
            totalTokens: dict["totalTokens"] as? Int ?? 0,
            cost: dict["cost"] as? Double ?? 0,
            currency: dict["currency"] as? String,
            date: storedDate
        )
    }

    /// Persist to UserDefaults. Called after each `.usage` event.
    static func save(_ usage: DailyUsage) {
        var dict: [String: Any] = [
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "date": usage.date
        ]
        if let currency = usage.currency { dict["currency"] = currency }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    /// Accumulate a run's usage into this daily total.
    mutating func add(_ usage: SessionUsage) {
        // Guard against double-counting if the date rolled over mid-session.
        if date != Self.todayString() {
            self = DailyUsage(date: Self.todayString())
        }
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        totalTokens += usage.totalTokens
        if let c = usage.cost { cost += c }
        if currency == nil { currency = usage.currency }
    }

    /// True if anything was tracked today (non-zero tokens).
    var hasData: Bool {
        totalTokens > 0 || cost > 0
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

// MARK: - Per-model usage breakdown (#583)

/// One model's contribution to a day's (or a run's) token/cost usage. Tokens
/// are summed across all runs that used this model; cost is the sum of the
/// per-run `SessionUsage.cost` amounts. Kept as a plain struct (no `EventLoop`
/// concerns) so it can be accumulated on the main actor and persisted to
/// `UserDefaults`. Mirrors `DailyUsage`'s shape but per-model.
struct ModelUsageBreakdown: Codable, Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var thoughtTokens: Int = 0
    var totalTokens: Int = 0
    var cost: Double = 0
    var currency: String = "USD"
    var runCount: Int = 0

    /// Placeholder model id used when the backend didn't report one (older
    /// agents, non-ACP backends). Kept as a constant so the bucket is stable
    /// across loads/persists, and so the formatter can render a friendly
    /// label ("Unknown model") rather than the literal sentinel.
    static let unknownModelKey = "__unknown__"

    /// Accumulate a `SessionUsage` snapshot into this breakdown. Each call
    /// represents one run's contribution — `runCount` is bumped by 1 so a
    /// multi-model day shows sensible per-model run counts.
    mutating func add(_ usage: SessionUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        thoughtTokens += (usage.thoughtTokens ?? 0)
        totalTokens += usage.totalTokens
        if let c = usage.cost { cost += c }
        if let cur = usage.currency, !cur.isEmpty { currency = cur }
        runCount += 1
    }

    /// True if this breakdown has any non-zero data.
    var hasData: Bool {
        totalTokens > 0 || cost > 0 || runCount > 0
    }
}

// MARK: - DailyUsageByModel (#583)

/// Per-model breakdown for a single calendar day. Persists to `UserDefaults`
/// with a date key that resets daily — mirrors `DailyUsage`'s lifecycle. Used
/// by the menu bar to render one disabled item per model below the summary
/// line: "Sonnet 4 · 52K in · 8K out · 1.2K thought · $0.89".
struct DailyUsageByModel: Sendable, Equatable {
    /// `[modelId: breakdown]`. Keyed by the raw model id reported by the
    /// agent (e.g. "claude-sonnet-4-5") — the display name is resolved lazily
    /// by the formatter, since the friendly name isn't on the usage event
    /// (only on `ModelsInfo.availableModels`, which the menu bar controller
    /// doesn't hold).
    var byModel: [String: ModelUsageBreakdown] = [:]
    var date: String

    private static let storageKey = "sdw_dailyUsageByModel_v1"

    /// Load today's per-model usage from UserDefaults. If the stored date is
    /// stale (yesterday or older), returns a fresh empty total for today.
    static func load() -> DailyUsageByModel {
        let today = Self.todayString()
        guard let dict = UserDefaults.standard.dictionary(forKey: storageKey),
              let storedDate = dict["date"] as? String,
              storedDate == today,
              let modelsDict = dict["byModel"] as? [String: [String: Any]]
        else {
            return DailyUsageByModel(date: today)
        }
        var byModel: [String: ModelUsageBreakdown] = [:]
        for (modelId, raw) in modelsDict {
            guard let b = ModelUsageBreakdown(from: raw) else { continue }
            byModel[modelId] = b
        }
        return DailyUsageByModel(byModel: byModel, date: storedDate)
    }

    /// Persist to UserDefaults. Called after each `.usage` event.
    static func save(_ usage: DailyUsageByModel) {
        let modelsDict: [String: [String: Any]] = usage.byModel.mapValues { b in
            [
                "inputTokens": b.inputTokens,
                "outputTokens": b.outputTokens,
                "thoughtTokens": b.thoughtTokens,
                "totalTokens": b.totalTokens,
                "cost": b.cost,
                "currency": b.currency,
                "runCount": b.runCount
            ]
        }
        UserDefaults.standard.set([
            "byModel": modelsDict,
            "date": usage.date
        ] as [String: Any], forKey: storageKey)
    }

    /// Accumulate a run's usage into the per-model breakdown for this day.
    mutating func add(_ usage: SessionUsage) {
        // Guard against double-counting if the date rolled over mid-session.
        if date != Self.todayString() {
            self = DailyUsageByModel(date: Self.todayString())
        }
        let key = usage.modelId ?? ModelUsageBreakdown.unknownModelKey
        byModel[key, default: ModelUsageBreakdown()].add(usage)
    }

    /// True if any model has tracked data.
    var hasData: Bool {
        byModel.values.contains { $0.hasData }
    }

    /// The breakdowns sorted for menu display: largest total tokens first
    /// (so the heaviest model is at the top of the per-model list), with the
    /// unknown-model bucket always last.
    var sortedForDisplay: [(modelId: String, breakdown: ModelUsageBreakdown)] {
        byModel
            .filter { $0.value.hasData }
            .sorted { lhs, rhs in
                let lhsUnknown = lhs.key == ModelUsageBreakdown.unknownModelKey
                let rhsUnknown = rhs.key == ModelUsageBreakdown.unknownModelKey
                if lhsUnknown != rhsUnknown { return rhsUnknown }
                return lhs.value.totalTokens > rhs.value.totalTokens
            }
            .map { (modelId: $0.key, breakdown: $0.value) }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

private extension ModelUsageBreakdown {
    /// Decode from the `[String: Any]` shape written to UserDefaults by
    /// `DailyUsageByModel.save`. Returns nil if the dict is malformed.
    init?(from dict: [String: Any]) {
        self.inputTokens = dict["inputTokens"] as? Int ?? 0
        self.outputTokens = dict["outputTokens"] as? Int ?? 0
        self.thoughtTokens = dict["thoughtTokens"] as? Int ?? 0
        self.totalTokens = dict["totalTokens"] as? Int ?? 0
        self.cost = dict["cost"] as? Double ?? 0
        self.currency = dict["currency"] as? String ?? "USD"
        self.runCount = dict["runCount"] as? Int ?? 0
        // A malformed dict isn't an error worth crashing on — the day's
        // breakdown is best-effort cosmetic data, not the source of truth.
        guard self.hasData else { return nil }
    }
}

// MARK: - Usage formatting (#528 spike)

/// Pure formatting helpers for token/cost usage display. No UI — just
/// number → string so views stay declarative and the logic is testable.
enum UsageFormatter {
    /// Format a token count as "12.4K" or "1.2M" (compact). Below 1,000 shows
    /// the raw integer. Uses the "K"/"M" suffixes the issue spec mentions.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Format a cost as "$0.34" or "$1234.56" (locale-independent: `%.2f`
    /// emits no grouping separator). Returns nil if cost is 0 or nil.
    static func cost(_ amount: Double?, currency: String?) -> String? {
        guard let amount, amount > 0 else { return nil }
        let symbol = currency == "USD" || currency == nil ? "$" : ""
        let suffix: String
        if let currency, currency != "USD" {
            suffix = " \(currency)"
        } else {
            suffix = ""
        }
        return String(format: "%@%.2f%@", symbol, amount, suffix)
    }

    /// Format a duration in milliseconds as a compact string: "42s", "1m 3s",
    /// "3m 0s". Below 1 second shows as "<1s" (avoiding "0s" for sub-second
    /// runs). Over 1 hour shows "1h 3m".
    static func duration(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let secs = ms / 1000
        if secs < 1 { return "<1s" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Format an epoch-millisecond timestamp as a compact wall-clock time:
    /// "3:42 PM" (locale-aware). Returns nil when the timestamp is nil/zero.
    static func startTime(ms: Int64?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.timeStyle = .short
        f.locale = .current
        return f.string(from: date)
    }

    /// A compact one-line summary of token usage with explicit units:
    /// "12.4K tokens in · 3.2K tokens out". Omits nothing — this is the
    /// token-only segment (no model/duration), used when the caller builds
    /// its own composite line.
    static func tokenSummary(usage: SessionUsage) -> String {
        var parts: [String] = []
        parts.append("\(tokens(usage.inputTokens)) tokens in")
        parts.append("\(tokens(usage.outputTokens)) tokens out")
        if let thought = usage.thoughtTokens, thought > 0 {
            parts.append("\(tokens(thought)) thought")
        }
        return parts.joined(separator: " · ")
    }

    /// A compact one-line summary: "12.4K tokens in · 3.2K tokens out · $0.34".
    /// Omits the cost segment when nil/zero. Uses middle-dot separator (macOS
    /// convention). Kept for backward compat (menu bar, simple callers).
    static func summary(usage: SessionUsage) -> String {
        var parts = [tokenSummary(usage: usage)]
        if let cost = cost(usage.cost, currency: usage.currency) {
            parts.append(cost)
        }
        return parts.joined(separator: " · ")
    }

    /// A grouped, locale-aware integer ("8,120"). The Run Details breakdown
    /// shows exact counts — never the compact "8.1K" vocabulary — so the
    /// operator can reconcile the panel against provider usage dashboards.
    static func groupedCount(_ count: Int) -> String {
        count.formatted()
    }

    /// Cost with sub-cent precision for the Run Details breakdown: "$0.0421".
    /// Four decimals, trailing zeros trimmed but never below two ("$0.34",
    /// "$0.10") so the line matches the two-decimal `cost` shape whenever the
    /// extra precision is not needed. Same omission rule as `cost` (nil/zero
    /// → nil).
    static func preciseCost(_ amount: Double?, currency: String?) -> String? {
        guard let amount, amount > 0 else { return nil }
        let symbol = currency == "USD" || currency == nil ? "$" : ""
        let suffix: String
        if let currency, currency != "USD" {
            suffix = " \(currency)"
        } else {
            suffix = ""
        }
        let pieces = String(format: "%.4f", amount).split(separator: ".", maxSplits: 1)
        var decimals = pieces.count > 1 ? String(pieces[1]) : ""
        while decimals.count > 2 && decimals.hasSuffix("0") {
            decimals.removeLast()
        }
        return symbol + pieces[0] + (decimals.isEmpty ? "" : "." + decimals) + suffix
    }

    /// The full per-run summary line for the Activity window. Combines run
    /// metadata (provider, model, start time, duration) with token usage:
    ///
    ///     "14:32 · 1m 3s · Claude · Sonnet 4 · 797 tokens in · 203 tokens out · 412 thought · $0.34"
    ///
    /// Segments are omitted when data is unavailable (nil model, no duration,
    /// zero cost, etc.). The `startedAt`/`finishedAt` epoch-ms timestamps
    /// come from the `QueueItem` — the activity tracker doesn't own them.
    static func fullSummary(
        usage: SessionUsage,
        startedAt: Int64?,
        finishedAt: Int64?
    ) -> String {
        var parts: [String] = []

        // Start time first — anchors the run in time.
        if (startedAt ?? 0) > 0 {
            if let time = startTime(ms: startedAt) {
                parts.append(time)
            }
            if let dur = duration(
                ms: finishedAt.map { Int($0 - (startedAt ?? $0)) }
            ) {
                parts.append(dur)
            }
        }

        // Provider (harness) + model — the "what ran it" context. Prefer the
        // human-readable name (e.g. "Claude Sonnet 4.5") when reported; fall
        // back to the raw `modelId` so a stale model id is still visible.
        if let label = usage.providerLabel {
            parts.append(label)
        }
        if let model = usage.modelName ?? usage.modelId {
            parts.append(model)
        }

        // #566: thinking-effort level (high/medium/low) — between the model and
        // the token counts, matching the issue's example line:
        // "Sonnet 4 · high · 797 tokens in · 203 tokens out · 412 thought".
        if let level = usage.thinkingLevel, !level.isEmpty {
            parts.append(level)
        }

        // Token usage with explicit units.
        parts.append(tokenSummary(usage: usage))

        if let cost = cost(usage.cost, currency: usage.currency) {
            parts.append(cost)
        }

        return parts.joined(separator: " · ")
    }

    /// A daily total line: "Today: 45.2K tokens · $1.23". Omits cost when nil.
    static func dailySummary(usage: DailyUsage) -> String {
        var parts: [String] = ["Today: \(tokens(usage.totalTokens)) tokens"]
        if usage.cost > 0 {
            parts.append(cost(usage.cost, currency: usage.currency) ?? "")
        }
        return parts.joined(separator: " · ")
    }

    /// A live in-progress summary line for a RUNNING row (#544 live progress).
    /// Combines the stream's current model/provider with running token counts:
    ///
    ///     "Sonnet 4 · 12.4K in · 3.2K out · 412 thought"
    ///
    /// Omits duration/cost — the on-completion `fullSummary` carries those (cost
    /// isn't meaningful mid-run, and elapsed time comes from the row's own
    /// timer, not the usage snapshot). Segments are omitted when data is
    /// unavailable (nil model, zero tokens). The caller appends elapsed time
    /// from its own clock so the line ticks independently of usage updates.
    static func liveSummary(usage: SessionUsage) -> String {
        var parts: [String] = []
        if let label = usage.providerLabel {
            parts.append(label)
        }
        if let model = usage.modelId {
            parts.append(model)
        }
        if usage.inputTokens > 0 || usage.outputTokens > 0 {
            parts.append("\(tokens(usage.inputTokens)) in")
            parts.append("\(tokens(usage.outputTokens)) out")
            if let thought = usage.thoughtTokens, thought > 0 {
                parts.append("\(tokens(thought)) thought")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// A single per-model menu line: "Sonnet 4 · 52K in · 8K out · 1.2K thought
    /// · $0.89". The model display name is resolved best-effort: the daily
    /// store is keyed by raw `modelId` (the menu bar doesn't hold
    /// `ModelsInfo.availableModels`), so we render the id as-is. Callers may
    /// pass a friendly-name lookup if one is available.
    ///
    /// The format mirrors the issue spec:
    ///
    ///     "  Sonnet 4 · 52K in · 8K out · 1.2K thought · $0.89"
    ///
    /// Tokens use the compact form (`XK`/`XM`); cost renders as `$X.XX` or is
    /// omitted when zero. `runCount > 1` appends " · N runs" so the user can
    /// see when many small runs added up to a model's total — that's the
    /// signal a flat aggregate hides.
    static func modelBreakdownLine(
        modelId: String,
        breakdown: ModelUsageBreakdown,
        displayNameProvider: ((String) -> String?)? = nil
    ) -> String {
        let label: String
        if modelId == ModelUsageBreakdown.unknownModelKey {
            label = "Unknown model"
        } else if let friendly = displayNameProvider?(modelId) {
            label = friendly
        } else {
            label = modelId
        }
        var parts: [String] = [
            label,
            "\(tokens(breakdown.inputTokens)) in",
            "\(tokens(breakdown.outputTokens)) out"
        ]
        if breakdown.thoughtTokens > 0 {
            parts.append("\(tokens(breakdown.thoughtTokens)) thought")
        }
        if let cost = cost(breakdown.cost, currency: breakdown.currency) {
            parts.append(cost)
        }
        if breakdown.runCount > 1 {
            parts.append("\(breakdown.runCount) runs")
        }
        return parts.joined(separator: " · ")
    }

    /// A per-item per-model line — same shape as the daily version but pulled
    /// from the per-item `ModelUsageBreakdown` (today a run's single snapshot
    /// produces a one-entry breakdown). Reads `SessionUsage`-style fields where
    /// available so the label can show the friendly `modelName`.
    static func itemModelBreakdownLine(
        modelId: String,
        breakdown: ModelUsageBreakdown,
        usage: SessionUsage?
    ) -> String {
        let label: String
        if modelId == ModelUsageBreakdown.unknownModelKey {
            label = usage?.modelName ?? "Unknown model"
        } else if let name = usage?.modelName {
            label = name
        } else {
            label = modelId
        }
        var parts: [String] = [
            label,
            "\(tokens(breakdown.inputTokens)) in",
            "\(tokens(breakdown.outputTokens)) out"
        ]
        if breakdown.thoughtTokens > 0 {
            parts.append("\(tokens(breakdown.thoughtTokens)) thought")
        }
        if let c = usage?.cost, c > 0,
           let cost = cost(c, currency: usage?.currency) {
            parts.append(cost)
        }
        return parts.joined(separator: " · ")
    }
}
