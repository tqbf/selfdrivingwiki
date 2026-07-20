import Foundation

/// The read-side projection of a page's origin provenance — the inverse of the
/// write-path that stamps an `agents` + `activities` + `page_versions` triple
/// on every save (the PROV-DM graph reuse, ``GRDBWikiStore``).
///
/// ``pageOrigin(pageID:)`` returns the active (HEAD) row; ``pageEditHistory
/// (pageID:)`` walks the whole `page_versions` chain for the page, oldest-first.
/// Mirrors ``SourceOrigin`` for sources (Phase 3a): the same
/// `refs → *_versions → activities → agents` join, decoded into a
/// pure-data struct that NULL-degrades gracefully (no row, no activity, or no
/// agent each fall through to nil/empty without throwing).
///
/// `agentKind` is exposed alongside `agentName` so the UI can render
/// `chat:<id>` / `agent:<kind>` / `human` / `model` distinctly (the writer
/// stamps it via ``GRDBWikiStore/authorKind(_:)`` — the structured upgrade of
/// the #131 flat `created_by`/`last_edited_by` strings). Pre-v39 rows and
/// unknown authors degrade to `"software"` (the legacy-import agent).
public struct PageOrigin: Sendable, Equatable {
    /// The page-version row id (the ULID of the `page_versions` row).
    public let versionID: String
    /// The version's title snapshotted at save time.
    public let title: String
    /// SHA-256 hex of the version's body blob (the CAS key). Useful for
    /// detecting no-op rewrites and tying history entries to blob rows.
    public let blobHash: String?
    /// The agent's display name — `chat:<chatID>` / `agent:<kind>` / `user` /
    /// a model id — i.e. exactly the value `last_edited_by` carries (and that
    /// the writer threads into `ensureAgent`). Degrades to `"unknown"` when
    /// the activity has no agent (NULL FK).
    public let agentName: String
    /// The agent's structured kind (`chat` / `agent` / `human` / `model` /
    /// `software`). Degrades to `"software"` for the legacy-import shared
    /// agent so the UI can label pre-v39 rows distinctly.
    public let agentKind: String
    /// The activity's kind: `'import'` (page create) or `'edit'` (page update).
    /// Degrades to `"import"` when NULL.
    public let activityKind: String
    /// Optional activity `plan` (executor phase / run label). Not yet
    /// populated by the write path (Phase 2 will thread a `WIKI_RUN_REF`).
    public let plan: String?
    /// Optional activity `external_ref` (run dir or chatID). Not yet
    /// populated by the write path (Phase 2).
    public let externalRef: String?
    /// When the save committed (the activity's `started_at`/`ended_at`,
    /// which match `page_versions.saved_at`).
    public let savedAt: Date

    public init(
        versionID: String,
        title: String,
        blobHash: String?,
        agentName: String,
        agentKind: String,
        activityKind: String,
        plan: String?,
        externalRef: String?,
        savedAt: Date
    ) {
        self.versionID = versionID
        self.title = title
        self.blobHash = blobHash
        self.agentName = agentName
        self.agentKind = agentKind
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.savedAt = savedAt
    }
}
