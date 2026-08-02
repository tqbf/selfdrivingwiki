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
    /// Page summaries ordered by `updated_at` DESC (most-recently-edited first).
    func listPages() throws -> [WikiPageSummary]
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

    // MARK: - Tracked repositories (v6)
    //
    // The whole repo surface lives on the protocol, not just the app's share of
    // it: `wikictl repo …` runs against `WikiStore` exactly as the `page` and
    // `log` commands do, so the reads (`listRepos`, `findRepo`) and the agent's
    // one write (`markRepoIngested`) have to be reachable without downcasting.

    /// Start tracking a repository. Throws if `remoteURL` is already tracked.
    @discardableResult
    func addRepo(name: String, remoteURL: String, branch: String) throws -> TrackedRepo

    /// Every tracked repo, oldest-first (ULID order == the order added).
    func listRepos() throws -> [TrackedRepo]

    /// One tracked repo by id. Throws `.notFound` if absent.
    func getRepo(id: PageID) throws -> TrackedRepo

    /// Resolve a repo by its `owner/repo` display name — how the agent addresses
    /// repos, since it never sees ULIDs. nil when nothing matches.
    func findRepo(name: String) throws -> TrackedRepo?

    /// Record a fetch result (upstream tip + when we looked). App-written.
    func updateRepoSync(id: PageID, headCommit: String, fetchedAt: Date) throws

    /// Move the ingested watermark to `commit`. AGENT-written, via
    /// `wikictl repo mark-ingested`, after a pass that actually wrote pages.
    func markRepoIngested(id: PageID, commit: String) throws

    /// Record the branch the clone actually landed on (the row is created before
    /// the clone, so an unspecified branch can only be filled in afterwards).
    func setRepoBranch(id: PageID, branch: String) throws

    /// Turn this repo's unattended updates on or off.
    func setRepoAutoIngest(id: PageID, enabled: Bool) throws

    /// Stop tracking a repo. The on-disk checkout is removed by the app.
    func deleteRepo(id: PageID) throws
}
