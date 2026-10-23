import Foundation
import WikiFSTypes
import WikiFSLinks

/// The report sections of a lint pre-flight, in the exact REQ-23 worklist
/// order. Boundary damage comes first because it can conceal later findings.
public enum LintScanSection: Int, CaseIterable, Sendable, Comparable {
    /// 1. Page identity, inspected head, scan coverage, pre-flight repair records.
    case identity = 1
    /// 2. Scan failures, unavailable checks, and truncated findings.
    case scanFailures = 2
    /// 3. Fence and block-boundary candidates, including whole-body wrap (D25).
    case fenceBoundaries = 3
    /// 4. Other Markdown structure: tables, lists, headings, delimiters
    /// (report-only classes in v1 marked as such).
    case markdownStructure = 4
    /// 5. Wiki-link syntax, target, citation fragment, version-pin, embed,
    /// and footnote candidates.
    case wikiReferences = 5
    /// 6. Raw URLs, Markdown references, media destinations, and rich-fence
    /// re-validation results (D28).
    case rawURLsAndMedia = 6
    /// 7. Placeholder, duplicate, conflict-marker, encoding and escaping
    /// damage, meta-text leakage, and regression candidates from history.
    case integrityAndHistory = 7
    /// 8. Metadata-contract findings. v1 records that no page metadata
    /// contract exists (D19).
    case metadata = 8
    /// 9. Required judgment audits that pre-flight cannot complete.
    /// Evidence-integrity audits are out of v1 scope (D3).
    case judgmentAudits = 9

    public static func < (lhs: LintScanSection, rhs: LintScanSection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The user-facing worklist heading.
    public var title: String {
        switch self {
        case .identity: return "Page identity and scan coverage"
        case .scanFailures: return "Scan failures, unavailable checks, and truncated findings"
        case .fenceBoundaries: return "Fence and block-boundary candidates"
        case .markdownStructure: return "Markdown structure candidates"
        case .wikiReferences: return "Wiki-link, citation, embed, and footnote candidates"
        case .rawURLsAndMedia: return "Raw URLs, Markdown references, media, and rich-fence re-validation"
        case .integrityAndHistory: return "Integrity, encoding, leakage, and history-regression candidates"
        case .metadata: return "Metadata-contract findings"
        case .judgmentAudits: return "Required judgment audits"
        }
    }
}

/// The status of one scan or section (REQ-25). The four states are NOT
/// interchangeable: a clean section renders `none detected`; a detector that
/// could not run never renders as clean (REQ-43).
public enum LintScanStatus: Equatable, Sendable {
    /// The scan ran and found nothing (`none detected`) or its findings are
    /// attached to the section.
    case completed
    /// The scan is not part of this operation's coverage.
    case notChecked(reason: String)
    /// The scan was attempted and could not complete — never rendered as
    /// clean (REQ-43).
    case blocked(reason: String)
    /// The scan ran but its result set was bounded; the omitted count and
    /// how to inspect the complete inventory are carried for the report.
    case truncated(omittedCount: Int, reason: String)

    public var isClean: Bool {
        if case .completed = self { return true }
        return false
    }
}
