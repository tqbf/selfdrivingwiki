import CoreGraphics
import Foundation
import WikiFSCore
import WikiFSEngine

// MARK: - Status

/// One status as it renders everywhere in the queue workspace: a text label, an
/// SF Symbol paired with it (plan: "Pair every color-coded status with text and
/// a symbol"), and a *semantic* style the views map to `foregroundStyle` so
/// light/dark and Increase Contrast adapt without per-view colors.
///
/// Pure value — no SwiftUI imports, no backend enums inspected. Callers map
/// `QueueItem.State` and §2 report target states onto the factories below; the
/// workspace never inspects backend enums. (File-wide caveat: the value layer
/// does carry one backend-reported payload as opaque data — the `SessionUsage`
/// field on `QueueRunDetailsFacts`, formatted into rows by `entries` and never
/// interpreted here.)
struct QueueWorkspaceStatus: Equatable, Sendable {
    /// Semantic color role. Views resolve it once; tests assert the role, not
    /// a resolved `Color`.
    enum Style: String, Sendable {
        /// Accent/normal emphasis — active work.
        case primary
        /// Quiet states that must not compete with content.
        case secondary
        /// Confirmed good outcome (green).
        case success
        /// Notable-but-not-fatal (orange) — skipped, permission stalls.
        case warning
        /// Failure (red).
        case failure
        /// Ongoing activity — renders with the running spinner affordance.
        case running
    }

    let text: String
    let symbol: String
    let style: Style

    init(text: String, symbol: String, style: Style) {
        self.text = text
        self.symbol = symbol
        self.style = style
    }
}

// Job lifecycle vocabulary — the `QueueItemState` projection.
extension QueueWorkspaceStatus {
    /// Waiting to be claimed.
    static func queued() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Queued", symbol: "clock", style: .secondary)
    }

    /// A worker is actively processing.
    static func running() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Running", symbol: "ellipsis.circle", style: .running)
    }

    /// Processing finished successfully.
    static func completed() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Completed", symbol: "checkmark.circle.fill", style: .success)
    }

    /// Processing failed with a recorded error.
    static func failed() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Failed", symbol: "exclamationmark.triangle.fill", style: .failure)
    }

    /// Cancelled by the user or the engine.
    static func cancelled() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Cancelled", symbol: "xmark.circle", style: .secondary)
    }
}

// Target-outcome vocabulary — the §2 report target-state projection.
extension QueueWorkspaceStatus {
    /// Worker is staging/preparing this target.
    static func preparing() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Preparing", symbol: "gearshape", style: .running)
    }

    /// Worker handed the target off (ingestion "submitted" ≠ "ingested").
    static func submitted() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Submitted", symbol: "paperplane", style: .primary)
    }

    /// Worker is actively processing the target.
    static func processing() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Processing", symbol: "ellipsis.circle", style: .running)
    }

    /// Target finished successfully (distinct from a persisted extraction
    /// output, which callers surface via a "Show Output" action).
    static func succeeded() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Succeeded", symbol: "checkmark.circle.fill", style: .success)
    }

    /// Deliberately not processed, with a recorded reason.
    static func skipped() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Skipped", symbol: "minus.circle", style: .warning)
    }
}

// MARK: - Recorded outputs (ingestion)

/// Durable output-snapshot state for an ingestion attempt. `notRecorded`
/// covers legacy reports and attempts whose post-run snapshot read failed;
/// `.loaded([])` is a distinct, known-empty result.
enum QueueOutputsLoadState: Equatable, Sendable {
    case loading
    case notRecorded
    case unavailable
    case loaded([QueueRecordedOutputPage])
}

/// Everything the Overview's Outputs section renders — plain values only,
/// derived before list iteration (same contract as
/// `QueueJobOverviewPresentation`). Rows use the shared
/// `QueueTargetRowValue`; a resolvable page's name link performs Open Page.
struct QueueOutputsSectionValue {
    /// Known count for a recorded snapshot, including a resolved zero.
    /// `nil` for legacy/unrecorded reports; unknown never renders as zero.
    let countText: String?
    let rows: [QueueTargetRowValue]
    /// Quiet state text for loading, unavailable, unrecorded, or empty
    /// snapshots. The view renders it under the section header.
    let emptyStateText: String
}

// MARK: - Job lifecycle

/// The job-level lifecycle the header and workspace act on. The caller maps
/// `QueueItem.state` 1:1 (`.transcription` queue kinds canonicalize before
/// mapping — this type is presentation-only and queue-kind-blind).
///
/// Centralizing cancel/retry visibility here keeps the header, and any future
/// context menu, from disagreeing about which states offer which action.
enum QueueWorkspaceJobLifecycle: String, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    /// Status line for the header (text + symbol + style decided once).
    var status: QueueWorkspaceStatus {
        switch self {
        case .queued: return .queued()
        case .running: return .running()
        case .completed: return .completed()
        case .failed: return .failed()
        case .cancelled: return .cancelled()
        }
    }

    /// Plan: "Show Cancel for queued/running jobs."
    var showsCancelAction: Bool {
        self == .queued || self == .running
    }

    /// Plan: "…and Retry Job for failed/cancelled jobs." Retry keeps existing
    /// whole-job semantics; this type only decides visibility.
    var showsRetryAction: Bool {
        self == .failed || self == .cancelled
    }
}

// MARK: - Progress

/// Phase progress for the header. Determinate bars are permitted *only* for a
/// known total with an observed numerator (plan: "Do not represent unknown
/// counts as zero"); anything else renders indeterminate with a meaningful
/// phase label.
enum QueueWorkspaceProgress: Equatable, Sendable {
    /// Activity without countable units — "Merging pages".
    case indeterminate(phase: String)
    /// A known total and an observed phase-specific numerator — "Staging
    /// sources: 8 of 12".
    case determinate(phase: String, completed: Int, total: Int)

    var phaseText: String {
        switch self {
        case .indeterminate(let phase): return phase
        case .determinate(let phase, _, _): return phase
        }
    }

    /// "8 of 12" — only ever produced by the determinate case, so an unknown
    /// count can never render as "0 of N".
    var countsText: String? {
        switch self {
        case .indeterminate: return nil
        case .determinate(_, let completed, let total): return "\(completed) of \(total)"
        }
    }

    /// Guards the determinate case against caller misuse (unknown totals
    /// passed as 0, negative or out-of-range numerators): when false the views
    /// fall back to the indeterminate presentation.
    var isRenderableDeterminate: Bool {
        switch self {
        case .indeterminate: return false
        case .determinate(_, let completed, let total):
            return total > 0 && completed >= 0 && completed <= total
        }
    }
}

// MARK: - Actions

/// One labeled affordance the workspace renders (row action, header action).
/// The closure is the whole action contract — this layer performs no commands,
/// logs nothing, and tracks no pending state; the caller's closure owns all of
/// that so header/context-menu/keyboard paths share one implementation.
struct QueueWorkspaceAction {
    let label: String
    let systemImage: String
    let perform: () -> Void

    init(label: String, systemImage: String, perform: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.perform = perform
    }
}

// MARK: - Target identity

/// Namespaced identity for one inventory entry (plan §2 vocabulary, mirrored in
/// presentation): the case tag makes a page ULID unable to compare equal to a
/// source ULID, per the repository's ID-separation rule. `nil`-identity rows
/// are scope markers ("Whole wiki"), not targets.
enum QueueWorkspaceTargetIdentity: Hashable, Sendable {
    case source(SourceID)
    case page(PageID)

    /// Stable list identity. The case prefix keeps the raw ULID
    /// strings from colliding across namespaces in `ForEach`/`Set<String>` use.
    var rowID: String {
        switch self {
        case .source(let id): return "source:\(id.rawValue)"
        case .page(let id): return "page:\(id.rawValue)"
        }
    }
}

// MARK: - Target row value

/// Everything one inventory row renders, derived by the caller *before* list
/// iteration (plan §4: "Derive presentation values from immutable inputs before
/// list iteration"). Plain values only — no `@Observable` reads inside row
/// bodies, preserving the existing observation-crash workaround.
///
/// A row whose `identity` is `nil` is a scope marker ("Whole wiki"): it has
/// no target to open, but may still carry a wiki-level action ("Browse
/// Pages") that its name link performs.
struct QueueTargetRowValue: Identifiable {
    /// Stable across reordering. Use
    /// `QueueWorkspaceTargetIdentity.rowID` for real targets; any stable string
    /// for scope rows.
    let id: String
    let identity: QueueWorkspaceTargetIdentity?
    /// Recognizable display name. For history rows this is the *recorded* name,
    /// preserved even when the target no longer resolves.
    let title: String
    /// Full name when it differs from the truncated `title`; `nil` means the
    /// title is already the full name. Search-only today (the row itself is
    /// not collapsible): it feeds local inventory matching and the name
    /// link's tooltip.
    let fullName: String?
    /// State/result text + symbol + style, or `nil` for an EVIDENCE-LESS
    /// target: "Planned" is the default state (operator decision, 2026-09-09),
    /// so a row with no recorded evidence renders name-only — no status
    /// circle, no "Planned" text. A row carrying a real recorded state
    /// (Submitted, Processing, Succeeded, Skipped, Failed, Interrupted,
    /// Preparing — or a whole-wiki scope row's live lifecycle) always carries
    /// a status here, and the row renders its chip.
    let status: QueueWorkspaceStatus?
    /// Skip/failure reason or an availability explanation ("Source bytes
    /// unavailable"). Search-only today (the row itself is not collapsible).
    let reason: String?
    /// Available navigation actions ("Open Page", "Open Source", "Browse
    /// Pages") — the row's name link performs the first. Empty when none are
    /// available — extraction output actions appear only while a recorded
    /// output reference stays resolvable.
    let actions: [QueueWorkspaceAction]

    init(
        id: String,
        identity: QueueWorkspaceTargetIdentity?,
        title: String,
        fullName: String? = nil,
        status: QueueWorkspaceStatus?,
        reason: String? = nil,
        actions: [QueueWorkspaceAction] = []
    ) {
        self.id = id
        self.identity = identity
        self.title = title
        self.fullName = fullName
        self.status = status
        self.reason = reason
        self.actions = actions
    }

    /// Convenience for real targets: derives `id` from the identity's
    /// namespaced `rowID`.
    init(
        identity: QueueWorkspaceTargetIdentity,
        title: String,
        fullName: String? = nil,
        status: QueueWorkspaceStatus?,
        reason: String? = nil,
        actions: [QueueWorkspaceAction] = []
    ) {
        self.init(
            id: identity.rowID,
            identity: identity,
            title: title,
            fullName: fullName,
            status: status,
            reason: reason,
            actions: actions)
    }

    /// The full recorded name — the name link's tooltip surface and a local
    /// search haystack. The row itself is not collapsible.
    var displayName: String { fullName ?? title }

    /// Local inventory search (plan: local search for large batches). Case- and
    /// diacritic-insensitive via `localizedStandardContains`, matching the
    /// job-navigator search behavior. Scope rows match on title/status too, so
    /// "Whole wiki" stays findable.
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystacks = [title, fullName, reason, status?.text].compactMap { $0 }
        return haystacks.contains { $0.localizedStandardContains(trimmed) }
    }
}

// MARK: - Run details facts

/// One labeled value in the Run Details inspector panel.
struct QueueRunDetailEntry: Equatable, Sendable {
    let label: String
    let value: String
    /// True for explicit placeholders ("Not Reported") — rendered in tertiary
    /// style so reported facts and absent facts never read the same.
    let isPlaceholder: Bool
    /// True for copyable identifiers (the job's raw ULID) — the value renders
    /// fully monospaced instead of monospaced-digit so every character aligns.
    let isMonospaced: Bool

    init(label: String, value: String, isPlaceholder: Bool = false, isMonospaced: Bool = false) {
        self.label = label
        self.value = value
        self.isPlaceholder = isPlaceholder
        self.isMonospaced = isMonospaced
    }

    static func notReported(_ label: String) -> QueueRunDetailEntry {
        QueueRunDetailEntry(label: label, value: "Not Reported", isPlaceholder: true)
    }
}

/// Run facts for the Run Details inspector panel, mapped by the caller from
/// `QueueItem` timestamps plus the §2 report header. Pure data — formatting and
/// the omit-vs-placeholder rules live in `entries` so tests cover them without
/// rendering.
///
/// Plan rules encoded here:
/// - The job's typed queue item ID leads the rows as "Job ID". The operator
///   uses it to correlate logs and CLI output with the panel. Synthetic facts
///   can omit the ID. It never uses a "Not Reported" placeholder.
/// - Unavailable optional metadata is *omitted*…
/// - …except provider/model, whose absence matters: they render a "Not
///   Reported" placeholder. Never pass a capacity bucket (`default-ingest`) as
///   the provider.
/// - An attempt of `0`/`nil` (first run) is omitted; retried attempts show.
struct QueueRunDetailsFacts: Sendable {
    /// The job's queue item ID. The inspector renders its raw value as the
    /// first row in monospaced, selectable text.
    var jobID: QueueItem.ID?
    var enqueuedAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    /// Caller-preferred static duration text (terminal states). When `nil`, the
    /// view omits the duration row; running jobs show the live clock in the
    /// header instead of here.
    var durationText: String?
    var attempt: Int?
    /// Actual provider when reported. `nil` → "Not Reported" placeholder.
    var providerText: String?
    /// Actual model when reported (usage). `nil` → "Not Reported" placeholder.
    var modelText: String?
    /// The job's usage/cost snapshot — the tracker's recorded totals, or
    /// while a run is in flight the live session's snapshot. `entries` maps
    /// it to one labeled row per PRESENT field (Input / Output / Cached /
    /// Thought / Cost); zero or absent fields are omitted — never a fake
    /// zero — and a snapshot with nothing reportable produces no usage rows.
    var usage: SessionUsage?

    init(
        jobID: QueueItem.ID? = nil,
        enqueuedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        durationText: String? = nil,
        attempt: Int? = nil,
        providerText: String? = nil,
        modelText: String? = nil,
        usage: SessionUsage? = nil
    ) {
        self.jobID = jobID
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationText = durationText
        self.attempt = attempt
        self.providerText = providerText
        self.modelText = modelText
        self.usage = usage
    }

    /// The inspector's entries, applying the omission rules above.
    var entries: [QueueRunDetailEntry] {
        var result: [QueueRunDetailEntry] = []
        if let jobID {
            result.append(QueueRunDetailEntry(
                label: "Job ID", value: jobID.rawValue, isMonospaced: true))
        }
        if let enqueuedAt {
            result.append(QueueRunDetailEntry(label: "Enqueued", value: QueueWorkspaceFormat.timestamp(enqueuedAt)))
        }
        if let startedAt {
            result.append(QueueRunDetailEntry(label: "Started", value: QueueWorkspaceFormat.timestamp(startedAt)))
        }
        if let finishedAt {
            result.append(QueueRunDetailEntry(label: "Finished", value: QueueWorkspaceFormat.timestamp(finishedAt)))
        }
        let duration = durationText?.trimmingCharacters(in: .whitespaces)
        if let duration, !duration.isEmpty {
            result.append(QueueRunDetailEntry(label: "Duration", value: duration))
        }
        if let attempt, attempt > 0 {
            result.append(QueueRunDetailEntry(label: "Attempt", value: String(attempt)))
        }
        // Provider/model absence matters (plan): explicit placeholder, never a
        // capacity bucket masquerading as a provider.
        let provider = providerText?.trimmingCharacters(in: .whitespaces)
        if let provider, !provider.isEmpty {
            result.append(QueueRunDetailEntry(label: "Provider", value: provider))
        } else {
            result.append(.notReported("Provider"))
        }
        let model = modelText?.trimmingCharacters(in: .whitespaces)
        if let model, !model.isEmpty {
            result.append(QueueRunDetailEntry(label: "Model", value: model))
        } else {
            result.append(.notReported("Model"))
        }
        // Usage maps to one labeled row per PRESENT field, in this order:
        // Input, Output, Cached, Thought, Cost. Zero or absent fields are
        // omitted — never a fake zero — and a snapshot with nothing
        // reportable produces no usage rows at all. Token values are
        // locale-grouped exact counts (`groupedCount`, never the compact
        // "8.1K" vocabulary) so the operator can reconcile the panel against
        // provider usage dashboards; cost goes through `preciseCost` so
        // sub-cent precision survives. Rows keep the default rendering
        // (monospacedDigit + text selection) — only the Job ID is fully
        // monospaced.
        if let usage {
            if usage.inputTokens > 0 {
                result.append(QueueRunDetailEntry(
                    label: "Input", value: UsageFormatter.groupedCount(usage.inputTokens)))
            }
            if usage.outputTokens > 0 {
                result.append(QueueRunDetailEntry(
                    label: "Output", value: UsageFormatter.groupedCount(usage.outputTokens)))
            }
            if let cached = usage.cachedReadTokens, cached > 0 {
                result.append(QueueRunDetailEntry(
                    label: "Cached", value: UsageFormatter.groupedCount(cached)))
            }
            if let thought = usage.thoughtTokens, thought > 0 {
                result.append(QueueRunDetailEntry(
                    label: "Thought", value: UsageFormatter.groupedCount(thought)))
            }
            if let cost = UsageFormatter.preciseCost(usage.cost, currency: usage.currency) {
                result.append(QueueRunDetailEntry(label: "Cost", value: cost))
            }
        }
        return result
    }
}

// MARK: - Formatting

/// Pure, locale-aware formatting shared by the header clock and run details.
/// Mirrors `AgentRunStatusView`'s compact duration vocabulary ("42s",
/// "3m 12s", "1h 5m") so the queue workspace and the run status pill agree.
enum QueueWorkspaceFormat {
    /// Elapsed wall time from `start` to `now`; "—" when `start` is nil (a
    /// queued job has no clock yet). Truncates sub-second noise downward.
    static func elapsed(from start: Date?, to now: Date) -> String {
        guard let start else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        return compactDuration(seconds: seconds)
    }

    /// Static duration for terminal states; `nil` when either bound is missing
    /// (run details omit the row rather than show "—").
    static func duration(from start: Date?, to end: Date?) -> String? {
        guard let start, let end else { return nil }
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded(.down)))
        return compactDuration(seconds: seconds)
    }

    /// Run-details timestamp: abbreviated date + standard time — enough to
    /// correlate with logs without flooding the grid.
    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static func compactDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}
