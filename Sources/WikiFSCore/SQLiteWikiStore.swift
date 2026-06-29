import Foundation
import SQLite3
import UniformTypeIdentifiers
import Darwin
import CSqliteVec

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
    public convenience init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, forceLadderMigration: false)
    }

    /// Designated open. `forceLadderMigration` (test-only) makes a FRESH db run
    /// the full stepwise ladder instead of the consolidated fast path, so a test
    /// can parity-check the two produce identical schemas.
    internal init(databaseURL: URL, forceLadderMigration: Bool) throws {
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
            try bootstrapSchema(forceLadderMigration: forceLadderMigration)
            // Register the statically-linked sqlite-vec on THIS connection
            // (connection-scoped). Non-fatal: FTS5 (v13) remains the fallback.
            registerVec(on: db)
            // Self-heal search indexes for content that predates the FTS/vec
            // migrations (or arrived via wikictl): seed native-markdown sources,
            // backfill source_search, rebuild any lagging FTS index, and embed
            // anything missing. Idempotent + near-zero cost when nothing is
            // missing, so search "just works" on every writable open without a
            // manual reindex. NOT run by the read-only File Provider connection.
            ensureSearchIndexesPopulated()
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
            registerVec(on: db)
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
    private func bootstrapSchema(forceLadderMigration: Bool = false) throws {
        var version = Int(try queryScalarText("PRAGMA user_version;")) ?? 0
        // Fresh DB: build the complete current schema in ONE consolidated block,
        // skipping the stepwise ladder's historical create→rename→drop churn
        // (e.g. v7/v12 create single-row embeddings that v14 drops; v2 creates
        // `ingested_files` which v10 renames to `sources`). EXISTING dbs
        // (version >= 1) — and fresh dbs forced onto the ladder by tests — run
        // `migrate(from:)` so every prior upgrade path is preserved.
        if version == 0 && !forceLadderMigration {
            try createFreshSchemaV14()
            return
        }
        try migrate(from: &version)
    }

    /// Build the complete current (v14) schema for a fresh database in one
    /// consolidated block. MUST stay schema-identical to the end state of
    /// `migrate(from:)`; the `freshFastPathMatchesStepwiseLadder` test enforces
    /// that by forcing a fresh db through the ladder and comparing. Legacy index
    /// names (`ingested_files_created`, `file_markdown_versions_file`) are
    /// reproduced verbatim — they survive the table renames in the ladder, so a
    /// fresh db must match.
    private func createFreshSchemaV14() throws {
        // Core page model + attachments/links.
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

        // Sources — final shape: ingested_files (v2) + ingested_at (v6) +
        // zotero columns (v9) + display_name (v10).
        try exec("""
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT,
            byte_size INTEGER NOT NULL,
            content BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,
            ingested_at REAL,
            zotero_item_key TEXT,
            zotero_item_title TEXT,
            display_name TEXT
        );
        """)
        try exec("CREATE INDEX ingested_files_created ON sources(created_at);")

        // Processed-markdown version chain (v8, v10 rename). The legacy index
        // name `file_markdown_versions_file` survives the table rename.
        try exec("""
        CREATE TABLE source_markdown_versions (
            id          TEXT PRIMARY KEY,
            file_id     TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            parent_id   TEXT,
            content     TEXT NOT NULL,
            origin      TEXT NOT NULL,
            note        TEXT,
            created_at  REAL NOT NULL
        );
        """)
        try exec("""
        CREATE INDEX file_markdown_versions_file
            ON source_markdown_versions(file_id, id);
        """)

        // source_links with cascade (v10 create, v11 cascade rebuild).
        try exec("""
        CREATE TABLE source_links (
            from_page_id TEXT NOT NULL REFERENCES pages(id),
            to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            link_text    TEXT NOT NULL,
            PRIMARY KEY (from_page_id, to_source_id)
        );
        """)

        // Singleton documents (seeded) + the append-only log.
        try exec("""
        CREATE TABLE system_prompt (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        );
        """)
        try exec("""
        CREATE TABLE log (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            note TEXT
        );
        """)
        try exec("""
        CREATE TABLE wiki_index (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        );
        """)
        let now = Date().timeIntervalSince1970
        let sp = try statement("""
        INSERT INTO system_prompt (id, body_markdown, updated_at, version)
        VALUES (1, ?1, ?2, 1);
        """)
        sp.reset(); try sp.bind(SystemPrompt.defaultBody, at: 1); try sp.bind(now, at: 2); _ = try sp.step()
        let wi = try statement("""
        INSERT INTO wiki_index (id, body_markdown, updated_at, version)
        VALUES (1, ?1, ?2, 1);
        """)
        wi.reset(); try wi.bind(WikiIndex.defaultBody, at: 1); try wi.bind(now, at: 2); _ = try wi.step()

        // Per-chunk embeddings (v14); supersedes the dropped v7/v12 single-row tables.
        try exec("""
        CREATE TABLE page_chunks (
            page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (page_id, chunk_idx)
        ) WITHOUT ROWID;
        """)
        try exec("""
        CREATE TABLE source_chunks (
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (source_id, chunk_idx)
        ) WITHOUT ROWID;
        """)

        // FTS5/BM25 (v13): pages (external-content over `pages`) + sources (via
        // the `source_search` sidecar), each kept in sync by AFTER
        // INSERT/UPDATE/DELETE triggers.
        try exec("""
        CREATE VIRTUAL TABLE pages_fts USING fts5(
            title, body_markdown,
            content='pages', content_rowid='rowid',
            tokenize='porter');
        """)
        try exec("""
        CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
          INSERT INTO pages_fts(rowid, title, body_markdown)
            VALUES (new.rowid, new.title, new.body_markdown);
        END;
        """)
        try exec("""
        CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
          INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
            VALUES ('delete', old.rowid, old.title, old.body_markdown);
        END;
        """)
        try exec("""
        CREATE TRIGGER pages_fts_au AFTER UPDATE ON pages BEGIN
          INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
            VALUES ('delete', old.rowid, old.title, old.body_markdown);
          INSERT INTO pages_fts(rowid, title, body_markdown)
            VALUES (new.rowid, new.title, new.body_markdown);
        END;
        """)
        try exec("""
        CREATE TABLE source_search (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            title     TEXT NOT NULL,
            body      TEXT NOT NULL
        );
        """)
        try exec("""
        CREATE VIRTUAL TABLE sources_fts USING fts5(
            title, body,
            content='source_search', content_rowid='rowid',
            tokenize='porter');
        """)
        try exec("""
        CREATE TRIGGER sources_fts_ai AFTER INSERT ON source_search BEGIN
          INSERT INTO sources_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)
        try exec("""
        CREATE TRIGGER sources_fts_ad AFTER DELETE ON source_search BEGIN
          INSERT INTO sources_fts(sources_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
        END;
        """)
        try exec("""
        CREATE TRIGGER sources_fts_au AFTER UPDATE ON source_search BEGIN
          INSERT INTO sources_fts(sources_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
          INSERT INTO sources_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)

        try exec("PRAGMA user_version=14;")
    }

    /// The stepwise, idempotent migration ladder keyed on `PRAGMA user_version`.
    /// Runs for any EXISTING db (version >= 1) up to the head version, and — when
    /// a test forces it — for a fresh db, so the fresh-DB fast path can be
    /// parity-checked against it. Each step is guarded by `if version < N` so a
    /// re-open is a no-op. **Do not collapse these steps**: they perform
    /// irreversible data migrations (renames, column adds, table rebuilds) that
    /// existing dbs at every intermediate version depend on.
    private func migrate(from version: inout Int) throws {

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
        // and served byte-for-byte; surfaced read-only under the `sources/` tree.
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
        // --source <id>`. The UI's "Processed" badge reads this deterministic flag
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

        // v8 → v9: provenance for files ingested from Zotero. Two nullable TEXT
        // columns capture the parent library item at ingest time so the detail
        // view can show "From Zotero: <title>" and link back without re-hitting
        // the API (the item could be renamed/deleted between ingest and view).
        // NULL for drag-drop / URL / folder-import (no Zotero provenance).
        if version < 9 {
            try exec("ALTER TABLE ingested_files ADD COLUMN zotero_item_key TEXT;")
            try exec("ALTER TABLE ingested_files ADD COLUMN zotero_item_title TEXT;")
            try exec("PRAGMA user_version=9;")
            version = 9
        }

        // v9 → v10: rename "ingested file" → "source" throughout. The main table
        // becomes `sources`; the processed-markdown version chain becomes
        // `source_markdown_versions`. A new `display_name` column defaults to the
        // original filename. `source_links` records [[source:…]] references from
        // wiki pages (mirrors `page_links` but FKs to `sources(id)`).
        // SQLite's ALTER TABLE RENAME TO automatically updates FK references in
        // `source_markdown_versions.file_id` to point to `sources(id)`.
        if version < 10 {
            try exec("ALTER TABLE ingested_files RENAME TO sources;")
            try exec("ALTER TABLE sources ADD COLUMN display_name TEXT;")
            try exec("UPDATE sources SET display_name = filename;")
            try exec("ALTER TABLE file_markdown_versions RENAME TO source_markdown_versions;")
            try exec("""
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id),
                link_text    TEXT NOT NULL,
                PRIMARY KEY (from_page_id, to_source_id)
            );
            """)
            try exec("PRAGMA user_version=10;")
            version = 10
        }

        // v10 → v11: add ON DELETE CASCADE to source_links.to_source_id. SQLite cannot
        // ALTER an FK constraint in place, so rebuild the table (rename old → create new
        // with the cascade → copy rows → drop old). source_links is a leaf join table
        // (nothing FKs to it), so the rename is safe. The rebuild is data-preserving for
        // DBs that already have Phase B rows, and a no-op rebuild on empty ones.
        // Mirrors the cascade already on source_markdown_versions (v8).
        if version < 11 {
            try exec("ALTER TABLE source_links RENAME TO source_links_v10;")
            try exec("""
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                link_text    TEXT NOT NULL,
                PRIMARY KEY (from_page_id, to_source_id)
            );
            """)
            try exec("""
            INSERT INTO source_links (from_page_id, to_source_id, link_text)
            SELECT from_page_id, to_source_id, link_text FROM source_links_v10;
            """)
            try exec("DROP TABLE source_links_v10;")
            try exec("PRAGMA user_version=11;")
            version = 11
        }

        // v11 → v12: source embeddings for semantic source search (sqlite-vec).
        // Mirrors page_embeddings (v7). ON DELETE CASCADE: removing a source
        // removes its embedding. FK target is sources(id) (renamed from
        // ingested_files in v10). `foreign_keys=ON` is set in configurePragmas().
        if version < 12 {
            try exec("""
            CREATE TABLE source_embeddings (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL
            );
            """)
            try exec("PRAGMA user_version=12;")
            version = 12
        }

        // v12 → v13: FTS5/BM25 full-text search over title + body. FTS5 is CORE
        // SQLite (ENABLE_FTS5 on the system build) — no loadable extension needed,
        // so it works in wikictl and under `swift test`, unlike the vec layer.
        //
        // PAGES: body (body_markdown) is inline on `pages`, so use external-content
        // FTS5 keyed on pages.rowid, maintained by AFTER INSERT/UPDATE/DELETE
        // triggers. This needs NO changes to the page-write Swift — createPage /
        // updatePage / deletePage already write `pages`, so the triggers fire.
        // Existing rows are backfilled lazily by rebuildFTS() (Reindex), via the
        // FTS5 'rebuild' command; new rows index immediately.
        //
        // SOURCES: body is the HEAD of the version chain (source_markdown_versions),
        // NOT inline on `sources`, so we index a sidecar `source_search` — one row
        // per source holding the current title + head body — maintained by
        // appendProcessedMarkdown / renameSource via upsertSourceSearch(). The
        // trigger keeps sources_fts in sync; deleting a source cascades to
        // source_search (FK ON DELETE CASCADE) whose trigger removes the FTS row.
        if version < 13 {
            try exec("""
            CREATE VIRTUAL TABLE pages_fts USING fts5(
                title, body_markdown,
                content='pages', content_rowid='rowid',
                tokenize='porter');
            """)
            try exec("""
            CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
              INSERT INTO pages_fts(rowid, title, body_markdown)
                VALUES (new.rowid, new.title, new.body_markdown);
            END;
            """)
            try exec("""
            CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
              INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
                VALUES ('delete', old.rowid, old.title, old.body_markdown);
            END;
            """)
            try exec("""
            CREATE TRIGGER pages_fts_au AFTER UPDATE ON pages BEGIN
              INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
                VALUES ('delete', old.rowid, old.title, old.body_markdown);
              INSERT INTO pages_fts(rowid, title, body_markdown)
                VALUES (new.rowid, new.title, new.body_markdown);
            END;
            """)

            try exec("""
            CREATE TABLE source_search (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                title     TEXT NOT NULL,
                body      TEXT NOT NULL
            );
            """)
            try exec("""
            CREATE VIRTUAL TABLE sources_fts USING fts5(
                title, body,
                content='source_search', content_rowid='rowid',
                tokenize='porter');
            """)
            try exec("""
            CREATE TRIGGER sources_fts_ai AFTER INSERT ON source_search BEGIN
              INSERT INTO sources_fts(rowid, title, body)
                VALUES (new.rowid, new.title, new.body);
            END;
            """)
            try exec("""
            CREATE TRIGGER sources_fts_ad AFTER DELETE ON source_search BEGIN
              INSERT INTO sources_fts(sources_fts, rowid, title, body)
                VALUES ('delete', old.rowid, old.title, old.body);
            END;
            """)
            try exec("""
            CREATE TRIGGER sources_fts_au AFTER UPDATE ON source_search BEGIN
              INSERT INTO sources_fts(sources_fts, rowid, title, body)
                VALUES ('delete', old.rowid, old.title, old.body);
              INSERT INTO sources_fts(rowid, title, body)
                VALUES (new.rowid, new.title, new.body);
            END;
            """)
            try exec("PRAGMA user_version=13;")
            version = 13
        }

        // v13 → v14: per-chunk embeddings (RAG-style). Replaces the old
        // one-embedding-per-document model (`page_embeddings`, `source_embeddings`)
        // with one embedding BLOB per text chunk, so a query can match the single
        // best passage of a large document (best-chunk-per-doc ranking) instead of
        // a blurry document centroid. Also fixes NLEmbedding's hard limit: a whole
        // document fed to NLEmbedding throws an uncatchable std::bad_alloc above
        // ~250k chars; chunking keeps each embedding input small.
        //
        // FK ON DELETE CASCADE: deleting a page/source removes its chunks. The vec
        // query uses the `vec_distance_cosine` scalar in a GROUP-BY to pick each
        // document's best (lowest-distance) chunk.
        if version < 14 {
            try exec("""
            CREATE TABLE page_chunks (
                page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (page_id, chunk_idx)
            ) WITHOUT ROWID;
            """)
            try exec("""
            CREATE TABLE source_chunks (
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (source_id, chunk_idx)
            ) WITHOUT ROWID;
            """)
            // The old single-embedding tables are superseded and unused after v14.
            try exec("DROP TABLE IF EXISTS page_embeddings;")
            try exec("DROP TABLE IF EXISTS source_embeddings;")
            try exec("PRAGMA user_version=14;")
            version = 14
        }
    }

    // MARK: - sqlite-vec registration (statically linked, -DSQLITE_CORE)

    /// Register the statically-linked sqlite-vec (`vec0` vtable + scalar distance
    /// functions like `vec_distance_cosine`) on a connection. No
    /// `sqlite3_load_extension` — the macOS system SQLite omits it, so vec is
    /// compiled in with `-DSQLITE_CORE` (see the `CSqliteVec` target). This is
    /// the sqlite-vec C/C++ guide's "direct call" pattern: `sqlite3_vec_init(db,
    /// NULL, NULL)` (NULL `pApi` is valid under SQLITE_CORE). Called from both
    /// inits. Non-fatal: on failure semantic ranking is skipped and FTS5 (v13)
    /// remains the search fallback.
    private func registerVec(on db: OpaquePointer) {
        let rc = wikifs_vec_register(UnsafeMutableRawPointer(db))
        if rc == 0 {
            DebugLog.store("registerVec: sqlite-vec registered on connection (vec_distance_cosine available)")
        } else {
            DebugLog.store("registerVec: sqlite3_vec_init FAILED rc=\(rc) — semantic search disabled, FTS5 fallback active")
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

    #if DEBUG
    /// Test hook: whether sqlite-vec is registered on this connection — proves the
    /// statically-linked extension (`-DSQLITE_CORE`, no `load_extension`) loaded.
    /// The semantic cosine path still can't RANK under `swift test` (NLEmbedding
    /// is app-gated), but this confirms the scalar functions are available.
    var vecRegisteredForTesting: Bool { isVecAvailable() }
    #endif

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
    /// Phase 5 / v10: the token ALSO folds in `sources`
    /// (`"\(pCount):\(pSum):\(fCount):\(fSum)"`). Without this, adding or
    /// removing a source would NOT advance the anchor and the `sources/` tree would
    /// never refresh. The enumerator treats the anchor as opaque (any non-equal
    /// parseable string forces a re-emit), so the wider format needs no
    /// enumerator change. `sources` may not exist yet on a not-yet-migrated
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
        guard try pages.step() else { return "0:0:0:0:0:0:0:0" }
        let pCount = pages.int(at: 0)
        let pSum = pages.int(at: 1)
        let (fCount, fSum) = sourceCountSum()
        let spVersion = systemPromptVersion()
        let logCount = logRowCount()
        let idxVersion = wikiIndexVersion()
        let smvCount = sourceMarkdownVersionCount()
        return "\(pCount):\(pSum):\(fCount):\(fSum):\(spVersion):\(logCount):\(idxVersion):\(smvCount)"
    }

    /// COUNT/SUM(version) over `sources`, resilient to the table not
    /// existing yet (a read connection opened against a pre-migration DB). On any
    /// failure returns `(0, 0)` so `changeToken()` still answers.
    private func sourceCountSum() -> (Int64, Int64) {
        guard let stmt = try? statement(
            "SELECT COUNT(*), COALESCE(SUM(version), 0) FROM sources;") else {
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

    /// The `source_markdown_versions` table's row COUNT, resilient to the table
    /// not existing yet (a read connection opened against a pre-v8 DB). On any
    /// failure returns `0` so `changeToken()` still answers.
    private func sourceMarkdownVersionCount() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COUNT(*) FROM source_markdown_versions;") else { return 0 }
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
        // COLLATE NOCASE: case-insensitive ASCII folding so [[home]] → "Home".
        let stmt = try statement(
            "SELECT id FROM pages WHERE title = ?1 COLLATE NOCASE ORDER BY id ASC LIMIT 1;")
        defer { stmt.reset() }
        try stmt.bind(title, at: 1)
        guard try stmt.step() else { return nil }
        return PageID(rawValue: stmt.text(at: 0))
    }

    /// Resolve a `[[source:…]]` target to a source id. Case-insensitive; on a
    /// multi-match collision, the most recently updated source wins.
    ///
    /// Two passes: an exact match on `display_name` (falling back to `filename`
    /// when `display_name` is NULL), then — because legacy rows stored
    /// `display_name = filename` WITH the file extension while the canonical cite
    /// target drops it — a scan that matches the query against each candidate's
    /// name with its last extension removed, so `[[source:Some Paper]]` still
    /// resolves a row named `Some Paper.pdf`.
    public func resolveSourceByName(_ displayName: String) throws -> PageID? {
        let exact = try statement("""
        SELECT id FROM sources
        WHERE COALESCE(display_name, filename) = ?1 COLLATE NOCASE
           OR filename = ?1 COLLATE NOCASE
        ORDER BY updated_at DESC LIMIT 1;
        """)
        defer { exact.reset() }
        try exact.bind(displayName, at: 1)
        if try exact.step() { return PageID(rawValue: exact.text(at: 0)) }

        let scan = try statement("""
        SELECT id, COALESCE(display_name, filename) AS name FROM sources
        ORDER BY updated_at DESC;
        """)
        defer { scan.reset() }
        while try scan.step() {
            let name = scan.text(at: 1)
            if (name as NSString).deletingPathExtension.caseInsensitiveCompare(displayName) == .orderedSame {
                return PageID(rawValue: scan.text(at: 0))
            }
        }
        return nil
    }

    public func replaceLinks(from pageID: PageID,
                             parsedLinks: [WikiLinkParser.ParsedLink]) throws {
        // One transaction: wipe this page's outgoing links in BOTH tables, then
        // insert the resolved subsets. Unresolved targets are OMITTED.
        // `INSERT OR IGNORE` collapses duplicate (from,to) pairs.
        // `source_links` inherits the same alias-collapsing behavior as
        // `page_links` via its PRIMARY KEY (from_page_id, to_source_id).
        try exec("BEGIN IMMEDIATE;")
        do {
            let delPage = try statement("DELETE FROM page_links WHERE from_page_id = ?1;")
            delPage.reset()
            try delPage.bind(pageID.rawValue, at: 1)
            _ = try delPage.step()

            let delSource = try statement("DELETE FROM source_links WHERE from_page_id = ?1;")
            delSource.reset()
            try delSource.bind(pageID.rawValue, at: 1)
            _ = try delSource.step()

            let insPage = try statement("""
            INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text)
            VALUES (?1, ?2, ?3);
            """)
            let insSource = try statement("""
            INSERT OR IGNORE INTO source_links (from_page_id, to_source_id, link_text)
            VALUES (?1, ?2, ?3);
            """)
            for link in parsedLinks {
                switch link.linkType {
                case .page:
                    guard let target = try resolveTitleToID(link.target) else { continue }
                    insPage.reset()
                    try insPage.bind(pageID.rawValue, at: 1)
                    try insPage.bind(target.rawValue, at: 2)
                    try insPage.bind(link.linkText, at: 3)
                    _ = try insPage.step()
                case .source:
                    guard let target = try resolveSourceByName(link.target) else { continue }
                    insSource.reset()
                    try insSource.bind(pageID.rawValue, at: 1)
                    try insSource.bind(target.rawValue, at: 2)
                    try insSource.bind(link.linkText, at: 3)
                    _ = try insSource.step()
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// All page→page link rows, ordered by `(from_page_id, to_page_id)`. Read-side
    /// helper for the File Provider projection's `links.jsonl` generator. Not on
    /// the `WikiStore` protocol — like `listAllPagesOrderedByID`, it is a
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
                linkText: stmt.text(at: 2),
                type: "page"
            ))
        }
        return out
    }

    /// All page→source link rows, ordered by `(from_page_id, to_source_id)`. Same
    /// shape as `listAllLinks` so the projection merges them into a unified
    /// `links.jsonl` (page rows first, then source rows).
    public func listAllSourceLinks() throws -> [IndexGenerators.LinkRow] {
        let stmt = try statement("""
        SELECT from_page_id, to_source_id, link_text
        FROM source_links ORDER BY from_page_id, to_source_id;
        """)
        defer { stmt.reset() }
        var out: [IndexGenerators.LinkRow] = []
        while try stmt.step() {
            out.append(IndexGenerators.LinkRow(
                from: stmt.text(at: 0),
                to: stmt.text(at: 1),
                linkText: stmt.text(at: 2),
                type: "source"
            ))
        }
        return out
    }

    /// Pages whose bodies link to `sourceID` via `[[source:…]]` (by source ID —
    /// stable across renames). Used by `renameSource` to find candidate pages for
    /// link rewriting. One query, zero false positives.
    public func sourceLinkingPages(to sourceID: PageID) throws -> [PageID] {
        let stmt = try statement("""
        SELECT DISTINCT from_page_id FROM source_links WHERE to_source_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var out: [PageID] = []
        while try stmt.step() {
            out.append(PageID(rawValue: stmt.text(at: 0)))
        }
        return out
    }

    // MARK: - Sources (Phase 5, renamed v10)

    /// Reject any single dropped file larger than this. A soft guard so the
    /// verbatim-bytes-in-SQLite model can't be handed a multi-GB blob that would
    /// blow up memory on read. 100 MB is generous for notes/PDFs/markdown.
    public static let ingestByteCap = 100 * 1024 * 1024

    /// Add a source's verbatim bytes + metadata as a NEW `sources` row.
    /// `ext` is the lowercased extension (no dot, `""` if none); `mime_type` is
    /// content-authoritative: explicit `mimeType` param → magic-byte sniff → ext
    /// fallback. `byte_size` mirrors `length(content)`. The id is a fresh ULID
    /// (sortable == ingest order). Throws if `data` exceeds `ingestByteCap`.
    /// The optional Zotero provenance is written to `zotero_item_key`/
    /// `zotero_item_title` (NULL when nil).
    @discardableResult
    public func addSource(
        filename: String,
        data: Data,
        zoteroItemKey: String? = nil,
        zoteroItemTitle: String? = nil,
        mimeType: String? = nil
    ) throws -> SourceSummary {
        guard data.count <= Self.ingestByteCap else {
            throw WikiStoreError.unexpected(
                "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
        }
        let id = PageID(rawValue: ULID.generate())
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType
            ?? ContentSniff.mimeType(of: data)
            ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
        let now = Date()
        let displayName = DisplayNameResolver.resolve(
            filename: filename, data: data, mimeType: mime,
            zoteroItemTitle: zoteroItemTitle)

        let stmt = try statement("""
        INSERT INTO sources
          (id, filename, ext, mime_type, byte_size, content, created_at, updated_at, version,
           zotero_item_key, zotero_item_title, display_name)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, 1, ?8, ?9, ?10);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(filename, at: 2)
        try stmt.bind(ext, at: 3)
        if let mime { try stmt.bind(mime, at: 4) }  // else leave NULL
        try stmt.bind(Int64(data.count), at: 5)
        try stmt.bind(data, at: 6)
        try stmt.bind(now.timeIntervalSince1970, at: 7)
        if let zoteroItemKey { try stmt.bind(zoteroItemKey, at: 8) }  // else leave NULL
        if let zoteroItemTitle { try stmt.bind(zoteroItemTitle, at: 9) }  // else leave NULL
        if let displayName { try stmt.bind(displayName, at: 10) }  // else leave NULL
        _ = try stmt.step()

        // Name-only full-text index entry so an un-extracted source is still
        // findable by filename/display name. The body is indexed once processed
        // markdown is appended (appendProcessedMarkdown → upsertSourceSearch).
        upsertSourceSearch(sourceID: id, body: "")

        return SourceSummary(
            id: id, filename: filename, ext: ext, mimeType: mime,
            byteSize: data.count, createdAt: now, updatedAt: now, version: 1,
            zoteroItemKey: zoteroItemKey, zoteroItemTitle: zoteroItemTitle,
            displayName: displayName
        )
    }

    /// All source summaries (NO content blob), most-recent-first for the
    /// management list. `id` is a ULID so `created_at DESC` orders by ingest.
    public func listSources() throws -> [SourceSummary] {
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name
        FROM sources ORDER BY created_at DESC, id DESC;
        """)
        defer { stmt.reset() }
        var out: [SourceSummary] = []
        while try stmt.step() {
            out.append(sourceSummary(from: stmt))
        }
        return out
    }

    /// One source summary (NO content blob). Throws `.notFound` if absent.
    public func getSource(id: PageID) throws -> SourceSummary {
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name
        FROM sources WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return sourceSummary(from: stmt)
    }

    /// The verbatim content bytes for one source, fetched on demand (never
    /// held in the summary list). Throws `.notFound` if absent.
    public func sourceContent(id: PageID) throws -> Data {
        let stmt = try statement("SELECT content FROM sources WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return stmt.blob(at: 0)
    }

    public func deleteSource(id: PageID) throws {
        let stmt = try statement("DELETE FROM sources WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        _ = try stmt.step()
    }

    /// Rename a source's `display_name` and rewrite every
    /// `[[source:<old>…]]` link that points at it. Bumps `sources.version` (→
    /// `changeToken` moves → File Provider refreshes).
    ///
    /// Rewrites only links whose base equals the old display name (or filename
    /// fallback). Filename-form links keep resolving (filename is immutable).
    /// Fragment and alias are preserved byte-for-byte.
    ///
    /// The source UPDATE happens first; then each linking page is updated
    /// individually via the existing `updatePage` + `replaceLinks` methods.
    /// If a crash occurs mid-loop, remaining pages still resolve (old name is
    /// a filename fallback) — the rename is eventually consistent.
    public func renameSource(id: PageID, to newDisplayName: String) throws {
        let old = try getSource(id: id)
        let oldBase = old.displayName ?? old.filename
        guard oldBase != newDisplayName else { return }

        // Update the source row first.
        let stmt = try statement("""
        UPDATE sources SET display_name = ?2, updated_at = ?3, version = version + 1 WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(newDisplayName, at: 2)
        try stmt.bind(Date().timeIntervalSince1970, at: 3)
        _ = try stmt.step()

        // Rewrite links in every page that points at this source.
        for pageID in try sourceLinkingPages(to: id) {
            let page = try getPage(id: pageID)
            guard let rewritten = WikiLinkRewriter.rewriteSourceBase(
                in: page.bodyMarkdown, matching: oldBase,
                to: newDisplayName) else { continue }
            try updatePage(id: pageID, title: page.title, body: rewritten)
            try replaceLinks(from: pageID, parsedLinks: WikiLinkParser.parse(rewritten))
        }

        // The title changed, so re-embed. Use the current processed-markdown HEAD
        // (if any) so the embedding reflects both the new name and the content;
        // embed name-only when there is no markdown yet.
        let headBody = (try? processedMarkdownHead(sourceID: id)?.content) ?? ""
        reembedSource(sourceID: id, body: headBody)
        // The FTS index title tracks the rename too (resolves display_name ?? filename).
        upsertSourceSearch(sourceID: id, body: headBody)
    }

    /// Stamp a source as summarized-into-the-wiki. Idempotent and a no-op
    /// for an unknown id. Called from `wikictl log append --kind ingest --source`.
    public func markSourceIngested(id: PageID) throws {
        let stmt = try statement(
            "UPDATE sources SET ingested_at = ?2 WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(Date().timeIntervalSince1970, at: 2)
        _ = try stmt.step()
    }

    /// IDs of sources the agent has marked ingested — the authoritative
    /// status the UI's "Processed" badge reads.
    public func markedSourceIDs() throws -> Set<String> {
        let stmt = try statement(
            "SELECT id FROM sources WHERE ingested_at IS NOT NULL;")
        defer { stmt.reset() }
        var ids: Set<String> = []
        while try stmt.step() { ids.insert(stmt.text(at: 0)) }
        return ids
    }

    /// All sources as `IndexGenerators.SourceIndexRow`s, ordered by id (ULID ==
    /// ingest order) for the deterministic `indexes/sources.jsonl` generator.
    /// Read-side projection helper (like `listAllPagesOrderedByID`).
    public func listAllSourcesOrderedByID() throws -> [IndexGenerators.SourceIndexRow] {
        let stmt = try statement("""
        SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size,
               s.created_at, s.updated_at, s.version, s.display_name,
               (SELECT 1 FROM source_markdown_versions WHERE file_id = s.id LIMIT 1) IS NOT NULL AS has_markdown
        FROM sources s ORDER BY s.id ASC;
        """)
        defer { stmt.reset() }
        var out: [IndexGenerators.SourceIndexRow] = []
        while try stmt.step() {
            let mime = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
                ? nil : stmt.text(at: 3)
            let displayName = sqlite3_column_type(stmt.handle, 8) == SQLITE_NULL
                ? nil : stmt.text(at: 8)
            out.append(IndexGenerators.SourceIndexRow(
                id: stmt.text(at: 0),
                filename: stmt.text(at: 1),
                ext: stmt.text(at: 2),
                mime: mime,
                byteSize: Int(stmt.int(at: 4)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
                version: Int(stmt.int(at: 7)),
                displayName: displayName,
                hasMarkdown: stmt.int(at: 9) != 0
            ))
        }
        return out
    }

    /// Map the current row of a `sources` SELECT (column order: id,
    /// filename, ext, mime_type, byte_size, created_at, updated_at, version,
    /// zotero_item_key, zotero_item_title, display_name) to a summary.
    /// `mime_type` and the two Zotero columns are read as NULL→nil via the column type.
    private func sourceSummary(from stmt: SQLiteStatement) -> SourceSummary {
        let mime = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            ? nil : stmt.text(at: 3)
        let zoteroItemKey = sqlite3_column_type(stmt.handle, 8) == SQLITE_NULL
            ? nil : stmt.text(at: 8)
        let zoteroItemTitle = sqlite3_column_type(stmt.handle, 9) == SQLITE_NULL
            ? nil : stmt.text(at: 9)
        let displayName = sqlite3_column_type(stmt.handle, 10) == SQLITE_NULL
            ? nil : stmt.text(at: 10)
        return SourceSummary(
            id: PageID(rawValue: stmt.text(at: 0)),
            filename: stmt.text(at: 1),
            ext: stmt.text(at: 2),
            mimeType: mime,
            byteSize: Int(stmt.int(at: 4)),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
            version: Int(stmt.int(at: 7)),
            zoteroItemKey: zoteroItemKey,
            zoteroItemTitle: zoteroItemTitle,
            displayName: displayName
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

    // MARK: - Semantic search (chunk embeddings, v14)

    /// Replace ALL chunks for one document in a chunk table. Deletes existing
    /// rows for `id`, then inserts the new chunk blobs (indexed from 0) inside a
    /// single transaction so a reader never sees a half-populated document.
    /// Generic over the (table, id-column) pair — `page_chunks(page_id)` and
    /// `source_chunks(source_id)` are structurally identical. Internal callers
    /// only; table/column names are never user input.
    private func replaceChunks(table: String, idColumn: String, id: PageID, chunks: [Data]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let del = try statement("DELETE FROM \(table) WHERE \(idColumn) = ?1;")
            defer { del.reset() }
            try del.bind(id.rawValue, at: 1)
            _ = try del.step()
            let ins = try statement("""
            INSERT INTO \(table) (\(idColumn), chunk_idx, embedding) VALUES (?1, ?2, ?3);
            """)
            defer { ins.reset() }
            for (idx, blob) in chunks.enumerated() {
                try ins.bind(id.rawValue, at: 1)
                try ins.bind(Int64(idx), at: 2)
                try ins.bind(blob, at: 3)
                _ = try ins.step()
                ins.reset()
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Store/replace all chunk embeddings for a page. Public so tests + the
    /// embedding maintenance path can drive it directly.
    public func storePageChunks(id: PageID, chunks: [Data]) throws {
        try replaceChunks(table: "page_chunks", idColumn: "page_id", id: id, chunks: chunks)
    }

    // MARK: - Search (hybrid: FTS5 + semantic vec0, fused via RRF)

    /// The single hybrid search flow used by BOTH page and source search, so the
    /// two can never drift apart. FTS5 bm25 — the reliable lexical floor — always
    /// runs; when sqlite-vec + the `NLEmbedding` model are available, a semantic
    /// cosine pass also runs and the two best-first lists are fused with
    /// Reciprocal Rank Fusion (`RankFusion.rrf`), so a row matching BOTH lexical
    /// + semantic outranks one matching only one. Falls back to FTS-only when vec
    /// or the model is unavailable.
    ///
    /// Generic over the result row type; each kind supplies its own FTS query,
    /// its own vec cosine query (both already in best-first order), and the row's
    /// id key path for fusion. The only real difference between pages and sources
    /// is *where the body lives* (inline on `pages` vs the source version chain),
    /// not the search algorithm.
    private func hybridSearch<Row>(
        kind: String,
        query: String,
        limit: Int,
        id: KeyPath<Row, PageID>,
        fts: (_ pool: Int) throws -> [Row],
        semantic: (_ queryBlob: Data, _ pool: Int) throws -> [Row]
    ) throws -> [Row] {
        let pool = max(limit * 2, limit)
        let ftsRows = try fts(pool)
        if isVecAvailable(), let queryBlob = EmbeddingService.embeddingBlob(for: query) {
            DebugLog.store("search[\(kind)]: query=\(query) hybrid (semantic+FTS) → RRF, vec=true")
            let semRows = try semantic(queryBlob, pool)
            return Array(RankFusion.rrf([semRows, ftsRows], id: id).prefix(limit))
        }
        DebugLog.store("search[\(kind)]: query=\(query) FTS-only, vec=false")
        return Array(ftsRows.prefix(limit))
    }

    public func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
        try hybridSearch(
            kind: "pages", query: query, limit: limit, id: \.id,
            fts: { try searchPagesFTS(query: query, limit: $0) },
            semantic: { try searchPagesSemantic(blob: $0, limit: $1) })
    }

    /// Semantic (vec0 cosine) pass over pages. Ranks by each page's BEST-matching
    /// chunk (lowest cosine distance over all its chunks) — a query hits the
    /// specific passage, not a document centroid. Best-first. Only pages with at
    /// least one chunk appear here.
    private func searchPagesSemantic(blob queryBlob: Data, limit: Int) throws -> [WikiPageSummary] {
        let sql = """
        SELECT p.id, p.title, p.updated_at, p.created_at
        FROM (
            SELECT page_id, MIN(vec_distance_cosine(embedding, ?1)) AS best
            FROM page_chunks GROUP BY page_id
        ) r
        JOIN pages p ON p.id = r.page_id
        ORDER BY r.best ASC
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

    public func recomputeMissingEmbeddings() -> Int {
        do {
            let stmt = try statement("""
            SELECT p.id, p.title, p.body_markdown
            FROM pages p
            LEFT JOIN page_chunks pc ON pc.page_id = p.id
            WHERE pc.page_id IS NULL;
            """)
            defer { stmt.reset() }
            var rows: [(id: PageID, title: String, body: String)] = []
            while try stmt.step() {
                rows.append((PageID(rawValue: stmt.text(at: 0)),
                             stmt.text(at: 1), stmt.text(at: 2)))
            }
            return chunkEmbedMissing(kind: "pages", rows,
                                     store: { try storePageChunks(id: $0, chunks: $1) })
        } catch {
            FileHandle.standardError.write(Data("SQLiteWikiStore.recomputeMissingEmbeddings: \(error)\n".utf8))
            return 0
        }
    }

    /// Shared inner of page + source embedding backfill. For each document the
    /// caller has already determined is missing from its chunk table, chunk the
    /// text via `EmbeddingService.chunkedEmbeddings(for:)` and store every chunk
    /// through the caller's store closure. No-op when vec is unavailable;
    /// per-doc failures are logged + skipped so one bad document can't abort the
    /// batch. Returns the count of documents embedded.
    @discardableResult
    private func chunkEmbedMissing(
        kind: String,
        _ rows: [(id: PageID, title: String, body: String)],
        store: (PageID, [Data]) throws -> Void
    ) -> Int {
        guard isVecAvailable() else { return 0 }
        var n = 0
        for (id, title, body) in rows {
            let text = body.isEmpty ? title : "\(title)\n\n\(body)"
            let chunks = EmbeddingService.chunkedEmbeddings(for: text)
            if chunks.isEmpty {
                DebugLog.store("recompute[\(kind)][\(id.rawValue)] no chunks (model unavailable?) bodyLen=\(body.count)")
                continue
            }
            DebugLog.store("recompute[\(kind)][\(id.rawValue)] bodyLen=\(body.count) chunks=\(chunks.count)")
            do { try store(id, chunks); n += 1 }
            catch { DebugLog.store("recompute[\(kind)][\(id.rawValue)] store failed — \(error)") }
        }
        DebugLog.store("recompute[\(kind)]: embedded \(n) of \(rows.count) doc(s)")
        return n
    }

    // MARK: - Full-text search (FTS5/BM25, v13)

    /// Turn free text into a safe FTS5 MATCH expression: keep alphanumerics and
    /// whitespace (FTS5 implicit-ANDs the tokens) and drop operator characters
    /// (`"`, `*`, `(`, `)`, `:`, `^`, …) so user input can't inject query syntax
    /// or throw a parse error. Returns "" when nothing useful remains.
    private static func ftsMatch(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let kept = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Lexical search over pages (FTS5 bm25). External-content over `pages`, so the
    /// join is on rowid. `ORDER BY rank` ranks by bm25 (lowest = best match).
    private func searchPagesFTS(query: String, limit: Int) throws -> [WikiPageSummary] {
        let q = Self.ftsMatch(query)
        guard !q.isEmpty else { return [] }
        let sql = """
        SELECT p.id, p.title, p.updated_at, p.created_at
        FROM pages_fts
        JOIN pages p ON p.rowid = pages_fts.rowid
        WHERE pages_fts MATCH ?1
        ORDER BY rank
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(q, at: 1)
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

    /// Lexical search over sources (FTS5 bm25) via the `source_search` sidecar.
    /// Columns enumerated explicitly — never `SELECT s.*` (the `sources` table has
    /// a `content` BLOB that would shift indices; see `searchSimilarSources`).
    private func searchSourcesFTS(query: String, limit: Int) throws -> [SourceSummary] {
        let q = Self.ftsMatch(query)
        guard !q.isEmpty else { return [] }
        let sql = """
        SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
               s.version, s.zotero_item_key, s.zotero_item_title, s.display_name
        FROM sources_fts
        JOIN source_search ss ON ss.rowid = sources_fts.rowid
        JOIN sources s ON s.id = ss.source_id
        WHERE sources_fts MATCH ?1
        ORDER BY rank
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(q, at: 1)
        try stmt.bind(Int64(limit), at: 2)
        var out: [SourceSummary] = []
        while try stmt.step() { out.append(sourceSummary(from: stmt)) }
        return out
    }

    /// Keep the source full-text sidecar fresh: one row per source holding the
    /// current title (display_name ?? filename) + body. INSERT OR REPLACE fires the
    /// ad+ai triggers, so `sources_fts` updates automatically. Best-effort, like
    /// `reembedSource`. Called from appendProcessedMarkdown + renameSource.
    private func upsertSourceSearch(sourceID: PageID, body: String) {
        guard let nameStmt = try? statement(
            "SELECT display_name, filename FROM sources WHERE id = ?1;") else { return }
        defer { nameStmt.reset() }
        let title: String
        do {
            try nameStmt.bind(sourceID.rawValue, at: 1)
            guard try nameStmt.step() else { return }
            let displayName = sqlite3_column_type(nameStmt.handle, 0) == SQLITE_NULL
                ? nil : nameStmt.text(at: 0)
            title = displayName ?? nameStmt.text(at: 1)
        } catch {
            DebugLog.store("upsertSourceSearch[\(sourceID.rawValue)] name lookup failed — \(error)")
            return
        }
        guard let stmt = try? statement("""
        INSERT OR REPLACE INTO source_search (source_id, title, body) VALUES (?1, ?2, ?3);
        """) else { return }
        defer { stmt.reset() }
        do {
            try stmt.bind(sourceID.rawValue, at: 1)
            try stmt.bind(title, at: 2)
            try stmt.bind(body, at: 3)
            _ = try stmt.step()
        } catch {
            DebugLog.store("upsertSourceSearch[\(sourceID.rawValue)] insert failed — \(error)")
        }
    }

    /// Backfill the FTS indexes for pre-existing content. Pages rebuild from
    /// `pages` via the FTS5 'rebuild' command; sources first backfill `source_search`
    /// from the HEAD of each version chain, then rebuild. Idempotent. Returns counts.
    public func rebuildFTS() -> (pages: Int, sources: Int) {
        do {
            try exec("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');")
        } catch { DebugLog.store("rebuildFTS: pages rebuild failed — \(error)") }
        do {
            let stmt = try statement("""
            INSERT OR IGNORE INTO source_search (source_id, title, body)
            SELECT s.id, COALESCE(s.display_name, s.filename),
                   COALESCE((SELECT smv.content FROM source_markdown_versions smv
                             WHERE smv.file_id = s.id ORDER BY smv.id DESC LIMIT 1), '')
            FROM sources s
            WHERE s.id NOT IN (SELECT source_id FROM source_search);
            """)
            defer { stmt.reset() }
            _ = try stmt.step()
            try exec("INSERT INTO sources_fts(sources_fts) VALUES ('rebuild');")
        } catch { DebugLog.store("rebuildFTS: sources rebuild failed — \(error)") }
        let pages = (Int((try? queryScalarText("SELECT count(*) FROM pages_fts;")) ?? "")) ?? 0
        let sources = (Int((try? queryScalarText("SELECT count(*) FROM sources_fts;")) ?? "")) ?? 0
        return (pages, sources)
    }

    // MARK: - Self-healing search indexes (open-time)

    /// Self-heal: keep the search indexes populated for ALL content (pages +
    /// sources) so search "just works" without a manual reindex. Run on every
    /// writable open (idempotent + near-zero cost when nothing is missing — each
    /// step is either a guarded FTS rebuild or a zero-row scan), which is what
    /// stops the page and source indexes from drifting out of sync again. NOT
    /// run by the read-only File Provider connection (which never writes).
    ///
    /// Order matters: seed native-markdown sources first (so their body flows
    /// into `source_search` and the embedding), then backfill any remaining
    /// `source_search` gaps, rebuild any FTS index that lags its content table,
    /// and finally embed every page/source still missing one.
    private func ensureSearchIndexesPopulated() {
        // 1. Seed a v1 processed-markdown version for markdown-native sources
        //    that have none, so their body is searchable (name-only otherwise).
        //    appendProcessedMarkdown also fires the re-embed + upsertSourceSearch
        //    hooks, so step 2/4 pick these up.
        _ = seedNativeMarkdownSources()

        // 2. Backfill the source full-text sidecar for any source still lacking a
        //    row (PDFs/binaries → name-only). The v13 AFTER-INSERT trigger on
        //    source_search keeps sources_fts in sync.
        do {
            let stmt = try statement("""
            INSERT OR IGNORE INTO source_search (source_id, title, body)
            SELECT s.id, COALESCE(s.display_name, s.filename),
                   COALESCE((SELECT smv.content FROM source_markdown_versions smv
                             WHERE smv.file_id = s.id ORDER BY smv.id DESC LIMIT 1), '')
            FROM sources s;
            """)
            defer { stmt.reset() }
            _ = try stmt.step()
        } catch {
            DebugLog.store("ensureSearchIndexes: source_search backfill failed — \(error)")
        }

        // 3. Rebuild an FTS index only when it lags its content table (a full
        //    rebuild on every open of a healthy DB is wasteful).
        if rowCount("pages") > 0 && rowCount("pages_fts") < rowCount("pages") {
            do { try exec("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');")
            } catch { DebugLog.store("ensureSearchIndexes: pages_fts rebuild failed — \(error)") }
        }
        if rowCount("sources") > 0 && rowCount("sources_fts") < rowCount("sources") {
            do { try exec("INSERT INTO sources_fts(sources_fts) VALUES ('rebuild');")
            } catch { DebugLog.store("ensureSearchIndexes: sources_fts rebuild failed — \(error)") }
        }

        // 4. Chunk embeddings are NOT computed here. NLEmbedding is too slow to
        //    run synchronously at launch (~5 s / 100k chars; minutes for a full
        //    corpus), so embedding backfill runs in the background via
        //    ``backfillMissingEmbeddings()`` (compute off-main, DB writes on the
        //    calling actor). FTS search works immediately; semantic search fills
        //    in as the background job completes.

        DebugLog.store("ensureSearchIndexes: pages_fts=\(rowCount("pages_fts"))/\(rowCount("pages")) sources_fts=\(rowCount("sources_fts"))/\(rowCount("sources")) pageChunks=\(rowCount("page_chunks")) sourceChunks=\(rowCount("source_chunks"))")
    }

    /// Snapshot of pages that have no chunk embeddings yet: `(id, embeddable
    /// text)`. The text is `title\n\nbody` (title-only when the body is empty).
    /// Read on the caller's thread (main); the expensive embedding runs off-main
    /// in ``backfillMissingEmbeddings``.
    public func missingPageEmbeddingWork() -> [(id: PageID, text: String)] {
        var out: [(id: PageID, text: String)] = []
        guard let stmt = try? statement("""
        SELECT p.id, p.title, p.body_markdown
        FROM pages p
        LEFT JOIN page_chunks pc ON pc.page_id = p.id
        WHERE pc.page_id IS NULL;
        """) else { return out }
        defer { stmt.reset() }
        while (try? stmt.step()) ?? false {
            let id = PageID(rawValue: stmt.text(at: 0))
            let title = stmt.text(at: 1)
            let body = stmt.text(at: 2)
            out.append((id, body.isEmpty ? title : "\(title)\n\n\(body)"))
        }
        return out
    }

    /// Snapshot of sources that have no chunk embeddings yet: `(id, embeddable
    /// text)`. The text is the source's title + its processed-markdown HEAD body
    /// (title-only for un-extracted PDFs/binaries). Mirrors
    /// ``missingPageEmbeddingWork``.
    public func missingSourceEmbeddingWork() -> [(id: PageID, text: String)] {
        var out: [(id: PageID, text: String)] = []
        guard let stmt = try? statement("""
        SELECT s.id, COALESCE(s.display_name, s.filename),
               (SELECT content FROM source_markdown_versions smv
                WHERE smv.file_id = s.id ORDER BY smv.id DESC LIMIT 1)
        FROM sources s
        LEFT JOIN source_chunks sc ON sc.source_id = s.id
        WHERE sc.source_id IS NULL;
        """) else { return out }
        defer { stmt.reset() }
        while (try? stmt.step()) ?? false {
            let id = PageID(rawValue: stmt.text(at: 0))
            let title = stmt.text(at: 1)
            let body = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL ? "" : stmt.text(at: 2)
            out.append((id, body.isEmpty ? title : "\(title)\n\n\(body)"))
        }
        return out
    }

    /// Seed the first processed-markdown version for markdown-native sources that
    /// lack one, by decoding their raw bytes as UTF-8 — the same lazy seeding the
    /// UI used to do on first view. Returns the count seeded. Best-effort.
    private func seedNativeMarkdownSources() -> Int {
        var seeded = 0
        guard let stmt = try? statement("""
        SELECT s.id FROM sources s
        WHERE s.mime_type LIKE 'text/%'
          AND NOT EXISTS (SELECT 1 FROM source_markdown_versions smv WHERE smv.file_id = s.id);
        """) else { return 0 }
        defer { stmt.reset() }
        while (try? stmt.step()) ?? false {
            let id = PageID(rawValue: stmt.text(at: 0))
            guard let bytes = try? sourceContent(id: id),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            _ = try? appendProcessedMarkdown(sourceID: id, content: text, origin: "source", note: nil)
            seeded += 1
        }
        if seeded > 0 { DebugLog.store("seedNativeMarkdownSources: seeded \(seeded) source(s)") }
        return seeded
    }

    /// `SELECT count(*) FROM <table>` as an Int (0 on any error). `<table>` is
    /// interpolated from trusted internal callers only — never user input.
    private func rowCount(_ table: String) -> Int {
        (Int((try? queryScalarText("SELECT count(*) FROM \(table);")) ?? "")) ?? 0
    }

    // MARK: - Source embeddings (v12, semantic source search)

    /// Store/replace all chunk embeddings for a source. Public so tests + the
    /// embedding maintenance path can drive it directly. Mirrors
    /// `storePageChunks` — both route through the generic `replaceChunks`.
    public func storeSourceChunks(id: PageID, chunks: [Data]) throws {
        try replaceChunks(table: "source_chunks", idColumn: "source_id", id: id, chunks: chunks)
    }

    /// Semantic search over sources. Tries cosine ranking on `source_embeddings`
    /// first; falls back to a `LIKE` filename/display-name match when sqlite-vec
    /// or the embedding model is unavailable. Mirrors `searchSimilar`.
    ///
    /// Columns are enumerated explicitly — NEVER `SELECT s.*`: the physical
    /// `sources` table (originally `ingested_files`, v2) has a `content` BLOB
    /// positioned between `byte_size` and `created_at`; `SELECT s.*` would emit
    /// it at index 5 and shift every later column, so `sourceSummary(from:)`
    /// (which reads index 5 as `created_at`) would dereference the BLOB as a
    /// Double. `listSources()` already names its columns for the same reason.
    public func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary] {
        try hybridSearch(
            kind: "sources", query: query, limit: limit, id: \.id,
            fts: { try searchSourcesFTS(query: query, limit: $0) },
            semantic: { try searchSourcesSemantic(blob: $0, limit: $1) })
    }

    /// Semantic (vec0 cosine) pass over sources. Ranks by each source's
    /// BEST-matching chunk (lowest cosine distance over all its chunks) — a
    /// query hits the specific passage, not a document centroid. Best-first.
    /// Only sources with at least one chunk appear here.
    private func searchSourcesSemantic(blob queryBlob: Data, limit: Int) throws -> [SourceSummary] {
        let sql = """
        SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
               s.version, s.zotero_item_key, s.zotero_item_title, s.display_name
        FROM (
            SELECT source_id, MIN(vec_distance_cosine(embedding, ?1)) AS best
            FROM source_chunks GROUP BY source_id
        ) r
        JOIN sources s ON s.id = r.source_id
        ORDER BY r.best ASC
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(queryBlob, at: 1)
        try stmt.bind(Int64(limit), at: 2)
        var out: [SourceSummary] = []
        while try stmt.step() { out.append(sourceSummary(from: stmt)) }
        return out
    }

    /// Backfill `source_chunks` for sources that lack any. Chunk-embeds each
    /// source on its processed-markdown HEAD body + name; name-only when no
    /// processed markdown exists yet (un-extracted PDF / binary file). Mirrors
    /// `recomputeMissingEmbeddings`. No-op (returns 0) when vec is unavailable.
    public func recomputeMissingSourceEmbeddings() -> Int {
        do {
            let stmt = try statement("""
            SELECT s.id, s.display_name, s.filename,
                   (SELECT content FROM source_markdown_versions smv
                    WHERE smv.file_id = s.id ORDER BY smv.id DESC LIMIT 1) AS body
            FROM sources s
            LEFT JOIN source_chunks sc ON sc.source_id = s.id
            WHERE sc.source_id IS NULL;
            """)
            defer { stmt.reset() }
            var rows: [(id: PageID, title: String, body: String)] = []
            while try stmt.step() {
                let id = PageID(rawValue: stmt.text(at: 0))
                let displayName = sqlite3_column_type(stmt.handle, 1) == SQLITE_NULL
                    ? nil : stmt.text(at: 1)
                let filename = stmt.text(at: 2)
                let body = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
                    ? "" : stmt.text(at: 3)
                rows.append((id, displayName ?? filename, body))
            }
            return chunkEmbedMissing(kind: "sources", rows,
                                     store: { try storeSourceChunks(id: $0, chunks: $1) })
        } catch {
            FileHandle.standardError.write(Data("SQLiteWikiStore.recomputeMissingSourceEmbeddings: \(error)\n".utf8))
            return 0
        }
    }

    /// Best-effort re-chunk + re-embed of a source after its content/name
    /// changed. No-op when vec is unavailable (the version still commits; the
    /// chunks are backfilled by `recomputeMissingSourceEmbeddings` on the next
    /// open). Called from `appendProcessedMarkdown` (covers extraction seeding,
    /// raw-text seeding, user edits, and revert) and `renameSource`.
    private func reembedSource(sourceID: PageID, body: String) {
        guard isVecAvailable() else { return }
        guard let nameStmt = try? statement(
            "SELECT display_name, filename FROM sources WHERE id = ?1;") else { return }
        defer { nameStmt.reset() }
        do {
            try nameStmt.bind(sourceID.rawValue, at: 1)
            guard try nameStmt.step() else { return }
            let displayName = sqlite3_column_type(nameStmt.handle, 0) == SQLITE_NULL
                ? nil : nameStmt.text(at: 0)
            let filename = nameStmt.text(at: 1)
            let title = displayName ?? filename
            let text = body.isEmpty ? title : "\(title)\n\n\(body)"
            let chunks = EmbeddingService.chunkedEmbeddings(for: text)
            if chunks.isEmpty {
                DebugLog.store("reembedSource[\(sourceID.rawValue)] no chunks (model unavailable?) bodyLen=\(body.count)")
                return
            }
            DebugLog.store("reembedSource[\(sourceID.rawValue)] title=\(title) bodyLen=\(body.count) chunks=\(chunks.count)")
            try? storeSourceChunks(id: sourceID, chunks: chunks)
        } catch {
            FileHandle.standardError.write(Data("SQLiteWikiStore.reembedSource: \(error)\n".utf8))
        }
    }

    // MARK: - Processed markdown versions (v8, renamed v10)

    /// Read one `source_markdown_versions` row from the current statement position
    /// (column order: id, file_id, parent_id, content, origin, note, created_at).
    private func sourceMarkdownVersion(from stmt: SQLiteStatement) -> SourceMarkdownVersion {
        let parentID: PageID? = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL
            ? nil : PageID(rawValue: stmt.text(at: 2))
        let note: String? = sqlite3_column_type(stmt.handle, 5) == SQLITE_NULL
            ? nil : stmt.text(at: 5)
        return SourceMarkdownVersion(
            id: PageID(rawValue: stmt.text(at: 0)),
            sourceID: PageID(rawValue: stmt.text(at: 1)),
            parentID: parentID,
            content: stmt.text(at: 3),
            origin: stmt.text(at: 4),
            note: note,
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 6))
        )
    }

    public func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion? {
        guard let stmt = try? statement("""
        SELECT id, file_id, parent_id, content, origin, note, created_at
        FROM source_markdown_versions WHERE file_id = ?1 ORDER BY id DESC LIMIT 1;
        """) else { return nil }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        guard try stmt.step() else { return nil }
        return sourceMarkdownVersion(from: stmt)
    }

    public func hasProcessedMarkdown(sourceID: PageID) throws -> Bool {
        guard let stmt = try? statement("""
        SELECT 1 FROM source_markdown_versions WHERE file_id = ?1 LIMIT 1;
        """) else { return false }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        return try stmt.step()
    }

    public func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion] {
        guard let stmt = try? statement("""
        SELECT id, file_id, parent_id, content, origin, note, created_at
        FROM source_markdown_versions WHERE file_id = ?1 ORDER BY id DESC;
        """) else { return [] }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var out: [SourceMarkdownVersion] = []
        while try stmt.step() {
            out.append(sourceMarkdownVersion(from: stmt))
        }
        return out
    }

    /// All processed markdown heads keyed by sourceID. Returns empty dict when
    /// the table doesn't exist yet (pre-migration read connection) so the caller
    /// never errors — the sources list simply has no markdown siblings.
    /// Single GROUP BY query avoids N+1 across the full source enumeration.
    public func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion] {
        guard let stmt = try? statement("""
        SELECT id, file_id, parent_id, content, origin, note, created_at
        FROM source_markdown_versions
        WHERE id IN (SELECT MAX(id) FROM source_markdown_versions GROUP BY file_id);
        """) else { return [:] }
        defer { stmt.reset() }
        var result: [String: SourceMarkdownVersion] = [:]
        while try stmt.step() {
            let version = sourceMarkdownVersion(from: stmt)
            result[version.sourceID.rawValue] = version
        }
        return result
    }

    @discardableResult
    public func appendProcessedMarkdown(sourceID: PageID, content: String,
                                        origin: String, note: String?) throws -> SourceMarkdownVersion {
        let id = PageID(rawValue: ULID.generate())
        let parentID = try processedMarkdownHead(sourceID: sourceID)?.id
        let now = Date()

        let stmt = try statement("""
        INSERT INTO source_markdown_versions
          (id, file_id, parent_id, content, origin, note, created_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(sourceID.rawValue, at: 2)
        if let parentID { try stmt.bind(parentID.rawValue, at: 3) }
        try stmt.bind(content, at: 4)
        try stmt.bind(origin, at: 5)
        if let note { try stmt.bind(note, at: 6) }
        try stmt.bind(now.timeIntervalSince1970, at: 7)
        _ = try stmt.step()

        // Re-embed the source from the just-written content + its name so content
        // search finds it immediately (covers extraction seeding, raw-text
        // seeding, user edits, and revert — revert routes through this method).
        reembedSource(sourceID: sourceID, body: content)
        // Keep the FTS5 source-search index fresh (title + head body) so keyword
        // search finds the new content immediately. Best-effort, like reembedSource.
        upsertSourceSearch(sourceID: sourceID, body: content)

        return SourceMarkdownVersion(
            id: id, sourceID: sourceID, parentID: parentID,
            content: content, origin: origin, note: note, createdAt: now
        )
    }

    @discardableResult
    public func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion {
        // Read the target version's content — must exist and belong to sourceID.
        guard let stmt = try? statement("""
        SELECT content FROM source_markdown_versions WHERE id = ?1 AND file_id = ?2;
        """) else {
            throw WikiStoreError.unexpected("source_markdown_versions table not found")
        }
        defer { stmt.reset() }
        try stmt.bind(versionID.rawValue, at: 1)
        try stmt.bind(sourceID.rawValue, at: 2)
        guard try stmt.step() else {
            throw WikiStoreError.notFound(versionID)
        }
        let oldContent = stmt.text(at: 0)

        // Append a new version whose content copies the target. History preserved.
        return try appendProcessedMarkdown(
            sourceID: sourceID, content: oldContent,
            origin: "revert", note: "revert to \(versionID.rawValue)"
        )
    }
}
