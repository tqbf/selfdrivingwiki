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

/// A mutable box for a `@Sendable` transcript-emit closure. Same pattern as
/// `ProgressEmitBox` — breaks the circular dependency between the ingestion
/// worker factory (needs the closure) and the engine (provides it).
final class TranscriptEmitBox: @unchecked Sendable {
    var emit: (@Sendable (QueueItem.ID, AgentEvent) -> Void)?
}

/// A mutable box for a `@Sendable` usage-emit closure. Same pattern as
/// `ProgressEmitBox`/`TranscriptEmitBox` — breaks the circular dependency
/// between the ingestion worker factory (needs the closure) and the engine
/// (provides it). #528 spike.
final class UsageEmitBox: @unchecked Sendable {
    var emit: (@Sendable (QueueItem.ID, SessionUsage) -> Void)?
}

/// A mutable box for a `@Sendable` live-usage-emit closure. Same pattern as
/// the other emit boxes — breaks the circular dependency between the ingestion
/// worker factory (needs the closure) and the engine (provides it). #544 live
/// progress: carries in-progress token/cost usage during a run (the final
/// `UsageEmitBox` fires once on completion).
final class LiveUsageEmitBox: @unchecked Sendable {
    var emit: (@Sendable (QueueItem.ID, SessionUsage) -> Void)?
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

    /// Source IDs currently being ingested (any ingestion queue item in
    /// `.running` state). Drives per-file "Ingesting…" labels and cross-file
    /// Ingest button disable. Replaces `launcher.ingestingSourceIDs`.
    private(set) var ingestingSourceIDs: Set<PageID> = []

    /// Queue item IDs currently running a lint (`.ingestion` items with
    /// `lintPageIDs != nil`). Lint items have empty `sourceIDs`, so they
    /// don't show up in `ingestingSourceIDs` — this set ensures
    /// `isIngesting` covers lint-only runs.
    private(set) var lintingItemIDs: Set<QueueItem.ID> = []

    /// True while any extraction is running. Drives the sidebar spinner.
    var isExtracting: Bool { !extractingSourceIDs.isEmpty }

    /// True while any ingestion or lint is running.
    var isIngesting: Bool { !ingestingSourceIDs.isEmpty || !lintingItemIDs.isEmpty }

    /// Per-item typed agent events, for the Activity window's transcript view.
    /// Bounded — pruned only when items are pruned from history (not on
    /// terminal state, so users can view completed/failed/cancelled transcripts).
    private(set) var transcripts: [QueueItem.ID: [AgentEvent]] = [:]

    /// Per-item accumulated progress text (for extraction items that produce
    /// progress strings, not typed `AgentEvent`s). Keyed by item ID.
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

    /// Accumulated progress log for the most recent extraction. Cleared on
    /// `.started`, appended on `.progress`. Drives the sidebar log text.
    private(set) var extractionLog: String = ""

    /// PID of the extraction subprocess (parsed from progress lines if the
    /// local pdf2md backend reports it). `nil` for remote backends.
    private(set) var extractionPID: Int32? = nil

    // MARK: - Internal tracking

    /// Maximum number of typed events to retain per item. Older events are
    /// dropped beyond this bound to keep memory bounded.
    private let maxTranscriptEvents = 1000

    /// Maximum number of items to retain transcripts for. When exceeded, the
    /// oldest item's transcript is pruned. This prevents unbounded growth when
    /// many items accumulate over a long session.
    private let maxTrackedItems = 200

    /// Maps queue item ID → source IDs, so we can remove source IDs from
    /// `extractingSourceIDs` when items finish.
    private var itemToSourceIDs: [QueueItem.ID: Set<PageID>] = [:]

    /// Items whose transcript's last row is an in-progress streamed assistant
    /// reply — the next `.assistantTextDelta` grows that row in place instead
    /// of appending a new one (mirrors `AgentLauncher.mergeOrAppend`; without
    /// this, a streamed reply renders as one row per word-fragment).
    private var streamingTranscriptItemIDs: Set<QueueItem.ID> = []

    /// Items whose transcript's last row is an in-progress streamed thinking
    /// block — the next `.thinkingDelta` grows that row in place instead of
    /// appending a new one (mirrors `streamingTranscriptItemIDs` for assistant text).
    private var streamingThinkingItemIDs: Set<QueueItem.ID> = []

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
        ingestingSourceIDs = []
        lintingItemIDs = []
        extractionLog = ""
        extractionPID = nil
        currentExtractionItemID = nil
        itemToSourceIDs.removeAll()
        transcripts.removeAll()
        progressLogs.removeAll()
        itemUsage.removeAll()
        liveUsage.removeAll()
        streamingTranscriptItemIDs.removeAll()
        streamingThinkingItemIDs.removeAll()
    }

    // MARK: - Public API

    /// Cancel the currently running extraction (if any). Calls
    /// `queueEngine.cancelItem(itemID)` which cancels the worker's `Task`
    /// and transitions the item to `.cancelled`.
    func cancelExtraction() async {
        guard let itemID = currentExtractionItemID, let engine = queueEngine else { return }
        await engine.cancelItem(itemID)
    }

    /// True if the tracker has been attached to a queue engine's event stream.
    /// Used by `appEnvironment` to assert the tracker is live before injection.
    var isAttachedToEngine: Bool {
        streamTask != nil
    }

    /// True if an extraction is running but NOT for this specific source.
    /// Used to disable the Extract button when another file holds the
    /// extraction slot (local pdf2md is limit 1).
    func isSlotBusyForOtherSource(_ id: PageID) -> Bool {
        !extractingSourceIDs.isEmpty && !extractingSourceIDs.contains(id)
    }

    /// Append a typed event to the transcript for a queue item. Called from
    /// the `.transcript` event handler. Streamed `.assistantTextDelta` chunks
    /// grow the last row in place (mirroring `AgentLauncher.mergeOrAppend`) —
    /// appending them raw renders one row per word-fragment. Bounded — drops
    /// oldest events beyond `maxTranscriptEvents` per item, and prunes oldest
    /// items beyond `maxTrackedItems`.
    func appendTranscriptEvent(itemID: QueueItem.ID, event: AgentEvent) {
        var arr = transcripts[itemID, default: []]
        switch event {
        case .assistantTextDelta(let delta):
            if streamingTranscriptItemIDs.contains(itemID),
               case .assistantText(let existing) = arr.last {
                arr[arr.count - 1] = .assistantText(existing + delta)
            } else {
                arr.append(.assistantText(delta))
                streamingTranscriptItemIDs.insert(itemID)
            }
            streamingThinkingItemIDs.remove(itemID)
        case .assistantText:
            // Authoritative full text for a block already being streamed —
            // replace the accumulated row rather than duplicating it.
            if streamingTranscriptItemIDs.contains(itemID),
               case .assistantText = arr.last {
                arr[arr.count - 1] = event
            } else {
                arr.append(event)
            }
            streamingTranscriptItemIDs.remove(itemID)
            streamingThinkingItemIDs.remove(itemID)
        case .thinkingDelta(let delta):
            if streamingThinkingItemIDs.contains(itemID),
               case .thinking(let existing) = arr.last {
                arr[arr.count - 1] = .thinking(existing + delta)
            } else {
                arr.append(.thinking(delta))
                streamingThinkingItemIDs.insert(itemID)
            }
            streamingTranscriptItemIDs.remove(itemID)
        case .thinking:
            // Authoritative full text for a thinking block already being
            // streamed — replace the accumulated row rather than duplicating it.
            if streamingThinkingItemIDs.contains(itemID),
               case .thinking = arr.last {
                arr[arr.count - 1] = event
            } else {
                arr.append(event)
            }
            streamingThinkingItemIDs.remove(itemID)
            streamingTranscriptItemIDs.remove(itemID)
        default:
            arr.append(event)
            streamingTranscriptItemIDs.remove(itemID)
            streamingThinkingItemIDs.remove(itemID)
        }
        if arr.count > maxTranscriptEvents {
            arr.removeFirst(arr.count - maxTranscriptEvents)
        }
        transcripts[itemID] = arr

        // Bound the number of tracked items — prune oldest (first inserted).
        if transcripts.count > maxTrackedItems {
            let toRemove = transcripts.count - maxTrackedItems
            let oldestIDs = Array(transcripts.keys.prefix(toRemove))
            for id in oldestIDs {
                transcripts.removeValue(forKey: id)
                progressLogs.removeValue(forKey: id)
            }
        }
    }

    /// Prune the transcript + progress log for an item. Called when items are
    /// pruned from history (the bounded-recent-items path), NOT on terminal
    /// state — so users can view completed/failed/cancelled transcripts.
    func pruneTranscripts(for itemID: QueueItem.ID) {
        transcripts.removeValue(forKey: itemID)
        progressLogs.removeValue(forKey: itemID)
        itemUsage.removeValue(forKey: itemID)
        liveUsage.removeValue(forKey: itemID)
        streamingTranscriptItemIDs.remove(itemID)
        streamingThinkingItemIDs.remove(itemID)
    }

    /// The transcript for a given item ID (may be empty / nil).
    func transcript(for itemID: QueueItem.ID) -> [AgentEvent] {
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

    // MARK: - Event handling

    @MainActor
    func handle(_ event: QueueEvent) {
        switch event {
        case .enqueued(let item):
            // Track the mapping so we can clean up on completion.
            let sourceIDs = Set(item.payload.sourceIDs)
            itemToSourceIDs[item.id] = sourceIDs

        case .started(let item):
            let sourceIDs = Set(item.payload.sourceIDs)
            itemToSourceIDs[item.id] = sourceIDs
            switch item.queue {
            case .extraction:
                extractingSourceIDs.formUnion(sourceIDs)
                extractionLog = ""
                extractionPID = nil
                currentExtractionItemID = item.id
                progressLogs[item.id] = ""
            case .ingestion:
                if item.payload.lintPageIDs != nil {
                    // Lint item — track separately (empty sourceIDs).
                    lintingItemIDs.insert(item.id)
                } else {
                    ingestingSourceIDs.formUnion(sourceIDs)
                }
            }

        case .transcript(let id, let agentEvent):
            appendTranscriptEvent(itemID: id, event: agentEvent)

        case .usage(let id, let usage):
            // #528 spike: store per-item usage for the Activity window, and
            // accumulate today's daily total (persists to UserDefaults).
            itemUsage[id] = usage
            todayUsage.add(usage)
            DailyUsage.save(todayUsage)
            // The run is complete — drop the in-progress snapshot so the
            // Activity window renders the final totals, not a stale live one.
            liveUsage.removeValue(forKey: id)

        case .liveUsage(let id, let usage):
            // #544 live progress: store the latest in-progress usage snapshot
            // for a running item. Overwrites the previous snapshot (each
            // usage_update carries the current cumulative totals + the latest
            // model/cost). Cleared on terminal state in removeItem().
            liveUsage[id] = usage

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

        case .failed(let item, let error):
            removeItem(item)
            if item.queue == .extraction, extractionLog.isEmpty {
                extractionLog = "Extraction failed: \(error)"
            }

        case .cancelled(let item):
            removeItem(item)

        case .runStateChanged:
            // Not relevant to activity tracking.
            break
        case .reordered:
            // Ordering changed but state is unchanged; the next snapshot
            // refresh will pick up the new order. No tracker update needed.
            break
        }
    }

    /// Remove an item from the active set and clean up its mapping.
    private func removeItem(_ item: QueueItem) {
        if let sourceIDs = itemToSourceIDs.removeValue(forKey: item.id) {
            switch item.queue {
            case .extraction:
                extractingSourceIDs.subtract(sourceIDs)
            case .ingestion:
                ingestingSourceIDs.subtract(sourceIDs)
            }
        }
        // Lint items are tracked separately — always remove on terminal state.
        lintingItemIDs.remove(item.id)
        if currentExtractionItemID == item.id {
            currentExtractionItemID = nil
        }
        // #544: drop the in-progress usage snapshot on terminal state. Failed
        // and cancelled items never emit a `.usage` event, so without this the
        // live snapshot would linger. Completed items have already dropped it
        // in the `.usage` handler (this is a redundant-clear safety net then).
        liveUsage.removeValue(forKey: item.id)
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
        UserDefaults.standard.set([
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "currency": usage.currency as Any,
            "date": usage.date
        ] as [String: Any], forKey: storageKey)
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

    /// Format a cost as "$0.34" or "$1,234.56". Returns nil if cost is 0 or nil.
    static func cost(_ amount: Double?, currency: String?) -> String? {
        guard let amount, amount > 0 else { return nil }
        let symbol = currency == "USD" || currency == nil ? "$" : ""
        let suffix = (currency != nil && currency != "USD") ? " \(currency!)" : ""
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

        // Provider (harness) + model — the "what ran it" context.
        if let label = usage.providerLabel {
            parts.append(label)
        }
        if let model = usage.modelId {
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
}
