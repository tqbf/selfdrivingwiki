import Foundation

/// One coherent read of a page: identity, title, body, the active head
/// version id, and the head version's source-input provenance — all
/// extracted inside ONE read transaction.
///
/// A plain `getPage` followed by a separate `pageHeadVersionID` (and a
/// separate provenance read) can straddle a concurrent writer's commit, so
/// the body could belong to version N while the head reports N+1 — a caller
/// like lint pre-flight would then compose a CAS write against a head whose
/// body it never saw, and a conflict-preserving repair becomes impossible to
/// reason about. `readPageCoherent(id:)` closes that race: whatever writer
/// commits mid-read becomes the NEXT snapshot, never a torn one.
///
/// `GRDBWikiStore` performs the whole extraction inside a single
/// `dbWriter.read` transaction. Read-only: emits no `ResourceChangeEvent`.
public struct PageCoherentRead: Equatable, Sendable {
    /// The page's stable identity.
    public let id: PageID
    /// The page row's current title.
    public let title: String
    /// The body bytes of the head version (the `pages` row's stored body).
    public let body: String
    /// The active head version id (`refs` → `page_versions`, the
    /// default-active `MAX(id)` rule when no ref row exists); `nil` for a
    /// page with no version rows.
    public let headVersionID: PageVersionID?
    /// The head version's recorded source inputs, in the store's canonical
    /// order — the exact `provenance` array a CAS rewrite of this head must
    /// carry forward.
    public let headSourceInputs: [PageVersionSourceInput]

    public init(
        id: PageID,
        title: String,
        body: String,
        headVersionID: PageVersionID?,
        headSourceInputs: [PageVersionSourceInput]
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.headVersionID = headVersionID
        self.headSourceInputs = headSourceInputs
    }
}
