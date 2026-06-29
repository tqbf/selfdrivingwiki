import Foundation

/// Errors thrown by a `WikiStore`. `.sqlite` carries the SQLite result code and
/// the `sqlite3_errmsg` text so failures are diagnosable; `.notFound` is raised
/// when a requested page id has no row.
public enum WikiStoreError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(code: Int32, message: String)
    case notFound(PageID)
    case unexpected(String)

    public var description: String {
        switch self {
        case .open(let m): return "WikiStore open failed: \(m)"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .notFound(let id): return "Page not found: \(id.rawValue)"
        case .unexpected(let m): return "Unexpected: \(m)"
        }
    }
}

/// Read/write storage interface for wiki pages (INITIAL.md §3). The SQLite
/// implementation is the source of truth; the Phase 2 File Provider extension
/// will adopt a read-only subset (`WikiReadStore`) of this.
public protocol WikiStore: Sendable {
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
    @discardableResult
    func addSource(
        filename: String,
        data: Data,
        zoteroItemKey: String?,
        zoteroItemTitle: String?,
        mimeType: String?
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

    /// The latest (HEAD) version of the processed markdown for a source, or nil
    /// when no version exists yet (not yet seeded/extracted).
    func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion?

    /// True when at least one processed-markdown version exists for this source.
    func hasProcessedMarkdown(sourceID: PageID) throws -> Bool

    /// All versions for a source, newest first (HEAD → v1). Empty if none.
    func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion]

    /// Append a new full-text markdown version to the chain. Reads the current
    /// head to set `parentID`. Returns the new version.
    @discardableResult
    func appendProcessedMarkdown(sourceID: PageID, content: String,
                                 origin: String, note: String?) throws -> SourceMarkdownVersion

    /// Revert to an older version by appending a NEW version whose content
    /// copies the target. History is preserved; HEAD = the new revert version.
    @discardableResult
    func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion

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
}
