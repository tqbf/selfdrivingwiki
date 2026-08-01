import Foundation

/// A snapshot of what references a page or source that the user is about to
/// delete (issue #219). The model computes this before showing the
/// delete-confirmation dialog so the user can see incoming links, bookmarks,
/// and (for sources) provenance blockers, then choose how to proceed.
public struct DeletionImpact: Sendable, Equatable {
    /// Pages that link to the target (excludes the target itself). The UI maps
    /// these to titles via `summaries`; the unlink path uses the ids directly.
    public let linkingPageIDs: [PageID]
    /// Where each referencing bookmark lives, as a folder display path
    /// (e.g. `"Research / Papers"`; `"Bookmarks"` for a root-level node).
    public let bookmarkLabels: [String]
    /// Page versions whose provenance cites this resource, making deletion
    /// impossible. Always empty for pages; populated for sources the agent has
    /// used to author pages (issue #219).
    public let provenanceBlockers: [ProvenanceDeletionBlocker]

    public init(
        linkingPageIDs: [PageID],
        bookmarkLabels: [String],
        provenanceBlockers: [ProvenanceDeletionBlocker] = []
    ) {
        self.linkingPageIDs = linkingPageIDs
        self.bookmarkLabels = bookmarkLabels
        self.provenanceBlockers = provenanceBlockers
    }

    /// True when a provenance edge prevents deletion — the dialog must NOT
    /// offer to delete (the store would throw).
    public var isProvenanceBlocked: Bool { !provenanceBlockers.isEmpty }

    /// True when there is at least one incoming link or bookmark.
    public var hasReferences: Bool {
        !linkingPageIDs.isEmpty || !bookmarkLabels.isEmpty
    }

    /// True when the delete-confirmation dialog should be shown at all — any
    /// incoming reference OR a provenance block.
    public var showsDialog: Bool { hasReferences || isProvenanceBlocked }
}
