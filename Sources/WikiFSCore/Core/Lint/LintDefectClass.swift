import Foundation

/// The defect taxonomy for page-validity lint (requirements §3). The class
/// identifies WHAT is wrong and WHICH policy applies to it — a class label
/// records attribution only; it never proves author intent or semantic
/// safety (a hunk's class does not authorize a repair by itself).
public enum LintDefectClass: String, CaseIterable, Sendable {

    // P0 structure
    case fenceBoundaryDamage = "D01"
    case delimiterDamage = "D02"           // report-only in v1 (D4)
    case tableDamage = "D03"
    case listNestingDamage = "D04"         // report-only in v1 (D4)
    case headingDamage = "D05"             // report-only in v1 (D4)
    // P0 references
    case malformedWikiLink = "D06"
    case brokenTarget = "D07"
    case noncanonicalSourceTarget = "D08"
    case citationFragmentDamage = "D09"
    case unsupportedEmbed = "D10"
    case rawExternalURL = "D11"
    // Out of v1 — the future evidence-audit operation (D3)
    case missingClaimSupport = "D12"
    case staleCitation = "D13"
    // P1
    case placeholderResidue = "D14"        // report-only in v1 (D4)
    case duplicateBlocksOrMergeResidue = "D15"
    case contradictoryDuplicates = "D16"   // out of v1 (D3)
    case encodingDamage = "D17"
    case pastedActiveContent = "D18"       // report-only (D6)
    case metadataFrontMatterDamage = "D19" // off in v1 — no metadata contract
    case missingMediaReference = "D20"
    case longLinesOrCosmetics = "D21"      // strategy-owned — excluded
    case footnoteDamage = "D22"
    case truncatedOutput = "D23"
    case metaTextLeakage = "D24"
    case wholeBodyFenceWrap = "D25"
    case escapingLayerDamage = "D26"
    case regressionAgainstPreviousHead = "D27"
    case richFenceRevalidation = "D28"     // reports; no forced conversion

    /// Whether a v1 hunk may carry this class.
    public enum RepairPolicy: String, Sendable {
        /// A confirmed defect of this class can authorize a patch hunk in v1.
        case repairable
        /// Detectors may list candidates; the prompt instructs
        /// report-don't-rewrite (operator decision D4 / D6).
        case reportOnly
        /// Outside v1 validity scope entirely: a separate future operation
        /// (evidence audit, D3), a not-applicable contract (D19), or a
        /// strategy-owned concern (D21).
        case outOfScope
    }

    public var repairPolicy: RepairPolicy {
        switch self {
        case .delimiterDamage, .listNestingDamage, .headingDamage,
             .placeholderResidue, .pastedActiveContent, .richFenceRevalidation:
            return .reportOnly
        case .missingClaimSupport, .staleCitation, .contradictoryDuplicates,
             .metadataFrontMatterDamage, .longLinesOrCosmetics:
            return .outOfScope
        default:
            return .repairable
        }
    }

    /// The report section (REQ-23 worklist order) this class belongs to.
    public var section: LintScanSection {
        switch self {
        case .fenceBoundaryDamage, .wholeBodyFenceWrap:
            return .fenceBoundaries
        case .delimiterDamage, .tableDamage, .listNestingDamage, .headingDamage:
            return .markdownStructure
        case .malformedWikiLink, .brokenTarget, .noncanonicalSourceTarget,
             .citationFragmentDamage, .unsupportedEmbed, .footnoteDamage:
            return .wikiReferences
        case .rawExternalURL, .missingMediaReference, .richFenceRevalidation:
            return .rawURLsAndMedia
        case .placeholderResidue, .duplicateBlocksOrMergeResidue, .encodingDamage,
             .escapingLayerDamage, .metaTextLeakage, .regressionAgainstPreviousHead,
             .truncatedOutput, .pastedActiveContent:
            return .integrityAndHistory
        case .missingClaimSupport, .staleCitation, .contradictoryDuplicates,
             .metadataFrontMatterDamage:
            return .metadata
        case .longLinesOrCosmetics:
            // Strategy-owned (excluded); surfaced under metadata-adjacent
            // reporting only if ever enabled — never a validity finding.
            return .metadata
        }
    }
}
