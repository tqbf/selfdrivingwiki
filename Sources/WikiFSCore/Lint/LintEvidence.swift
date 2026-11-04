import Foundation

// MARK: - Model evidence budgets and selection
//
// The pure evidence-selection/serialization seam shared by the ACP check and
// repair prompts. Deterministic capture and MODEL evidence have DIFFERENT
// limits, and both statuses stay visible: a model excerpt is never the full
// source unless explicitly marked complete.
//
// Budgets (plan-named constants):
// - at most 8 source-version records,
// - 8 KiB text per source record,
// - 16 KiB parent text,
// - 64 KiB total serialized evidence INCLUDING metadata,
// - the complete page body is capped separately at 256 KiB,
// - the complete serialized model task (title, strategy, evidence, selected
//   repair context, page body) at 384 KiB.
//
// Selection: source records in first-authored order; excerpts prefer text
// around an exact quote match (1 KiB context each side, inside the
// per-record budget), else a labeled prefix. Omitted records are counted,
// never silently dropped. Strings clip only at Unicode scalar boundaries.
// The 64 KiB evidence cap excludes the page body; if any budget is exceeded
// beyond excerpt trimming, the model step is SKIPPED with a visible
// Incomplete notice — a clipped page or clipped evidence identity never
// ships to a provider.

public enum LintEvidenceBudgets {
    public static let maxSourceRecords = 8
    public static let maxBytesPerSourceRecord = 8 * 1024
    public static let maxParentBytes = 16 * 1024
    public static let maxSerializedEvidenceBytes = 64 * 1024
    public static let maxPageBodyBytes = 256 * 1024
    public static let maxSerializedTaskBytes = 384 * 1024
    /// Context on each side of an exact quote match.
    public static let quoteContextBytes = 1024

    /// Shrink the per-record excerpt budget by this factor per fitting pass.
    static let excerptShrinkFactor = 0.5
}

/// The serialized evidence + honest over-budget report for one run.
public struct LintEvidenceSelection: Sendable, Equatable {
    /// The evidence JSON (a data object for the model — never instructions).
    public let json: String
    /// Source-version records captured but not selected (cap 8).
    public let omittedSourceRecords: Int
    /// Typed reasons the model step must be skipped instead of sent clipped.
    public let skipReasons: [String]

    public var isUsable: Bool { skipReasons.isEmpty }
}

public enum LintEvidence {

    // MARK: Wire shapes (Codable for stable field order + explicit data)

    struct WireEvidence: Codable {
        var pageID: String
        var citations: [WireSource]
        var parent: WireParent?
        var omittedSourceRecords: Int
        var notes: [String]
    }

    struct WireSource: Codable {
        var sourceId: String
        var request: String
        var versionId: String?
        var digest: String?
        /// complete | prefix | missing-target | missing-version |
        /// unavailable-extraction | read-failed | budget-omitted
        var availability: String
        var capturedBytes: Int?
        var originalBytes: Int?
        var excerpt: String?
        /// True when the excerpt IS the whole captured text.
        var excerptIsCompleteCapture: Bool
    }

    struct WireParent: Codable {
        var versionId: String?
        /// complete | prefix | first-version | unavailable | read-failed |
        /// budget-omitted
        var availability: String
        var digest: String?
        var excerpt: String?
        var excerptIsCompleteCapture: Bool
    }

    // MARK: - Selection

    /// Select + serialize the bounded evidence for one run. `quoteHints`
    /// anchor excerpt windows (the page's citation quotes); records whose
    /// text contains a hint excerpt around the FIRST match, others prefix.
    /// `prioritySourceIDs` (a repair's finding-range targets) sort the
    /// selected records first, stable by authored order.
    public static func selection(
        snapshot: LintPageSnapshot, quoteHints: [String],
        prioritySourceIDs: Set<String> = []
    ) -> LintEvidenceSelection {
        let citations = snapshot.citations
        guard citations.isAvailable else {
            return LintEvidenceSelection(
                json: encode(WireEvidence(
                    pageID: snapshot.pageID.rawValue, citations: [],
                    parent: parentWire(snapshot.parent, budget: LintEvidenceBudgets.maxParentBytes),
                    omittedSourceRecords: 0,
                    notes: ["citation capture unavailable for this run"])),
                omittedSourceRecords: 0,
                skipReasons: [])
        }

        // Select records in authored order, capped; priorities lead.
        let capped = Array(citations.sourceVersions.prefix(
            LintEvidenceBudgets.maxSourceRecords))
        let ordered = capped.enumerated().sorted { lhs, rhs in
            let lhsPriority = prioritySourceIDs.contains(
                lhs.element.sourceID.rawValue.uppercased())
            let rhsPriority = prioritySourceIDs.contains(
                rhs.element.sourceID.rawValue.uppercased())
            if lhsPriority != rhsPriority { return lhsPriority }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let selected = ordered
        let omitted = citations.sourceVersions.count - capped.count

        var wires: [WireSource] = []
        for record in selected {
            wires.append(sourceWire(
                record, hints: quoteHints,
                budget: LintEvidenceBudgets.maxBytesPerSourceRecord))
        }

        var notes: [String] = citations.notices.map(\.message)
        if omitted > 0 {
            notes.append("\(omitted) captured source version(s) were not selected for the "
                + "model evidence (selection cap "
                + "\(LintEvidenceBudgets.maxSourceRecords)).")
        }

        let wire = WireEvidence(
            pageID: snapshot.pageID.rawValue,
            citations: wires,
            parent: parentWire(snapshot.parent, budget: LintEvidenceBudgets.maxParentBytes),
            omittedSourceRecords: omitted,
            notes: notes)

        // Fit the serialized evidence inside the total cap by shrinking
        // excerpts only — metadata (identity, availability, completeness)
        // is never overwritten or dropped.
        var perRecordBudget = LintEvidenceBudgets.maxBytesPerSourceRecord
        var parentBudget = LintEvidenceBudgets.maxParentBytes
        var fitted = encode(refit(wire, recordBudget: perRecordBudget, parentBudget: parentBudget))
        while fitted.utf8.count > LintEvidenceBudgets.maxSerializedEvidenceBytes,
              perRecordBudget > 256 {
            perRecordBudget = max(256, Int(Double(perRecordBudget) * LintEvidenceBudgets.excerptShrinkFactor))
            parentBudget = max(256, Int(Double(parentBudget) * LintEvidenceBudgets.excerptShrinkFactor))
            fitted = encode(refit(wire, recordBudget: perRecordBudget, parentBudget: parentBudget))
        }

        var skipReasons: [String] = []
        if fitted.utf8.count > LintEvidenceBudgets.maxSerializedEvidenceBytes {
            skipReasons.append(
                "The model evidence could not be serialized within the "
                + "\(LintEvidenceBudgets.maxSerializedEvidenceBytes)-byte budget — the model "
                + "review step did not run. Built-in checks above are unaffected.")
        }
        return LintEvidenceSelection(
            json: fitted,
            omittedSourceRecords: omitted,
            skipReasons: skipReasons)
    }

    /// The typed gate for sending the COMPLETE page body. Returns the
    /// skip reason when the body exceeds the cap (the model step is then
    /// skipped — never a clipped page).
    public static func pageBodySkipReason(_ body: String) -> String? {
        let bytes = body.utf8.count
        guard bytes > LintEvidenceBudgets.maxPageBodyBytes else { return nil }
        return "The page body (\(bytes) bytes) exceeds the "
            + "\(LintEvidenceBudgets.maxPageBodyBytes)-byte model limit — the model review "
            + "step did not run rather than send a clipped page. Built-in checks above "
            + "are unaffected."
    }

    /// The typed gate for the complete serialized task (title, strategy,
    /// evidence, selected repair context, and page body).
    public static func taskSkipReason(task: String) -> String? {
        let bytes = task.utf8.count
        guard bytes > LintEvidenceBudgets.maxSerializedTaskBytes else { return nil }
        return "The model task (\(bytes) bytes) exceeds the "
            + "\(LintEvidenceBudgets.maxSerializedTaskBytes)-byte limit — the model step "
            + "did not run. Built-in checks above are unaffected."
    }

    // MARK: - Wire construction

    private static func sourceWire(
        _ record: LintCapturedSourceVersion, hints: [String], budget: Int
    ) -> WireSource {
        var wire = WireSource(
            sourceId: record.sourceID.rawValue.uppercased(),
            request: requestLabel(record.request),
            versionId: record.resolvedVersionID?.rawValue,
            digest: record.digest,
            availability: availabilityLabel(record.status, completeness: record.completeness),
            capturedBytes: record.text.map { $0.utf8.count },
            originalBytes: record.originalByteCount,
            excerpt: nil,
            excerptIsCompleteCapture: false)
        guard let text = record.text, !text.isEmpty else { return wire }

        // Prefer a window around the FIRST exact hint match (1 KiB context
        // each side), else the labeled prefix — both inside the budget.
        var start = text.startIndex
        if let hint = hints.first(where: { !$0.isEmpty && text.contains($0) }),
           let range = text.range(of: hint) {
            let lower = text.index(range.lowerBound, offsetBy: -min(
                LintEvidenceBudgets.quoteContextBytes,
                text.utf8.distance(from: text.startIndex, to: range.lowerBound)),
                limitedBy: text.startIndex) ?? text.startIndex
            start = lower
        }
        let clipped = LintCaptureLimits.clipped(
            String(text[start...]), byteLimit: budget)
        wire.excerpt = clipped.text
        wire.excerptIsCompleteCapture = record.isComplete
            && start == text.startIndex
            && clipped.originalByteCount == clipped.text.utf8.count
        return wire
    }

    private static func parentWire(
        _ parent: LintCapturedParentVersion?, budget: Int
    ) -> WireParent? {
        guard let parent else { return nil }
        var wire = WireParent(
            versionId: parent.parentVersionID?.rawValue,
            availability: parentAvailability(parent.status, completeness: parent.completeness),
            digest: parent.bodyDigest,
            excerpt: nil,
            excerptIsCompleteCapture: false)
        guard parent.status == .captured, let text = parent.text, !text.isEmpty else {
            return wire
        }
        let clipped = LintCaptureLimits.clipped(text, byteLimit: budget)
        wire.excerpt = clipped.text
        wire.excerptIsCompleteCapture = parent.completeness?.isComplete == true
            && clipped.originalByteCount == clipped.text.utf8.count
        return wire
    }

    /// Rebuild the wire with fresh excerpt budgets (metadata preserved).
    private static func refit(
        _ wire: WireEvidence, recordBudget: Int, parentBudget: Int
    ) -> WireEvidence {
        var fitted = wire
        fitted.citations = wire.citations.map { record in
            var copy = record
            copy.excerpt = nil
            copy.excerptIsCompleteCapture = false
            return copy
        }
        // Re-excerpt from the ORIGINAL captured text is not possible here —
        // the wire was built from captured text once. Instead, clip the
        // existing excerpts further, at scalar boundaries, and keep the
        // completeness flag pointing at the CAPTURE, not the excerpt
        // (excerpt length is its own field).
        for index in fitted.citations.indices {
            guard let excerpt = wire.citations[index].excerpt else { continue }
            let clipped = LintCaptureLimits.clipped(excerpt, byteLimit: recordBudget)
            fitted.citations[index].excerpt = clipped.text
            fitted.citations[index].excerptIsCompleteCapture =
                wire.citations[index].excerptIsCompleteCapture
                && clipped.originalByteCount == clipped.text.utf8.count
        }
        if let excerpt = wire.parent?.excerpt {
            let clipped = LintCaptureLimits.clipped(excerpt, byteLimit: parentBudget)
            fitted.parent?.excerpt = clipped.text
            fitted.parent?.excerptIsCompleteCapture =
                wire.parent?.excerptIsCompleteCapture == true
                && clipped.originalByteCount == clipped.text.utf8.count
        }
        return fitted
    }

    private static func requestLabel(_ request: LintSourceVersionRequest) -> String {
        switch request {
        case .active: return "active"
        case .pinned(let pin): return "v\(pin.ordinal)"
        case .invalidPin(let literal): return "invalid-pin:v\(literal)"
        }
    }

    private static func availabilityLabel(
        _ status: LintSourceCaptureStatus, completeness: LintEvidenceCompleteness?
    ) -> String {
        switch status {
        case .present:
            return completeness?.isComplete == true ? "complete" : "prefix"
        case .missingTarget: return "missing-target"
        case .missingVersion: return "missing-version"
        case .unavailableExtraction: return "unavailable-extraction"
        case .readFailed: return "read-failed"
        case .budgetOmitted: return "budget-omitted"
        }
    }

    private static func parentAvailability(
        _ status: LintParentCaptureStatus, completeness: LintEvidenceCompleteness?
    ) -> String {
        switch status {
        case .captured:
            return completeness?.isComplete == true ? "complete" : "prefix"
        case .firstVersion: return "first-version"
        case .unavailable: return "unavailable"
        case .readFailed: return "read-failed"
        case .budgetOmitted: return "budget-omitted"
        }
    }

    private static func encode(_ wire: WireEvidence) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding of a fully in-memory Codable struct cannot fail; the
        // empty object is still valid "no evidence" data.
        // swiftlint:disable:next silent_try_optional
        guard let data = try? encoder.encode(wire) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
