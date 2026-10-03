import Foundation

/// The expected-state contract for one composed page write
/// (cumulative ingestion, plan phase 4 §4).
///
/// One closed set replaces the old "`expectedHeadVersionID: PageVersionID?`"
/// flag pair so the three legal write preconditions cannot be misspelled:
/// a create-only write is not "CAS with a made-up head", and the CLI can
/// reject `--create-only` + `--expect-head` as a contradiction instead of
/// guessing which one the caller meant. Carried by
/// ``WikiStore/upsertPage(id:title:rawBody:expectation:author:provenance:)``
/// and ``PageUpsert/upsert(in:id:title:body:expectation:author:provenance:)``.
public enum PageWriteExpectation: Equatable, Sendable {

    /// Legacy unrestricted write: resolve `title` to an existing page and
    /// update it, or create a new page when nothing resolves. Callers that
    /// passed no expectation before this enum exists keep exactly this
    /// behavior (`wikictl page add` without flags, the in-app editor's
    /// non-CAS saves).
    case unrestricted

    /// Compare-and-swap against the target page's current head version id —
    /// the `head_version_id` the caller read before composing the body. A
    /// head that moved since that read throws `PageConflictError`; a target
    /// that no longer exists (deleted, or its title renamed away since the
    /// read) throws `PageExpectedTargetMissingError`. Either way nothing is
    /// written — an expected-head write never silently creates a page.
    case expectedHead(PageVersionID)

    /// Create-only write, closing the create-versus-create race: the caller
    /// read the title and found NO page under it. If a page appeared since
    /// that read, the write throws `PageCreateConflictError` without a
    /// version, link, or provenance mutation — the agent then reads that
    /// page and reconciles against its head.
    case expectedAbsence
}

/// Thrown by an `.expectedHead` write when its target page does not exist at
/// write time: the page was deleted since the caller read it, or the title
/// the caller read no longer resolves to any page (renamed away). Distinct
/// from `PageConflictError` (the target EXISTS but its head moved) because
/// there is no current head to report — `pageID` is `nil` when the write
/// selected its target by title and nothing resolves to that title anymore.
/// Surfaces as the same CLI exit code 3 as the other expected-state
/// conflicts: re-read (`page list` / `page get`), reconcile, write again.
public struct PageExpectedTargetMissingError: Error, Equatable {
    /// The explicit page id when one was given; `nil` when the target was
    /// selected by title and that title no longer resolves to any page.
    public let pageID: PageID?
    /// The head the caller expected to write against.
    public let expectedHead: PageVersionID
    /// The sanitized title at write time.
    public let title: String

    public init(pageID: PageID?, expectedHead: PageVersionID, title: String) {
        self.pageID = pageID
        self.expectedHead = expectedHead
        self.title = title
    }
}

/// Thrown by a create-only page write (`PageWriteExpectation.expectedAbsence`)
/// when the title already resolves to a page: another writer created it after
/// the caller's read found the title absent. Carries the existing page's id
/// and current head so the agent can re-read and reconcile. Surfaces as the
/// same CLI exit code 3 as `PageConflictError` (the "re-read, reconcile,
/// retry once" signal).
public struct PageCreateConflictError: Error, Equatable {
    /// The page that now exists under the create-only title.
    public let pageID: PageID
    /// The sanitized title the caller attempted to create under.
    public let title: String
    /// The existing page's current head version id (nil only if the page has
    /// no version rows, which post-migration data should not produce).
    public let actualVersionID: PageVersionID?

    public init(pageID: PageID, title: String, actualVersionID: PageVersionID?) {
        self.pageID = pageID
        self.title = title
        self.actualVersionID = actualVersionID
    }
}
