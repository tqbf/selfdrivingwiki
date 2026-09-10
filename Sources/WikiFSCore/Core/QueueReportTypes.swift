import Foundation

// MARK: - Queue report identities

/// The producing execution identity for one durable queue report. A queue
/// dispatch creates a new `WorkerLeaseID` (in `WikiFSEngine`); the report
/// header persists this core-side wrapper of the same UUID so the store can
/// reject writes and loads from an execution that no longer owns the item
/// without `WikiFSCore` depending on the engine.
///
/// Distinct from `QueueAttemptID`: a retry creates a new attempt, while a
/// re-dispatch of the SAME attempt (halt-resume, crash recovery) creates a new
/// execution. Same-attempt restarts reset report progress; new attempts start
/// a fresh report and preserve the previous attempt's rows.
public struct QueueExecutionID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Monotonically increasing revision of one `(item, attempt)` report. It only
/// ever moves forward — including across same-attempt execution resets — so a
/// delayed older-execution update or load response can never replace newer
/// data. The store allocates revisions; producers never choose them.
public struct QueueReportRevision: Hashable, Codable, Sendable, RawRepresentable,
    Comparable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: QueueReportRevision, rhs: QueueReportRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The raw model identifier a run actually used (e.g. an ACP `modelId`), when
/// usage reporting supplies it. A boundary wrapper — never compare a bare
/// `String` against provider ids or wiki ids.
public struct QueueReportModelName: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Targets

/// Namespaced report target identity. The case tag is part of the durable
/// storage key, so a source ULID and a page ULID that happen to be equal as
/// strings can never collide in one report.
public enum QueueReportTarget: Hashable, Codable, Sendable {
    /// A `sources` row (`SourceID`).
    case source(SourceID)
    /// A `pages` row (`PageID`).
    case page(PageID)

    /// Stable storage namespace: `"source"` or `"page"`.
    public var namespace: String {
        switch self {
        case .source: return "source"
        case .page: return "page"
        }
    }

    /// The raw identifier inside its namespace.
    public var id: String {
        switch self {
        case .source(let id): return id.rawValue
        case .page(let id): return id.rawValue
        }
    }

    /// SwiftUI-stable identity across the two namespaces.
    public var compositeID: String {
        "\(namespace)#\(id)"
    }
}

/// A typed extraction output result. Emitted only after the persistence
/// boundary returns sufficient evidence (the created `SourceMarkdownVersion`).
/// `.noContent` is reserved for a future producer that can actually
/// distinguish it — the current pipeline never fabricates it.
public enum QueueTargetResult: Hashable, Codable, Sendable {
    /// The extraction persisted and the store reported the created version.
    case outputReference(QueueExtractionOutputReference)
    /// The producer observed that there was nothing to persist.
    case noContent
    /// The producer ran but could not determine an output state.
    case unavailable
}

/// Where a persisted extraction output lives. `versionID` is the raw
/// `SourceMarkdownVersion.id` when the persistence layer returned one.
public struct QueueExtractionOutputReference: Hashable, Codable, Sendable {
    public let versionID: String?

    public init(versionID: String?) {
        self.versionID = versionID
    }
}

// MARK: - States, phases, availability

/// Coarse recorded phase of one attempt. Phases exist only where the actual
/// runner has them; a producer that cannot observe a phase simply never
/// reports it.
public enum QueueReportPhase: String, Codable, Sendable, Hashable {
    case planned
    case staging
    case launching
    case running
    case merging
    case persisting
    case finished
}

/// Explicit availability of the aggregate result. Unknown is never zero.
public enum QueueReportAvailability: String, Codable, Sendable, Hashable {
    /// Observed facts are persisted and durable.
    case available
    /// Report persistence failed; only `.reportUnavailable` events exist.
    /// Never presented as durable.
    case reportingUnavailable
    /// The producer cannot supply this class of results (e.g. the current
    /// agent lint has no typed page-findings contract).
    case notReported
}

/// Recorded per-target state. Reasons are recorded strings, not inferred.
public enum QueueReportTargetState: Hashable, Codable, Sendable {
    /// In the payload inventory, unobserved.
    case planned
    case preparing
    /// Handed to the runner (e.g. staged and submitted to the agent).
    case submitted
    case processing
    case succeeded
    case skipped(reason: String)
    case failed(reason: String)
    /// A dispatch died (cancel/halt/crash) before observing this target.
    /// Projected at cancellation; never presented as failed or succeeded.
    case interrupted
    /// No observation exists for this target.
    case notReported

    /// Aggregate counting key. Reasons collapse so counts stay a small,
    /// stably-keyed dictionary.
    public var countKey: QueueReportTargetCountKey {
        switch self {
        case .planned: return .planned
        case .preparing: return .preparing
        case .submitted: return .submitted
        case .processing: return .processing
        case .succeeded: return .succeeded
        case .skipped: return .skipped
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .notReported: return .notReported
        }
    }

    /// Whether this state is terminal-observed (outcome recorded).
    public var isObservedOutcome: Bool {
        switch self {
        case .succeeded, .skipped, .failed: return true
        default: return false
        }
    }
}

/// Bounded counting keys derived from target records.
public enum QueueReportTargetCountKey: String, Codable, Sendable, Hashable,
    CaseIterable {
    case planned, preparing, submitted, processing, succeeded
    case skipped, failed, interrupted, notReported
}

// MARK: - Records

/// One recorded target in an attempt report: identity, the name captured at
/// staging time (preserved for history even after deletion), the recorded
/// state, and the optional typed result.
public struct QueueReportTargetRecord: Hashable, Codable, Sendable, Identifiable {
    public var target: QueueReportTarget
    /// Recorded display name. Empty when the producer could not resolve one.
    public var displayName: String
    public var state: QueueReportTargetState
    public var result: QueueTargetResult?
    public var detail: String?

    public init(
        target: QueueReportTarget,
        displayName: String = "",
        state: QueueReportTargetState = .planned,
        result: QueueTargetResult? = nil,
        detail: String? = nil
    ) {
        self.target = target
        self.displayName = displayName
        self.state = state
        self.result = result
        self.detail = detail
    }

    public var id: String { target.compositeID }
}

// MARK: - Scope

/// The planned scope of one attempt, captured before execution. Whole-wiki
/// lint is a marker — the report never enumerates a wiki to build it.
public enum QueueReportScope: Hashable, Codable, Sendable {
    /// Every planned payload target, in payload order.
    case targets([QueueReportTargetRecord])
    /// Whole-wiki scope marker.
    case wholeWiki
}

// MARK: - Durable usage

/// Final usage totals for one attempt, committed into the report header by
/// the agent-completion mutation. These are the same values the navigator
/// showed live (`AgentLauncher.runTotalUsage`) — persisted so Run Details
/// keeps them after completion/reload instead of depending on the tracker's
/// in-memory session snapshots.
///
/// Field rules mirror `SessionUsage`'s own optionality: the mandatory token
/// counters are always stored; the optional counters ride along when the
/// provider reported them. Reports written before usage was durable have all
/// NULL columns and decode `usage == nil` — absence is absence, never zeros.
public struct QueueReportUsage: Hashable, Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedReadTokens: Int?
    public let thoughtTokens: Int?
    public let cost: Double?
    public let currency: String?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedReadTokens: Int?,
        thoughtTokens: Int?,
        cost: Double?,
        currency: String?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.thoughtTokens = thoughtTokens
        self.cost = cost
        self.currency = currency
    }
}

// MARK: - Recorded outputs

/// One page captured in an ingestion attempt's immutable output snapshot.
/// The page ID remains strongly typed; `title` is the display name recorded at
/// completion so historical jobs do not depend on a live wiki session.
public enum QueueRecordedOutputLimits {
    public static let maxRows = 200
}

public struct QueueRecordedOutputPage: Hashable, Codable, Sendable, Identifiable {
    public let pageID: PageID
    public let title: String?

    public init(pageID: PageID, title: String?) {
        self.pageID = pageID
        self.title = title
    }

    public var id: PageID { pageID }
}

// MARK: - Mutations

/// One producer-originated report change. The store validates the attempt and
/// execution identity, applies the change, allocates the next revision, and
/// returns the committed report.
public struct QueueReportMutation: Sendable, Hashable {
    public var phase: QueueReportPhase?
    /// The actual provider, set when the runner resolves it.
    public var provider: ProviderID?
    /// The actual model, set only when usage reporting supplies it.
    public var model: QueueReportModelName?
    public var availability: QueueReportAvailability?
    public var resultSummary: String?
    /// Final usage totals, set by the terminal completion mutation when the
    /// launcher's run-total usage is available. Absent in every other
    /// mutation — those never clobber committed usage.
    public var usage: QueueReportUsage?
    /// `nil` leaves the current output snapshot unchanged. A non-nil value
    /// replaces it atomically; an empty array records a known-empty snapshot.
    public var outputs: [QueueRecordedOutputPage]?
    /// Affected target rows only — never a whole-batch document.
    public var targetUpserts: [QueueReportTargetRecord]

    public init(
        phase: QueueReportPhase? = nil,
        provider: ProviderID? = nil,
        model: QueueReportModelName? = nil,
        availability: QueueReportAvailability? = nil,
        resultSummary: String? = nil,
        usage: QueueReportUsage? = nil,
        outputs: [QueueRecordedOutputPage]? = nil,
        targetUpserts: [QueueReportTargetRecord] = []
    ) {
        self.phase = phase
        self.provider = provider
        self.model = model
        self.availability = availability
        self.resultSummary = resultSummary
        self.usage = usage
        self.outputs = outputs
        self.targetUpserts = targetUpserts
    }
}

// MARK: - Full report

/// The durable report for one queue attempt: header facts plus per-target
/// records. Queue lifecycle (queued/running/failed/…) stays authoritative in
/// `QueueItem` — this type records operation outcomes only.
public struct QueueAttemptReport: Hashable, Codable, Sendable {
    public let attemptID: QueueAttemptID
    public let executionID: QueueExecutionID
    public let revision: QueueReportRevision
    public let operation: QueueReportOperation
    public let scope: QueueReportScope
    public let phase: QueueReportPhase
    public let provider: ProviderID?
    public let model: QueueReportModelName?
    public let availability: QueueReportAvailability
    public let resultSummary: String?
    /// Final usage committed at agent completion, or `nil` for reports
    /// written before usage was durable (NULL columns — never zeros) and for
    /// attempts that never reached the completion mutation.
    public let usage: QueueReportUsage?
    /// The post-run provenance snapshot. `nil` means the attempt did not
    /// record outputs (legacy report or snapshot failure); `[]` is known empty.
    public let outputs: [QueueRecordedOutputPage]?
    /// Ordered by stable inventory sequence.
    public let targets: [QueueReportTargetRecord]

    public init(
        attemptID: QueueAttemptID,
        executionID: QueueExecutionID,
        revision: QueueReportRevision,
        operation: QueueReportOperation,
        scope: QueueReportScope,
        phase: QueueReportPhase,
        provider: ProviderID?,
        model: QueueReportModelName?,
        availability: QueueReportAvailability,
        resultSummary: String?,
        usage: QueueReportUsage? = nil,
        outputs: [QueueRecordedOutputPage]? = nil,
        targets: [QueueReportTargetRecord]
    ) {
        self.attemptID = attemptID
        self.executionID = executionID
        self.revision = revision
        self.operation = operation
        self.scope = scope
        self.phase = phase
        self.provider = provider
        self.model = model
        self.availability = availability
        self.resultSummary = resultSummary
        self.usage = usage
        self.outputs = outputs
        self.targets = targets
    }

    /// Aggregate counts derived from the recorded targets. Unknown is absent
    /// from the dictionary — never a zero entry.
    public func counts() -> [QueueReportTargetCountKey: Int] {
        var counts: [QueueReportTargetCountKey: Int] = [:]
        for target in targets {
            counts[target.state.countKey, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Operation

/// The recorded operation of one attempt. Lint-vs-ingest comes from the
/// payload at report-begin time, so consumers never re-derive it from payload
/// fields.
public enum QueueReportOperation: String, Codable, Sendable, Hashable {
    case ingest
    case extract
    case lint
}

// MARK: - Summaries

/// Bounded per-item report summary for navigator rows and outcome search.
/// Deliberately excludes findings and full diagnostics — full target detail
/// remains selected-item-only.
public struct QueueReportSummary: Hashable, Codable, Sendable {
    public let itemID: QueueItem.ID
    public let attempt: Int
    public let revision: QueueReportRevision
    public let phase: QueueReportPhase
    public let availability: QueueReportAvailability
    public let phaseCounts: [QueueReportTargetCountKey: Int]
    public let resultSummary: String?
    /// Recorded target names, reasons, and the result summary joined for
    /// search. Bounded (see `QueueReportSummaryLimits`); never exhaustive.
    public let searchText: String

    public init(
        itemID: QueueItem.ID,
        attempt: Int,
        revision: QueueReportRevision,
        phase: QueueReportPhase,
        availability: QueueReportAvailability,
        phaseCounts: [QueueReportTargetCountKey: Int],
        resultSummary: String?,
        searchText: String
    ) {
        self.itemID = itemID
        self.attempt = attempt
        self.revision = revision
        self.phase = phase
        self.availability = availability
        self.phaseCounts = phaseCounts
        self.resultSummary = resultSummary
        self.searchText = searchText
    }
}

/// Bounds for summary search text so a 1,000-target batch cannot bloat the
/// batched summary load. Summaries back row progress and search hints, not a
/// full inventory.
public enum QueueReportSummaryLimits {
    /// Maximum target rows folded into one summary's search text.
    public static let maxSearchTargets = 64
    /// Maximum characters per folded field.
    public static let maxFieldLength = 200
    /// Maximum total search-text characters per item.
    public static let maxTotalLength = 8_000
}

// MARK: - Load results

/// Result of an item-scoped report load. Non-throwing on purpose: reporting
/// capability problems surface as `.unavailable`, never as a generic error,
/// and old jobs simply have `.notReported`.
public enum QueueReportLoadResult: Sendable, Hashable, Codable {
    /// The current attempt's committed report.
    case loaded(QueueAttemptReport)
    /// No report exists for the item's current attempt (legacy jobs, or the
    /// producer never began one).
    case notReported
    /// The store or transport could not serve reports. Consumers keep any
    /// previously loaded report and label reporting unavailable.
    case unavailable(reason: String)
}

/// Result of a batched summary load for displayed item IDs.
public enum QueueReportSummariesResult: Sendable, Hashable, Codable {
    case loaded([QueueItem.ID: QueueReportSummary])
    case unavailable(reason: String)
}
