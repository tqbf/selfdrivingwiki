import Foundation
import SQLite3

/// SQLite-backed `WikiStore`. Hand-wraps the system `SQLite3` C API — no
/// third-party dependency (per the BRINGUP decision). Owns one serial
/// connection; all access in Phase 1 is main-thread-synchronous. Phase 2 will
/// add short-lived read connections inside the File Provider extension (the
/// app stays the only writer; WAL mode makes concurrent reads safe).
public final class SQLiteWikiStore: WikiStore {
    private let db: OpaquePointer
    /// Prepared-statement cache keyed by SQL text; reused via `reset()`.
    private var statements: [String: SQLiteStatement] = [:]

    /// Open (creating if needed) the database at `databaseURL`.
    /// Tests inject a temp-dir or `:memory:` URL; the app injects
    /// `DatabaseLocation.appGroupContainerURL()`.
    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            if let handle { sqlite3_close(handle) }
            throw WikiStoreError.open(msg)
        }
        self.db = handle

        do {
            try configurePragmas()
            try bootstrapSchema()
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    /// Open the database at `readOnlyURL` as a **read-only** store, for the File
    /// Provider extension. The extension opens a fresh, short-lived store per
    /// request (INITIAL §10) and must never write or mutate schema.
    ///
    /// Design choice (orchestrator tightening): open a read-WRITE handle and set
    /// `PRAGMA query_only=ON` rather than `SQLITE_OPEN_READONLY`. A pure
    /// read-only connection to a WAL DB fails to attach/create the `-shm` when no
    /// writer has set it up (e.g. the app is closed — relevant for Phase 4
    /// agents). A same-user read-write handle robustly creates/attaches `-shm`,
    /// and `query_only=ON` still rejects every write at the SQLite layer (the
    /// File Provider read-only capabilities reject writes at the FS layer too).
    /// We skip `bootstrapSchema()` and the WAL-mode assertion: this connection
    /// must not author the DB, only read whatever the writer has produced.
    public init(readOnlyURL: URL) throws {
        var handle: OpaquePointer?
        // No CREATE: a read-only consumer must never conjure an empty DB.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(readOnlyURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            if let handle { sqlite3_close(handle) }
            throw WikiStoreError.open(msg)
        }
        self.db = handle

        do {
            try exec("PRAGMA busy_timeout=5000;")
            try exec("PRAGMA query_only=ON;")
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        // Finalize every cached statement before closing the connection,
        // otherwise sqlite3_close returns SQLITE_BUSY and leaks the handle.
        statements.removeAll()
        sqlite3_close(db)
    }

    // MARK: - Open-time configuration

    private func configurePragmas() throws {
        // journal_mode=WAL returns a row ("wal"); read it to confirm it took.
        let mode = try queryScalarText("PRAGMA journal_mode=WAL;")
        guard mode.lowercased() == "wal" else {
            throw WikiStoreError.unexpected("journal_mode is '\(mode)', expected 'wal'")
        }
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")
    }

    /// Idempotent schema bootstrap guarded by `PRAGMA user_version` (0 → 1).
    /// Schema is INITIAL.md §3 verbatim: `pages`, `attachments`, `page_links`,
    /// plus the unique slug index. attachments/page_links are unused this
    /// phase but created now so Phase 2+ is a drop-in.
    private func bootstrapSchema() throws {
        let version = Int(try queryScalarText("PRAGMA user_version;")) ?? 0
        guard version < 1 else { return }  // already bootstrapped — no-op

        try exec("""
        CREATE TABLE pages (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        );
        """)
        try exec("CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);")
        try exec("""
        CREATE TABLE attachments (
            id TEXT PRIMARY KEY,
            page_id TEXT,
            filename TEXT NOT NULL,
            mime_type TEXT,
            data BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY(page_id) REFERENCES pages(id)
        );
        """)
        try exec("""
        CREATE TABLE page_links (
            from_page_id TEXT NOT NULL,
            to_page_id TEXT NOT NULL,
            link_text TEXT NOT NULL,
            PRIMARY KEY (from_page_id, to_page_id),
            FOREIGN KEY(from_page_id) REFERENCES pages(id),
            FOREIGN KEY(to_page_id) REFERENCES pages(id)
        );
        """)
        try exec("PRAGMA user_version=1;")
    }

    // MARK: - WikiStore

    public func listPages() throws -> [WikiPageSummary] {
        let stmt = try statement(
            "SELECT id, title, updated_at FROM pages ORDER BY updated_at DESC;"
        )
        defer { stmt.reset() }
        var out: [WikiPageSummary] = []
        while try stmt.step() {
            out.append(WikiPageSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                title: stmt.text(at: 1),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 2))
            ))
        }
        return out
    }

    /// All pages with full bodies, ordered by `id` (ULID == creation order).
    /// Used by the File Provider projection to enumerate `pages/by-id` and
    /// `pages/by-title` deterministically (INITIAL §6). Not on the `WikiStore`
    /// protocol — it is a read-projection helper, not part of the editing API.
    public func listAllPagesOrderedByID() throws -> [WikiPage] {
        let stmt = try statement("""
        SELECT id, title, slug, body_markdown, created_at, updated_at, version
        FROM pages ORDER BY id ASC;
        """)
        defer { stmt.reset() }
        var out: [WikiPage] = []
        while try stmt.step() {
            out.append(WikiPage(
                id: PageID(rawValue: stmt.text(at: 0)),
                title: stmt.text(at: 1),
                slug: stmt.text(at: 2),
                bodyMarkdown: stmt.text(at: 3),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
                version: Int(stmt.int(at: 6))
            ))
        }
        return out
    }

    /// A whole-database change token that advances on ANY page mutation.
    ///
    /// Returns `"\(count):\(sumVersions)"` from
    /// `SELECT COUNT(*), COALESCE(SUM(version),0) FROM pages`. Used as the File
    /// Provider sync anchor (INITIAL §6 — "notify File Provider that the item
    /// changed").
    ///
    /// Why count:sum and NOT `MAX(version)`: `version` is PER-PAGE
    /// (`updatePage` does `version = version + 1` on that row only), so editing a
    /// page that doesn't hold the global maximum would leave `MAX(version)`
    /// unchanged and the edit would silently stay stale. With count:sum, every
    /// `update` bumps SUM by 1, and every `create`/`delete` changes COUNT and
    /// SUM — so the token differs on every create, update, or delete of any page.
    public func changeToken() throws -> String {
        let stmt = try statement("SELECT COUNT(*), COALESCE(SUM(version), 0) FROM pages;")
        defer { stmt.reset() }
        guard try stmt.step() else { return "0:0" }
        return "\(stmt.int(at: 0)):\(stmt.int(at: 1))"
    }

    public func getPage(id: PageID) throws -> WikiPage {
        let stmt = try statement("""
        SELECT id, title, slug, body_markdown, created_at, updated_at, version
        FROM pages WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return WikiPage(
            id: PageID(rawValue: stmt.text(at: 0)),
            title: stmt.text(at: 1),
            slug: stmt.text(at: 2),
            bodyMarkdown: stmt.text(at: 3),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
            version: Int(stmt.int(at: 6))
        )
    }

    public func createPage(title: String) throws -> WikiPage {
        let id = PageID(rawValue: ULID.generate())
        let slug = try uniqueSlug(from: title, id: id)
        let now = Date()
        let stmt = try statement("""
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
        VALUES (?1, ?2, ?3, '', ?4, ?4, 1);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(title, at: 2)
        try stmt.bind(slug, at: 3)
        try stmt.bind(now.timeIntervalSince1970, at: 4)
        _ = try stmt.step()
        return WikiPage(
            id: id, title: title, slug: slug, bodyMarkdown: "",
            createdAt: now, updatedAt: now, version: 1
        )
    }

    public func updatePage(id: PageID, title: String, body: String) throws {
        // Recompute slug from the (possibly renamed) title, then bump version
        // and updated_at. version bumps support Phase 3 change signaling.
        let slug = try uniqueSlug(from: title, id: id)
        let stmt = try statement("""
        UPDATE pages
        SET title = ?2, slug = ?3, body_markdown = ?4,
            updated_at = ?5, version = version + 1
        WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(title, at: 2)
        try stmt.bind(slug, at: 3)
        try stmt.bind(body, at: 4)
        try stmt.bind(Date().timeIntervalSince1970, at: 5)
        _ = try stmt.step()
        guard sqlite3_changes(db) > 0 else { throw WikiStoreError.notFound(id) }
    }

    public func deletePage(id: PageID) throws {
        // FK safety (Phase 4): `page_links` has FKs onto `pages(id)` for BOTH
        // `from_page_id` and `to_page_id`, and `foreign_keys=ON`. Once links are
        // populated, deleting a page referenced as a link SOURCE or TARGET would
        // throw a constraint violation. So clear every link touching this page
        // first, then delete the row — in ONE transaction so a failure can't
        // leave dangling link rows.
        try exec("BEGIN IMMEDIATE;")
        do {
            let unlink = try statement(
                "DELETE FROM page_links WHERE from_page_id = ?1 OR to_page_id = ?1;")
            unlink.reset()
            try unlink.bind(id.rawValue, at: 1)
            _ = try unlink.step()

            let stmt = try statement("DELETE FROM pages WHERE id = ?1;")
            stmt.reset()
            try stmt.bind(id.rawValue, at: 1)
            _ = try stmt.step()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Wiki links (Phase 4)

    public func resolveTitleToID(_ title: String) throws -> PageID? {
        // Lowest ULID == oldest page on a duplicate-title collision.
        let stmt = try statement(
            "SELECT id FROM pages WHERE title = ?1 ORDER BY id ASC LIMIT 1;")
        defer { stmt.reset() }
        try stmt.bind(title, at: 1)
        guard try stmt.step() else { return nil }
        return PageID(rawValue: stmt.text(at: 0))
    }

    public func replaceLinks(from pageID: PageID,
                             parsedLinks: [WikiLinkParser.ParsedLink]) throws {
        // One transaction: wipe this page's outgoing links, then insert the
        // resolved subset. Unresolved targets are OMITTED (NULL to_page_id is
        // forbidden by the schema). `INSERT OR IGNORE` collapses duplicate
        // (from,to) pairs from distinct titles that resolve to the same page.
        try exec("BEGIN IMMEDIATE;")
        do {
            let del = try statement("DELETE FROM page_links WHERE from_page_id = ?1;")
            del.reset()
            try del.bind(pageID.rawValue, at: 1)
            _ = try del.step()

            let ins = try statement("""
            INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text)
            VALUES (?1, ?2, ?3);
            """)
            for link in parsedLinks {
                guard let target = try resolveTitleToID(link.target) else { continue }
                ins.reset()
                try ins.bind(pageID.rawValue, at: 1)
                try ins.bind(target.rawValue, at: 2)
                try ins.bind(link.linkText, at: 3)
                _ = try ins.step()
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// All link rows, ordered by `(from_page_id, to_page_id)`. Read-side helper
    /// for the File Provider projection's `links.jsonl` generator. Not on the
    /// `WikiStore` protocol — like `listAllPagesOrderedByID`, it is a
    /// read-projection helper, not part of the editing API.
    public func listAllLinks() throws -> [IndexGenerators.LinkRow] {
        let stmt = try statement("""
        SELECT from_page_id, to_page_id, link_text
        FROM page_links ORDER BY from_page_id, to_page_id;
        """)
        defer { stmt.reset() }
        var out: [IndexGenerators.LinkRow] = []
        while try stmt.step() {
            out.append(IndexGenerators.LinkRow(
                from: stmt.text(at: 0),
                to: stmt.text(at: 1),
                linkText: stmt.text(at: 2)
            ))
        }
        return out
    }

    // MARK: - Slugs

    /// Derive a slug from a title (lowercased, spaces → `-`, strip anything
    /// outside `[a-z0-9-]`). On a UNIQUE collision, append `-<first 6 of the
    /// page's ULID>`. Duplicate titles are allowed; duplicate slugs are not.
    private func uniqueSlug(from title: String, id: PageID) throws -> String {
        let base = Self.slugify(title)
        if try !slugExists(base, excluding: id) { return base }
        let suffix = String(id.rawValue.prefix(6)).lowercased()
        return "\(base)-\(suffix)"
    }

    static func slugify(_ title: String) -> String {
        let lowered = title.lowercased()
        var chars: [Character] = []
        for ch in lowered {
            if ch == " " || ch == "\t" || ch == "\n" {
                chars.append("-")
            } else if ch.isLetter, ch.isASCII {
                chars.append(ch)
            } else if ch.isNumber, ch.isASCII {
                chars.append(ch)
            } else if ch == "-" {
                chars.append(ch)
            }
        }
        // Collapse runs of '-' and trim leading/trailing ones.
        let collapsed = String(chars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }

    private func slugExists(_ slug: String, excluding id: PageID) throws -> Bool {
        let stmt = try statement("SELECT 1 FROM pages WHERE slug = ?1 AND id != ?2 LIMIT 1;")
        defer { stmt.reset() }
        try stmt.bind(slug, at: 1)
        try stmt.bind(id.rawValue, at: 2)
        return try stmt.step()
    }

    // MARK: - Statement helpers

    private func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = statements[sql] { return cached }
        let stmt = try SQLiteStatement(db: db, sql: sql)
        statements[sql] = stmt
        return stmt
    }

    /// Execute a statement that returns no rows (DDL / PRAGMA assignment).
    /// Not cached — these run once at open time.
    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        defer { sqlite3_free(errmsg) }
        guard rc == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? SQLiteStatement.message(db)
            throw WikiStoreError.sqlite(code: rc, message: msg)
        }
    }

    /// Test hook: read a one-row PRAGMA on the store's OWN connection. Pragmas
    /// like `foreign_keys` are per-connection, so they can't be observed from a
    /// separately-opened connection — tests must ask the live store.
    func pragmaValue(_ name: String) -> String {
        (try? queryScalarText("PRAGMA \(name);")) ?? ""
    }

    /// Run a one-row PRAGMA/SELECT and return column 0 as text.
    private func queryScalarText(_ sql: String) throws -> String {
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else {
            throw WikiStoreError.sqlite(code: rc, message: SQLiteStatement.message(db))
        }
        defer { sqlite3_finalize(handle) }
        let step = sqlite3_step(handle)
        guard step == SQLITE_ROW else { return "" }
        guard let c = sqlite3_column_text(handle, 0) else { return "" }
        return String(cString: c)
    }
}
