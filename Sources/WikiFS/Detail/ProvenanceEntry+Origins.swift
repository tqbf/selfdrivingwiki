import Foundation
import WikiFSCore

// MARK: - ProvenanceEntry projections

extension PageOrigin {
    /// Project this page origin into the shared display model used by
    /// ``ProvenancePanel`` (DRY with ``SourceOrigin``).
    var provenanceEntry: ProvenanceEntry {
        ProvenanceEntry(
            versionID: versionID,
            agentName: agentName,
            agentKind: agentKind,
            activityKind: activityKind,
            plan: plan,
            externalRef: externalRef,
            runTitle: runTitle,
            savedAt: savedAt
        )
    }
}

extension SourceOrigin {
    /// Project this source origin into the shared display model used by
    /// ``ProvenancePanel`` (DRY with ``PageOrigin``). Source origins use
    /// `fetchedAt` as the display timestamp (the source-side equivalent of
    /// `PageOrigin.savedAt`).
    var provenanceEntry: ProvenanceEntry {
        ProvenanceEntry(
            versionID: versionID,
            agentName: agentName,
            agentKind: agentKind,
            activityKind: activityKind,
            plan: plan,
            externalRef: externalRef,
            runTitle: runTitle,
            savedAt: fetchedAt
        )
    }
}
