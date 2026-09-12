import Foundation

/// How a protected deletion treats the incoming Markdown links that point at
/// the deleted targets (issue #219). Bookmarks are NOT policy-governed — every
/// protected deletion removes matching bookmark leaves unconditionally, because
/// a bookmark to a missing page or source is invalid.
public enum ResourceDeletionLinkPolicy: Equatable, Hashable, Sendable {
    /// Keep the Markdown link text unchanged. After the target row is deleted
    /// the link renders as a "ghost link" (its target no longer resolves).
    case preserve
    /// Convert every matching link and embed to its plain display text before
    /// the target rows are deleted, so no ghost links survive. Unrelated links
    /// and protected code ranges are left untouched.
    case unlink
}

/// One deletion target. `PageID` and `SourceID` are separate id namespaces;
/// the case tag keeps a page ULID from ever comparing equal to a source ULID
/// (the same discipline as `BookmarkNode.Content`).
public enum ResourceDeletionTarget: Hashable, Sendable {
    case page(PageID)
    case source(SourceID)

    /// The page row ids carried by this target set (empty when none).
    public var pageID: PageID? {
        switch self {
        case .page(let id): return id
        case .source: return nil
        }
    }

    /// The source row ids carried by this target set (empty when none).
    public var sourceID: SourceID? {
        switch self {
        case .page: return nil
        case .source(let id): return id
        }
    }

    /// Deterministic sort key: pages before sources, then raw ULID ascending.
    private var sortKey: (kind: Int, raw: String) {
        switch self {
        case .page(let id): return (0, id.rawValue)
        case .source(let id): return (1, id.rawValue)
        }
    }

    /// The members of `targets` in the canonical deterministic order (pages
    /// before sources, raw ULID ascending within each kind). Every result and
    /// impact collection downstream of a request uses this order.
    public static func sorted(_ targets: Set<ResourceDeletionTarget>) -> [ResourceDeletionTarget] {
        targets.sorted { a, b in
            let (ka, ra) = a.sortKey
            let (kb, rb) = b.sortKey
            return ka != kb ? ka < kb : ra < rb
        }
    }
}

/// A normalized, policy-carrying deletion request — the single input to
/// `WikiStore.deleteResources(_:)`. Duplicate ids collapse into one effect and
/// one result entry (the stored value is a typed set).
public struct ResourceDeletionRequest: Equatable, Sendable {
    /// The distinct targets to delete, across both id namespaces.
    public let targets: Set<ResourceDeletionTarget>
    /// How incoming Markdown links to these targets are treated.
    public let linkPolicy: ResourceDeletionLinkPolicy

    public init(targets: Set<ResourceDeletionTarget>, linkPolicy: ResourceDeletionLinkPolicy) {
        self.targets = targets
        self.linkPolicy = linkPolicy
    }

    /// Convenience: accepts any order, tolerates duplicates (normalized to a set).
    public init(targets: [ResourceDeletionTarget], linkPolicy: ResourceDeletionLinkPolicy) {
        self.init(targets: Set(targets), linkPolicy: linkPolicy)
    }

    /// Convenience: a single-target request (the compatibility forwarder shape).
    public init(target: ResourceDeletionTarget, linkPolicy: ResourceDeletionLinkPolicy) {
        self.init(targets: [target], linkPolicy: linkPolicy)
    }

    /// The page members in deterministic order.
    public var pageIDs: [PageID] {
        ResourceDeletionTarget.sorted(targets).compactMap(\.pageID)
    }

    /// The source members in deterministic order.
    public var sourceIDs: [SourceID] {
        ResourceDeletionTarget.sorted(targets).compactMap(\.sourceID)
    }
}

/// One page whose body links to a deletion target — the stable identity plus
/// its presentation title. `title` is presentation data only; `pageID` is the
/// key every decision and rewrite routes through.
public struct DeletionLinkingPage: Equatable, Hashable, Sendable {
    public let pageID: PageID
    /// The live `pages.title`, or `nil` when the row has vanished.
    public let title: String?

    public init(pageID: PageID, title: String?) {
        self.pageID = pageID
        self.title = title
    }
}

/// One bookmark leaf that points at a deletion target — the stable node
/// identity plus where it lives. `folderPath` is presentation data (e.g.
/// `"Research / Papers"`; `"Bookmarks"` for a root-level node); `nodeID` is
/// the key the protected delete uses to remove the row.
public struct DeletionBookmarkImpact: Equatable, Hashable, Sendable {
    public let nodeID: BookmarkID
    public let folderPath: String

    public init(nodeID: BookmarkID, folderPath: String) {
        self.nodeID = nodeID
        self.folderPath = folderPath
    }
}

/// A snapshot of what references the page(s) and/or source(s) the user is
/// about to delete (issue #219). The store computes this — both for the
/// pre-delete confirmation (`deletionImpact(for:)`) and again inside the
/// protected write transaction — so the UI decides on the same data the write
/// revalidates.
///
/// Ordering contract: `linkingPages`, `bookmarks`, and `provenanceBlockers`
/// are each deterministically ordered (linking pages and bookmarks by raw
/// ULID; blockers by page, then version, then source), so the same store
/// state always produces an equal impact value.
public struct DeletionImpact: Sendable, Equatable {
    /// Pages whose bodies link to any target (excludes targets themselves).
    public let linkingPages: [DeletionLinkingPage]
    /// Bookmarks that point at any target. Every one of these rows is removed
    /// by the protected delete — there is no keep-bookmarks option.
    public let bookmarks: [DeletionBookmarkImpact]
    /// Page versions whose provenance cites a selected source, making the
    /// deletion impossible. Always empty for page-only requests; the store
    /// throws `WikiStoreError.deletionRestricted` before any write when set.
    public let provenanceBlockers: [ProvenanceDeletionBlocker]
    /// The number of link edges (`page_links` + `source_links`) pointing at
    /// the target set. This is the count a `.preserve` delete leaves as ghost
    /// links and an `.unlink` delete converts to plain text.
    public let incomingLinkCount: Int

    public init(
        linkingPages: [DeletionLinkingPage],
        bookmarks: [DeletionBookmarkImpact],
        provenanceBlockers: [ProvenanceDeletionBlocker] = [],
        incomingLinkCount: Int = 0
    ) {
        self.linkingPages = linkingPages
        self.bookmarks = bookmarks
        self.provenanceBlockers = provenanceBlockers
        self.incomingLinkCount = incomingLinkCount
    }

    /// The linking pages' stable identities, in impact order.
    public var linkingPageIDs: [PageID] { linkingPages.map(\.pageID) }

    /// The bookmarks' folder paths, in impact order (presentation projection).
    public var bookmarkLabels: [String] { bookmarks.map(\.folderPath) }

    /// True when a provenance edge prevents deletion — the dialog must NOT
    /// offer to delete (the store throws before any write).
    public var isProvenanceBlocked: Bool { !provenanceBlockers.isEmpty }

    /// True when there is at least one incoming link or bookmark.
    public var hasReferences: Bool {
        !linkingPages.isEmpty || !bookmarks.isEmpty
    }

    /// True when the delete-confirmation dialog should be shown at all — any
    /// incoming reference OR a provenance block.
    public var showsDialog: Bool { hasReferences || isProvenanceBlocked }
}

/// The committed outcome of one protected deletion
/// (`WikiStore.deleteResources(_:)`). Everything here is post-commit truth:
/// the rows are gone, the rewrites are durable, and the emitted events
/// correspond exactly to these identities.
public struct ResourceDeletionResult: Equatable, Sendable {
    /// Targets whose rows were actually deleted, in deterministic order. A
    /// missing (already-gone) target does NOT appear here — its deletion is an
    /// idempotent no-op.
    public let deletedTargets: [ResourceDeletionTarget]
    /// Pages whose bodies were rewritten (`.unlink` policy only), in
    /// deterministic order.
    public let rewrittenPageIDs: [PageID]
    /// Bookmark leaves removed because they pointed at a deleted target, in
    /// deterministic order.
    public let removedBookmarkIDs: [BookmarkID]
    /// The number of incoming link edges that pointed at the deleted targets:
    /// the ghost links preserved (`.preserve`) or the spans unlinked
    /// (`.unlink`).
    public let incomingLinkCount: Int

    public init(
        deletedTargets: [ResourceDeletionTarget],
        rewrittenPageIDs: [PageID],
        removedBookmarkIDs: [BookmarkID],
        incomingLinkCount: Int
    ) {
        self.deletedTargets = deletedTargets
        self.rewrittenPageIDs = rewrittenPageIDs
        self.removedBookmarkIDs = removedBookmarkIDs
        self.incomingLinkCount = incomingLinkCount
    }
}

/// Where a protected deletion should deterministically fail. This is a TEST
/// seam for the transaction rollback contract (issue #219 hardening): every
/// non-`none` case throws inside the outer write transaction, so the whole
/// operation rolls back as one unit. Production always uses `.none` — the
/// value lives on the concrete store as an internal var defaulted to `.none`
/// and is never set by app or CLI code.
enum ProtectedDeletionFailurePoint: Equatable, Sendable {
    /// No injected failure (the only production value).
    case none
    /// Throw after the link rewrites have been staged.
    case afterRewrite
    /// Throw after the bookmark cleanup has been staged.
    case afterBookmarkCleanup
    /// Throw immediately before the target rows are deleted.
    case beforeTargetDeletion
}
