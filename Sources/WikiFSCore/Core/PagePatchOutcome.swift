import Foundation
import WikiFSTypes

/// The outcome of one committed page patch: the server-observed write facts
/// (REQ-52) — the agent's claimed diff is never the record.
public struct PagePatchOutcome: Equatable, Sendable {
    public let pageID: PageID
    /// The head the patch was composed against (the CAS check passed on it).
    public let expectedHead: PageVersionID
    /// The new head after the committed version.
    public let writtenHead: PageVersionID
    /// The defect classes of the hunks actually applied (server-observed, in
    /// submission order).
    public let appliedClasses: [LintDefectClass]
    /// The committed body's SHA-256 hex fingerprint.
    public let writtenFingerprint: String

    public init(
        pageID: PageID,
        expectedHead: PageVersionID,
        writtenHead: PageVersionID,
        appliedClasses: [LintDefectClass],
        writtenFingerprint: String
    ) {
        self.pageID = pageID
        self.expectedHead = expectedHead
        self.writtenHead = writtenHead
        self.appliedClasses = appliedClasses
        self.writtenFingerprint = writtenFingerprint
    }
}

/// Why a patch's citation/provenance integrity check rejected (REQ-54): the
/// patch creates NO version and emits NO event.
public enum PagePatchIntegrityError: Error, Equatable, CustomStringConvertible {
    /// An added `[[source:…]]` citation resolves to no source (or ambiguously
    /// to several).
    case unresolvedAddedCitation(String)
    /// An added citation's quote fragment does not appear in the citation's
    /// target version's stored text.
    case quoteNotInSource(sourceID: SourceID, quote: String)
    /// An added citation carries a `@vN` version pin that names no
    /// extraction of that source (review M5 — a pin must resolve; it never
    /// silently falls back to the active head).
    case unresolvedPin(sourceID: SourceID, pin: Int)

    public var description: String {
        switch self {
        case .unresolvedAddedCitation(let link):
            return "added citation does not resolve to exactly one existing source: \(link)"
        case .quoteNotInSource(let sourceID, let quote):
            return "added citation's quote does not appear in source \(sourceID.rawValue): \(quote.debugDescription)"
        case .unresolvedPin(let sourceID, let pin):
            return "added citation's version pin @v\(pin) names no extraction of source \(sourceID.rawValue)"
        }
    }
}
