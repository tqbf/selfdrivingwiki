import Foundation
import WikiFSTypes
import WikiFSLinks

/// A pre-flight repair record — what pre-flight itself did (or tried to do)
/// to the page before the audit started. Phase 0's bracket auto-fix records
/// here; later phases replace pre-flight mutation with candidate hunks, and
/// this record carries the same facts about the patch path.
public struct LintRepairRecord: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The repair committed; `writtenHead` names the new head.
        case applied
        /// The repair was attempted and did not commit.
        case failed
    }

    public enum Failure: Equatable, Sendable {
        /// The CAS check failed twice (initial + one recomposition).
        case conflictLimitReached
        /// The write committed but the stored body no longer matches.
        case postWriteVerificationMismatch
        /// Any other write failure.
        case writeFailed(String)
    }

    public let kind: String
    /// The head the repair was composed against.
    public let inspectedHead: PageVersionID?
    /// The head after a committed repair; nil when nothing committed.
    public let writtenHead: PageVersionID?
    /// Authored ranges (in the PRE-repair body) the repair rewrote.
    public let repairedRanges: [MarkdownSourceRange]
    public let state: State
    public let failure: Failure?

    public init(
        kind: String,
        inspectedHead: PageVersionID?,
        writtenHead: PageVersionID?,
        repairedRanges: [MarkdownSourceRange],
        state: State,
        failure: Failure? = nil
    ) {
        self.kind = kind
        self.inspectedHead = inspectedHead
        self.writtenHead = writtenHead
        self.repairedRanges = repairedRanges
        self.state = state
        self.failure = failure
    }
}

/// The complete mechanical pre-flight report for one page snapshot, published
/// in the exact REQ-23 order. Pure scanning never writes; repairs are
/// records of work already done under the Phase 0 contract.
public struct LintPreflightReport: Equatable, Sendable {

    /// Named bounds (REQ-23: bounded prompt excerpts and per-section
    /// findings). Raising a limit changes the detector revision.
    public enum Limits {
        /// Maximum findings published per section before the section is
        /// marked truncated with the omitted count.
        public static let findingsPerSection = 40
        /// Maximum evidence excerpt characters per finding.
        public static let evidenceCharacters = 120
        /// Maximum inventory items published in the prompt body before the
        /// report states truncation (the complete inventory stays in the
        /// staged artifact).
        public static let promptInventoryItems = 200
    }

    /// The audit's detector revision — bump when detector behavior changes,
    /// so evaluation artifacts and gate keys can tell scans apart.
    public static let detectorRevision = "lint-preflight-v1"

    /// One published report section.
    public struct Section: Equatable, Sendable {
        public let section: LintScanSection
        public let status: LintScanStatus
        public let findings: [LintFinding]
        /// Applicable dialect limits / false-positive bounds the detector
        /// operates under (REQ-44).
        public let dialectLimits: [String]
    }

    /// The page under audit (identity, head, fingerprint — no body bytes in
    /// the report; the snapshot carries those).
    public let pageID: PageID
    public let title: String
    public let inspectedHead: PageVersionID?
    public let bodyFingerprint: String
    public let detectorRevision: String
    /// Sections in REQ-23 order (every `LintScanSection` is present).
    public let sections: [Section]
    /// Every inventoried occurrence (complete — not excerpt-bounded).
    public let inventory: [LintInventoryItem]
    public let inventoryTotals: LintInventoryTotals
    /// Pre-flight repair records (Phase 0 bracket fix and later patch-path
    /// equivalents).
    public let repairs: [LintRepairRecord]

    public init(
        pageID: PageID,
        title: String,
        inspectedHead: PageVersionID?,
        bodyFingerprint: String,
        sections: [Section],
        inventory: [LintInventoryItem],
        repairs: [LintRepairRecord]
    ) {
        self.pageID = pageID
        self.title = title
        self.inspectedHead = inspectedHead
        self.bodyFingerprint = bodyFingerprint
        self.detectorRevision = Self.detectorRevision
        // Publish every section, ordered by the REQ-23 worklist.
        let bySection = Dictionary(groups: sections, key: \.section)
        self.sections = LintScanSection.allCases.sorted().map { section in
            bySection[section]
                ?? Section(section: section, status: .notChecked(reason: "no detector reported for this section"), findings: [], dialectLimits: [])
        }
        self.inventory = inventory
        self.inventoryTotals = LintInventoryTotals(items: inventory)
        self.repairs = repairs
    }

    /// The page has no findings anywhere and every scan completed.
    public var isClean: Bool {
        sections.allSatisfy { section in
            section.findings.isEmpty && section.status.isClean
        }
    }

    /// Sections whose status is not clean — blocked or truncated scans.
    public var uncleanStatuses: [(LintScanSection, LintScanStatus)] {
        sections.compactMap { section in
            section.status.isClean && section.findings.isEmpty ? nil : (section.section, section.status)
        }
    }
}

private extension Dictionary where Key == LintScanSection, Value == LintPreflightReport.Section {
    init(groups: [LintPreflightReport.Section], key: (LintPreflightReport.Section) -> LintScanSection) {
        self.init(minimumCapacity: groups.count)
        for element in groups {
            self[key(element)] = element
        }
    }
}
