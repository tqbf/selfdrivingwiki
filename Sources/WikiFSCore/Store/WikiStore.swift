import Foundation

/// Errors thrown by a `WikiStore`. `.sqlite` carries the SQLite result code and
/// the `sqlite3_errmsg` text so failures are diagnosable; `.notFound` is raised
/// when a requested page id has no row.
public enum WikiStoreError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(code: Int32, message: String)
    case notFound(PageID)
    case unexpected(String)
    /// Thrown by `addSource` when the incoming bytes are byte-identical to an
    /// already-stored source (matched by `content_hash`). Carries the existing
    /// row so callers can reference it (e.g. "already added as <name>") instead
    /// of just reporting a bare failure.
    case duplicateContent(existing: SourceSummary)

    public var description: String {
        switch self {
        case .open(let m): return "WikiStore open failed: \(m)"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .notFound(let id): return "Page not found: \(id.rawValue)"
        case .unexpected(let m): return "Unexpected: \(m)"
        case .duplicateContent(let existing):
            return "Duplicate content: already stored as \(existing.effectiveName) (\(existing.id.rawValue))"
        }
    }
}

extension WikiStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Result of a blob-GC sweep (`WikiStore.vacuumBlobs`). `bytesReclaimed` is the
/// SUM of orphan `byte_size`; on a dry run it is the bytes that *would* be
/// reclaimed. `applied` is `true` only when the call actually deleted rows.
public struct BlobVacuumReport: Equatable, Sendable {
    public let orphanCount: Int
    public let bytesReclaimed: Int
    public let applied: Bool

    public init(orphanCount: Int, bytesReclaimed: Int, applied: Bool) {
        self.orphanCount = orphanCount
        self.bytesReclaimed = bytesReclaimed
        self.applied = applied
    }
}

/// Result of an activity-GC sweep (`WikiStore.vacuumActivities`). Activities
/// carry no byte payload, so the report is just a count + whether the delete
/// ran. `applied` is `true` only when the call actually deleted rows.
public struct ActivityVacuumReport: Equatable, Sendable {
    public let orphanCount: Int
    public let applied: Bool

    public init(orphanCount: Int, applied: Bool) {
        self.orphanCount = orphanCount
        self.applied = applied
    }
}

/// Result of a page-version-GC sweep (`WikiStore.vacuumPageVersions`).
/// Page versions carry no byte payload separate from blobs (the blob is
/// deduped separately), so the report is just a count + whether the delete ran.
/// `applied` is `true` only when the call actually deleted rows.
public struct PageVersionVacuumReport: Equatable, Sendable {
    public let deletedCount: Int
    public let applied: Bool

    public init(deletedCount: Int, applied: Bool) {
        self.deletedCount = deletedCount
        self.applied = applied
    }
}

/// Combined result of a `vacuum-all` sweep (blobs + activities). Used by the
/// app's Help-menu confirm flow and the `wikictl admin vacuum-all` command so
/// a single pass reports everything reclaimable.
public struct VacuumReport: Equatable, Sendable {
    public let blobs: BlobVacuumReport
    public let activities: ActivityVacuumReport
    public let pageVersions: PageVersionVacuumReport

    public init(blobs: BlobVacuumReport, activities: ActivityVacuumReport, pageVersions: PageVersionVacuumReport) {
        self.blobs = blobs
        self.activities = activities
        self.pageVersions = pageVersions
    }

    /// `true` when neither sweep found anything to reclaim.
    public var isEmpty: Bool { blobs.orphanCount == 0 && activities.orphanCount == 0 && pageVersions.deletedCount == 0 }

    /// Human-readable summary for the vacuum confirm alert. Handles the empty
    /// case, pluralization, and byte formatting so the SwiftUI alert body stays
    /// a one-liner (keeps the type checker happy in the complex app-scene body).
    public var alertMessage: String {
        if isEmpty {
            return "No orphaned blobs, activities, or page versions found — nothing to reclaim."
        }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(blobs.bytesReclaimed), countStyle: .file)
        var parts: [String] = []
        if blobs.orphanCount > 0 {
            parts.append("\(blobs.orphanCount) orphan blob\(blobs.orphanCount == 1 ? "" : "s"), \(bytes)")
        }
        if activities.orphanCount > 0 {
            parts.append("\(activities.orphanCount) orphaned activit\(activities.orphanCount == 1 ? "y" : "ies")")
        }
        if pageVersions.deletedCount > 0 {
            parts.append("\(pageVersions.deletedCount) orphaned page version\(pageVersions.deletedCount == 1 ? "" : "s")")
        }
        return "\(parts.joined(separator: "; ")) reclaimable. This removes data no source references and cannot be undone."
    }
}

/// Read/write storage interface for wiki pages (INITIAL.md §3). The SQLite
/// implementation is the source of truth; the Phase 2 File Provider extension
/// will adopt a read-only subset (`WikiReadStore`) of this.
public protocol WikiStore: Sendable {
    /// Per-wiki resource-change event bus. `GRDBWikiStore` emits one event per
    /// public mutating method (outside its recursive lock, via `mutate()`);
    /// `nil` for stores that never surface changes (e.g. `wikictl`'s own store,
    /// where emit is a silent no-op). Set once by the app wiring during wiki
    /// open; the File Provider signaler and the model's external-reload path
    /// both subscribe to it. See `plans/event-bus.md`.
    var eventBus: WikiEventBus? { get set }

    /// Page summaries ordered by the given sort criterion.
    func listPages(sortBy: PageSortOrder) throws -> [WikiPageSummary]
    func getPage(id: PageID) throws -> WikiPage
    /// Create a page with no author. Convenience so callers omitting
    /// `createdBy` (the common case) route through a protocol requirement —
    /// protocol requirements can't declare default arguments, so both backends
    /// implement this 1-arg forwarder. Equivalent to
    /// `createPage(title: createdBy: nil)`.
    @discardableResult
    func createPage(title: String) throws -> WikiPage
    func createPage(title: String, createdBy: String?) throws -> WikiPage
    func updatePage(id: PageID, title: String, body: String, lastEditedBy: String?) throws
    func deletePage(id: PageID) throws

    /// Resolve a page *title* to its id, or nil if no page has that title.
    /// On duplicate titles, the lowest ULID (oldest page) wins. Used by
    /// `[[wiki-link]]` resolution (INITIAL §4 v1).
    func resolveTitleToID(_ title: String) throws -> PageID?

    /// Resolve a `[[source:…]]` target to a source id. Matches display_name first,
    /// falling back to filename (so a retired display name still resolves via its
    /// original filename). Case-insensitive (COLLATE NOCASE). On a multi-match
    /// collision, the most recently updated source wins.
    func resolveSourceByName(_ displayName: String) throws -> PageID?

    /// Replace ALL outgoing links for `pageID` with the resolved subset of
    /// `parsedLinks`, in one transaction. Targets that don't resolve to a page
    /// are omitted (the schema forbids a NULL `to_page_id`). Self-links allowed.
    func replaceLinks(from pageID: PageID, parsedLinks: [ParsedLink]) throws

    // MARK: - Ingested files (Phase 5)
    //
    // Only the three methods `WikiStoreModel` actually calls live on the
    // protocol. The read-projection helpers (listAllSourcesOrderedByID,
    // getSource, sourceContent) stay concrete on `GRDBWikiStore` —
    // the File Provider extension uses the concrete read store, exactly as it
    // does for `listAllPagesOrderedByID` / `listAllLinks`.

    /// Store a dropped file's verbatim bytes + metadata as a new ingested-file
    /// row, returning its summary. Throws if the data exceeds the soft size cap.
    /// The optional `zoteroItemKey`/`zoteroItemTitle` capture provenance when the
    /// file was ingested from a Zotero library item; they default to `nil` so
    /// drag-drop / URL / folder-import callers are unchanged.
    ///
    /// Centralized duplicate detection: `data` is hashed (SHA-256) and compared
    /// against every existing source's `content_hash` BEFORE the insert. A
    /// byte-identical match throws `WikiStoreError.duplicateContent(existing:)`
    /// instead of inserting a second copy — every caller funnels through this
    /// one seam, so drag-drop, URL fetch, Zotero ingest, and folder import all
    /// get the check automatically.
    @discardableResult
    func addSource(
        filename: String,
        data: Data,
        zoteroItemKey: String?,
        zoteroItemTitle: String?,
        mimeType: String?,
        provenance: SourceProvenance?,
        role: SourceRole,
        originalPath: String?,
        activityID: String?,
        resolvedDisplayName: String??
    ) throws -> SourceSummary

    /// 2-arg convenience: store a source with only `filename` + `data` (all
    /// trailing args default to `nil` / `.primary`). Protocol requirements can't
    /// declare default arguments, so both backends implement this forwarder,
    /// which routes to the full-signature impl with the trailing args at their
    /// defaults. This is the most common test call shape.
    @discardableResult
    func addSource(filename: String, data: Data) throws -> SourceSummary

    /// Store a **byteless** source: a source whose identity row + v1 content
    /// version carry NO blob (`blob_hash = NULL`, `byte_size = 0`,
    /// `content_hash = NULL`). The source is a pointer to an external resource
    /// (e.g. an Apple Podcasts episode); its derived alternative (the transcript
    /// markdown) is stored separately via `appendProcessedMarkdown`. Mirrors
    /// `addSource`'s transaction discipline minus the blob/hash write. Dedups on
    /// `external_identity` (when non-nil) among byteless sources — throws
    /// `.duplicateContent(existing:)` if one already exists with the same
    /// identity. See `plans/graph-model-and-versioning.md` §11.
    ///
    /// IMPORTANT: `sources.content_hash IS NULL` is used as a one-shot
    /// "needs backfill" sentinel ONLY inside the schema-version-gated v20
    /// migration block (already shipped; cannot re-trigger). Byteless rows with
    /// `content_hash = NULL` are safe, but NO future migration may reuse that
    /// sentinel — a byteless row would falsely match it.
    @discardableResult
    func addBytelessSource(
        filename: String,
        mimeType: String?,
        provenance: SourceProvenance,
        role: SourceRole
    ) throws -> SourceSummary

    /// Source summaries (no content blob), most-recent-first.
    func listSources() throws -> [SourceSummary]

    /// The verbatim content bytes for one source, fetched on demand. On the
    /// protocol so `WikiStoreModel` can STAGE the source into the agent's scratch
    /// dir (reading from SQLite, not the laggy mount) without downcasting. Throws
    /// `.notFound` if absent.
    func sourceContent(id: PageID) throws -> Data

    /// Remove a source by id.
    func deleteSource(id: PageID) throws

    /// The origin provenance of a source: the provider agent + the activity that
    /// fetched/imported it, joined from the active content version to its activity
    /// to the agent. Returns `nil` when the source has no version rows (unknown id).
    /// `plan`/`externalRef` come from the per-ingest **activity** row (so two
    /// website sources with different URLs each return their own URL); `agentName`
    /// from the **agent** row.
    func sourceOrigin(sourceID: PageID) throws -> SourceOrigin?

    /// The active content version for a source, resolved exactly like
    /// `sourceContent` (ref → version, else default-active `MAX(id)`). Returns
    /// nil when the source has no version rows at all. On the protocol (not only
    /// the concrete read helper) so callers — notably the website snapshot store
    /// and the refresh guard — can read it through `any WikiStore` without
    /// downcasting to a concrete backend. Both `GRDBWikiStore` and
    /// `GRDBWikiStore` implement this identically.
    func activeContentVersion(sourceID: PageID) throws -> SourceVersion?

    /// Rename a source's display_name and rewrite every `[[source:<old>…]]` link
    /// that points at it. Transactional — source row + all affected pages + their
    /// link rows in one commit. Fragment and alias are preserved.
    func renameSource(id: PageID, to newDisplayName: String) throws
    /// Set display_name without the link-rewrite/FTS overhead of renameSource.
    func setSourceDisplayName(id: PageID, displayName: String) throws

    /// Stamp a source as summarized-into-the-wiki. The agent calls this on
    /// successful completion via `wikictl log append --kind ingest --source <id>`;
    /// the UI reads it as the authoritative "Processed" status.
    func markSourceIngested(id: PageID) throws

    /// IDs of sources the agent has marked ingested — the deterministic
    /// source of truth for the "Processed" badge (no fuzzy log-title matching).
    func markedSourceIDs() throws -> Set<String>

    // MARK: - Processed markdown versions (v8, renamed v10)

    /// Append a new content version for a source (the store-level refresh/
    /// re-ingest primitive). Hashes the bytes → CAS blob → new version row →
    /// UPSERT the active ref → refresh the denormalized `sources` mirror, all in
    /// one transaction. Used by the provider refresh path (Phase 3b).
    @discardableResult
    func appendContentVersion(
        sourceID: PageID, data: Data, mimeType: String?,
        provenance: SourceProvenance?
    ) throws -> SourceVersion

    /// The latest (HEAD) version of the processed markdown for a source, or nil
    /// when no version exists yet (not yet seeded/extracted).
    func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion?

    /// True when at least one processed-markdown version exists for this source.
    func hasProcessedMarkdown(sourceID: PageID) throws -> Bool

    /// All versions for a source, newest first (HEAD → v1). Empty if none.
    func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion]

    /// Read a single resolved-markdown version by its smv id (Phase 6). Returns
    /// the blob-decoded `SourceMarkdownVersion`, or `nil` when no row matches.
    /// Used by the pinned-extraction viewer to load the exact extraction a quote
    /// was written against.
    func processedMarkdownVersion(id: PageID) throws -> SourceMarkdownVersion?

    /// Every source's derived-markdown chain as `[sourceID: [smvID]]`, ULID-asc
    /// per source (chronological; index 0 = v1). Phase 6: the render precompute
    /// builds the `sourceID → [smvID]` map in one query so `linkified` can
    /// resolve `@vN` per occurrence.
    func sourceDerivedChains() throws -> [PageID: [PageID]]

    /// Embed descriptors for every **byteless** source, batched in one query
    /// (`[sourceID: SourceEmbedDescriptor]`). Joins the active content version →
    /// activity (`plan`) → agent (`name`), restricted to `blob_hash IS NULL`.
    /// Byteful sources are excluded. Used by the page-reader precompute to feed
    /// `ExternalEmbed.target(for:)` for byteless external embeds.
    func embedDescriptors() throws -> [PageID: SourceEmbedDescriptor]

    // MARK: - Phase 4: website snapshot store primitives

    /// Create the shared fetch activity for a website snapshot. Commits the
    /// agent + activity FIRST (own transaction) so `source_versions.activity_id`
    /// FK is satisfied before any image version is written. Returns the id.
    @discardableResult
    func ensureFetchActivity(provenance: SourceProvenance) throws -> String

    /// Store one snapshot image as a per-snapshot `.media` source — NO
    /// source-level content-hash dedup (each snapshot owns its image sources);
    /// the blob is still deduped (`INSERT OR IGNORE`). Used by `storeSnapshot`.
    @discardableResult
    func addSnapshotImage(
        filename: String,
        data: Data,
        mimeType: String,
        originalPath: String,
        sourceURL: URL,
        activityID: String,
        role: SourceRole
    ) throws -> SourceSummary

    /// True when the source's active content version's `activity_id` has
    /// sibling versions with non-null `original_path` (a snapshot page with
    /// images). Used by the refresh guard.
    func hasImageSiblings(sourceID: PageID) throws -> Bool

    /// Batched sibling-image resolver maps: per source,
    /// `[original_path → sibling sourceID]`, joined on the source's active
    /// version's `activity_id`. First-wins per path in ULID order (§7).
    func siblingImageResolvers() throws -> [PageID: [String: PageID]]

    /// The producing agent name for each of a source's markdown versions
    /// (smv.id → agents.name), for the alternatives UI labels.
    func processedMarkdownAgentNames(sourceID: PageID) throws -> [String: String]

    /// All extraction alternatives for a source, newest first, each bundled
    /// with its recoverable provenance (backend display name, model version,
    /// char count) and whether it is the active HEAD. Consolidates
    /// `processedMarkdownHistory` + `processedMarkdownAgentNames` into one join
    /// (smv → activity → agent). For the track C compare/nominate UI.
    func processedMarkdownAlternatives(sourceID: PageID) throws -> [ExtractionAlternative]

    /// Append a new full-text markdown version to the chain. Reads the current
    /// head to set `parentID`. Returns the new version.
    @discardableResult
    func appendProcessedMarkdown(sourceID: PageID, content: String,
                                 origin: SourceMarkdownOrigin, note: String?,
                                 technique: String?) throws -> SourceMarkdownVersion

    /// Revert to an older version by appending a NEW version whose content
    /// copies the target. History is preserved; HEAD = the new revert version.
    @discardableResult
    func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion

    /// Record a provenance-carrying extraction alternative (§4.5, §4.7): create
    /// the backend's Agent + an `extract` Activity + a CAS'd markdown row in one
    /// transaction. Does NOT write the `source-derived` ref — alternatives
    /// coexist; the first becomes HEAD by the default-active rule, later ones are
    /// alternatives until nominated via `setActiveMarkdown`.
    @discardableResult
    func recordMarkdownExtraction(
        sourceID: PageID, content: String, backend: ExtractionBackend,
        sourceVersionID: String?, note: String?, modelVersion: String?
    ) throws -> SourceMarkdownVersion

    /// Nominate an existing processed-markdown row as the active HEAD for a
    /// source (UPSERT the `source-derived` ref). Used by the alternatives UI,
    /// `wikictl source set-active`, and revert.
    func setActiveMarkdown(sourceID: PageID, to versionID: PageID) throws

    // MARK: - Page versions (W0, PR #312)

    /// Append a new page version with CAS (compare-and-swap) conflict
    /// detection. If `expectedHeadVersionID` is non-nil, the save is rejected
    /// with `PageConflictError` when the current head doesn't match (another
    /// writer committed since the editor loaded). When nil, the save is a
    /// blind write (backward-compatible with pre-versioning callers). Returns
    /// the new version's id.
    func appendPageVersion(
        pageID: PageID, title: String, body: String,
        expectedHeadVersionID: String?,
        lastEditedBy: String?
    ) throws -> String

    /// Resolve the active page-content version id (ref → version_id, or
    /// MAX(id) if no ref row exists — the default-active rule). Returns nil if
    /// the page has no versions (shouldn't happen post-migration).
    func pageHeadVersionID(pageID: PageID) throws -> String?

    /// The full version chain for a page, ordered by ULID (chain order).
    func pageVersionHistory(pageID: PageID) throws -> [PageVersionSummary]

    /// The origin provenance of a page's active (HEAD) version: joins
    /// `refs → page_versions → activities → agents` (the PROV-DM read
    /// mirror of `sourceOrigin(sourceID:)`). Returns `nil` when the page has
    /// no version rows (unknown id). `agentName` is `chat:<id>` /
    /// `agent:<kind>` / `user` / a model id (the structured upgrade of the
    /// #131 flat `last_edited_by` string); `agentKind` is its PROV kind
    /// (chat / agent / human / model / software). Pre-v39 rows and unknown
    /// authors degrade to the shared `"legacy-import"` agent (no crash). On
    /// the protocol (not only the concrete read helper) so callers — notably
    /// `PageDetailView` and `wikictl page info` — can route through it via
    /// `any WikiStore`. No default implementation (mirrors `sourceOrigin`):
    /// `GRDBWikiStore` is the sole conformer; a future mock/test double must
    /// stub `nil`.
    func pageOrigin(pageID: PageID) throws -> PageOrigin?

    /// The full edit history for a page — every `page_versions` row joined to
    /// its `activities` → `agents` (extending `pageVersionHistory` with the
    /// agent/activity join). Ordered OLDEST-FIRST (matches `pageVersionHistory`
    /// so `entry.last` is the HEAD). An empty page (`createPage`'s empty root)
    /// is included as one entry (kind 'import'); a fresh-then-edited page
    /// therefore returns exactly 2 entries (the empty root + the first real
    /// edit). NULL activity/agent columns degrade gracefully. New protocol
    /// requirement (no default — mirrors `pageOrigin`/`sourceOrigin`).
    func pageEditHistory(pageID: PageID) throws -> [PageOrigin]

    /// Revert a page to a specific version: repoint the `page-content` ref to
    /// `versionID` and update the denormalized `pages.body_markdown` from the
    /// version's blob. Emits a `.page .updated` change event.
    func revertPage(pageID: PageID, to versionID: String) throws

    // MARK: - Workspaces (W1, PR #312)

    /// Create a durable, named workspace for a speculative ingestion branch.
    /// Returns the new workspace's id. The workspace starts in `open` status.
    func createWorkspace(name: String?, activityID: String?) throws -> String

    /// Read the workspace's current status + metadata.
    func workspaceSummary(id: String) throws -> WorkspaceSummary?

    /// List all page-overlay refs in a workspace (the write set).
    func workspaceRefs(workspaceID: String) throws -> [WorkspaceRef]

    /// Write a page version into the workspace's overlay: append a
    /// `page_versions` row + UPSERT the `workspace_refs` row (recording
    /// `base_version_id` = main head at first touch). Does NOT touch the
    /// `pages` mirror or main `refs` — main is untouched until merge.
    /// Returns the new version's id. `author` threads the provenance identity
    /// (#763: `agent:ingest` / `chat:<id>` / `user`) into the workspace
    /// version's activity — nil degrades to the shared `legacy-import` agent.
    func workspaceWritePage(
        workspaceID: String, pageID: PageID, title: String, body: String,
        author: String?
    ) throws -> String

    /// Resolve the workspace's current version id for a page (overlay read).
    /// Returns nil if the workspace hasn't touched this page.
    func workspacePageVersion(workspaceID: String, pageID: PageID) throws -> String?

    /// Overlay read for the workspace's staged page body (Phase 7). Returns the
    /// body the agent would see if it read the page from within this workspace —
    /// either the workspace's version blob (existing page) or the staged blob
    /// (created page). Returns nil if the workspace hasn't touched this page,
    /// so the caller falls through to the main version.
    func workspacePageBody(workspaceID: String, pageID: PageID) throws -> String?

    /// Stage wiki-index changes into the workspace (`index_body` +
    /// `index_base_version`). Phase 7: routed from `index set --workspace`.
    func setWorkspaceIndexBody(
        workspaceID: String, indexBody: String, indexBaseVersion: String
    ) throws

    /// Attempt a fast-forward-only merge. For each workspace_ref: if main head
    /// == base_version_id (or base is nil = page created in workspace), fast-
    /// forward (repoint main ref + update mirror + links/FTS). Any divergence
    /// → park the workspace as `conflicted` (durable, retryable). On success,
    /// set status to `merged`.
    ///
    /// Returns the page IDs that were merged (Phase 6). After the merge
    /// transaction commits, those pages are re-embedded and an ingest-
    /// completion log entry is appended — both best-effort.
    @discardableResult
    func workspaceMerge(workspaceID: String) throws -> [String]

    /// Abandon a workspace: set status to `abandoned` + delete its
    /// `workspace_refs`. Orphaned versions/blobs fall to lazy GC.
    func abandonWorkspace(id: String) throws

    /// Refresh (re-base) a workspace against current main: for each
    /// workspace_ref, run diff3 against the new main head. If clean, update
    /// `base_version_id` to current main_head. If conflict, park.
    func workspaceRefresh(workspaceID: String) throws

    /// List persisted conflict details for a parked workspace (W3).
    func workspaceConflicts(workspaceID: String) throws -> [WorkspaceConflict]

    /// Resolve a conflict: write the resolved body as a new workspace
    /// version for the page + delete the conflict row (W3). After resolving
    /// all conflicts, call `workspaceRetryMerge`.
    func workspaceResolveConflict(
        workspaceID: String, pageID: PageID, body: String
    ) throws

    /// Set a conflicted workspace back to `open` and attempt merge again
    /// (W3). Resolves remaining conflicts (or parks again).
    func workspaceRetryMerge(workspaceID: String) throws

    /// Reap stale open workspaces: mark any workspace with status `open`
    /// whose `updated_at` is older than the TTL as `abandoned` (W4, PR #312).
    /// Called on app launch or via `wikictl workspace reap` to clean up
    /// crashed/abandoned runs. Returns the number of workspaces reaped.
    func reapStaleWorkspaces(ttl: TimeInterval) throws -> Int

    // MARK: - System prompt (singleton document, v3)

    /// Read the user-editable singleton system-prompt document (projected at the
    /// root as `CLAUDE.md` / `AGENTS.md`). Returns the seeded default if absent.
    func getSystemPrompt() throws -> SystemPrompt

    /// Replace the system-prompt body, bumping its version + `updated_at`.
    func updateSystemPrompt(body: String) throws

    // MARK: - Log + wiki index (Phase B)
    //
    // The append-only `log` write and the singleton `wiki_index` read/write live
    // on the protocol so the `wikictl log append` / `index set` commands run
    // against `WikiStore` (testable against any conforming store), mirroring how
    // the `page` commands do. The `log.md` read-projection helper
    // (`listAllLogEntriesOrderedByID`) stays concrete on `GRDBWikiStore`, exactly
    // like `listAllPagesOrderedByID` / `listAllSourcesOrderedByID`.

    /// Append one row to the append-only chronological log, returning the inserted
    /// entry (so the caller can echo its id).
    @discardableResult
    func appendLog(kind: LogEntry.Kind, title: String, note: String?) throws -> LogEntry

    /// The most recent `limit` log entries in chronological order (oldest-of-the-tail
    /// first), for the live state snapshot the operation prompts inject. On the
    /// protocol (not only the concrete read helper) so `WikiStoreModel` can gather
    /// the snapshot without downcasting. An empty/absent log yields `[]`.
    func recentLogEntries(limit: Int) throws -> [LogEntry]

    /// Read the curated singleton index document (projected at the root as
    /// `index.md`). Returns the seeded default if absent.
    func getWikiIndex() throws -> WikiIndex

    /// Replace the wiki-index body wholesale, bumping its version + `updated_at`.
    func updateWikiIndex(body: String) throws

    // MARK: - Semantic search (v14 chunk embeddings)

    /// Store or replace ALL chunk embeddings for a page (one 512 × Float32 BLOB
    /// per text chunk). Replaces any existing chunks for the page atomically.
    func storePageChunks(id: PageID, chunks: [Data]) throws

    /// Pages with no chunk embeddings yet, as `(id, embeddable text)`. Used by
    /// the background embedding backfill (read on the caller's thread; the
    /// embedding compute runs off it).
    func missingPageEmbeddingWork() -> [(id: PageID, text: String)]

    /// Search pages semantically (cosine similarity via Swift-side
    /// `VectorCosine`, ranked by each page's best-matching chunk). The cosine
    /// leg runs only when `EmbeddingService.isAvailable` (NLEmbedding/MiniLM,
    /// app-gated) AND `EmbeddingService.embeddingBlob(for:)` both resolve —
    /// otherwise the BM25 leg alone is returned.
    ///
    /// - Parameter bm25Leg: The pre-computed, best-first BM25 leg from Tantivy
    ///   (Phase 2 / #649). This is the SOLE lexical path after #634 dropped
    ///   FTS5. nil/empty means no BM25 leg at all — the result is cosine-only
    ///   (empty under `swift test` where NLEmbedding is unavailable). Callers
    ///   (the model, `wikictl`) resolve the Tantivy leg before calling; the
    ///   store fuses both legs via `RankFusion.rrf` exactly as before.
    func searchSimilar(query: String, limit: Int, bm25Leg: [WikiPageSummary]?) throws -> [WikiPageSummary]

    // MARK: - Semantic source search (v14 source chunk embeddings)

    /// Store or replace ALL chunk embeddings for a source. Mirrors
    /// `storePageChunks` for sources.
    func storeSourceChunks(id: PageID, chunks: [Data]) throws

    /// Sources with no chunk embeddings yet, as `(id, embeddable text)`. Mirrors
    /// `missingPageEmbeddingWork`.
    func missingSourceEmbeddingWork() -> [(id: PageID, text: String)]

    /// Search sources semantically (cosine similarity via Swift-side
    /// `VectorCosine`, ranked by each source's best-matching chunk). Mirrors
    /// `searchSimilar`.
    ///
    /// - Parameter bm25Leg: The pre-computed best-first BM25 leg from Tantivy
    ///   (post-#634, the sole lexical path). See `searchSimilar(query:limit:bm25Leg:)`.
    func searchSimilarSources(query: String, limit: Int, bm25Leg: [SourceSummary]?) throws -> [SourceSummary]

    // MARK: - Bookmark nodes (Bookmarks sidebar tree)

    /// All bookmark nodes (flat), ordered so that parents precede children and
    /// siblings sort by position. The tree is assembled by `BookmarkTreeBuilder`.
    func listBookmarkNodes() throws -> [BookmarkNode]

    /// Insert a new bookmark node, shifting sibling positions ≥ `position` up by 1.
    /// Returns the inserted node with its generated id.
    @discardableResult
    func createBookmarkNode(
        parentID: String?,
        position: Int,
        kind: BookmarkNodeKind,
        label: String?,
        targetID: PageID?
    ) throws -> BookmarkNode

    /// Update the label of a bookmark node (folders only).
    func updateBookmarkNode(id: String, label: String?) throws

    /// Delete a bookmark node by id. `ON DELETE CASCADE` removes descendants.
    func deleteBookmarkNode(id: String) throws

    /// Move a node to a new parent and/or position. Renumber siblings of both
    /// the old and new parent so positions stay contiguous (0, 1, 2, …).
    func moveBookmarkNode(id: String, toParentID: String?, position: Int) throws

    // MARK: - Persisted chats (issue #119 phase 1)

    /// Create a new chat row. `id` is a fresh ULID; `createdAt`/`updatedAt` both
    /// start at "now"; `messageCount` starts at 0. Returns the inserted summary.
    @discardableResult
    func createChat(kind: ChatKind, title: String) throws -> ChatSummary

    /// Append the given events as new `chat_messages` rows, in one transaction:
    /// each row gets the next dense `seq` (continuing from the chat's current
    /// max), `role` from `event.chatRole`, `event_json` from encoding `event`,
    /// and `text` from `event.plainText`. Bumps `chats.updated_at` to "now" —
    /// skipped entirely (including the `updated_at` bump) when `events` is
    /// empty. Throws `.notFound` if `chatID` has no row. Returns the inserted
    /// messages in `seq` order.
    @discardableResult
    func appendChatMessages(chatID: PageID, events: [AgentEvent]) throws -> [ChatMessage]

    /// All chat summaries, most-recently-updated first (ties broken by
    /// insertion order), for the history list.
    func listChats() throws -> [ChatSummary]

    /// A chat's messages in `seq` order. Tolerant read: a row whose
    /// `event_json` fails to decode (e.g. a future event case) is skipped
    /// rather than failing the whole read.
    func chatMessages(chatID: PageID) throws -> [ChatMessage]

    /// Rename a chat's title, bumping `updated_at`. Throws `.notFound` if no
    /// chat has `id`.
    func renameChat(id: PageID, to title: String) throws

    /// Delete a chat. `ON DELETE CASCADE` removes its messages. No error if
    /// `id` doesn't exist.
    func deleteChat(id: PageID) throws

    /// Write the one-line summary of the model's first response (issue #411),
    /// bumping `updated_at`. Throws `.notFound` if no chat has `id`.
    func updateChatSummary(chatID: PageID, summary: String) throws

    /// Write the cached one-line summary for a single assistant message
    /// (chat-summary plan §3.5). The chat row is the change-emission resource
    /// (there is no `.message` resource kind); emits `.chat .updated` with the
    /// chat's id. Idempotent at the SQL level; the caller short-circuits on a
    /// non-nil cached summary to enforce compute-once (AC.6).
    func updateMessageSummary(
        chatID: PageID, messageID: PageID, summary: String, kind: ChatMessageSummaryKind
    ) throws

    /// All chat summaries ordered by ULID (creation order) — for the File
    /// Provider projection. Mirrors `listAllPagesOrderedByID()`.
    func listAllChatsOrderedByID() throws -> [ChatSummary]

    /// Resolve a `[[chat:…]]` target to a chat id. Case-insensitive; lowest
    /// ULID wins on a duplicate-title collision.
    func resolveChatByTitle(_ title: String) throws -> PageID?

    // MARK: - Semantic chat search (v28 chat chunk embeddings)

    /// Store or replace ALL chunk embeddings for a chat. Mirrors
    /// `storePageChunks`/`storeSourceChunks` (used by the bulk search-index
    /// upgrade; incremental appends embed inline).
    func storeChatChunks(id: PageID, chunks: [Data]) throws

    /// Chats with no chunk embeddings yet, as `(id, embeddable text)`. Mirrors
    /// `missingPageEmbeddingWork`/`missingSourceEmbeddingWork`.
    func missingChatEmbeddingWork() -> [(id: PageID, text: String)]

    /// Search chats semantically + lexically (hybrid RRF, same as
    /// `searchSimilar`/`searchSimilarSources`). The semantic cosine leg runs
    /// when the embedder is loaded; the lexical leg is the supplied Tantivy
    /// BM25 leg (post-#634, the sole lexical path).
    ///
    /// - Parameter bm25Leg: The pre-computed best-first BM25 leg from Tantivy
    ///   (post-#634). See `searchSimilar(query:limit:bm25Leg:)`.
    func searchSimilarChats(query: String, limit: Int, bm25Leg: [ChatSummary]?) throws -> [ChatSummary]

    // MARK: - Blob GC (#253)

    /// Sweep **orphaned** blob rows — blobs no version references (the leak left
    /// by `deleteSource`, which cascades version rows but not their blobs).
    /// `dryRun == true` reports the orphan count + reclaimable bytes WITHOUT
    /// deleting; `false` deletes them in one transaction, so the returned report
    /// matches exactly what was reclaimed. Classified NO_EMIT on the concrete
    /// store: vacuuming orphans changes no projected `ResourceKind`.
    @discardableResult
    func vacuumBlobs(dryRun: Bool) throws -> BlobVacuumReport

    /// Sweep **orphaned** activity rows — activities no version references (the
    /// leak left by `deleteSource`, which cascades version rows but not their
    /// activities, issue #257). `dryRun == true` reports the orphan count
    /// WITHOUT deleting; `false` deletes them in one transaction. Classified
    /// NO_EMIT: vacuuming orphans changes no projected `ResourceKind` (the
    /// `activities` count folds into the changeToken but the token only needs
    /// to *change* on mutation, which a GC delete does).
    @discardableResult
    func vacuumActivities(dryRun: Bool) throws -> ActivityVacuumReport

    /// Sweep **orphaned** `page_versions` rows — versions not reachable from
    /// any `page-content` ref target (by walking `parent_id`/`merge_parent_id`
    /// chains), and not referenced by any `workspace_refs` row. `dryRun == true`
    /// reports the orphan count WITHOUT deleting; `false` deletes them in one
    /// transaction. Classified NO_EMIT: vacuuming orphans changes no projected
    /// `ResourceKind` — the served tree is unaffected.
    @discardableResult
    func vacuumPageVersions(dryRun: Bool) throws -> PageVersionVacuumReport

    // MARK: - Wiki metadata (v37, issue #477)

    /// Read a metadata value for `key`, or `nil` if the key doesn't exist.
    /// Used to persist one-time work flags (e.g. link-reconcile version) so
    /// they survive model recreation between launches.
    func getMetadata(_ key: String) throws -> String?

    /// Set a metadata value for `key` (upsert). NO-EMIT: metadata flags don't
    /// change projected content — they only gate one-time maintenance work.
    func setMetadata(_ key: String, value: String) throws
}

// MARK: - searchSimilar default-argument convenience (Phase 2 bm25Leg)
//
// Protocol requirements can't carry default arguments, so the 2-arg legacy
// entry points live here. As of #634 (FTS5 dropped), `bm25Leg == nil` has NO
// BM25 leg at all (the store's FTS5 fallback was removed — Tantivy is the sole
// lexical path now). The semantic cosine leg still runs; with no Tantivy leg
// AND no cosine query blob (NLEmbedding app-gated under `swift test`), the
// result is empty. Callers MUST resolve a Tantivy leg explicitly to get
// lexical matches. Migrate to `searchSimilar(query:limit:bm25Leg:)` (or the
// kind-specific equivalent) and resolve a Tantivy leg first.

extension WikiStore {
    /// Legacy 2-arg entry point — `nil` bm25Leg means NO BM25 leg post-#634.
    /// See `searchSimilar(query:limit:bm25Leg:)`.
    ///
    /// Deprecated (#637 / #634): call `searchSimilar(query:limit:bm25Leg:)`
    /// and resolve a Tantivy leg via `WikiStoreModel.resolveTantivyLeg(...)` (app)
    /// or `CLITantivyLegResolver` (CLI). A `nil` leg yields cosine-only (empty
    /// under `swift test` where NLEmbedding is unavailable).
    @available(*, deprecated, message: "Pass an explicit `bm25Leg:` — resolve a Tantivy leg for the BM25 leg, or `nil` for cosine-only. See #637 / #634.")
    public func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
        try searchSimilar(query: query, limit: limit, bm25Leg: nil)
    }

    /// Legacy 2-arg entry point for sources. See
    /// `searchSimilarSources(query:limit:bm25Leg:)`.
    ///
    /// Deprecated (#637 / #634): call `searchSimilarSources(query:limit:bm25Leg:)`
    /// and resolve a Tantivy leg. See ``searchSimilar(query:limit:)``.
    @available(*, deprecated, message: "Pass an explicit `bm25Leg:` — resolve a Tantivy leg for the BM25 leg, or `nil` for cosine-only. See #637 / #634.")
    public func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary] {
        try searchSimilarSources(query: query, limit: limit, bm25Leg: nil)
    }

    /// Legacy 2-arg entry point for chats. See
    /// `searchSimilarChats(query:limit:bm25Leg:)`.
    ///
    /// Deprecated (#637 / #634): call `searchSimilarChats(query:limit:bm25Leg:)`
    /// and resolve a Tantivy leg. See ``searchSimilar(query:limit:)``.
    @available(*, deprecated, message: "Pass an explicit `bm25Leg:` — resolve a Tantivy leg for the BM25 leg, or `nil` for cosine-only. See #637 / #634.")
    public func searchSimilarChats(query: String, limit: Int) throws -> [ChatSummary] {
        try searchSimilarChats(query: query, limit: limit, bm25Leg: nil)
    }
}

// MARK: - addSource default-argument convenience

extension WikiStore {
    /// Convenience overload so existing callers that don't pre-resolve a
    /// display name can omit `resolvedDisplayName` (defaults to `nil` → resolve
    /// in-method). Protocol requirements can't have default arguments, so this
    /// extension provides the zero-arg-by-default entry point.
    @discardableResult
    func addSource(
        filename: String,
        data: Data,
        zoteroItemKey: String?,
        zoteroItemTitle: String?,
        mimeType: String?,
        provenance: SourceProvenance?,
        role: SourceRole,
        originalPath: String?,
        activityID: String?
    ) throws -> SourceSummary {
        try addSource(
            filename: filename, data: data,
            zoteroItemKey: zoteroItemKey, zoteroItemTitle: zoteroItemTitle,
            mimeType: mimeType, provenance: provenance, role: role,
            originalPath: originalPath, activityID: activityID,
            resolvedDisplayName: nil)
    }
}
