import Foundation
import WikiFSLinks

/// The per-finding repair's extra verification rule (a person's Fix click
/// on ONE finding): layered on top of `LintVerification.compare`, never in
/// place of it. The shared compare already fails a claimed repair that
/// persists, a new finding, and a finding that vanished outside the applied
/// hunks; this adds the two facts only a one-finding scope can state.
///
/// - A run that WROTE a change must have resolved its target: a write that
///   leaves the target in place changed bytes for nothing it was asked to.
/// - No OTHER pre-run finding OUTSIDE the target's bytes may change: the
///   store-observed change region is one prefix/suffix-trimmed span, so a
///   second repair inside that span passes the shared compare's "outside
///   the applied hunks" rule — this rule catches it. A finding whose range
///   overlaps the target's range resolves WITH it legitimately (a broken
///   wiki-link's truncation candidate covers the same bytes), so it is not
///   a violation; a whole-body target scopes every finding.
///
/// A run that wrote nothing (a careful no-op, an honest `unresolved`) has no
/// violation: nothing changed, so there is nothing to revert. Findings
/// compare by the same identity the shared compare uses (class + evidence),
/// so a finding whose bytes merely moved still matches.
public enum LintPerFindingScope {

    /// The violation reasons, sorted; empty when the written head honors
    /// the one-finding scope.
    public static func violations(
        focus: LintRepairFocus,
        before: LintPreflightReport,
        written: LintPreflightReport,
        wroteChange: Bool
    ) -> [String] {
        guard wroteChange else { return [] }
        func identity(_ finding: LintFinding) -> String {
            "\(finding.defectClass.rawValue)|\(finding.evidence)"
        }
        let beforeFindings = before.sections.flatMap(\.findings)
        let writtenIdentities = Set(written.sections.flatMap(\.findings).map(identity))
        let targetIdentity = beforeFindings
            .first { $0.occurrenceID == focus.occurrenceID }
            .map(identity)
            ?? "\(focus.defectClass.rawValue)|\(focus.evidence)"

        var reasons: [String] = []
        if writtenIdentities.contains(targetIdentity) {
            reasons.append(
                "per-finding repair wrote a change but its finding \(focus.occurrenceID) persists on the written head")
        }
        guard let targetRange = focus.authoredRange else { return reasons.sorted() }
        var reported: Set<String> = []
        for finding in beforeFindings where identity(finding) != targetIdentity {
            // Overlapping the target's bytes (or spanning the whole body)
            // means the finding sits inside the repair's own scope.
            guard let range = finding.authoredRange, range.intersects(targetRange) == false,
                  writtenIdentities.contains(identity(finding)) == false,
                  reported.insert(finding.occurrenceID).inserted else { continue }
            reasons.append(
                "per-finding repair changed finding \(finding.occurrenceID) — only \(focus.occurrenceID) was in scope")
        }
        return reasons.sorted()
    }
}
