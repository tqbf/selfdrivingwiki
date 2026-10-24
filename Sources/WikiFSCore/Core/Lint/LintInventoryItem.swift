import Foundation
import WikiFSLinks

/// One inventoried occurrence on the audited page (REQ-30/REQ-31). Every
/// table, source-citation occurrence, raw URL, footnote reference, footnote
/// definition, and fence gets its own item — occurrences are NEVER
/// deduplicated by target, because the per-item audit contract accounts for
/// each one individually.
public struct LintInventoryItem: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Sendable {
        case table
        case sourceCitation
        case rawURL
        case footnoteReference
        case footnoteDefinition
        case fence
    }

    /// Stable occurrence ID within one scan revision, e.g. `table-1`,
    /// `citation-3`, `fence-2` (1-based per kind, in source order).
    public let occurrenceID: String
    public let kind: Kind
    /// The occurrence's location in authored bytes (half-open); nil when the
    /// occurrence spans the whole body (a whole-body fence wrap's inventory
    /// still locates its fence delimiter).
    public let authoredRange: MarkdownSourceRange?
    /// Short evidence: the occurrence's bounded excerpt or its target.
    public let evidence: String

    public init(
        occurrenceID: String,
        kind: Kind,
        authoredRange: MarkdownSourceRange?,
        evidence: String
    ) {
        self.occurrenceID = occurrenceID
        self.kind = kind
        self.authoredRange = authoredRange
        self.evidence = evidence
    }

    /// Build occurrence IDs in the stable `<kind>-<n>` form.
    public static func occurrenceID(kind: Kind, index: Int) -> String {
        "\(kind.rawValue)-\(index)"
    }
}

/// Per-kind inventory totals for a report.
public struct LintInventoryTotals: Equatable, Sendable {
    public var tables: Int = 0
    public var sourceCitations: Int = 0
    public var rawURLs: Int = 0
    public var footnoteReferences: Int = 0
    public var footnoteDefinitions: Int = 0
    public var fences: Int = 0

    public init() {}

    public init(items: [LintInventoryItem]) {
        for item in items {
            switch item.kind {
            case .table: tables += 1
            case .sourceCitation: sourceCitations += 1
            case .rawURL: rawURLs += 1
            case .footnoteReference: footnoteReferences += 1
            case .footnoteDefinition: footnoteDefinitions += 1
            case .fence: fences += 1
            }
        }
    }

    /// Compact one-line form for report messages ("tables=2 citations=1 …").
    public var summary: String {
        "tables=\(tables) source-citations=\(sourceCitations) raw-urls=\(rawURLs) "
            + "footnote-references=\(footnoteReferences) footnote-definitions=\(footnoteDefinitions) "
            + "fences=\(fences)"
    }
}
