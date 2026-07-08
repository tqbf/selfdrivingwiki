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

/// Read/write storage interface for wiki pages (INITIAL.md §3). The SQLite
/// implementation is the source of truth; the Phase 2 File Provider extension
/// will adopt a read-only subset (`WikiReadStore`) of this.
public protocol WikiStore: Sendable {
    /// Per-wiki resource-change event bus. `SQLiteWikiStore` emits one event per
    /// public mutating method (outside its recursive lock, via `mutate()`);
    /// `nil` for stores that never surface changes (e.g. `wikictl`'s own store,
    /// where emit is a silent no-op). Set once by the app wiring during wiki
    /// open; the File Provider signaler and the model's external-reload path
    /// both subscribe to it. See `plans/event-bus.md`.
    var eventBus: WikiEventBus? { get set }

    /// Page summaries ordered by the given sort criterion.
    func listPages(sortBy: PageSortOrder) throws -> [WikiPageSummary]
    func getPage(id: PageID) throws -> WikiPage
    func createPage(title: String) throws -> WikiPage
    func updatePage(id: PageID, title: String, body: String) throws
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
    func replaceLinks(from pageID: PageID, parsedLinks: [WikiLinkParser.ParsedLink]) throws

    // MARK: - Ingested files (Phase 5)
    //
    // Only the three methods `WikiStoreModel` actually calls live on the
    // protocol. The read-projection helpers (listAllSourcesOrderedByID,
    // getSource, sourceContent) stay concrete on `SQLiteWikiStore` —
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
        activityID: String?
    ) throws -> SourceSummary

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

    /// Rename a source's display_name and rewrite every `[[source:<old>…]]` link
    /// that points at it. Transactional — source row + all affected pages + their
    /// link rows in one commit. Fragment and alias are preserved.
    func renameSource(id: PageID, to newDisplayName: String) throws

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
                                 origin: String, note: String?) throws -> SourceMarkdownVersion

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
    // (`listAllLogEntriesOrderedByID`) stays concrete on `SQLiteWikiStore`, exactly
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

    /// Search pages semantically (cosine similarity via `vec_distance_cosine`,
    /// ranked by each page's best-matching chunk). Falls back to FTS5 only when
    /// the vec extension or embedding model is unavailable. Search indexes (FTS
    /// + chunk embeddings) are populated automatically on open, so all content
    /// is searchable.
    func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary]

    // MARK: - Semantic source search (v14 source chunk embeddings)

    /// Store or replace ALL chunk embeddings for a source. Mirrors
    /// `storePageChunks` for sources.
    func storeSourceChunks(id: PageID, chunks: [Data]) throws

    /// Sources with no chunk embeddings yet, as `(id, embeddable text)`. Mirrors
    /// `missingPageEmbeddingWork`.
    func missingSourceEmbeddingWork() -> [(id: PageID, text: String)]

    /// Search sources semantically (cosine similarity via `vec_distance_cosine`,
    /// ranked by each source's best-matching chunk). Falls back to FTS5 only when
    /// the vec extension or embedding model is unavailable. Mirrors `searchSimilar`.
    func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary]

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
}
