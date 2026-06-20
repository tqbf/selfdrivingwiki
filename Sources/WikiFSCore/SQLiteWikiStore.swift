import Foundation
import SQLite3
import UniformTypeIdentifiers
import Darwin

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
        // Load sqlite-vec on the first DB open of the process lifetime.
        // Idempotent — sqlite3_load_extension short-circuits if already loaded
        // on this connection. On failure (dylib missing, sandbox), semantic
        // search degrades to LIKE fallback; save + open never fail.
        Self.ensureVecExtensionLoaded()

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
            // Load extension on THIS connection (connection-scoped).
            // Non-fatal: logged, semantic search degrades gracefully.
            Self.loadVecExtension(on: db)
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
            Self.loadVecExtension(on: db)
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

    /// Stepwise, idempotent schema migration keyed on `PRAGMA user_version`.
    /// Each step runs only when the DB is below that step's target version, so:
    ///   * a FRESH DB (version 0) runs every step in order;
    ///   * an EXISTING v1 DB (the live one already holds pages) runs ONLY the
    ///     v1→2 step — its page data is preserved untouched.
    /// `user_version` is bumped at the end of each step so re-opening is a no-op.
    private func bootstrapSchema() throws {
        var version = Int(try queryScalarText("PRAGMA user_version;")) ?? 0

        // Step 0 → 1: the original v0 schema (INITIAL §3 verbatim) — pages, the
        // unique slug index, attachments, page_links. UNCHANGED from the v0 cut.
        if version < 1 {
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
            version = 1
        }

        // Step 1 → 2 (Phase 5): the `ingested_files` table holds verbatim dropped
        // files — raw bytes + metadata, a NEW object kind, NOT tied to a page
        // (so it does NOT reuse `attachments`, which has a `page_id` FK). Stored
        // and served byte-for-byte; surfaced read-only under the `files/` tree.
        if version < 2 {
            try exec("""
            CREATE TABLE ingested_files (
                id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                ext TEXT NOT NULL DEFAULT '',
                mime_type TEXT,
                byte_size INTEGER NOT NULL,
                content BLOB NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1
            );
            """)
            try exec("CREATE INDEX ingested_files_created ON ingested_files(created_at);")
            try exec("PRAGMA user_version=2;")
            version = 2
        }

        // Step 2 → 3: the singleton `system_prompt` table — the user-editable
        // "system prompt" document the managing agent reads each run, projected
        // read-only at the wiki root as `CLAUDE.md` AND `AGENTS.md`. One row,
        // pinned to `id = 1` by a CHECK so there can only ever be one. Seeded
        // with `SystemPrompt.defaultBody` so the document exists from day one.
        if version < 3 {
            try exec("""
            CREATE TABLE system_prompt (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                body_markdown TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1
            );
            """)
            // Seed the singleton via a bound statement (the default body has
            // quotes/newlines — never interpolate it into the DDL string).
            let seed = try statement("""
            INSERT INTO system_prompt (id, body_markdown, updated_at, version)
            VALUES (1, ?1, ?2, 1);
            """)
            seed.reset()
            try seed.bind(SystemPrompt.defaultBody, at: 1)
            try seed.bind(Date().timeIntervalSince1970, at: 2)
            _ = try seed.step()
            try exec("PRAGMA user_version=3;")
            version = 3
        }

        // Step 3 → 4 (Phase B): the append-only `log` table — one ULID-keyed row
        // per agent operation (an ingest, a query, a lint). `id` is a ULID so it
        // sorts == chronological; `ts` carries the wall-clock time the row was
        // appended; `note` is optional. NOT a singleton: each `wikictl log append`
        // INSERTs a fresh row. Projected read-only at the root as `log.md`.
        if version < 4 {
            try exec("""
            CREATE TABLE log (
                id TEXT PRIMARY KEY,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                note TEXT
            );
            """)
            try exec("PRAGMA user_version=4;")
            version = 4
        }

        // Step 4 → 5 (Phase B): the singleton `wiki_index` table — the curated
        // catalog document the managing agent rewrites wholesale on each ingest,
        // projected read-only at the root as `index.md`. Modeled EXACTLY on
        // `system_prompt` (v2→3): one row pinned to `id = 1` by a CHECK, a
        // `version` bumped on every write, seeded with `WikiIndex.defaultBody` so
        // the document exists from day one.
        if version < 5 {
            try exec("""
            CREATE TABLE wiki_index (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                body_markdown TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1
            );
            """)
            // Seed the singleton via a bound statement (the default body has
            // newlines — never interpolate it into the DDL string).
            let seed = try statement("""
            INSERT INTO wiki_index (id, body_markdown, updated_at, version)
            VALUES (1, ?1, ?2, 1);
            """)
            seed.reset()
            try seed.bind(WikiIndex.defaultBody, at: 1)
            try seed.bind(Date().timeIntervalSince1970, at: 2)
            _ = try seed.step()
            try exec("PRAGMA user_version=5;")
            version = 5
        }

        // Step 5 → 6: record WHICH ingested files the agent has actually
        // summarized into the wiki. `ingested_at` stays NULL until the agent
        // finishes an ingest and stamps it via `wikictl log append --kind ingest
        // --source <id>`. The UI's "Ingested" badge reads this deterministic flag
        // instead of fuzzy-matching the agent's free-text log titles (which the
        // agent is free to phrase however it likes, so the match silently failed).
        if version < 6 {
            try exec("ALTER TABLE ingested_files ADD COLUMN ingested_at REAL;")
            try exec("PRAGMA user_version=6;")
            version = 6
        }

        // v6 → v7: page embeddings for semantic search (sqlite-vec).
        // The BLOB holds 512 × Float32 (2048 bytes) produced by Apple
        // NLEmbedding. ON DELETE CASCADE mirrors the v0 attachment FK:
        // removing a page removes its embedding.
        if version < 7 {
            try exec("""
            CREATE TABLE page_embeddings (
                page_id TEXT PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL
            );
            """)
            try exec("PRAGMA user_version=7;")
            version = 7
        }

        // v7 → v8: append-only version chain for processed markdown.
        // Full-text snapshots (never deltas). ULID-sorted: MAX(id) == HEAD.
        // ON DELETE CASCADE so removing a file cleans up its version chain.
        // Migration is additive; no backfill — versions are seeded lazily.
        if version < 8 {
            try exec("""
            CREATE TABLE file_markdown_versions (
                id          TEXT PRIMARY KEY,
                file_id     TEXT NOT NULL REFERENCES ingested_files(id) ON DELETE CASCADE,
                parent_id   TEXT,
                content     TEXT NOT NULL,
                origin      TEXT NOT NULL,
                note        TEXT,
                created_at  REAL NOT NULL
            );
            """)
            try exec("""
            CREATE INDEX file_markdown_versions_file
                ON file_markdown_versions(file_id, id);
            """)
            try exec("PRAGMA user_version=8;")
            version = 8
        }
    }

    // MARK: - vec extension loading

    /// Called ONCE per process lifetime. Finds the bundled vec0.dylib, enables
    /// extension loading on a throwaway connection so the module is available
    /// on every subsequent `sqlite3_load_extension` call across connections.
    /// Failure is non-fatal: logged, semantic search degrades to LIKE fallback.
    private static let vecInitQueue = DispatchQueue(label: "wiki.vec.init")
    nonisolated(unsafe) private static var _vecDylibPath: String?
    nonisolated(unsafe) private static var _vecLoadAttempted = false

    private static func ensureVecExtensionLoaded() {
        // When there's no app bundle (test / CI), the dylib path search is
        // pointless AND Bundle.main can crash in some configurations.
        // Semantic search degrades to LIKE fallback automatically.
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        vecInitQueue.sync {
            guard !_vecLoadAttempted else { return }
            _vecLoadAttempted = true
        // Production: dylib lives in Contents/Helpers/ (copied by build.sh).
        // Development (swift build / Xcode): the binary runs from a build
        // directory.  We walk up from the bundle URL to find the project
        // root's Resources/ dir.  Also respect an explicit env-var override.
        var candidatePaths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["WIKIFS_VEC_DYLIB_PATH"] {
            candidatePaths.append(envPath)
        }
        let bundle = Bundle.main.bundleURL
        candidatePaths.append(
            bundle.appendingPathComponent("Contents/Helpers/vec0.dylib").path)
        // Walk up from the bundle to find Resources/vec0.dylib (dev builds).
        // make → build/*.app; swift build → .build/debug/*.app or .build/release/*.app.
        var cursor = bundle
        for _ in 0..<6 {
            cursor = cursor.deletingLastPathComponent()
            candidatePaths.append(
                cursor.appendingPathComponent("Resources/vec0.dylib").path)
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(
                resourceURL.appendingPathComponent("vec0.dylib").path)
        }
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                _vecDylibPath = path
                break
            }
        }
        guard _vecDylibPath != nil else {
            FileHandle.standardError.write(Data("SQLiteWikiStore: vec0.dylib not found — semantic search disabled\n".utf8))
            return
        }
        }  // end vecInitQueue.sync
        // Spin a throwaway connection just to enable extension loading once.
        var tmp: OpaquePointer?
        guard sqlite3_open(":memory:", &tmp) == SQLITE_OK, let tmp else { return }
        defer { sqlite3_close(tmp) }
        loadVecExtension(on: tmp)
    }

    /// Load the sqlite-vec extension on ONE connection. Safe to call on every
    /// open — sqlite3_load_extension short-circuits if already loaded on this
    /// connection. Errors are printed but not thrown.
    ///
    /// Apple's Swift `SQLite3` module intentionally omits
    /// `sqlite3_enable_load_extension` and `sqlite3_load_extension`. Both
    /// symbols ARE present in the system libsqlite3.dylib — we resolve them
    /// via `dlsym(RTLD_DEFAULT)` so no experimental compiler flags are needed.
    private static func loadVecExtension(on db: OpaquePointer) {
        guard let dylibPath = _vecDylibPath else { return }

        typealias EnableFn = @convention(c) (OpaquePointer?, Int32) -> Int32
        typealias LoadFn = @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        ) -> Int32

        guard let enablePtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!,
                                     "sqlite3_enable_load_extension"),
              let loadPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!,
                                  "sqlite3_load_extension")
        else {
            FileHandle.standardError.write(Data("SQLiteWikiStore: dlsym failed for sqlite3_*_load_extension\n".utf8))
            return
        }
        let enableFn = unsafeBitCast(enablePtr, to: EnableFn.self)
        let loadFn = unsafeBitCast(loadPtr, to: LoadFn.self)

        guard enableFn(db, 1) == SQLITE_OK else {
            FileHandle.standardError.write(Data("SQLiteWikiStore: sqlite3_enable_load_extension failed\n".utf8))
            return
        }
        let rc = dylibPath.withCString { path in
            loadFn(db, path, "sqlite3_vec_init", nil)
        }
        if rc != SQLITE_OK, let err = sqlite3_errmsg(db) {
            FileHandle.standardError.write(Data("SQLiteWikiStore: sqlite3_load_extension failed: \(String(cString: err))\n".utf8))
        }
    }

    /// Whether sqlite-vec scalar functions are available on THIS connection.
    /// Probes with a lightweight `SELECT vec_distance_cosine` on zero-length
    /// BLOBs — succeeds if registered, fails with "no such function" otherwise.
    private func isVecAvailable() -> Bool {
        (try? queryScalarText(
            "SELECT vec_distance_cosine(x'00000000', x'00000000');"
        )) != nil
    }

    // MARK: - WikiStore

    public func listPages(sortBy: PageSortOrder) throws -> [WikiPageSummary] {
        let orderClause: String
        switch sortBy {
        case .lastUpdated:
            orderClause = "ORDER BY updated_at DESC"
        case .newestFirst:
            orderClause = "ORDER BY created_at DESC"
        case .titleAZ:
            orderClause = "ORDER BY title COLLATE NOCASE ASC"
        }

        let sql = "SELECT id, title, updated_at, created_at FROM pages \(orderClause);"
        let stmt = try statement(sql)
        defer { stmt.reset() }
        var out: [WikiPageSummary] = []
        while try stmt.step() {
            out.append(WikiPageSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                title: stmt.text(at: 1),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 2)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3))
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
    ///
    /// Phase 5: the token ALSO folds in `ingested_files`
    /// (`"\(pCount):\(pSum):\(fCount):\(fSum)"`). Without this, ingesting or
    /// removing a file would NOT advance the anchor and the `files/` tree would
    /// never refresh. The enumerator treats the anchor as opaque (any non-equal
    /// parseable string forces a re-emit), so the wider format needs no
    /// enumerator change. `ingested_files` may not exist yet on a not-yet-migrated
    /// read connection, so its part falls back to `0:0`.
    ///
    /// System prompt (v3): the token ALSO appends the singleton `system_prompt`
    /// row's `version` (`"…:\(spVersion)"`). Editing ONLY the prompt (no page or
    /// file change) must still advance the anchor, or the projected
    /// `CLAUDE.md`/`AGENTS.md` would never refresh without a relaunch. Falls back
    /// to `0` on a not-yet-migrated read connection (table absent).
    ///
    /// Phase B (v4/v5): the token ALSO appends the `log` row COUNT and the
    /// singleton `wiki_index` row's `version`
    /// (`"…:\(logCount):\(idxVersion)"`). Same reasoning as the `spVersion` fold:
    /// appending ONLY a log entry, or editing ONLY the index, must still advance
    /// the anchor or the projected `log.md` / `index.md` would never refresh. The
    /// `log` part uses COUNT (it is append-only — rows only ever grow, never bump
    /// a per-row version) and the index part uses the row `version` (it UPSERTs
    /// like `system_prompt`). Both fall back to `0` on a not-yet-migrated read
    /// connection (the v4/v5 tables absent), exactly like the `spVersion` fold.
    public func changeToken() throws -> String {
        let pages = try statement("SELECT COUNT(*), COALESCE(SUM(version), 0) FROM pages;")
        defer { pages.reset() }
        guard try pages.step() else { return "0:0:0:0:0:0:0" }
        let pCount = pages.int(at: 0)
        let pSum = pages.int(at: 1)
        let (fCount, fSum) = ingestedFileCountSum()
        let spVersion = systemPromptVersion()
        let logCount = logRowCount()
        let idxVersion = wikiIndexVersion()
        return "\(pCount):\(pSum):\(fCount):\(fSum):\(spVersion):\(logCount):\(idxVersion)"
    }

    /// COUNT/SUM(version) over `ingested_files`, resilient to the table not
    /// existing yet (a read connection opened against a pre-migration DB). On any
    /// failure returns `(0, 0)` so `changeToken()` still answers.
    private func ingestedFileCountSum() -> (Int64, Int64) {
        guard let stmt = try? statement(
            "SELECT COUNT(*), COALESCE(SUM(version), 0) FROM ingested_files;") else {
            return (0, 0)
        }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return (0, 0) }
        return (stmt.int(at: 0), stmt.int(at: 1))
    }

    /// The singleton `system_prompt` row's `version`, resilient to the table not
    /// existing yet (a read connection opened against a pre-v3 DB). On any
    /// failure returns `0` so `changeToken()` still answers.
    private func systemPromptVersion() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COALESCE(version, 0) FROM system_prompt WHERE id = 1;") else {
            return 0
        }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// The append-only `log` table's row COUNT, resilient to the table not
    /// existing yet (a read connection opened against a pre-v4 DB). On any failure
    /// returns `0` so `changeToken()` still answers.
    private func logRowCount() -> Int64 {
        guard let stmt = try? statement("SELECT COUNT(*) FROM log;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// The singleton `wiki_index` row's `version`, resilient to the table not
    /// existing yet (a read connection opened against a pre-v5 DB). On any failure
    /// returns `0` so `changeToken()` still answers.
    private func wikiIndexVersion() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COALESCE(version, 0) FROM wiki_index WHERE id = 1;") else {
            return 0
        }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
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

    // MARK: - Ingested files (Phase 5)

    /// Reject any single dropped file larger than this. A soft guard so the
    /// verbatim-bytes-in-SQLite model can't be handed a multi-GB blob that would
    /// blow up memory on read. 100 MB is generous for notes/PDFs/markdown.
    public static let ingestByteCap = 100 * 1024 * 1024

    /// Ingest a file's verbatim bytes + metadata as a NEW `ingested_files` row.
    /// `ext` is the lowercased extension (no dot, `""` if none); `mime_type` is
    /// the best-effort UTI→MIME for that extension. `byte_size` mirrors
    /// `length(content)`. The id is a fresh ULID (sortable == ingest order).
    /// Throws if `data` exceeds `ingestByteCap`.
    @discardableResult
    public func ingestFile(filename: String, data: Data) throws -> IngestedFileSummary {
        guard data.count <= Self.ingestByteCap else {
            throw WikiStoreError.unexpected(
                "ingested file \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
        }
        let id = PageID(rawValue: ULID.generate())
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType
        let now = Date()

        let stmt = try statement("""
        INSERT INTO ingested_files
          (id, filename, ext, mime_type, byte_size, content, created_at, updated_at, version)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, 1);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(filename, at: 2)
        try stmt.bind(ext, at: 3)
        if let mime { try stmt.bind(mime, at: 4) }  // else leave NULL
        try stmt.bind(Int64(data.count), at: 5)
        try stmt.bind(data, at: 6)
        try stmt.bind(now.timeIntervalSince1970, at: 7)
        _ = try stmt.step()

        return IngestedFileSummary(
            id: id, filename: filename, ext: ext, mimeType: mime,
            byteSize: data.count, createdAt: now, updatedAt: now, version: 1
        )
    }

    /// All ingested-file summaries (NO content blob), most-recent-first for the
    /// management list. `id` is a ULID so `created_at DESC` orders by ingest.
    public func listIngestedFiles() throws -> [IngestedFileSummary] {
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version
        FROM ingested_files ORDER BY created_at DESC, id DESC;
        """)
        defer { stmt.reset() }
        var out: [IngestedFileSummary] = []
        while try stmt.step() {
            out.append(ingestedSummary(from: stmt))
        }
        return out
    }

    /// One ingested-file summary (NO content blob). Throws `.notFound` if absent.
    public func getIngestedFile(id: PageID) throws -> IngestedFileSummary {
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version
        FROM ingested_files WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return ingestedSummary(from: stmt)
    }

    /// The verbatim content bytes for one ingested file, fetched on demand (never
    /// held in the summary list). Throws `.notFound` if absent.
    public func ingestedFileContent(id: PageID) throws -> Data {
        let stmt = try statement("SELECT content FROM ingested_files WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return stmt.blob(at: 0)
    }

    public func deleteIngestedFile(id: PageID) throws {
        let stmt = try statement("DELETE FROM ingested_files WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        _ = try stmt.step()
    }

    /// Stamp an ingested file as summarized-into-the-wiki. Idempotent and a no-op
    /// for an unknown id. Called from `wikictl log append --kind ingest --source`.
    public func markIngestedFile(id: PageID) throws {
        let stmt = try statement(
            "UPDATE ingested_files SET ingested_at = ?2 WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(Date().timeIntervalSince1970, at: 2)
        _ = try stmt.step()
    }

    /// IDs of ingested files the agent has marked ingested — the authoritative
    /// status the UI's "Ingested" badge reads.
    public func markedIngestedFileIDs() throws -> Set<String> {
        let stmt = try statement(
            "SELECT id FROM ingested_files WHERE ingested_at IS NOT NULL;")
        defer { stmt.reset() }
        var ids: Set<String> = []
        while try stmt.step() { ids.insert(stmt.text(at: 0)) }
        return ids
    }

    /// All ingested files as `IndexGenerators.FileRow`s, ordered by id (ULID ==
    /// ingest order) for the deterministic `indexes/files.jsonl` generator.
    /// Read-side projection helper (like `listAllPagesOrderedByID`).
    public func listAllIngestedFilesOrderedByID() throws -> [IndexGenerators.FileRow] {
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version
        FROM ingested_files ORDER BY id ASC;
        """)
        defer { stmt.reset() }
        var out: [IndexGenerators.FileRow] = []
        while try stmt.step() {
            let mime = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
                ? nil : stmt.text(at: 3)
            out.append(IndexGenerators.FileRow(
                id: stmt.text(at: 0),
                filename: stmt.text(at: 1),
                ext: stmt.text(at: 2),
                mime: mime,
                byteSize: Int(stmt.int(at: 4)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
                version: Int(stmt.int(at: 7))
            ))
        }
        return out
    }

    /// Map the current row of an `ingested_files` SELECT (column order: id,
    /// filename, ext, mime_type, byte_size, created_at, updated_at, version) to a
    /// summary. `mime_type` is read as NULL→nil via the column type.
    private func ingestedSummary(from stmt: SQLiteStatement) -> IngestedFileSummary {
        let mime = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            ? nil : stmt.text(at: 3)
        return IngestedFileSummary(
            id: PageID(rawValue: stmt.text(at: 0)),
            filename: stmt.text(at: 1),
            ext: stmt.text(at: 2),
            mimeType: mime,
            byteSize: Int(stmt.int(at: 4)),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
            version: Int(stmt.int(at: 7))
        )
    }

    // MARK: - System prompt (singleton document, v3)

    /// Read the singleton system-prompt document. Returns the seeded default if
    /// no row exists yet (defensive — the v2→3 migration seeds one). The caller
    /// (read projection) wraps this in `try?` and falls back to the default if
    /// the table itself is absent on a not-yet-migrated read connection.
    public func getSystemPrompt() throws -> SystemPrompt {
        let stmt = try statement(
            "SELECT body_markdown, updated_at, version FROM system_prompt WHERE id = 1;")
        defer { stmt.reset() }
        guard try stmt.step() else {
            return SystemPrompt(body: SystemPrompt.defaultBody,
                                updatedAt: Date(timeIntervalSince1970: 0), version: 0)
        }
        return SystemPrompt(
            body: stmt.text(at: 0),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 1)),
            version: Int(stmt.int(at: 2))
        )
    }

    /// Replace the system-prompt body, bumping `version` (so `changeToken()`
    /// advances and the projected `CLAUDE.md`/`AGENTS.md` refresh) and
    /// `updated_at`. UPSERT so it works even if the singleton row is somehow
    /// missing (creates it at version 1; otherwise increments).
    public func updateSystemPrompt(body: String) throws {
        let stmt = try statement("""
        INSERT INTO system_prompt (id, body_markdown, updated_at, version)
        VALUES (1, ?1, ?2, 1)
        ON CONFLICT(id) DO UPDATE SET
            body_markdown = excluded.body_markdown,
            updated_at = excluded.updated_at,
            version = system_prompt.version + 1;
        """)
        defer { stmt.reset() }
        try stmt.bind(body, at: 1)
        try stmt.bind(Date().timeIntervalSince1970, at: 2)
        _ = try stmt.step()
    }

    // MARK: - Log (append-only chronological log, Phase B)

    /// Append one row to the `log` table. The id is a fresh ULID (sortable ==
    /// chronological); `ts` is "now". `kind` is the stable rawValue of the closed
    /// `LogEntry.Kind` set. Returns the inserted entry (so the CLI can echo its
    /// id). Append-only: this never updates or UPSERTs.
    @discardableResult
    public func appendLog(kind: LogEntry.Kind, title: String, note: String?) throws -> LogEntry {
        let id = PageID(rawValue: ULID.generate())
        let now = Date()
        let stmt = try statement("""
        INSERT INTO log (id, ts, kind, title, note)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(now.timeIntervalSince1970, at: 2)
        try stmt.bind(kind.rawValue, at: 3)
        try stmt.bind(title, at: 4)
        if let note { try stmt.bind(note, at: 5) }  // else leave NULL
        _ = try stmt.step()
        return LogEntry(id: id, timestamp: now, kind: kind, title: title, note: note)
    }

    /// All log rows in chronological (insertion) order, oldest-first, for the
    /// `log.md` projection. Read-side helper (like `listAllPagesOrderedByID`) — not
    /// on the `WikiStore` protocol. Resilient to the table not existing yet is the
    /// caller's job (the projection wraps this in `try?`).
    ///
    /// Ordered by `ts` then `rowid` — NOT by the ULID `id`. The ULID's lexical sort
    /// only matches creation order to millisecond granularity, so two appends in the
    /// same millisecond would tie and order randomly by the ULID's random bits (a
    /// flaky `log.md` ordering). `ts` is sub-millisecond and `rowid` is monotonic
    /// per insert, so this is fully deterministic insertion order.
    public func listAllLogEntriesOrderedByID() throws -> [LogEntry] {
        let stmt = try statement("""
        SELECT id, ts, kind, title, note FROM log ORDER BY ts ASC, rowid ASC;
        """)
        defer { stmt.reset() }
        var out: [LogEntry] = []
        while try stmt.step() {
            let note = sqlite3_column_type(stmt.handle, 4) == SQLITE_NULL ? nil : stmt.text(at: 4)
            out.append(LogEntry(
                id: PageID(rawValue: stmt.text(at: 0)),
                timestamp: Date(timeIntervalSince1970: stmt.double(at: 1)),
                kind: LogEntry.Kind(rawValue: stmt.text(at: 2)) ?? .ingest,
                title: stmt.text(at: 3),
                note: note
            ))
        }
        return out
    }

    /// The most recent `limit` log rows in chronological order (oldest-of-the-tail
    /// first), for the operation prompts' live state snapshot. Selects the newest
    /// `limit` by `ts`/`rowid` DESC (same deterministic ordering as
    /// `listAllLogEntriesOrderedByID`, just bounded) and reverses to chronological
    /// so the rendered tail matches `log.md`'s `tail`. A non-positive `limit`, or an
    /// empty log, yields `[]`.
    public func recentLogEntries(limit: Int) throws -> [LogEntry] {
        guard limit > 0 else { return [] }
        let stmt = try statement("""
        SELECT id, ts, kind, title, note FROM log ORDER BY ts DESC, rowid DESC LIMIT ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(Int64(limit), at: 1)
        var out: [LogEntry] = []
        while try stmt.step() {
            let note = sqlite3_column_type(stmt.handle, 4) == SQLITE_NULL ? nil : stmt.text(at: 4)
            out.append(LogEntry(
                id: PageID(rawValue: stmt.text(at: 0)),
                timestamp: Date(timeIntervalSince1970: stmt.double(at: 1)),
                kind: LogEntry.Kind(rawValue: stmt.text(at: 2)) ?? .ingest,
                title: stmt.text(at: 3),
                note: note
            ))
        }
        return out.reversed()  // newest-first query → chronological for the tail.
    }

    // MARK: - Wiki index (singleton catalog document, Phase B)

    /// Read the singleton `wiki_index` document. Returns the seeded default if no
    /// row exists yet (defensive — the v4→5 migration seeds one). The read
    /// projection wraps this in `try?` and falls back to the default if the table
    /// itself is absent on a not-yet-migrated read connection. Mirrors
    /// `getSystemPrompt()`.
    public func getWikiIndex() throws -> WikiIndex {
        let stmt = try statement(
            "SELECT body_markdown, updated_at, version FROM wiki_index WHERE id = 1;")
        defer { stmt.reset() }
        guard try stmt.step() else {
            return WikiIndex(body: WikiIndex.defaultBody,
                             updatedAt: Date(timeIntervalSince1970: 0), version: 0)
        }
        return WikiIndex(
            body: stmt.text(at: 0),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 1)),
            version: Int(stmt.int(at: 2))
        )
    }

    /// Replace the wiki-index body wholesale, bumping `version` (so `changeToken()`
    /// advances and the projected `index.md` refreshes) and `updated_at`. UPSERT so
    /// it works even if the singleton row is somehow missing (creates it at version
    /// 1; otherwise increments). Mirrors `updateSystemPrompt(body:)`.
    public func updateWikiIndex(body: String) throws {
        let stmt = try statement("""
        INSERT INTO wiki_index (id, body_markdown, updated_at, version)
        VALUES (1, ?1, ?2, 1)
        ON CONFLICT(id) DO UPDATE SET
            body_markdown = excluded.body_markdown,
            updated_at = excluded.updated_at,
            version = wiki_index.version + 1;
        """)
        defer { stmt.reset() }
        try stmt.bind(body, at: 1)
        try stmt.bind(Date().timeIntervalSince1970, at: 2)
        _ = try stmt.step()
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

    // MARK: - Semantic search (v7)

    public func storePageEmbedding(id: PageID, blob: Data) throws {
        let stmt = try statement("""
        INSERT OR REPLACE INTO page_embeddings (page_id, embedding)
        VALUES (?1, ?2);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(blob, at: 2)
        _ = try stmt.step()
    }

    public func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
        // Try semantic search first; fall back to LIKE title match.
        if isVecAvailable(), let queryBlob = EmbeddingService.embeddingBlob(for: query) {
            return try searchSimilarSemantic(blob: queryBlob, limit: limit)
        }
        return try searchSimilarFallback(query: query, limit: limit)
    }

    private func searchSimilarSemantic(blob queryBlob: Data, limit: Int) throws -> [WikiPageSummary] {
        let sql = """
        SELECT p.id, p.title, p.updated_at, p.created_at
        FROM pages p
        JOIN page_embeddings pe ON pe.page_id = p.id
        ORDER BY vec_distance_cosine(pe.embedding, ?1) ASC
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(queryBlob, at: 1)
        try stmt.bind(Int64(limit), at: 2)

        var out: [WikiPageSummary] = []
        while try stmt.step() {
            out.append(WikiPageSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                title: stmt.text(at: 1),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 2)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3))
            ))
        }
        return out
    }

    private func searchSimilarFallback(query: String, limit: Int) throws -> [WikiPageSummary] {
        let pattern = "%\(query)%"
        let sql = """
        SELECT id, title, updated_at, created_at
        FROM pages
        WHERE title LIKE ?1
        ORDER BY updated_at DESC
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(pattern, at: 1)
        try stmt.bind(Int64(limit), at: 2)

        var out: [WikiPageSummary] = []
        while try stmt.step() {
            out.append(WikiPageSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                title: stmt.text(at: 1),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 2)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3))
            ))
        }
        return out
    }

    public func recomputeMissingEmbeddings() -> Int {
        guard isVecAvailable() else { return 0 }
        var count = 0
        do {
            let stmt = try statement("""
            SELECT p.id, p.title, p.body_markdown
            FROM pages p
            LEFT JOIN page_embeddings pe ON pe.page_id = p.id
            WHERE pe.page_id IS NULL;
            """)
            defer { stmt.reset() }
            while try stmt.step() {
                let id = PageID(rawValue: stmt.text(at: 0))
                let title = stmt.text(at: 1)
                let body = stmt.text(at: 2)
                if let blob = EmbeddingService.embeddingBlob(title: title, body: body) {
                    try? storePageEmbedding(id: id, blob: blob)
                    count += 1
                }
            }
        } catch {
            FileHandle.standardError.write(Data("SQLiteWikiStore.recomputeMissingEmbeddings: \(error)\n".utf8))
        }
        return count
    }

    // MARK: - Processed markdown versions (v8)

    /// Read one `file_markdown_versions` row from the current statement position
    /// (column order: id, file_id, parent_id, content, origin, note, created_at).
    private func fileMarkdownVersion(from stmt: SQLiteStatement) -> FileMarkdownVersion {
        let parentID: PageID? = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL
            ? nil : PageID(rawValue: stmt.text(at: 2))
        let note: String? = sqlite3_column_type(stmt.handle, 5) == SQLITE_NULL
            ? nil : stmt.text(at: 5)
        return FileMarkdownVersion(
            id: PageID(rawValue: stmt.text(at: 0)),
            fileID: PageID(rawValue: stmt.text(at: 1)),
            parentID: parentID,
            content: stmt.text(at: 3),
            origin: stmt.text(at: 4),
            note: note,
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 6))
        )
    }

    public func processedMarkdownHead(fileID: PageID) throws -> FileMarkdownVersion? {
        guard let stmt = try? statement("""
        SELECT id, file_id, parent_id, content, origin, note, created_at
        FROM file_markdown_versions WHERE file_id = ?1 ORDER BY id DESC LIMIT 1;
        """) else { return nil }
        defer { stmt.reset() }
        try stmt.bind(fileID.rawValue, at: 1)
        guard try stmt.step() else { return nil }
        return fileMarkdownVersion(from: stmt)
    }

    public func hasProcessedMarkdown(fileID: PageID) throws -> Bool {
        guard let stmt = try? statement("""
        SELECT 1 FROM file_markdown_versions WHERE file_id = ?1 LIMIT 1;
        """) else { return false }
        defer { stmt.reset() }
        try stmt.bind(fileID.rawValue, at: 1)
        return try stmt.step()
    }

    public func processedMarkdownHistory(fileID: PageID) throws -> [FileMarkdownVersion] {
        guard let stmt = try? statement("""
        SELECT id, file_id, parent_id, content, origin, note, created_at
        FROM file_markdown_versions WHERE file_id = ?1 ORDER BY id DESC;
        """) else { return [] }
        defer { stmt.reset() }
        try stmt.bind(fileID.rawValue, at: 1)
        var out: [FileMarkdownVersion] = []
        while try stmt.step() {
            out.append(fileMarkdownVersion(from: stmt))
        }
        return out
    }

    @discardableResult
    public func appendProcessedMarkdown(fileID: PageID, content: String,
                                        origin: String, note: String?) throws -> FileMarkdownVersion {
        let id = PageID(rawValue: ULID.generate())
        let parentID = try processedMarkdownHead(fileID: fileID)?.id
        let now = Date()

        let stmt = try statement("""
        INSERT INTO file_markdown_versions
          (id, file_id, parent_id, content, origin, note, created_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(fileID.rawValue, at: 2)
        if let parentID { try stmt.bind(parentID.rawValue, at: 3) }
        try stmt.bind(content, at: 4)
        try stmt.bind(origin, at: 5)
        if let note { try stmt.bind(note, at: 6) }
        try stmt.bind(now.timeIntervalSince1970, at: 7)
        _ = try stmt.step()

        return FileMarkdownVersion(
            id: id, fileID: fileID, parentID: parentID,
            content: content, origin: origin, note: note, createdAt: now
        )
    }

    @discardableResult
    public func revertProcessedMarkdown(fileID: PageID, to versionID: PageID) throws -> FileMarkdownVersion {
        // Read the target version's content — must exist and belong to fileID.
        guard let stmt = try? statement("""
        SELECT content FROM file_markdown_versions WHERE id = ?1 AND file_id = ?2;
        """) else {
            throw WikiStoreError.unexpected("file_markdown_versions table not found")
        }
        defer { stmt.reset() }
        try stmt.bind(versionID.rawValue, at: 1)
        try stmt.bind(fileID.rawValue, at: 2)
        guard try stmt.step() else {
            throw WikiStoreError.notFound(versionID)
        }
        let oldContent = stmt.text(at: 0)

        // Append a new version whose content copies the target. History preserved.
        return try appendProcessedMarkdown(
            fileID: fileID, content: oldContent,
            origin: "revert", note: "revert to \(versionID.rawValue)"
        )
    }
}
