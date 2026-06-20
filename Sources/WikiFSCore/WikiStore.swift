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
public protocol WikiStore {
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

    /// Replace ALL outgoing links for `pageID` with the resolved subset of
    /// `parsedLinks`, in one transaction. Targets that don't resolve to a page
    /// are omitted (the schema forbids a NULL `to_page_id`). Self-links allowed.
    func replaceLinks(from pageID: PageID, parsedLinks: [WikiLinkParser.ParsedLink]) throws

    // MARK: - Ingested files (Phase 5)
    //
    // Only the three methods `WikiStoreModel` actually calls live on the
    // protocol. The read-projection helpers (listAllIngestedFilesOrderedByID,
    // getIngestedFile, ingestedFileContent) stay concrete on `SQLiteWikiStore` —
    // the File Provider extension uses the concrete read store, exactly as it
    // does for `listAllPagesOrderedByID` / `listAllLinks`.

    /// Store a dropped file's verbatim bytes + metadata as a new ingested-file
    /// row, returning its summary. Throws if the data exceeds the soft size cap.
    @discardableResult
    func ingestFile(filename: String, data: Data) throws -> IngestedFileSummary

    /// Ingested-file summaries (no content blob), most-recent-first.
    func listIngestedFiles() throws -> [IngestedFileSummary]

    /// The verbatim content bytes for one ingested file, fetched on demand. On the
    /// protocol so `WikiStoreModel` can STAGE the source into the agent's scratch
    /// dir (reading from SQLite, not the laggy mount) without downcasting. Throws
    /// `.notFound` if absent.
    func ingestedFileContent(id: PageID) throws -> Data

    /// Remove an ingested file by id.
    func deleteIngestedFile(id: PageID) throws

    /// Stamp an ingested file as summarized-into-the-wiki. The agent calls this on
    /// successful completion via `wikictl log append --kind ingest --source <id>`;
    /// the UI reads it as the authoritative "Ingested" status.
    func markIngestedFile(id: PageID) throws

    /// IDs of ingested files the agent has marked ingested — the deterministic
    /// source of truth for the "Ingested" badge (no fuzzy log-title matching).
    func markedIngestedFileIDs() throws -> Set<String>

    // MARK: - Processed markdown versions (v8)

    /// The latest (HEAD) version of the processed markdown for a file, or nil
    /// when no version exists yet (not yet seeded/extracted).
    func processedMarkdownHead(fileID: PageID) throws -> FileMarkdownVersion?

    /// True when at least one processed-markdown version exists for this file.
    func hasProcessedMarkdown(fileID: PageID) throws -> Bool

    /// All versions for a file, newest first (HEAD → v1). Empty if none.
    func processedMarkdownHistory(fileID: PageID) throws -> [FileMarkdownVersion]

    /// Append a new full-text markdown version to the chain. Reads the current
    /// head to set `parentID`. Returns the new version.
    @discardableResult
    func appendProcessedMarkdown(fileID: PageID, content: String,
                                 origin: String, note: String?) throws -> FileMarkdownVersion

    /// Revert to an older version by appending a NEW version whose content
    /// copies the target. History is preserved; HEAD = the new revert version.
    @discardableResult
    func revertProcessedMarkdown(fileID: PageID, to versionID: PageID) throws -> FileMarkdownVersion

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
    // like `listAllPagesOrderedByID` / `listAllIngestedFilesOrderedByID`.

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

    // MARK: - Semantic search (v7 page embeddings)

    /// Store or replace a page's embedding BLOB (512 × Float32). No-op if the
    /// store does not support embeddings (pre‑v7 schema, or extension not loaded).
    func storePageEmbedding(id: PageID, blob: Data) throws

    /// Search pages semantically (cosine similarity via `vec_distance_cosine`).
    /// Falls back to a `LIKE` title match when the vec extension or embedding
    /// model is unavailable. Only pages WITH an embedding appear in semantic
    /// results (pages saved before v7 must be re‑saved or reindexed).
    func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary]

    /// Compute + store embeddings for every page that is missing one. Returns the
    /// count of newly-embedded pages. Per‑page failures are logged and skipped so
    /// one bad page doesn't abort the batch.
    func recomputeMissingEmbeddings() -> Int
}
