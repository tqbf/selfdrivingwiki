import Foundation
import SQLite3
import UniformTypeIdentifiers
import Darwin
import CSqliteVec
import CryptoKit

/// SQLite-backed `WikiStore`. Hand-wraps the system `SQLite3` C API — no
/// third-party dependency (per the BRINGUP decision). Owns one serial
/// connection with a prepared-statement cache.
///
/// **Concurrency contract (graph-model Phase 0):** every public entry point is
/// method-atomic — it acquires `lock` (recursive, so public methods may compose)
/// for its whole body. That closes the two app-level races `FULLMUTEX` cannot:
/// two callers of byte-identical SQL sharing one cached `sqlite3_stmt*` (the
/// historical `String(cString:)` crash), and unguarded mutation of the
/// `statements` dictionary. The store is therefore safe to *call* from any
/// thread; UI writes still flow through the `@MainActor` model because they
/// mutate observable state, and off-main reads should prefer `WikiReadPool`
/// (separate snapshot connections) so they never contend with the writer.
/// See `plans/graph-model-and-versioning.md` §8 and
/// `.claude/skills/sqlite-concurrency/SKILL.md`.
public final class SQLiteWikiStore: WikiStore, @unchecked Sendable {
    private let db: OpaquePointer
    /// Prepared-statement cache keyed by SQL text; reused via `reset()`.
    private var statements: [String: SQLiteStatement] = [:]
    /// Serializes whole method bodies (bind → step → column reads) against the
    /// single connection. Recursive because public methods call each other
    /// (`renameSource` → `updatePage` → …). Guarded state: `statements`,
    /// `transactionDepth`, every `sqlite3_*` call on `db`, and connection-global
    /// values like `sqlite3_changes`.
    private let lock = NSRecursiveLock()
    /// Current `withTransaction` nesting depth. 0 = no open transaction.
    /// Only ever touched while holding `lock`.
    private var transactionDepth = 0
    /// Guards against double-close (`close()` then `deinit`). `sqlite3_close`
    /// on an already-closed handle returns SQLITE_MISUSE; the flag keeps it clean.
    private var closed = false
    /// `mutate()`'s OWN nesting depth — distinct from `transactionDepth`.
    /// `mutate()` flushes its buffered event to `eventBus` only when this returns
    /// to 0 (the outermost `mutate()` call), AFTER releasing the lock, so no
    /// handler ever runs under the lock and subscribers always read committed
    /// state. Public methods compose (the recursive lock exists for this), so
    /// `mutate`-within-`mutate` nesting is real; only the outermost emits.
    /// Only ever touched while holding `lock`.
    private var mutateDepth = 0
    /// Per-wiki resource-change bus (set once by the app wiring; `nil` in
    /// `wikictl`, where every emit is a silent no-op). Guarded by `lock` via the
    /// computed ``eventBus`` accessors.
    private var _eventBus: WikiEventBus?
    /// Per-wiki resource-change bus. Set once during wiki open (main actor) and
    /// read inside `mutate()` (under `lock`); both accessors take the lock so the
    /// `@unchecked Sendable` store never exposes a torn read/write.
    public var eventBus: WikiEventBus? {
        get { lock.lock(); defer { lock.unlock() }; return _eventBus }
        set { lock.lock(); defer { lock.unlock() }; _eventBus = newValue }
    }

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
        guard !closed else { return }
        closed = true
        statements.removeAll()
        Self.checkpointAndClose(db)
    }

    /// Explicitly close the database connection. After calling this, the store
    /// must not be used further. `deinit` normally handles this, but ARC does not
    /// guarantee deinit timing — callers that need a second raw connection on the
    /// same file (e.g. tests inserting corrupt data) must call this to quiesce the
    /// WAL before opening the new connection.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        statements.removeAll()
        Self.checkpointAndClose(db)
    }

    /// Force-checkpoint the WAL to zero length, then close. `sqlite3_close`'s
    /// own internal checkpoint can race with a new connection opening the same
    /// file under CI load, intermittently producing SQLITE_ERROR on the new
    /// connection's writes (#223, #234). An explicit TRUNCATE checkpoint
    /// flushes all committed frames into the main file first so `sqlite3_close`
    /// has nothing left to do. Harmless on non-WAL / read-only connections
    /// (the pragma is a no-op and the return value is unchecked).
    nonisolated private static func checkpointAndClose(_ db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
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
            try createFreshSchemaV20()
            return
        }
        try migrate(from: &version)
    }

    /// Build the complete current (v20) schema for a fresh database in one
    /// consolidated block. MUST stay schema-identical to the end state of
    /// `migrate(from:)`; the `freshFastPathMatchesStepwiseLadder` test enforces
    /// that by forcing a fresh db through the ladder and comparing. Legacy index
    /// names (`ingested_files_created`, `file_markdown_versions_file`) are
    /// reproduced verbatim — they survive the table renames in the ladder, so a
    /// fresh db must match.
    ///
    /// v20 (graph-model Phase 1): moves source content out of `sources.content`
    /// into immutable, content-addressed `blobs` (§4.1), an append-only
    /// `source_versions` chain (§4.2), a PROV-DM `agents`/`activities`
    /// provenance substrate (§4.7), and a single mutable `refs` pointer table
    /// (§4.3). The `sources` table keeps `byte_size`/`mime_type`/`content_hash`
    /// as denormalized mirrors of the active version's blob (deviation from
    /// §4.2, flagged in the plan's Risks) to minimize blast radius — every
    /// Phase 1 source has exactly one version, so the mirror never drifts.
    private func createFreshSchemaV20() throws {
        // Core page model + attachments/links.
        try exec("""
        CREATE TABLE pages (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,
            created_by TEXT,
            last_edited_by TEXT
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
        // zotero columns (v9) + display_name (v10) + content_hash (v19).
        // v20 (graph-model Phase 1): the `content` column is GONE — bytes live
        // in immutable `blobs`, reached through the `source_versions` chain and
        // the `refs` pointer (see the objects tables below). `byte_size`,
        // `mime_type`, and `content_hash` stay as denormalized mirrors of the
        // active version's blob (minimize blast radius; single version per
        // source in Phase 1).
        try exec("""
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT,
            byte_size INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,
            ingested_at REAL,
            zotero_item_key TEXT,
            zotero_item_title TEXT,
            display_name TEXT,
            content_hash TEXT,
            role TEXT NOT NULL DEFAULT 'primary'
        );
        """)
        try exec("CREATE INDEX ingested_files_created ON sources(created_at);")
        try exec("CREATE INDEX sources_content_hash ON sources(content_hash);")

        // Processed-markdown version chain (v8, v10 rename). The legacy index
        // name `file_markdown_versions_file` survives the table rename.
        try exec("""
        CREATE TABLE source_markdown_versions (
            id                TEXT PRIMARY KEY,
            file_id           TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            parent_id         TEXT,
            origin            TEXT NOT NULL,
            note              TEXT,
            created_at        REAL NOT NULL,
            activity_id       TEXT REFERENCES activities(id),
            source_version_id TEXT,
            blob_hash         TEXT REFERENCES blobs(hash),
            mime_type         TEXT NOT NULL DEFAULT 'text/markdown',
            technique         TEXT
        );
        """)
        try exec("""
        CREATE INDEX file_markdown_versions_file
            ON source_markdown_versions(file_id, id);
        """)

        // source_links with cascade (v10 create, v11 cascade rebuild, v22
        // role/pin rebuild). v22 turns this into a rowid table (drops the
        // composite PRIMARY KEY) and adds `role` + `pinned_version_id` per §4.4
        // (edges — roles and pins). The `source_links_edge` unique index on
        // `(from_page_id, to_source_id, role, COALESCE(pinned_version_id, ''))`
        // restores the v11 dedup semantics: SQLite treats NULLs as distinct in
        // unique constraints, so the COALESCE collapses duplicate *unpinned*
        // links to one source exactly as the old composite PK did.
        try exec("""
        CREATE TABLE source_links (
            from_page_id TEXT NOT NULL REFERENCES pages(id),
            to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            link_text    TEXT NOT NULL,
            role         TEXT NOT NULL DEFAULT 'cite',
            pinned_version_id TEXT
        );
        """)
        try exec("""
        CREATE UNIQUE INDEX source_links_edge
            ON source_links(from_page_id, to_source_id, role,
                            COALESCE(pinned_version_id, ''));
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

        try exec("""
        CREATE TABLE embedding_meta (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            embedder TEXT NOT NULL
        );
        """)
        try exec("INSERT INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")

        // Bookmark nodes: the user-defined Bookmarks sidebar tree — folders, page
        // refs, and source refs.
        try exec("""
        CREATE TABLE bookmark_nodes (
            id            TEXT PRIMARY KEY,
            parent_id     TEXT REFERENCES bookmark_nodes(id) ON DELETE CASCADE,
            position      INTEGER NOT NULL DEFAULT 0,
            kind          TEXT NOT NULL,
            label         TEXT,
            target_id     TEXT,
            created_at    REAL NOT NULL DEFAULT 0,
            updated_at    REAL NOT NULL DEFAULT 0
        );
        """)
        try exec("CREATE INDEX bookmark_nodes_parent ON bookmark_nodes(parent_id, position);")

        // v18 is a data-only step (name sanitization) — a fresh DB has no rows
        // to sweep, so the fast path just stamps the version. v19 adds
        // content_hash (above, in the table def) — also no rows to backfill.

        // v20 (graph-model Phase 1): the objects & versioning substrate (§4.1–
        // 4.3). `sources.content` is already absent from the table def above;
        // these five tables are the immutable storage it migrates into. Shared
        // with the v19→20 migration step so the fresh path and the ladder stay
        // byte-identical (`freshFastPathMatchesStepwiseLadder`).
        try createObjectsTablesV20()

        // v21 (graph-model Phase 2): the four new `source_markdown_versions`
        // columns are already in the fresh-path table def above; no legacy rows
        // to backfill on a brand-new DB. Shared with the v20→21 migration step.

        // v22 (graph-model Phase 4 foundation): `sources.role` is already in the
        // fresh-path table def above, and `source_links` is already rebuilt to
        // the §4.4 rowid + role/pin shape. No legacy rows to backfill on a
        // brand-new DB. Shared with the v21→22 migration step.

        // v23 (graph-model Phase 5): data-only link canonicalization sweep —
        // no schema change, and a fresh DB has no rows to sweep. Shared with
        // the v22→23 migration step.
        //
        // v24: reserved slot, never stamped. The `source_markdown_versions.content`
        // drop lands as v26 below — appended at the top (not inserted here) so a
        // DB already at v25 actually runs it (`version < 24` would skip v25 DBs).
        //
        // v25 (issue #119 phase 1): persisted chat history — `chats` +
        // `chat_messages`. Purely additive. `IF NOT EXISTS` (idempotent).
        try createChatTablesV23()

        // v28 (issue #245): semantic + FTS search over chats — `chat_chunks` +
        // `chat_search` + `chats_fts`. Purely additive. Shared with the v27→28
        // migration step so the fresh path and ladder stay schema-identical.
        try createChatSearchTables()

        // v26 (graph-model Phase 2 close-out): drops the dead
        // `source_markdown_versions.content` column — the body lives only in
        // `blobs` (CAS-only). The fresh path omits the column entirely (nothing
        // to drop); the ladder drops it in the v25→26 step.
        //
        // v27 (issue #242): bookmark nodes gain `created_at`/`updated_at`
        // timestamps so the UI can show "date added"/"date updated" (companion
        // sort/filter in #241). The fresh-path table def already includes both
        // columns; a brand-new DB has no rows to backfill. Shared with the
        // v26→27 migration step.
        //
        // v29 (remove-readonly-chat-mode): data-only — rewrite any legacy
        // `kind = 'ask'` chat rows to `'edit'`. The fresh path has no chat rows,
        // so the UPDATE is a no-op; the ladder runs it in the v28→29 step.
        //
        // v30 (W0 — page versioning, PR #312): `page_versions` table + the
        // `refs` CHECK constraint (already in `createObjectsTablesV20` above).
        // The fresh path has no pages to seed; the ladder seeds root versions
        // per existing page in the v29→30 step.
        try createPageVersionsV30()
        try exec("PRAGMA user_version=30;")

        // v31 (W1 — workspaces, PR #312): durable workspace substrate for
        // multi-writer ingestion. Purely additive (`IF NOT EXISTS`); a fresh
        // DB has no workspaces to seed.
        try createWorkspacesV31()
        try exec("PRAGMA user_version=31;")

        // v32 (W3 — conflict resolution, PR #312): `workspace_conflicts`
        // table for persisting per-page conflict details when a workspace is
        // parked as `conflicted`. Purely additive.
        try createWorkspaceConflictsV32()
        try exec("PRAGMA user_version=32;")

        // v33 (#131 — provenance frontmatter): adds `created_by`,
        // `last_edited_by` to `pages` and `technique` to
        // `source_markdown_versions`. The columns are already in the fresh
        // schema's CREATE TABLE above, so this just advances the version stamp.
        try exec("PRAGMA user_version=33;")

        // v34 (#multi-writer-hardening Phase 3 — head-ref invariant): a fresh
        // DB has no pages to backfill; the version stamp is needed so the
        // stepwise ladder's v33→34 step is a no-op when re-run. The
        // `createPage` ref-seeding change ensures all future-created pages
        // have refs from birth.
        try exec("PRAGMA user_version=34;")

        // v35 (#multi-writer-hardening Phase 5 — created-page staging):
        // `workspace_refs.version_id` is nullable and `blob_hash` + `title`
        // columns are present so created pages can be staged without a phantom
        // `pages` row. A fresh DB has no workspaces, so this is a version
        // stamp only — `createWorkspacesV31` above already uses the new shape.
        try exec("PRAGMA user_version=35;")
    }

    /// Create the five graph-model objects tables (§4.1–4.3): `blobs`,
    /// `agents`, `activities`, `source_versions`, `refs`. Called by both the
    /// fresh-schema fast path and the v19→20 migration step so the two stay
    /// schema-identical. Idempotent in spirit but NOT guarded — callers ensure
    /// the tables do not yet exist (fresh path: brand-new DB; migration: this
    /// step runs once at v19).
    private func createObjectsTablesV20() throws {
        // `IF NOT EXISTS`: idempotent. The fresh path calls this on a brand-new
        // DB (no tables), but a DB rewound from v20 for testing already has them.
        try exec("""
        CREATE TABLE IF NOT EXISTS blobs (
            hash       TEXT PRIMARY KEY,
            byte_size  INTEGER NOT NULL,
            content    BLOB NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS agents (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            name         TEXT NOT NULL,
            version      TEXT,
            external_ref TEXT
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS activities (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            agent_id     TEXT NOT NULL REFERENCES agents(id),
            plan         TEXT,
            external_ref TEXT,
            started_at   REAL NOT NULL,
            ended_at     REAL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS source_versions (
            id                TEXT PRIMARY KEY,
            source_id         TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            parent_id         TEXT,
            blob_hash         TEXT REFERENCES blobs(hash),
            mime_type         TEXT,
            original_path     TEXT,
            thumbnail_hash    TEXT REFERENCES blobs(hash),
            activity_id       TEXT REFERENCES activities(id),
            external_identity TEXT,
            fetched_at        REAL NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS source_versions_source ON source_versions(source_id, id);")
        // UNIQUE partial index for byteless-source dedup: keeps the
        // external_identity lookup O(log n) AND provides a DB-level backstop
        // against the SELECT-then-INSERT TOCTOU (a concurrent wikictl writer
        // could pass the dedup check and both insert). NULL external_identity
        // values are not equal in SQLite, so multiple NULLs coexist fine.
        // Created here (fresh DB) and re-asserted idempotently in
        // ensureSearchIndexesPopulated so existing v21 DBs pick it up too.
        try exec("""
        CREATE UNIQUE INDEX IF NOT EXISTS source_versions_byteless_eid
            ON source_versions(external_identity) WHERE blob_hash IS NULL;
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS refs (
            kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
            owner_id   TEXT NOT NULL,
            version_id TEXT NOT NULL,
            generation INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL,
            PRIMARY KEY (kind, owner_id)
        );
        """)
    }

    /// Create the `page_versions` table (v30, W0 — PR #312). Mirrors the
    /// `source_versions` pattern: append-only, ULID-ordered chain, blob-backed
    /// body, PROV activity linkage. Called by both the fresh-schema fast path
    /// and the v29→30 migration step so the two stay schema-identical
    /// (`freshFastPathMatchesStepwiseLadder`). `IF NOT EXISTS`: idempotent so a
    /// DB rewound for testing already has it.
    private func createPageVersionsV30() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS page_versions (
            id               TEXT PRIMARY KEY,
            page_id          TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
            parent_id        TEXT,
            merge_parent_id  TEXT,
            blob_hash        TEXT NOT NULL REFERENCES blobs(hash),
            title            TEXT NOT NULL,
            activity_id      TEXT REFERENCES activities(id),
            saved_at         REAL NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS page_versions_page ON page_versions(page_id, id);")
    }

    /// Create the workspace tables (v31, W1 — PR #312). `workspaces` holds the
    /// durable, named speculative branch for a long-running ingestion;
    /// `workspace_refs` is the per-page overlay (the workspace's current head
    /// + the base version observed at first write, for three-way merge).
    ///
    /// v35 (multi-writer-hardening Phase 5): `version_id` is now nullable and
    /// `blob_hash` + `title` columns are added so created pages can be staged
    /// entirely inside `workspace_refs` — no phantom `pages` row on main until
    /// merge. The staging invariant:
    /// - Existing page: `version_id` set, `blob_hash` + `title` nil.
    /// - Created page: `version_id` nil, `blob_hash` + `title` set.
    ///
    /// Called by both the fresh-schema fast path and the v30→31 migration step
    /// so the two stay schema-identical. `IF NOT EXISTS`: idempotent.
    private func createWorkspacesV31() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS workspaces (
            id               TEXT PRIMARY KEY,
            name             TEXT,
            status           TEXT NOT NULL DEFAULT 'open',
            activity_id      TEXT REFERENCES activities(id),
            index_body       TEXT,
            index_base_version TEXT,
            created_at       REAL NOT NULL,
            updated_at       REAL NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS workspace_refs (
            workspace_id  TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            kind           TEXT NOT NULL CHECK (kind = 'page-content'),
            owner_id       TEXT NOT NULL,
            base_version_id TEXT,
            version_id     TEXT,
            blob_hash      TEXT REFERENCES blobs(hash),
            title          TEXT,
            updated_at     REAL NOT NULL,
            PRIMARY KEY (workspace_id, kind, owner_id)
        );
        """)
    }

    /// Create the `workspace_conflicts` table (v32, W3 — PR #312). Stores
    /// per-page conflict details when a workspace is parked as `conflicted`,
    /// so they can be queried and resolved. Called by both the fresh-schema
    /// fast path and the v31→32 migration step. `IF NOT EXISTS`: idempotent.
    private func createWorkspaceConflictsV32() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS workspace_conflicts (
            workspace_id    TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            page_id         TEXT NOT NULL,
            base_version_id TEXT,
            main_version_id TEXT,
            ws_version_id   TEXT NOT NULL,
            created_at      REAL NOT NULL,
            PRIMARY KEY (workspace_id, page_id)
        );
        """)
    }

    /// Create the two persisted-chat-history tables (issue #119 phase 1):
    /// `chats` (one row per chat) and `chat_messages` (one row per
    /// persistable `AgentEvent`, `event_json` verbatim). Called by both the
    /// fresh-schema fast path and the v23→25 migration step so the two stay
    /// schema-identical (`freshFastPathMatchesStepwiseLadder`). `IF NOT
    /// EXISTS`, same rationale as `createObjectsTablesV20`: idempotent so a
    /// DB rewound to a pre-v25 `user_version` for testing (already having
    /// these tables from its original fresh-schema creation) can still run
    /// this step without a "table already exists" error. See
    /// `plans/chat-and-persistence.md`.
    private func createChatTablesV23() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS chats (
            id         TEXT PRIMARY KEY,
            kind       TEXT NOT NULL,
            title      TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS chats_updated ON chats(updated_at);")
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id         TEXT PRIMARY KEY,
            chat_id    TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            seq        INTEGER NOT NULL,
            role       TEXT NOT NULL,
            event_json TEXT NOT NULL,
            text       TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        """)
        try exec("CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_seq ON chat_messages(chat_id, seq);")
    }

    /// Create the chat-search tables (issue #245): `chat_chunks` (per-chunk
    /// cosine embeddings, mirroring `page_chunks`/`source_chunks`) and the
    /// `chat_search` FTS sidecar + `chats_fts` external-content index (mirroring
    /// `source_search`/`sources_fts`). Called by both the fresh-schema fast path
    /// and the v27→28 migration step so the two stay schema-identical
    /// (`freshFastPathMatchesStepwiseLadder`). `IF NOT EXISTS` — idempotent so a
    /// DB rewound to a pre-v28 `user_version` for testing can still run it.
    ///
    /// `chat_search` is one row per chat (title + concatenated message text) —
    /// the chat body is multi-row (spread across `chat_messages`), so like
    /// sources it needs a sidecar rather than the inline-`pages` external-content
    /// pattern. Kept fresh by `appendChatMessages`/`renameChat`.
    private func createChatSearchTables() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_chunks (
            chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (chat_id, chunk_idx)
        ) WITHOUT ROWID;
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_search (
            chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
            title   TEXT NOT NULL,
            body    TEXT NOT NULL
        );
        """)
        // FTS5/BM25 (v28): external-content over `chat_search`, kept in sync by
        // AFTER INSERT/UPDATE/DELETE triggers — mirrors `sources_fts`.
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chats_fts USING fts5(
            title, body,
            content='chat_search', content_rowid='rowid',
            tokenize='porter');
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS chats_fts_ai AFTER INSERT ON chat_search BEGIN
          INSERT INTO chats_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS chats_fts_ad AFTER DELETE ON chat_search BEGIN
          INSERT INTO chats_fts(chats_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
        END;
        """)
        try exec("""
        CREATE TRIGGER IF NOT EXISTS chats_fts_au AFTER UPDATE ON chat_search BEGIN
          INSERT INTO chats_fts(chats_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
          INSERT INTO chats_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)
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

        if version < 15 {
            try exec("""
            CREATE TABLE embedding_meta (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                embedder TEXT NOT NULL
            );
            """)
            try exec("INSERT INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")
            try exec("PRAGMA user_version=15;")
            version = 15
        }

        if version < 16 {
            try exec("""
            CREATE TABLE view_nodes (
                id            TEXT PRIMARY KEY,
                parent_id     TEXT REFERENCES view_nodes(id) ON DELETE CASCADE,
                position      INTEGER NOT NULL DEFAULT 0,
                kind          TEXT NOT NULL,
                label         TEXT,
                target_id     TEXT
            );
            """)
            try exec("CREATE INDEX view_nodes_parent ON view_nodes(parent_id, position);")
            try exec("PRAGMA user_version=16;")
            version = 16
        }

        if version < 17 {
            // Rename view_nodes → bookmark_nodes.
            try exec("ALTER TABLE view_nodes RENAME TO bookmark_nodes;")
            try exec("DROP INDEX IF EXISTS view_nodes_parent;")
            try exec("CREATE INDEX bookmark_nodes_parent ON bookmark_nodes(parent_id, position);")
            try exec("PRAGMA user_version=17;")
            version = 17
        }

        // Step 17 → 18: one-time CONTENT fix, no schema change — sanitize
        // unlinkable characters out of page titles and source display names
        // (`|`, `[`/`]`, leading `#` — see WikiNameRules; those break the
        // `[[wiki-link]]` grammar with no escape, so such names could never be
        // linked/cited). New writes are sanitized at the store boundary from
        // v18 on; this sweeps rows that predate the rule. Nothing referenced
        // the dirty names (they were unlinkable), so no link rewriting is
        // needed. Versions bump so the File Provider re-syncs; FTS/embeddings
        // refresh on the row's next save (staleness only for renamed rows).
        if version < 18 {
            try sanitizeStoredNames()
            try exec("PRAGMA user_version=18;")
            version = 18
        }

        // Step 18 → 19: add content_hash for duplicate-content detection at
        // addSource time (issue #126). Backfilled here so existing rows are
        // immediately eligible for dedup matching against newly-added sources.
        // Column/index existence is checked first: a db built by the fresh-schema
        // fast path (which already includes content_hash) and then rewound to an
        // older `user_version` for ladder testing would otherwise hit "duplicate
        // column name" here.
        if version < 19 {
            let hasColumn = try queryScalarText("SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name='content_hash';") != "0"
            if !hasColumn {
                try exec("ALTER TABLE sources ADD COLUMN content_hash TEXT;")
            }
            let hasIndex = try queryScalarText("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='sources_content_hash';") != "0"
            if !hasIndex {
                try exec("CREATE INDEX sources_content_hash ON sources(content_hash);")
            }
            try backfillContentHashes()
            try exec("PRAGMA user_version=19;")
            version = 19
        }

        // Step 19 → 20 (graph-model Phase 1): move source content out of the
        // mutable `sources.content` column into immutable, content-addressed
        // `blobs`, an append-only `source_versions` chain, a PROV-DM
        // `agents`/`activities` substrate, and a single mutable `refs` pointer
        // (§4.1–4.3). Each existing source gets one v1 version + one ref + a
        // blob whose hash reuses the v19 `content_hash` (same SHA-256 — no
        // re-hash). `sources.content` is then DROPPED. The single read path
        // (`sourceContent`) becomes ref-resolved (ref → version → blob).
        //
        // All DML is inside ONE `withTransaction` (BEGIN IMMEDIATE → savepoint
        // nesting): if the pre-migration assertion fails, the whole step rolls
        // back harmlessly. This is a one-shot, irreversible migration (no
        // soak/dual-write, §9 pre-launch rationale); the DB is VCS-restorable.
        if version < 20 {
            try migrateV19ToV20()
            try exec("PRAGMA user_version=20;")
            version = 20
        }

        // Step 20 → 21 (graph-model Phase 2): turn `source_markdown_versions`
        // from a flat inline-content chain into CAS'd, provenance-carrying
        // extraction alternatives. Adds `activity_id`, `source_version_id`,
        // `blob_hash`, `mime_type`; one-shot backfill CAS-moves each legacy row's
        // inline `content` into a blob, creates a synthetic `legacy-extraction`
        // agent + per-row `extract` activity, and backfills `source_version_id`
        // to the source's active content version. See `migrateV20ToV21`.
        if version < 21 {
            try migrateV20ToV21()
            try exec("PRAGMA user_version=21;")
            version = 21
        }

        // Step 21 → 22 (graph-model Phase 4 foundation): adds `sources.role`
        // (`'primary'` | `'media'`) and rebuilds `source_links` into the §4.4
        // rowid + role/pin shape (`role` + `pinned_version_id` + the
        // `source_links_edge` unique index). `role` defaults to `'primary'`
        // (every existing source is primary); `source_links.role` defaults to
        // `'cite'`, `pinned_version_id` to NULL. Both are additive and
        // data-preserving. See `migrateV21ToV22`.
        if version < 22 {
            try migrateV21ToV22()
            try exec("PRAGMA user_version=22;")
            version = 22
        }

        // Step 22 → 23 (graph-model Phase 5): data-only body sweep — rewrite
        // every resolvable `[[…]]` link in every page body to canonical
        // ULID-stable form. (issue #119 phase 1 chats tables moved to v25 —
        // see below — so this step matches main's v23 exactly.)
        if version < 23 {
            try migrateV22ToV23()
            try exec("PRAGMA user_version=23;")
            version = 23
        }

        // Step 23 → 25 (issue #119 phase 1): persisted chat history — `chats` +
        // `chat_messages`. Purely additive. `IF NOT EXISTS` — a no-op on a DB
        // that already has them. (v24 is a reserved slot, never stamped; the
        // smv.content drop is appended as v26 below so DBs already at v25 run it.)
        if version < 25 {
            try createChatTablesV23()
            try exec("PRAGMA user_version=25;")
            version = 25
        }

        // Step 25 → 26 (graph-model Phase 2 close-out): drop the now-dead
        // `source_markdown_versions.content` column. Post-v21 every derived-
        // markdown row is content-addressed in `blobs` (the inline column was
        // `''` and unread), so finishing the CAS-only model removes it
        // entirely. Appended at the TOP — not inserted at the reserved v24 slot
        // — because a DB already at v25 would skip a `version < 24` step; the
        // drop must be the newest version to run on every existing DB. Idempotent:
        // a no-op where the column is already gone (fresh DBs never create it).
        // Without this, the store's blob-only readers throw
        // `no such column: smv.content` against a column-less DB — the bug that
        // left byteless podcast transcripts projecting as empty `.md` files.
        if version < 26 {
            let hasSMVContent = try queryScalarText(
                "SELECT COUNT(*) FROM pragma_table_info('source_markdown_versions') WHERE name='content';") != "0"
            if hasSMVContent {
                try exec("ALTER TABLE source_markdown_versions DROP COLUMN content;")
            }
            try exec("PRAGMA user_version=26;")
            version = 26
        }

        // Step 26 → 27 (issue #242): add `created_at`/`updated_at` to
        // `bookmark_nodes` so the UI can show "date added"/"date updated"
        // (companion sort/filter in #241). Additive ALTER (NOT NULL DEFAULT 0),
        // then backfill every existing row to `now` — legacy nodes have no
        // recorded creation time, so migration time is the best available proxy
        // (and on a brand-new DB forced through the ladder there are no rows).
        // Column defs match the fresh-path CREATE TABLE byte-for-byte — the
        // `freshFastPathMatchesStepwiseLadder` parity test compares defaults.
        // Idempotent: pragma_table_info-guarded so a rewound-for-testing DB
        // stamps v27 without re-adding the columns.
        if version < 27 {
            // `bookmark_nodes` is created at v16, so any DB that reached here
            // through the real ladder already has it. But hand-crafted test
            // fixtures (e.g. a minimal v19 DB with only `sources`) may be
            // stamped at ≥16 without the table — skip the column work in that
            // case rather than crash mid-migration. There's nothing to backfill
            // when the table is absent.
            let tableExists = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='bookmark_nodes';") != "0"
            if tableExists {
                let hasCreatedAt = try queryScalarText(
                    "SELECT COUNT(*) FROM pragma_table_info('bookmark_nodes') WHERE name='created_at';") != "0"
                if !hasCreatedAt {
                    try exec("ALTER TABLE bookmark_nodes ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
                    try exec("ALTER TABLE bookmark_nodes ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
                    let now = Date().timeIntervalSince1970
                    try exec("UPDATE bookmark_nodes SET created_at = \(now), updated_at = \(now);")
                }
            }
            try exec("PRAGMA user_version=27;")
            version = 27
        }

        // Step 27 → 28 (issue #245): semantic + FTS search over chats. Adds
        // `chat_chunks` (per-chunk cosine embeddings) + the `chat_search` FTS
        // sidecar + `chats_fts` external-content index, mirroring the existing
        // pages/sources search pipeline. Purely additive (`IF NOT EXISTS`); a
        // brand-new DB forced through the ladder has no chat rows to index.
        if version < 28 {
            try createChatSearchTables()
            try exec("PRAGMA user_version=28;")
            version = 28
        }

        // Step 28 → 29 (remove-readonly-chat-mode): data-only sweep — the
        // read-only Ask chat mode is deleted; every chat is now write-capable
        // (`.edit`). Rewrite any legacy `kind = 'ask'` rows to `'edit'` so the
        // single-case `ChatKind` enum decodes them. No schema change —
        // `user_version=29` is only a run-once guard (the v23 precedent). A
        // fresh DB has no chat rows, so the UPDATE is a no-op there.
        if version < 29 {
            try migrateV28ToV29()
            try exec("PRAGMA user_version=29;")
            version = 29
        }

        // Step 29 → 30 (W0 — page versioning, PR #312): adds the `page_versions`
        // table (append-only, blob-backed page body chain), rebuilds `refs` to
        // drop the `owner_id REFERENCES sources(id)` FK (replaced by a CHECK on
        // `kind` so `page-content` refs can use a page id as `owner_id`), and
        // seeds one root version per existing page (blob of current body_markdown).
        // No ref rows are written for the root versions — the default-active
        // rule (no ref → head is MAX(id)) means main tracks latest, exactly like
        // sources did at v20.
        if version < 30 {
            try migrateV29ToV30()
            try exec("PRAGMA user_version=30;")
            version = 30
        }

        // Step 30 → 31 (W1 — workspaces, PR #312): creates the `workspaces` +
        // `workspace_refs` tables for multi-writer ingestion isolation. Purely
        // additive (`IF NOT EXISTS`); no existing data to backfill.
        if version < 31 {
            try createWorkspacesV31()
            try exec("PRAGMA user_version=31;")
            version = 31
        }

        // Step 31 → 32 (W3 — conflict resolution, PR #312): creates the
        // `workspace_conflicts` table for persisting per-page conflict details
        // when a workspace is parked as `conflicted`. Purely additive.
        if version < 32 {
            try createWorkspaceConflictsV32()
            try exec("PRAGMA user_version=32;")
            version = 32
        }

        // Step 32 → 33 (#131 — provenance frontmatter): adds `created_by` and
        // `last_edited_by` nullable text columns to `pages` (agent/model
        // attribution), and a `technique` nullable text column to
        // `source_markdown_versions` (which extraction backend produced it).
        // All additive — existing rows get NULL, which the frontmatter layer
        // treats as "unknown" and omits.
        if version < 33 {
            try migrateV32ToV33()
            try exec("PRAGMA user_version=33;")
            version = 33
        }

        // Step 33 → 34 (#multi-writer-hardening Phase 3 — head-ref invariant):
        // backfills a `page-content` ref for every page that lacks one, and
        // seeds a root version for pages that have none (agent-created pages
        // via blind `wikictl page upsert` never created a version row).
        // After v34, every page has an explicit ref → the MAX(id) fallback in
        // `pageHeadVersionIDLocked` is dead code for migrated data.
        if version < 34 {
            try migrateV33ToV34()
            try exec("PRAGMA user_version=34;")
            version = 34
        }

        // Step 34 → 35 (#multi-writer-hardening Phase 5 — created-page staging):
        // Rebuilds `workspace_refs` to make `version_id` nullable and add
        // `blob_hash` + `title` columns. SQLite cannot ALTER TABLE to relax a
        // NOT NULL constraint, so a table rebuild (CREATE-INSERT-DROP-RENAME)
        // is required. Existing rows are preserved with their original
        // `version_id` values; new `blob_hash`/`title` columns are NULL.
        if version < 35 {
            try migrateV34ToV35()
            try exec("PRAGMA user_version=35;")
            version = 35
        }
    }

    /// The v19→20 migration step. Creates the objects tables, then — for every
    /// existing source — writes a blob (reusing `content_hash` as the SHA-256),
    /// a per-source import activity, a v1 `source_versions` row, and a
    /// `source-content` ref (generation 1). Finally drops `sources.content`.
    /// Throws (rolling back) if any source lacks a `content_hash` — a
    /// silent-data-loss guard (in practice impossible: `content BLOB NOT NULL`
    /// + the v19 backfill sweep guarantee a hash).
    private func migrateV19ToV20() throws {
        try withTransaction {
            // 1. Create the five objects tables (idempotent — IF NOT EXISTS).
            try createObjectsTablesV20()

            // If `sources.content` is already gone, this DB was migrated to v20
            // and then rewound to an older stamp for testing. Its blobs/versions/
            // refs are already populated from the original creation, and there is
            // no `content` to migrate — so the data step is a no-op. (A genuine
            // v19 DB always has `content`.)
            let hasContentColumn = try queryScalarText(
                "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name='content';") != "0"
            guard hasContentColumn else { return }

            // 0. Pre-migration assertion (silent-data-loss guard). Every source
            //    MUST have a non-empty content_hash to reuse as the blob hash.
            let unhashed = try queryScalarText(
                "SELECT COUNT(*) FROM sources WHERE content_hash IS NULL OR content_hash = '';")
            if unhashed != "0" {
                // A NULL hash is impossible under `content NOT NULL` + the v19
                // sweep, but if one ever appears, hash that source's bytes
                // in-step before proceeding — never silently drop content.
                try backfillContentHashes()
                let recheck = try queryScalarText(
                    "SELECT COUNT(*) FROM sources WHERE content_hash IS NULL OR content_hash = '';")
                guard recheck == "0" else {
                    throw WikiStoreError.unexpected(
                        "v20 migration: \(recheck) source(s) still lack a content_hash after backfill — refusing to drop content")
                }
            }

            // 2. Seed one legacy agent representing every pre-Phase-1 import.
            //    No real extraction provenance exists to backfill (§3); this
            //    agent stands in so each v1 version has a valid wasAssociatedWith.
            let legacyAgentID = ULID.generate()
            let seedAgent = try statement(
                "INSERT INTO agents (id, kind, name) VALUES (?1, 'software', 'legacy-import');")
            seedAgent.reset()
            try seedAgent.bind(legacyAgentID, at: 1)
            _ = try seedAgent.step()

            // 3. For each existing source: blob + activity + v1 version + ref.
            let now = Date().timeIntervalSince1970
            let select = try statement("""
            SELECT id, content, content_hash, mime_type, byte_size, created_at
            FROM sources;
            """)
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'import', ?2, ?3, ?3);
            """)
            let insVersion = try statement("""
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, activity_id, fetched_at)
            VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6);
            """)
            let insRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, 1, ?3);
            """)

            while try select.step() {
                let sourceID = select.text(at: 0)
                let content = select.blob(at: 1)
                let hash = select.text(at: 2)
                let mimeIsNull = sqlite3_column_type(select.handle, 3) == SQLITE_NULL
                let mime = mimeIsNull ? nil : select.text(at: 3)
                let byteSize = select.int(at: 4)
                let createdAt = select.double(at: 5)

                // Reuse content_hash as the blob hash (same SHA-256, v19).
                insBlob.reset()
                try insBlob.bind(hash, at: 1)
                try insBlob.bind(byteSize, at: 2)
                try insBlob.bind(content, at: 3)
                _ = try insBlob.step()

                // Per-source import activity.
                let activityID = ULID.generate()
                insActivity.reset()
                try insActivity.bind(activityID, at: 1)
                try insActivity.bind(legacyAgentID, at: 2)
                try insActivity.bind(createdAt, at: 3)
                _ = try insActivity.step()

                // v1 version.
                let versionID = ULID.generate()
                insVersion.reset()
                try insVersion.bind(versionID, at: 1)
                try insVersion.bind(sourceID, at: 2)
                try insVersion.bind(hash, at: 3)
                if let mime { try insVersion.bind(mime, at: 4) }
                try insVersion.bind(activityID, at: 5)
                try insVersion.bind(createdAt, at: 6)
                _ = try insVersion.step()

                // Active ref.
                insRef.reset()
                try insRef.bind(sourceID, at: 1)
                try insRef.bind(versionID, at: 2)
                try insRef.bind(now, at: 3)
                _ = try insRef.step()
            }
            select.reset()
            insBlob.reset()
            insActivity.reset()
            insVersion.reset()
            insRef.reset()

            // 4. Drop the content column. macOS 15 ships SQLite ≥ 3.43
            //    (`DROP COLUMN` since 3.35). If an older SQLite is ever
            //    targeted, fall back to the rename→create→copy→drop rebuild
            //    the ladder already uses elsewhere.
            try exec("ALTER TABLE sources DROP COLUMN content;")
        }
    }

    /// The v20→21 migration step (graph-model Phase 2). Adds the four
    /// `source_markdown_versions` columns and CAS-moves each legacy row's inline
    /// `content` into a blob, recording a synthetic `legacy-extraction` agent +
    /// per-row `extract` activity and backfilling `source_version_id` to the
    /// source's active content version. All DML inside ONE `withTransaction`;
    /// a pre-assertion (every legacy row has non-empty content) throws and rolls
    /// back the whole step on corruption (silent-data-loss guard).
    private func migrateV20ToV21() throws {
        try withTransaction {
            // 0. Guard: a DB rewound from v21 for testing, or an artificial
            //    migration fixture that only stamps `sources` (the v8 step that
            //    creates `source_markdown_versions` was skipped), has no smv table
            //    to backfill. A genuine v19 DB always has it. No-op + stamp.
            let hasSMV = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='source_markdown_versions';") != "0"
            guard hasSMV else { return }

            // 1. Add the four columns idempotently (a DB rewound from v21 for
            //    testing already has them).
            for (col, decl) in [
                ("activity_id", "TEXT REFERENCES activities(id)"),
                ("source_version_id", "TEXT"),
                ("blob_hash", "TEXT REFERENCES blobs(hash)"),
                ("mime_type", "TEXT NOT NULL DEFAULT 'text/markdown'"),
            ] {
                let present = try queryScalarText(
                    "SELECT COUNT(*) FROM pragma_table_info('source_markdown_versions') WHERE name='\(col)';") != "0"
                guard !present else { continue }
                try exec("ALTER TABLE source_markdown_versions ADD COLUMN \(col) \(decl);")
            }

            // If every row already has a blob_hash, this DB was migrated to v21
            // and rewound — nothing to backfill.
            let unmigrated = try queryScalarText(
                "SELECT COUNT(*) FROM source_markdown_versions WHERE blob_hash IS NULL;")
            guard unmigrated != "0" else { return }

            // 2. Seed one legacy-extraction agent (parallel to legacy-import),
            //    reusing it if already present (idempotent for rewound DBs).
            let legacyAgentID: String
            let existing = try? statement(
                "SELECT id FROM agents WHERE name='legacy-extraction' LIMIT 1;")
            let found = existing.flatMap { stmt -> Bool in
                (try? stmt.step()) ?? false
            } ?? false
            defer { existing?.reset() }
            if found, let existing {
                legacyAgentID = existing.text(at: 0)
            } else {
                legacyAgentID = ULID.generate()
                let ins = try statement(
                    "INSERT INTO agents (id, kind, name) VALUES (?1, 'software', 'legacy-extraction');")
                ins.reset()
                try ins.bind(legacyAgentID, at: 1)
                _ = try ins.step()
                ins.reset()
            }

            // 3. Materialize legacy rows into Swift (sqlite-concurrency: no live
            //    cursor while inner INSERT/UPDATE run on the same connection).
            //    `origin` decides whether a row is a real extraction (gets a
            //    legacy-extraction activity) or a user/revert/source edit (no
            //    extraction provenance — its `origin` column already tells that
            //    story, so activity_id stays NULL).
            let select = try statement("""
            SELECT id, file_id, content, origin, created_at
            FROM source_markdown_versions WHERE blob_hash IS NULL;
            """)
            defer { select.reset() }
            struct LegacyRow {
                let id: String; let fileID: String
                let content: String; let origin: String; let createdAt: Double
            }
            var rows: [LegacyRow] = []
            while try select.step() {
                let row = LegacyRow(
                    id: select.text(at: 0),
                    fileID: select.text(at: 1),
                    content: select.text(at: 2),
                    origin: select.text(at: 3),
                    createdAt: select.double(at: 4))
                // Silent-data-loss guard: an empty extraction body is corruption.
                guard !row.content.isEmpty else {
                    throw WikiStoreError.unexpected(
                        "v21 migration: source_markdown_versions row \(row.id) has empty content — refusing to backfill")
                }
                rows.append(row)
            }

            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'extract', ?2, ?3, ?3);
            """)
            let upd = try statement("""
            UPDATE source_markdown_versions
               SET blob_hash = ?1, activity_id = ?2, source_version_id = ?3,
                   mime_type = 'text/markdown', content = ''
             WHERE id = ?4;
            """)
            // Resolve the active content-version id for a source (ref → version,
            // else default-active MAX(id)) — mirrors `activeContentVersion`.
            let resolveVersion = try statement("""
            SELECT sv.id
            FROM refs r
            JOIN source_versions sv ON sv.id = r.version_id
            WHERE r.kind = 'source-content' AND r.owner_id = ?1;
            """)
            defer { resolveVersion.reset() }
            let resolveVersionMax = try statement("""
            SELECT id FROM source_versions
            WHERE source_id = ?1 ORDER BY id DESC LIMIT 1;
            """)
            defer { resolveVersionMax.reset() }

            for row in rows {
                // SHA-256 of the UTF-8 markdown bytes.
                let data = Data(row.content.utf8)
                let hash = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()

                insBlob.reset()
                try insBlob.bind(hash, at: 1)
                try insBlob.bind(Int64(data.count), at: 2)
                try insBlob.bind(data, at: 3)
                _ = try insBlob.step()

                // Only real extractions get a synthetic legacy-extraction activity.
                // User/revert/source rows are edits, not extractions — their origin
                // is the provenance; stamping an extract activity would mislabel a
                // manual edit as a backend extraction (activity_id stays NULL).
                var activityID: String? = nil
                if row.origin == "extraction" {
                    let id = ULID.generate()
                    insActivity.reset()
                    try insActivity.bind(id, at: 1)
                    try insActivity.bind(legacyAgentID, at: 2)
                    try insActivity.bind(row.createdAt, at: 3)
                    _ = try insActivity.step()
                    activityID = id
                }

                // source_version_id: the source's active content version.
                var sourceVersionID: String?
                resolveVersion.reset()
                try resolveVersion.bind(row.fileID, at: 1)
                if try resolveVersion.step() {
                    sourceVersionID = resolveVersion.text(at: 0)
                } else {
                    resolveVersionMax.reset()
                    try resolveVersionMax.bind(row.fileID, at: 1)
                    if try resolveVersionMax.step() {
                        sourceVersionID = resolveVersionMax.text(at: 0)
                    }
                }

                upd.reset()
                try upd.bind(hash, at: 1)
                if let activityID { try upd.bind(activityID, at: 2) }
                if let sourceVersionID { try upd.bind(sourceVersionID, at: 3) }
                try upd.bind(row.id, at: 4)
                _ = try upd.step()
            }
            insBlob.reset()
            insActivity.reset()
            upd.reset()
        }
    }

    /// The v21→v22 migration step (graph-model Phase 4 foundation). Two additive,
    /// data-preserving schema changes inside one `withTransaction`:
    ///
    /// 1. `sources.role TEXT NOT NULL DEFAULT 'primary'` — `ALTER TABLE … ADD
    ///    COLUMN` applies the default to every existing row (the backfill *is*
    ///    the default). Today every source is `primary`; `media` sources are
    ///    written later by future provider fetches.
    /// 2. `source_links` rebuild — mirrors the shipped v10→v11 rename→create→
    ///    copy→drop pattern exactly (it's a leaf join table; nothing FKs to it).
    ///    The composite `PRIMARY KEY` is dropped (making it a rowid table per
    ///    §4.4), and `role TEXT NOT NULL DEFAULT 'cite'` +
    ///    `pinned_version_id TEXT` are added. The `source_links_edge` unique
    ///    index on `(from_page_id, to_source_id, role, COALESCE(pinned_version_id,
    ///    ''))` restores the v11 dedup semantics: SQLite treats NULLs as distinct
    ///    in unique constraints, so the COALESCE collapses duplicate *unpinned*
    ///    links to one source exactly as the old composite PK did.
    private func migrateV21ToV22() throws {
        try withTransaction {
            // Guard: a DB rewound from v22 for testing already has `sources.role`
            // (and the rebuilt `source_links`). A genuine v21 DB does not. Skip
            // the whole step if present — matches the established rewind guard.
            let hasRole = try queryScalarText(
                "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name='role';") != "0"
            guard !hasRole else { return }

            // 1. sources.role — ADD COLUMN applies the default to every existing
            //    row (the backfill *is* the default). Every source becomes 'primary'.
            try exec("ALTER TABLE sources ADD COLUMN role TEXT NOT NULL DEFAULT 'primary';")

            // 2. source_links rebuild (mirrors the shipped v10→v11 rename→create→
            //    copy→drop pattern — it's a leaf join table, nothing FKs to it).
            //    Drop the composite PRIMARY KEY (rowid table per §4.4) and add
            //    `role` + `pinned_version_id`. The `source_links_edge` unique index
            //    on `(from_page_id, to_source_id, role, COALESCE(pinned_version_id,
            //    ''))` restores the v11 dedup semantics: SQLite treats NULLs as
            //    distinct in unique constraints, so the COALESCE collapses
            //    duplicate *unpinned* links to one source exactly as the old PK did.
            // Guard: a hand-built test fixture at v19/v21 may not have the table
            // (created at v10) — skip the rebuild when it's absent. A genuine
            // production DB at v21 always has it.
            let hasSourceLinks = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='source_links';") != "0"
            guard hasSourceLinks else { return }
            let hasRoleCol = try queryScalarText(
                "SELECT COUNT(*) FROM pragma_table_info('source_links') WHERE name='role';") != "0"
            guard !hasRoleCol else { return }  // already rebuilt (rewound v22 DB)
            try exec("ALTER TABLE source_links RENAME TO source_links_v21;")
            try exec("""
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                link_text    TEXT NOT NULL,
                role         TEXT NOT NULL DEFAULT 'cite',
                pinned_version_id TEXT
            );
            """)
            try exec("""
            INSERT INTO source_links (from_page_id, to_source_id, link_text, role, pinned_version_id)
            SELECT from_page_id, to_source_id, link_text, 'cite', NULL FROM source_links_v21;
            """)
            try exec("DROP TABLE source_links_v21;")
            try exec("""
            CREATE UNIQUE INDEX source_links_edge
                ON source_links(from_page_id, to_source_id, role,
                                COALESCE(pinned_version_id, ''));
            """)
        }
    }

    /// The v22→23 step (graph-model Phase 5): a one-time, data-only sweep that
    /// rewrites every page body's resolvable `[[…]]` links to canonical
    /// ULID-stable form (`[[page:ULID|alias]]` / `[[source:ULID|alias]]`). No
    /// schema change — `user_version=23` is only a run-once guard (the v18
    /// name-sanitization precedent). Idempotent (canonical→no-op), code-fence-
    /// safe, and alias/fragment-preserving (see `WikiLinkRewriter.canonicalize`).
    ///
    /// The change token MUST advance: `changeToken()` folds `COUNT(pages)` +
    /// `COALESCE(SUM(version),0)`, and the File Provider versions each projected
    /// `.md` by `page.version` + `page.updatedAt`. A body rewrite that left the
    /// token unmoved would serve stale pre-canonicalization bodies — reintroducing
    /// the ghost-link class this phase kills. So every rewritten page bumps
    /// `version` + `updated_at` (matching the v18 precedent exactly). Link rows
    /// are NOT touched: the from→to edges are invariant under canonicalization
    /// (a `[[Title]]` that resolved to page X becomes `[[page:X_id|Title]]`,
    /// same edge), so the existing `page_links`/`source_links` stay correct.
    private func migrateV22ToV23() throws {
        try withTransaction {
            // Guard: a minimal fixture (or a DB rewound for testing) may lack a
            // `pages` table — the canonicalizer has nothing to sweep, so skip
            // (matches the established "check before SELECT" rewind guard).
            let hasPages = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pages';") != "0"
            guard hasPages else { return }

            // At v22 `sources` always exists, but a minimal/corrupted fixture may
            // lack it — a body with `[[source:…]]` would then throw "no such
            // table" from `resolveSourceByName` and abort the open. Pass a nil
            // resolver when it's absent so those spans are simply left as-written.
            let hasSources = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sources';") != "0"
            let resolveSource: (String) throws -> PageID? = hasSources
                ? { [self] in try self.resolveSourceByName($0) }
                : { _ in nil }

            // The chats table may also be absent in a minimal/corrupted fixture
            // — guard it the same way so `[[chat:…]]` spans are left as-written.
            let hasChats = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chats';") != "0"
            let resolveChat: (String) throws -> PageID? = hasChats
                ? { [self] in try self.resolveChatByTitle($0) }
                : { _ in nil }

            // Snapshot id + body under the write lock. The canonicalizer is pure
            // (resolvers are read-only lookups), so collecting first then rewriting
            // avoids a statement handle spanning the reparse.
            let select = try statement("SELECT id, body_markdown FROM pages;")
            defer { select.reset() }
            var rows: [(id: String, body: String)] = []
            while try select.step() {
                rows.append((select.text(at: 0), select.text(at: 1)))
            }
            let now = Date().timeIntervalSince1970
            let update = try statement("""
            UPDATE pages SET body_markdown = ?2, updated_at = ?3, version = version + 1 WHERE id = ?1;
            """)
            for row in rows {
                guard let canonical = try WikiLinkRewriter.canonicalize(
                    in: row.body, resolvePage: resolveTitleToID,
                    resolveSource: resolveSource,
                    resolveChat: resolveChat) else { continue }
                update.reset()
                try update.bind(row.id, at: 1)
                try update.bind(canonical, at: 2)
                try update.bind(now, at: 3)
                _ = try update.step()
            }
            update.reset()
        }
    }

    /// The v28→29 step (remove-readonly-chat-mode): a one-time, data-only sweep
    /// that rewrites every legacy `kind = 'ask'` chat row to `'edit'`. The
    /// read-only Ask chat mode is deleted — all chats are now write-capable — so
    /// the single-case `ChatKind` enum must decode every row. No schema change;
    /// `user_version=29` is only a run-once guard (the v22→23 precedent).
    /// Idempotent (a row already `'edit'` is untouched). Guarded so a minimal
    /// fixture (or a rewound-for-testing DB) lacking a `chats` table skips
    /// harmlessly — matching the established "check before UPDATE" rewind guard.
    private func migrateV28ToV29() throws {
        let hasChats = try queryScalarText(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chats';") != "0"
        guard hasChats else { return }
        try exec("UPDATE chats SET kind = 'edit' WHERE kind = 'ask';")
    }

    /// The v29→30 migration step (W0 — page versioning, PR #312):
    ///
    /// 1. Creates the `page_versions` table (append-only, blob-backed page body
    ///    chain, mirroring `source_versions`).
    /// 2. Rebuilds the `refs` table to drop the `owner_id REFERENCES sources(id)`
    ///    FK and replace it with a CHECK on `kind` (so `page-content` refs can
    ///    use a page id as `owner_id`). The graph-model plan (§4.3) explicitly
    ///    flagged this as the trigger condition for a third ref kind.
    /// 3. Seeds one root version per existing page (blob of current
    ///    `body_markdown`, legacy-import activity, parent_id NULL). No ref rows
    ///    are written — the default-active rule (no ref → head is MAX(id))
    ///    means main tracks latest, exactly like sources did at v20.
    private func migrateV29ToV30() throws {
        try withTransaction {
            // 1. Create page_versions (idempotent — IF NOT EXISTS).
            try createPageVersionsV30()

            // 2. Rebuild refs: drop the owner_id FK, add the CHECK on kind.
            //    Standard SQLite table-rebuild pattern (can't ALTER TABLE DROP
            //    CONSTRAINT). The graph-model plan §4.3 noted the FK would need
            //    to go when a third ref kind landed.
            //
            //    Guard: if refs already has the CHECK (a DB rewound to v29 for
            //    testing after already being at v30), the rebuild is a no-op
            //    (copy → drop → rename is identity).
            //
            //    Guard: hand-built migration fixtures (e.g. a v28 chats-only DB)
            //    may not have a `refs` table at all — the v19→v20 step that
            //    creates it was skipped. If refs doesn't exist, create it fresh
            //    (the CHECK-constrained shape) rather than copying from nothing.
            let refsExists = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='refs';") != "0"
            if refsExists {
                let refsHasCheck = try queryScalarText(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='refs';").contains("CHECK")
                if !refsHasCheck {
                    try exec("""
                    CREATE TABLE _refs_new (
                        kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
                        owner_id   TEXT NOT NULL,
                        version_id TEXT NOT NULL,
                        generation INTEGER NOT NULL DEFAULT 1,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (kind, owner_id)
                    );
                    """)
                    try exec("INSERT INTO _refs_new (kind, owner_id, version_id, generation, updated_at) SELECT kind, owner_id, version_id, generation, updated_at FROM refs;")
                    try exec("DROP TABLE refs;")
                    try exec("ALTER TABLE _refs_new RENAME TO refs;")
                }
            } else {
                // No `refs` table → create the CHECK-constrained shape fresh.
                try exec("""
                CREATE TABLE IF NOT EXISTS refs (
                    kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
                    owner_id   TEXT NOT NULL,
                    version_id TEXT NOT NULL,
                    generation INTEGER NOT NULL DEFAULT 1,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (kind, owner_id)
                );
                """)
            }

            // 3. Seed root versions for existing pages. Idempotent: if
            //    page_versions already has rows (a rewound DB), skip.
            let pageCount = try queryScalarText(
                "SELECT COUNT(*) FROM page_versions;") ?? "0"
            guard pageCount == "0" else { return }

            let hasPages = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pages';") != "0"
            guard hasPages else { return }

            // Reuse the legacy-import agent (same as the v20 source seeding).
            // Create one if it doesn't exist (a v29 DB always has agents from
            // v20, but guard anyway).
            let legacyAgentID: String
            let hasLegacyAgent = try queryScalarText(
                "SELECT COUNT(*) FROM agents WHERE name = 'legacy-import';") != "0"
            if hasLegacyAgent {
                legacyAgentID = try queryScalarText(
                    "SELECT id FROM agents WHERE name = 'legacy-import' LIMIT 1;")
            } else {
                legacyAgentID = ULID.generate()
                let seedAgent = try statement(
                    "INSERT INTO agents (id, kind, name) VALUES (?1, 'software', 'legacy-import');")
                seedAgent.reset()
                try seedAgent.bind(legacyAgentID, at: 1)
                _ = try seedAgent.step()
            }

            let now = Date().timeIntervalSince1970
            let select = try statement("""
            SELECT id, title, body_markdown, created_at FROM pages;
            """)
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'import', ?2, ?3, ?3);
            """)
            let insVersion = try statement("""
            INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6);
            """)

            while try select.step() {
                let pageID = select.text(at: 0)
                let title = select.text(at: 1)
                let bodyData = Data(select.blob(at: 2))
                let createdAt = select.double(at: 3)

                // SHA-256 of the body → blob hash.
                let hash = SHA256.hash(data: bodyData)
                    .map { String(format: "%02x", $0) }.joined()

                insBlob.reset()
                try insBlob.bind(hash, at: 1)
                try insBlob.bind(Int64(bodyData.count), at: 2)
                try insBlob.bind(bodyData, at: 3)
                _ = try insBlob.step()

                let activityID = ULID.generate()
                insActivity.reset()
                try insActivity.bind(activityID, at: 1)
                try insActivity.bind(legacyAgentID, at: 2)
                try insActivity.bind(createdAt, at: 3)
                _ = try insActivity.step()

                let versionID = ULID.generate()
                insVersion.reset()
                try insVersion.bind(versionID, at: 1)
                try insVersion.bind(pageID, at: 2)
                try insVersion.bind(hash, at: 3)
                try insVersion.bind(title, at: 4)
                try insVersion.bind(activityID, at: 5)
                try insVersion.bind(createdAt, at: 6)
                _ = try insVersion.step()
            }
            select.reset()
        }
    }

    /// v32 → v33 (#131): adds provenance columns to `pages`
    /// (`created_by`, `last_edited_by`) and `source_markdown_versions`
    /// (`technique`). All nullable, additive — existing rows get NULL.
    private func migrateV32ToV33() throws {
        try withTransaction {
            // Guard: check each column exists before adding (the fresh schema
            // createFreshSchemaV20 may already include them on a rewound DB).
            // Also guard table existence: hand-built migration fixtures (e.g.
            // a v28 chats-only DB) may not have `pages` or
            // `source_markdown_versions` — the steps that create them (0→1,
            // 7→8) were skipped because the fixture stamps a high user_version.
            // Migrating such a fixture all the way to v35 must not throw on a
            // table that was never created.
            let hasPages = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pages';") != "0"
            if hasPages {
                let pagesCols = try tableColumnInfo("pages")
                if !pagesCols.contains("created_by") {
                    try exec("ALTER TABLE pages ADD COLUMN created_by TEXT;")
                }
                if !pagesCols.contains("last_edited_by") {
                    try exec("ALTER TABLE pages ADD COLUMN last_edited_by TEXT;")
                }
            }
            let hasSMV = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='source_markdown_versions';") != "0"
            if hasSMV {
                let smvCols = try tableColumnInfo("source_markdown_versions")
                if !smvCols.contains("technique") {
                    try exec("ALTER TABLE source_markdown_versions ADD COLUMN technique TEXT;")
                }
            }
        }
    }

    /// v33 → v34 (#multi-writer-hardening Phase 3 — head-ref invariant):
    /// For every `pages` row that has no `page-content` ref, resolves the head
    /// via MAX(id), seeds a root version if the page has none (agent-created
    /// pages via blind `wikictl page upsert`), then inserts a `page-content`
    /// ref pointing at the resolved head. After this, the MAX(id) fallback in
    /// `pageHeadVersionIDLocked` is dead code for migrated data. Idempotent:
    /// re-running on a v34 DB is a no-op (all pages already have refs).
    private func migrateV33ToV34() throws {
        try withTransaction {
            // Guard: hand-built migration fixtures (e.g. a v19 sources-only or
            // v28 chats-only DB) may not have `pages` or `refs` — the steps
            // that create them (0→1 for pages, 19→20 for refs) were skipped
            // because the fixture stamps a high user_version. If the tables
            // don't exist, there is nothing to backfill → no-op. Matches the
            // resilience convention from migrateV29ToV30 (hasPages guard).
            let hasPages = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pages';") != "0"
            guard hasPages else { return }
            let hasRefs = try queryScalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='refs';") != "0"
            guard hasRefs else { return }

            // Reuse the legacy-import agent (same as v20/v30 seeding).
            let legacyAgentID = try legacyImportAgentID()
            let now = Date().timeIntervalSince1970

            // Collect refless page IDs first (avoid stepping a query cursor while
            // inserting — the SQLite statement discipline forbids leaving a cursor
            // at SQLITE_ROW across other statement operations).
            let reflessPages = try statement("""
            SELECT p.id, p.title, p.body_markdown, p.created_at
            FROM pages p
            WHERE NOT EXISTS (
                SELECT 1 FROM refs r
                WHERE r.kind = 'page-content' AND r.owner_id = p.id
            );
            """)
            var pages: [(id: String, title: String, body: Data, createdAt: Double)] = []
            while try reflessPages.step() {
                pages.append((
                    id: reflessPages.text(at: 0),
                    title: reflessPages.text(at: 1),
                    body: Data(reflessPages.blob(at: 2)),
                    createdAt: reflessPages.double(at: 3)
                ))
            }
            reflessPages.reset()

            // No refless pages → no-op (idempotent for a v34 DB).
            guard !pages.isEmpty else { return }

            // Prepared statements for the seeding path.
            let maxStmt = try statement("""
            SELECT id FROM page_versions
            WHERE page_id = ?1
            ORDER BY id DESC LIMIT 1;
            """)
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'import', ?2, ?3, ?3);
            """)
            let insVersion = try statement("""
            INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6);
            """)
            let insRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?1, ?2, 1, ?3);
            """)
            defer {
                maxStmt.reset()
                insBlob.reset()
                insActivity.reset()
                insVersion.reset()
                insRef.reset()
            }

            for page in pages {
                // Resolve the head via MAX(id) — the pre-v34 fallback.
                maxStmt.reset()
                try maxStmt.bind(page.id, at: 1)

                var headVersionID: String
                if try maxStmt.step() {
                    // The page already has versions but no ref → just write the ref.
                    headVersionID = maxStmt.text(at: 0)
                } else {
                    // No versions at all → seed a root version (agent-created page
                    // via blind upsert). Mirror the v30 migration pattern.
                    let hash = SHA256.hash(data: page.body)
                        .map { String(format: "%02x", $0) }.joined()

                    insBlob.reset()
                    try insBlob.bind(hash, at: 1)
                    try insBlob.bind(Int64(page.body.count), at: 2)
                    try insBlob.bind(page.body, at: 3)
                    _ = try insBlob.step()

                    let activityID = ULID.generate()
                    insActivity.reset()
                    try insActivity.bind(activityID, at: 1)
                    try insActivity.bind(legacyAgentID, at: 2)
                    try insActivity.bind(page.createdAt, at: 3)
                    _ = try insActivity.step()

                    headVersionID = ULID.generate()
                    insVersion.reset()
                    try insVersion.bind(headVersionID, at: 1)
                    try insVersion.bind(page.id, at: 2)
                    try insVersion.bind(hash, at: 3)
                    try insVersion.bind(page.title, at: 4)
                    try insVersion.bind(activityID, at: 5)
                    try insVersion.bind(page.createdAt, at: 6)
                    _ = try insVersion.step()
                }

                // Write the ref pointing at the resolved head.
                insRef.reset()
                try insRef.bind(page.id, at: 1)
                try insRef.bind(headVersionID, at: 2)
                try insRef.bind(now, at: 3)
                _ = try insRef.step()
            }
        }
    }

    /// v34 → v35 (#multi-writer-hardening Phase 5 — created-page staging):
    /// Rebuilds `workspace_refs` to make `version_id` nullable and add
    /// `blob_hash` + `title` columns. SQLite cannot `ALTER TABLE` to relax a
    /// NOT NULL constraint, so a CREATE-INSERT-DROP-RENAME table rebuild is
    /// required. Existing `workspace_refs` rows are preserved with their
    /// original values; the new columns are NULL for pre-v35 data.
    ///
    /// The PK is inline (part of CREATE TABLE), so it survives the rebuild.
    /// Idempotent: if `workspace_refs` already has `blob_hash`, the migration
    /// is a no-op (re-running on a v35 DB).
    private func migrateV34ToV35() throws {
        // Idempotency guard: if `blob_hash` column already exists, skip.
        let columns = try tableColumnInfo("workspace_refs")
        guard !columns.contains("blob_hash") else { return }

        try withTransaction {
            // 1. Create the new table with the updated shape.
            try exec("""
            CREATE TABLE _workspace_refs_new (
                workspace_id  TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                kind           TEXT NOT NULL CHECK (kind = 'page-content'),
                owner_id       TEXT NOT NULL,
                base_version_id TEXT,
                version_id     TEXT,
                blob_hash      TEXT REFERENCES blobs(hash),
                title          TEXT,
                updated_at     REAL NOT NULL,
                PRIMARY KEY (workspace_id, kind, owner_id)
            );
            """)

            // 2. Copy all existing rows (blob_hash + title = NULL for migrated data).
            try exec("""
            INSERT INTO _workspace_refs_new
                (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
            SELECT workspace_id, kind, owner_id, base_version_id, version_id, NULL, NULL, updated_at
            FROM workspace_refs;
            """)

            // 3. Drop the old table.
            try exec("DROP TABLE workspace_refs;")

            // 4. Rename the new table into place.
            try exec("ALTER TABLE _workspace_refs_new RENAME TO workspace_refs;")
        }
    }

    /// Returns column names for `table` via pragma_table_info.
    private func tableColumnInfo(_ table: String) throws -> Set<String> {
        let stmt = try statement("SELECT name FROM pragma_table_info('\(table)');")
        defer { stmt.reset() }
        var cols: Set<String> = []
        while try stmt.step() {
            cols.insert(stmt.text(at: 0))
        }
        return cols
    }

    /// One-time backfill for the v18→19 step: hash every existing source's
    /// `content` (SHA-256, hex) into the new `content_hash` column. Content is a
    /// pure function of the stored bytes, so this is safe to compute once and
    /// never touch again — new rows get their hash at insert time in `addSource`.
    private func backfillContentHashes() throws {
        // Resilience: the `content` column is dropped in the v20 step. A DB that
        // was already migrated to v20 then rewound to an older stamp for testing
        // (or any DB where content is already gone) has no `content` to hash —
        // and its `content_hash` is already populated, so this backfill is a
        // no-op. Bail rather than throw "no such column: content".
        let hasContentColumn = try queryScalarText(
            "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name='content';") != "0"
        guard hasContentColumn else { return }
        let select = try statement("SELECT id, content FROM sources;")
        defer { select.reset() }
        var rows: [(id: String, hash: String)] = []
        while try select.step() {
            let id = select.text(at: 0)
            let data = select.blob(at: 1)
            let digest = SHA256.hash(data: data)
            rows.append((id: id, hash: digest.map { String(format: "%02x", $0) }.joined()))
        }
        let update = try statement("UPDATE sources SET content_hash = ?1 WHERE id = ?2;")
        for row in rows {
            update.reset()
            try update.bind(row.hash, at: 1)
            try update.bind(row.id, at: 2)
            _ = try update.step()
        }
        update.reset()
    }

    /// The v17→18 sweep: rewrite every page title and source display name that
    /// `WikiNameRules` would change. Pages also get their slug recomputed from
    /// the sanitized title. Sources with a NULL display_name but an unlinkable
    /// FILENAME get the sanitized filename as their display name (the filename
    /// itself stays verbatim — it is the file's identity on the mount).
    private func sanitizeStoredNames() throws {
        let now = Date().timeIntervalSince1970

        var pages: [(id: String, title: String)] = []
        let pageRows = try statement("SELECT id, title FROM pages;")
        defer { pageRows.reset() }
        while try pageRows.step() {
            pages.append((pageRows.text(at: 0), pageRows.text(at: 1)))
        }
        for page in pages where !WikiNameRules.isLinkable(page.title) {
            let clean = WikiNameRules.sanitized(page.title)
            let slug = try uniqueSlug(from: clean, id: PageID(rawValue: page.id))
            let update = try statement("""
            UPDATE pages SET title = ?2, slug = ?3, updated_at = ?4,
                             version = version + 1 WHERE id = ?1;
            """)
            defer { update.reset() }
            try update.bind(page.id, at: 1)
            try update.bind(clean, at: 2)
            try update.bind(slug, at: 3)
            try update.bind(now, at: 4)
            _ = try update.step()
        }

        var sources: [(id: String, effectiveName: String)] = []
        let sourceRows = try statement(
            "SELECT id, COALESCE(display_name, filename) FROM sources;")
        defer { sourceRows.reset() }
        while try sourceRows.step() {
            sources.append((sourceRows.text(at: 0), sourceRows.text(at: 1)))
        }
        for source in sources where !WikiNameRules.isLinkable(source.effectiveName) {
            let update = try statement("""
            UPDATE sources SET display_name = ?2, updated_at = ?3,
                               version = version + 1 WHERE id = ?1;
            """)
            defer { update.reset() }
            try update.bind(source.id, at: 1)
            try update.bind(WikiNameRules.sanitized(source.effectiveName), at: 2)
            try update.bind(now, at: 3)
            _ = try update.step()
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
        // Assembled from per-kind ``ChangeTokenContributor``s (slice 2b). The
        // registry joins fragments in registration order; today's order
        // reproduces the historical 11-field token byte-for-byte — the ~20
        // hardcoded-literal assertions in SQLiteWikiStoreTests / LogIndexTests
        // / SystemPromptTests enforce that. Each contributor runs under this
        // lock and reads committed state via the private `*Count`/`*Version`
        // helpers below (values only — no statement handle crosses the call;
        // `docs/skills/sqlite-concurrency/SKILL.md`).
        return try Self.tokenContributors
            .map { try $0.fragment(in: self) }
            .joined(separator: ":")
    }

    /// `COUNT`/`SUM(version)` over `pages`. Unlike the resilient `*Count`/
    /// `*Version` helpers below (which `try?` and return `0` on a missing
    /// table), this one `try`s and therefore **throws** if the `pages` table is
    /// absent — matching the pre-2b `changeToken()` behavior (the pages fold was
    /// the only one that could throw). The `step` guard is defensive
    /// (`COUNT(*)` always yields a row); kept for parity.
    private func pageCountSum() throws -> (Int64, Int64) {
        let stmt = try statement("SELECT COUNT(*), COALESCE(SUM(version), 0) FROM pages;")
        defer { stmt.reset() }
        guard try stmt.step() else { return (0, 0) }
        return (stmt.int(at: 0), stmt.int(at: 1))
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

    /// v20 fold: the `source_versions` table's row COUNT. Resilient to the table
    /// not existing yet (a read connection opened against a pre-v20 DB). On any
    /// failure returns `0` so `changeToken()` still answers.
    private func sourceVersionCount() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COUNT(*) FROM source_versions;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// v20 fold: the `COALESCE(SUM(generation), 0)` over `refs` — the only
    /// mutable pointer state. Bumps on every repoint (refresh/rollback); drops
    /// when a source (and its ref) is deleted. Resilient to the table not
    /// existing yet (pre-v20 read connection).
    private func refsGenerationSum() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COALESCE(SUM(generation), 0) FROM refs;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// v20 fold: the `activities` table's row COUNT. Resilient to the table not
    /// existing yet (pre-v20 read connection).
    private func activitiesCount() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COUNT(*) FROM activities;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// Phase D fold: the `bookmark_nodes` table's row COUNT. Resilient to the
    /// table not existing yet (pre-v17 read connection).
    private func bookmarkNodesCount() -> Int64 {
        guard let stmt = try? statement(
            "SELECT COUNT(*) FROM bookmark_nodes;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// The `chats` table's row COUNT, resilient to the table not existing yet
    /// (a read connection opened against a pre-v25 DB). On any failure returns
    /// `0` so `changeToken()` still answers.
    private func chatCount() -> Int64 {
        guard let stmt = try? statement("SELECT COUNT(*) FROM chats;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    /// The `chat_messages` table's row COUNT, resilient to the table not
    /// existing yet. On any failure returns `0`.
    private func chatMessageCount() -> Int64 {
        guard let stmt = try? statement("SELECT COUNT(*) FROM chat_messages;") else { return 0 }
        defer { stmt.reset() }
        guard (try? stmt.step()) == true else { return 0 }
        return stmt.int(at: 0)
    }

    // MARK: - changeToken contributors (slice 2b)

    /// The per-kind contributors whose fragments join into ``changeToken()``.
    /// Order is load-bearing: it reproduces the historical 11-field token
    /// byte-for-byte. A kind may appear more than once (the historical layout
    /// interleaves the system-prompt/log/index folds between the `sources`
    /// table fold and the graph-model source folds). `internal` so the
    /// contributor-exhaustiveness test can read it (`@testable import`).
    static let tokenContributors: [any ChangeTokenContributor] = [
        PagesTokenContributor(),
        SourceTableTokenContributor(),
        SystemPromptTokenContributor(),
        LogTokenContributor(),
        WikiIndexTokenContributor(),
        SourceDerivedTokenContributor(),
        SourceGraphTokenContributor(),
        BookmarkTokenContributor(),
        ChatTokenContributor(),
    ]

    private struct PagesTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .page
        func fragment(in store: SQLiteWikiStore) throws -> String {
            let (count, sum) = try store.pageCountSum()
            return "\(count):\(sum)"
        }
    }

    private struct SourceTableTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fragment(in store: SQLiteWikiStore) throws -> String {
            let (count, sum) = store.sourceCountSum()
            return "\(count):\(sum)"
        }
    }

    private struct SystemPromptTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .systemPrompt
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.systemPromptVersion())"
        }
    }

    private struct LogTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .log
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.logRowCount())"
        }
    }

    private struct WikiIndexTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .wikiIndex
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.wikiIndexVersion())"
        }
    }

    /// The derived-alternative fold: the `source_markdown_versions` row count.
    /// Logically a source concern; appears after the index fold in the
    /// historical layout, so it is its own contributor in registry order.
    private struct SourceDerivedTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.sourceMarkdownVersionCount())"
        }
    }

    /// The graph-model source folds: `source_versions` count, `refs` generation
    /// sum, `activities` count. Appended at the token tail by Phase 1 (v20);
    /// logically source provenance/version state.
    private struct SourceGraphTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.sourceVersionCount()):\(store.refsGenerationSum()):\(store.activitiesCount())"
        }
    }

    /// Phase D fold: the `bookmark_nodes` row count. A bookmark create/delete
    /// bumps the token so the File Provider re-enumerates the `bookmarks/` tree.
    private struct BookmarkTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .bookmark
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.bookmarkNodesCount())"
        }
    }

    /// Chat fold (#119 follow-on): the `chats` row count + `chat_messages` row
    /// count. A chat create/delete bumps the count; a message append bumps the
    /// message count. Both advance the token so the FP re-enumerates `chats/`.
    private struct ChatTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .chat
        func fragment(in store: SQLiteWikiStore) throws -> String {
            "\(store.chatCount()):\(store.chatMessageCount())"
        }
    }

    public func getPage(id: PageID) throws -> WikiPage {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, title, slug, body_markdown, created_at, updated_at, version, created_by, last_edited_by
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
            version: Int(stmt.int(at: 6)),
            createdBy: sqlite3_column_type(stmt.handle, 7) == SQLITE_NULL ? nil : stmt.text(at: 7),
            lastEditedBy: sqlite3_column_type(stmt.handle, 8) == SQLITE_NULL ? nil : stmt.text(at: 8)
        )
    }

    public func createPage(title: String, createdBy: String? = nil) throws -> WikiPage {
        try mutate(event: { page in localEvent(.page, id: page.id.rawValue, change: .created) }) {
        // Titles must stay linkable (`[[title]]`) — see WikiNameRules.
        let title = WikiNameRules.sanitized(title)
        let id = PageID(rawValue: ULID.generate())
        let slug = try uniqueSlug(from: title, id: id)
        let now = Date()
        let nowTS = now.timeIntervalSince1970
        let stmt = try statement("""
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version, created_by, last_edited_by)
        VALUES (?1, ?2, ?3, '', ?4, ?4, 1, ?5, ?5);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(title, at: 2)
        try stmt.bind(slug, at: 3)
        try stmt.bind(nowTS, at: 4)
        if let createdBy { try stmt.bind(createdBy, at: 5) } else { try stmt.bind(nil, at: 5) }
        _ = try stmt.step()

        // Phase 3 (head-ref invariant): seed a root version + page-content ref
        // atomically so the page has a ref from birth (not relying on the
        // first save). The empty body is the initial blob.
        let bodyData = Data("".utf8)
        let hash = SHA256.hash(data: bodyData)
            .map { String(format: "%02x", $0) }.joined()

        let insBlob = try statement(
            "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
        insBlob.reset()
        try insBlob.bind(hash, at: 1)
        try insBlob.bind(Int64(0), at: 2)
        try insBlob.bind(bodyData, at: 3)
        _ = try insBlob.step()
        insBlob.reset()

        let legacyAgentID = try legacyImportAgentID()
        let activityID = ULID.generate()
        let insActivity = try statement("""
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?1, 'import', ?2, ?3, ?3);
        """)
        insActivity.reset()
        try insActivity.bind(activityID, at: 1)
        try insActivity.bind(legacyAgentID, at: 2)
        try insActivity.bind(nowTS, at: 3)
        _ = try insActivity.step()
        insActivity.reset()

        let versionID = ULID.generate()
        let insVersion = try statement("""
        INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
        VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6);
        """)
        insVersion.reset()
        try insVersion.bind(versionID, at: 1)
        try insVersion.bind(id.rawValue, at: 2)
        try insVersion.bind(hash, at: 3)
        try insVersion.bind(title, at: 4)
        try insVersion.bind(activityID, at: 5)
        try insVersion.bind(nowTS, at: 6)
        _ = try insVersion.step()
        insVersion.reset()

        let insRef = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?1, ?2, 1, ?3);
        """)
        insRef.reset()
        try insRef.bind(id.rawValue, at: 1)
        try insRef.bind(versionID, at: 2)
        try insRef.bind(nowTS, at: 3)
        _ = try insRef.step()
        insRef.reset()

        return WikiPage(
            id: id, title: title, slug: slug, bodyMarkdown: "",
            createdAt: now, updatedAt: now, version: 1,
            createdBy: createdBy, lastEditedBy: createdBy
        )
        }
    }

    public func updatePage(id: PageID, title: String, body: String, lastEditedBy: String? = nil) throws {
        try mutate(event: { _ in localEvent(.page, id: id.rawValue, change: .updated) }) {
        // Recompute slug from the (possibly renamed) title, then bump version
        // and updated_at. version bumps support Phase 3 change signaling.
        // Titles must stay linkable (`[[title]]`) — see WikiNameRules.
        let title = WikiNameRules.sanitized(title)
        let slug = try uniqueSlug(from: title, id: id)
        let stmt = try statement("""
        UPDATE pages
        SET title = ?2, slug = ?3, body_markdown = ?4,
            updated_at = ?5, version = version + 1, last_edited_by = ?6
        WHERE id = ?1;
        """)
        stmt.reset()  // reset cached statement before reusing (it may be at SQLITE_DONE)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(title, at: 2)
        try stmt.bind(slug, at: 3)
        try stmt.bind(body, at: 4)
        try stmt.bind(Date().timeIntervalSince1970, at: 5)
        if let lastEditedBy { try stmt.bind(lastEditedBy, at: 6) } else { try stmt.bind(nil, at: 6) }
        DebugLog.store("updatePage DEBUG: about to step")
        _ = try stmt.step()
        DebugLog.store("updatePage DEBUG: step OK, changes=\(sqlite3_changes(db))")
        guard sqlite3_changes(db) > 0 else { throw WikiStoreError.notFound(id) }
        }
    }

    // MARK: - Page versions (W0, PR #312)

    /// Append a new page version with CAS conflict detection. When
    /// `expectedHeadVersionID` is non-nil, throws `PageConflictError` if the
    /// current head doesn't match. When nil, blind write (backward-compatible).
    /// The `pages.body_markdown` mirror is updated so FTS triggers still fire
    /// and reads stay unchanged.
    public func appendPageVersion(
        pageID: PageID, title: String, body: String,
        expectedHeadVersionID: String?,
        lastEditedBy: String? = nil
    ) throws -> String {
        try mutate(event: { _ in localEvent(.page, id: pageID.rawValue, change: .updated) }) {
        let title = WikiNameRules.sanitized(title)
        let slug = try uniqueSlug(from: title, id: pageID)
        let bodyData = Data(body.utf8)
        let hash = SHA256.hash(data: bodyData)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        return try withTransaction {
            // 1. CAS check: resolve current head (ref → version_id, or MAX(id)).
            let head = try pageHeadVersionIDLocked(pageID: pageID)
            if let expected = expectedHeadVersionID, expected != head {
                throw PageConflictError(
                    pageID: pageID, expectedVersionID: expected, actualVersionID: head)
            }

            // 1b. Amend check (Phase 4 — autosave coalescing). Same-actor saves
            //     within a short coalescing window amend the head version in
            //     place instead of appending a new row. This bounds page history
            //     growth from autosave debouncing without losing data (the
            //     amend is in-place + event-emitted, so the File Provider
            //     invalidates and re-projects).
            if let amendVersionID = try tryAmendPageVersion(
                pageID: pageID, head: head, title: title, slug: slug,
                body: body, bodyData: bodyData, hash: hash,
                lastEditedBy: lastEditedBy, now: now, nowTS: nowTS)
            {
                return amendVersionID
            }

            // 2. Blob (identical body = one row, ever).
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(hash, at: 1)
            try insBlob.bind(Int64(bodyData.count), at: 2)
            try insBlob.bind(bodyData, at: 3)
            _ = try insBlob.step()

            // 3. Legacy-import agent + activity (mirrors the source pattern).
            let agentID = try legacyImportAgentID()
            let activityID = ULID.generate()
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'edit', ?2, ?3, ?3);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(agentID, at: 2)
            try insActivity.bind(nowTS, at: 3)
            _ = try insActivity.step()

            // 4. New version (parent = current head).
            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(pageID.rawValue, at: 2)
            if let parent = head { try insVersion.bind(parent, at: 3) }
            try insVersion.bind(hash, at: 4)
            try insVersion.bind(title, at: 5)
            try insVersion.bind(activityID, at: 6)
            try insVersion.bind(nowTS, at: 7)
            _ = try insVersion.step()

            // 5. Update the denormalized pages mirror (keeps FTS triggers
            //    working; reads stay on `pages` directly).
            let upPage = try statement("""
            UPDATE pages
            SET title = ?2, slug = ?3, body_markdown = ?4,
                updated_at = ?5, version = version + 1, last_edited_by = ?6
            WHERE id = ?1;
            """)
            upPage.reset()
            try upPage.bind(pageID.rawValue, at: 1)
            try upPage.bind(title, at: 2)
            try upPage.bind(slug, at: 3)
            try upPage.bind(body, at: 4)
            try upPage.bind(nowTS, at: 5)
            if let lastEditedBy { try upPage.bind(lastEditedBy, at: 6) } else { try upPage.bind(nil, at: 6) }
            _ = try upPage.step()
            guard sqlite3_changes(db) > 0 else { throw WikiStoreError.notFound(pageID) }

            // 6. Write the page-content ref (explicit, so revert works; the
            //    default-active rule still covers migrated root versions).
            let upRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?1, ?2, 1, ?3)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = generation + 1,
                updated_at = excluded.updated_at;
            """)
            upRef.reset()
            try upRef.bind(pageID.rawValue, at: 1)
            try upRef.bind(versionID, at: 2)
            try upRef.bind(nowTS, at: 3)
            _ = try upRef.step()

            return versionID
        }
        }
    }

    /// Coalescing window for autosave amend (Phase 4). Same-actor saves within
    /// this window amend the head version in place instead of appending a new
    /// row, bounding history growth from the 500ms autosave debounce. Tunable.
    private static let amendCoalescingWindow: TimeInterval = 5.0

    /// Attempt to amend the head page version in place instead of appending.
    /// Returns the (unchanged) version id if the amend succeeded, or nil to
    /// fall through to the append path. Assumes the caller holds the lock and
    /// is inside a `withTransaction` (internal helper called from
    /// `appendPageVersion`).
    ///
    /// All five conditions must hold:
    /// 1. Same actor (pre-save `pages.last_edited_by` == incoming `lastEditedBy`).
    /// 2. Head saved within the coalescing window.
    /// 3. Head has no children (no `parent_id`/`merge_parent_id` points at it).
    /// 4. No `workspace_refs` row references the head.
    /// 5. Blind-write guard: `pages.body_markdown` matches the head blob (no
    ///    unversioned `updatePage` happened between the last versioned save and now).
    private func tryAmendPageVersion(
        pageID: PageID, head: String?, title: String, slug: String,
        body: String, bodyData: Data, hash: String,
        lastEditedBy: String?, now: Date, nowTS: Double
    ) throws -> String? {
        // Need a head to amend.
        guard let head else { return nil }

        // 1. Same-actor check: the head must have been produced by the same
        //    actor as this save. We compare the pre-save `pages.last_edited_by`
        //    (which reflects the head version's actor — every versioned save
        //    routes through here and sets it) against the incoming actor.
        guard let lastEditedBy else { return nil }
        let actorStmt = try statement(
            "SELECT last_edited_by FROM pages WHERE id = ?1;")
        try actorStmt.bind(pageID.rawValue, at: 1)
        guard try actorStmt.step() else { actorStmt.reset(); return nil }
        let existingActor = actorStmt.text(at: 0)
        actorStmt.reset()  // reset immediately — don't pin the connection at SQLITE_ROW
        guard existingActor == lastEditedBy else { return nil }

        // 2. Within the coalescing window.
        let windowStmt = try statement("""
        SELECT saved_at FROM page_versions WHERE id = ?1;
        """)
        try windowStmt.bind(head, at: 1)
        guard try windowStmt.step() else { windowStmt.reset(); return nil }
        let savedAt = windowStmt.double(at: 0)
        windowStmt.reset()
        let elapsed = nowTS - savedAt
        guard elapsed >= 0 && elapsed <= Self.amendCoalescingWindow else { return nil }

        // 3. Head has no children (no version has parent_id or merge_parent_id
        //    pointing at it).
        let childStmt = try statement("""
        SELECT COUNT(*) FROM page_versions
        WHERE parent_id = ?1 OR merge_parent_id = ?1;
        """)
        try childStmt.bind(head, at: 1)
        guard try childStmt.step() else { childStmt.reset(); return nil }
        let childCount = Int(childStmt.int(at: 0))
        childStmt.reset()
        guard childCount == 0 else { return nil }

        // 4. No workspace_refs row references the head (version_id or base_version_id).
        let wsStmt = try statement("""
        SELECT COUNT(*) FROM workspace_refs
        WHERE version_id = ?1 OR base_version_id = ?1;
        """)
        try wsStmt.bind(head, at: 1)
        guard try wsStmt.step() else { wsStmt.reset(); return nil }
        let wsCount = Int(wsStmt.int(at: 0))
        wsStmt.reset()
        guard wsCount == 0 else { return nil }

        // 5. Blind-write guard: pages.body_markdown must match the head version's
        //    blob content. If they diverge, an unversioned `updatePage` happened
        //    between the last versioned save and now — append instead of amend.
        let bodyCheckStmt = try statement("""
        SELECT b.content FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ?1;
        """)
        try bodyCheckStmt.bind(head, at: 1)
        guard try bodyCheckStmt.step() else { bodyCheckStmt.reset(); return nil }
        let headBlobData = bodyCheckStmt.blob(at: 0)
        bodyCheckStmt.reset()
        let pageMirrorStmt = try statement(
            "SELECT body_markdown FROM pages WHERE id = ?1;")
        try pageMirrorStmt.bind(pageID.rawValue, at: 1)
        guard try pageMirrorStmt.step() else { pageMirrorStmt.reset(); return nil }
        let mirrorBody = pageMirrorStmt.text(at: 0)
        pageMirrorStmt.reset()
        let mirrorData = Data(mirrorBody.utf8)
        guard mirrorData == headBlobData else { return nil }

        // All conditions hold — amend in place.
        DebugLog.store("appendPageVersion: amending head \(head) for page \(pageID.rawValue) (same-actor coalescing, \(String(format: "%.2f", elapsed))s since last save)")

        // Insert the new blob (identical body = one row, ever).
        let insBlob = try statement(
            "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
        insBlob.reset()
        try insBlob.bind(hash, at: 1)
        try insBlob.bind(Int64(bodyData.count), at: 2)
        try insBlob.bind(bodyData, at: 3)
        _ = try insBlob.step()

        // Update the head version's blob_hash + title in place (same version id).
        let upVersion = try statement("""
        UPDATE page_versions
        SET blob_hash = ?2, title = ?3
        WHERE id = ?1;
        """)
        upVersion.reset()
        try upVersion.bind(head, at: 1)
        try upVersion.bind(hash, at: 2)
        try upVersion.bind(title, at: 3)
        _ = try upVersion.step()

        // Update the denormalized pages mirror.
        let upPage = try statement("""
        UPDATE pages
        SET title = ?2, slug = ?3, body_markdown = ?4,
            updated_at = ?5, version = version + 1, last_edited_by = ?6
        WHERE id = ?1;
        """)
        upPage.reset()
        try upPage.bind(pageID.rawValue, at: 1)
        try upPage.bind(title, at: 2)
        try upPage.bind(slug, at: 3)
        try upPage.bind(body, at: 4)
        try upPage.bind(nowTS, at: 5)
        try upPage.bind(lastEditedBy, at: 6)
        _ = try upPage.step()
        guard sqlite3_changes(db) > 0 else { throw WikiStoreError.notFound(pageID) }

        // Bump the page-content ref generation (same version_id, but generation
        // increments to signal the body change to the File Provider).
        let upRef = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?1, ?2, 1, ?3)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """)
        upRef.reset()
        try upRef.bind(pageID.rawValue, at: 1)
        try upRef.bind(head, at: 2)
        try upRef.bind(nowTS, at: 3)
        _ = try upRef.step()

        return head
    }
    /// MAX(id) from page_versions if no ref row exists (default-active rule).
    /// Returns nil if the page has no versions. Assumes the lock is held
    /// (internal helper called from within `withTransaction`/`mutate`).
    private func pageHeadVersionIDLocked(pageID: PageID) throws -> String? {
        // Try the explicit ref first.
        let refStmt = try statement("""
        SELECT version_id FROM refs WHERE kind = 'page-content' AND owner_id = ?1;
        """)
        defer { refStmt.reset() }
        try refStmt.bind(pageID.rawValue, at: 1)
        if try refStmt.step() {
            return refStmt.text(at: 0)
        }
        // No ref → default-active = MAX(id) for this page.
        // After v34, every page has a ref — reaching this fallback means a code
        // path failed to seed one. Log it (not assertionFailure — this remains
        // correct behavior, but it surfaces a ref-seeding gap).
        DebugLog.store("pageHeadVersionIDLocked: MAX(id) fallback for page \(pageID.rawValue) — no page-content ref found (should not happen after v34 migration)")
        let maxStmt = try statement("""
        SELECT id FROM page_versions
        WHERE page_id = ?1
        ORDER BY id DESC LIMIT 1;
        """)
        defer { maxStmt.reset() }
        try maxStmt.bind(pageID.rawValue, at: 1)
        if try maxStmt.step() {
            return maxStmt.text(at: 0)
        }
        return nil
    }

    public func pageHeadVersionID(pageID: PageID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try pageHeadVersionIDLocked(pageID: pageID)
    }

    public func pageVersionHistory(pageID: PageID) throws -> [PageVersionSummary] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at
        FROM page_versions
        WHERE page_id = ?1
        ORDER BY id ASC;
        """)
        defer { stmt.reset() }
        try stmt.bind(pageID.rawValue, at: 1)
        var out: [PageVersionSummary] = []
        while try stmt.step() {
            let parentIsNull = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL
            let mergeIsNull = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            let activityIsNull = sqlite3_column_type(stmt.handle, 6) == SQLITE_NULL
            out.append(PageVersionSummary(
                id: stmt.text(at: 0),
                pageID: PageID(rawValue: stmt.text(at: 1)),
                parentID: parentIsNull ? nil : stmt.text(at: 2),
                mergeParentID: mergeIsNull ? nil : stmt.text(at: 3),
                blobHash: stmt.text(at: 4),
                title: stmt.text(at: 5),
                activityID: activityIsNull ? nil : stmt.text(at: 6),
                savedAt: Date(timeIntervalSince1970: stmt.double(at: 7))
            ))
        }
        return out
    }

    public func revertPage(pageID: PageID, to versionID: String) throws {
        try mutate(event: { _ in localEvent(.page, id: pageID.rawValue, change: .updated) }) {
        try withTransaction {
            // Fetch the target version's blob + title.
            let target = try statement("""
            SELECT pv.blob_hash, pv.title, b.content
            FROM page_versions pv
            JOIN blobs b ON b.hash = pv.blob_hash
            WHERE pv.id = ?1 AND pv.page_id = ?2;
            """)
            target.reset()
            try target.bind(versionID, at: 1)
            try target.bind(pageID.rawValue, at: 2)
            guard try target.step() else {
                throw WikiStoreError.unexpected("version \(versionID) not found for page \(pageID.rawValue)")
            }
            let blobHash = target.text(at: 0)
            let title = target.text(at: 1)
            let bodyData = target.blob(at: 2)
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            target.reset()

            // Update the denormalized pages mirror.
            let slug = try uniqueSlug(from: WikiNameRules.sanitized(title), id: pageID)
            let now = Date().timeIntervalSince1970
            let upPage = try statement("""
            UPDATE pages
            SET title = ?2, slug = ?3, body_markdown = ?4,
                updated_at = ?5, version = version + 1
            WHERE id = ?1;
            """)
            upPage.reset()
            try upPage.bind(pageID.rawValue, at: 1)
            try upPage.bind(WikiNameRules.sanitized(title), at: 2)
            try upPage.bind(slug, at: 3)
            try upPage.bind(body, at: 4)
            try upPage.bind(now, at: 5)
            _ = try upPage.step()
            guard sqlite3_changes(db) > 0 else { throw WikiStoreError.notFound(pageID) }

            // Repoint the page-content ref to the target version.
            let upRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?1, ?2, 1, ?3)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = generation + 1,
                updated_at = excluded.updated_at;
            """)
            upRef.reset()
            try upRef.bind(pageID.rawValue, at: 1)
            try upRef.bind(versionID, at: 2)
            try upRef.bind(now, at: 3)
            _ = try upRef.step()
        }
        }
    }

    // MARK: - Workspaces (W1, PR #312)

    public func createWorkspace(name: String?, activityID: String?) throws -> String {
        try mutate(event: { _ in nil }) {  // workspaces are invisible to the FP token
        let id = ULID.generate()
        let now = Date().timeIntervalSince1970
        let stmt = try statement("""
        INSERT INTO workspaces (id, name, status, activity_id, created_at, updated_at)
        VALUES (?1, ?2, 'open', ?3, ?4, ?4);
        """)
        defer { stmt.reset() }
        try stmt.bind(id, at: 1)
        if let name { try stmt.bind(name, at: 2) }
        if let activityID { try stmt.bind(activityID, at: 3) }
        try stmt.bind(now, at: 4)
        _ = try stmt.step()
        return id
        }
    }

    public func workspaceSummary(id: String) throws -> WorkspaceSummary? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, name, status, activity_id, created_at, updated_at
        FROM workspaces WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id, at: 1)
        guard try stmt.step() else { return nil }
        let nameIsNull = sqlite3_column_type(stmt.handle, 1) == SQLITE_NULL
        let activityIsNull = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
        return WorkspaceSummary(
            id: stmt.text(at: 0),
            name: nameIsNull ? nil : stmt.text(at: 1),
            status: WorkspaceStatus(rawValue: stmt.text(at: 2)) ?? .open,
            activityID: activityIsNull ? nil : stmt.text(at: 3),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 5)))
    }

    public func workspaceRefs(workspaceID: String) throws -> [WorkspaceRef] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT workspace_id, owner_id, base_version_id, version_id, blob_hash, title, updated_at
        FROM workspace_refs WHERE workspace_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(workspaceID, at: 1)
        var out: [WorkspaceRef] = []
        while try stmt.step() {
            let baseIsNull = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL
            let versionIsNull = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            let blobHashIsNull = sqlite3_column_type(stmt.handle, 4) == SQLITE_NULL
            let titleIsNull = sqlite3_column_type(stmt.handle, 5) == SQLITE_NULL
            out.append(WorkspaceRef(
                workspaceID: stmt.text(at: 0),
                ownerID: PageID(rawValue: stmt.text(at: 1)),
                baseVersionID: baseIsNull ? nil : stmt.text(at: 2),
                versionID: versionIsNull ? nil : stmt.text(at: 3),
                blobHash: blobHashIsNull ? nil : stmt.text(at: 4),
                title: titleIsNull ? nil : stmt.text(at: 5),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 6))))
        }
        return out
    }

    public func workspaceWritePage(
        workspaceID: String, pageID: PageID, title: String, body: String
    ) throws -> String {
        try mutate(event: { _ in nil }) {  // workspace writes are invisible to the FP token
        let title = WikiNameRules.sanitized(title)
        let bodyData = Data(body.utf8)
        let hash = SHA256.hash(data: bodyData)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        return try withTransaction {
            // Guard: the workspace must be 'open'. Writes to a
            // merged/conflicted/abandoned workspace would succeed silently but
            // be invisible — the workspace will never merge again, so agent
            // edits (e.g. via a stale WIKI_WORKSPACE env var) would vanish.
            let statusStmt = try statement(
                "SELECT status FROM workspaces WHERE id = ?1;")
            statusStmt.reset()
            try statusStmt.bind(workspaceID, at: 1)
            guard try statusStmt.step(), statusStmt.text(at: 0) == "open" else {
                throw WikiStoreError.unexpected("workspace \(workspaceID) is not open")
            }
            statusStmt.reset()

            // 0. Determine whether the page exists on main.
            let pageExists = try statement("SELECT 1 FROM pages WHERE id = ?1;")
            try pageExists.bind(pageID.rawValue, at: 1)
            let existsOnMain = try pageExists.step()
            pageExists.reset()  // reset immediately — don't pin the connection at SQLITE_ROW

            if !existsOnMain {
                // Created page: stage entirely in workspace_refs (v35).
                // No `pages` row, no `page_versions` row, no activity.
                // The page is invisible on main until merge mints it.
                // The blob is needed so the merge can read the staged body.
                let insBlob = try statement(
                    "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
                insBlob.reset()
                try insBlob.bind(hash, at: 1)
                try insBlob.bind(Int64(bodyData.count), at: 2)
                try insBlob.bind(bodyData, at: 3)
                _ = try insBlob.step()

                // UPSERT workspace_refs: blob_hash + title set, version_id NULL,
                // base_version_id NULL (created page — no base to diff against).
                let upRef = try statement("""
                INSERT INTO workspace_refs (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
                VALUES (?1, 'page-content', ?2, NULL, NULL, ?3, ?4, ?5)
                ON CONFLICT(workspace_id, kind, owner_id) DO UPDATE SET
                    version_id = NULL,
                    blob_hash = excluded.blob_hash,
                    title = excluded.title,
                    updated_at = excluded.updated_at;
                """)
                upRef.reset()
                try upRef.bind(workspaceID, at: 1)
                try upRef.bind(pageID.rawValue, at: 2)
                try upRef.bind(hash, at: 3)
                try upRef.bind(title, at: 4)
                try upRef.bind(nowTS, at: 5)
                _ = try upRef.step()

                // Touch the workspace's updated_at.
                let touchWs = try statement(
                    "UPDATE workspaces SET updated_at = ?2 WHERE id = ?1;")
                touchWs.reset()
                try touchWs.bind(workspaceID, at: 1)
                try touchWs.bind(nowTS, at: 2)
                _ = try touchWs.step()

                // Return the blob hash as the identifier (no version was created).
                return hash
            }

            // Existing page (stages version_id): current behavior unchanged.
            // 1. Blob.
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(hash, at: 1)
            try insBlob.bind(Int64(bodyData.count), at: 2)
            try insBlob.bind(bodyData, at: 3)
            _ = try insBlob.step()

            // 2. Activity + agent.
            let agentID = try legacyImportAgentID()
            let activityID = ULID.generate()
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'edit', ?2, ?3, ?3);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(agentID, at: 2)
            try insActivity.bind(nowTS, at: 3)
            _ = try insActivity.step()

            // 3. Append page_version (parent = workspace's current head for
            //    this page, or main head if first touch).
            let wsHead = try workspacePageVersionLocked(
                workspaceID: workspaceID, pageID: pageID)
            let mainHead = try pageHeadVersionIDLocked(pageID: pageID)

            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(pageID.rawValue, at: 2)
            // Parent = workspace head if it exists, else main head (this is the
            // first workspace write — chain from main).
            if let parent = wsHead ?? mainHead {
                try insVersion.bind(parent, at: 3)
            }
            try insVersion.bind(hash, at: 4)
            try insVersion.bind(title, at: 5)
            try insVersion.bind(activityID, at: 6)
            try insVersion.bind(nowTS, at: 7)
            _ = try insVersion.step()

            // 4. UPSERT workspace_refs. On first touch, record base_version_id
            //    = main head (the three-way-merge base). On subsequent touches,
            //    keep the original base. Clear blob_hash + title to maintain
            //    the staging invariant (existing page → version_id set, not
            //    blob_hash + title).
            let baseToRecord: String?
            if wsHead != nil {
                // Already have a workspace_ref → keep the existing base.
                baseToRecord = nil  // ON CONFLICT won't touch base_version_id
            } else {
                // First touch → record current main head as the base.
                baseToRecord = mainHead
            }

            let upRef = try statement("""
            INSERT INTO workspace_refs (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
            VALUES (?1, 'page-content', ?2, ?3, ?4, NULL, NULL, ?5)
            ON CONFLICT(workspace_id, kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                blob_hash = NULL,
                title = NULL,
                updated_at = excluded.updated_at;
            """)
            upRef.reset()
            try upRef.bind(workspaceID, at: 1)
            try upRef.bind(pageID.rawValue, at: 2)
            if let base = baseToRecord { try upRef.bind(base, at: 3) }
            try upRef.bind(versionID, at: 4)
            try upRef.bind(nowTS, at: 5)
            _ = try upRef.step()

            // 5. Update the workspace's updated_at.
            let touchWs = try statement(
                "UPDATE workspaces SET updated_at = ?2 WHERE id = ?1;")
            touchWs.reset()
            try touchWs.bind(workspaceID, at: 1)
            try touchWs.bind(nowTS, at: 2)
            _ = try touchWs.step()

            return versionID
        }
        }
    }

    /// Internal: resolve the workspace's current version for a page.
    /// Assumes the lock is held. Returns nil if the page has no workspace_ref
    /// or if the page is staged as a created page (version_id is NULL — the
    /// content lives in blob_hash instead of a page_version row).
    private func workspacePageVersionLocked(
        workspaceID: String, pageID: PageID
    ) throws -> String? {
        let stmt = try statement("""
        SELECT version_id FROM workspace_refs
        WHERE workspace_id = ?1 AND kind = 'page-content' AND owner_id = ?2;
        """)
        defer { stmt.reset() }
        try stmt.bind(workspaceID, at: 1)
        try stmt.bind(pageID.rawValue, at: 2)
        if try stmt.step() {
            // Created pages have version_id = NULL (staged as blob_hash).
            if sqlite3_column_type(stmt.handle, 0) == SQLITE_NULL { return nil }
            return stmt.text(at: 0)
        }
        return nil
    }

    public func workspacePageVersion(workspaceID: String, pageID: PageID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try workspacePageVersionLocked(workspaceID: workspaceID, pageID: pageID)
    }

    /// Overlay read: return the workspace's staged body for a page, or nil if
    /// the workspace hasn't touched it. For existing pages (version_id set),
    /// reads the version's blob. For created pages (blob_hash set, version_id
    /// nil), reads the staged blob directly. Phase 7.
    public func workspacePageBody(workspaceID: String, pageID: PageID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        // Check if the workspace has a ref for this page.
        let refStmt = try statement("""
        SELECT version_id, blob_hash FROM workspace_refs
        WHERE workspace_id = ?1 AND kind = 'page-content' AND owner_id = ?2;
        """)
        defer { refStmt.reset() }
        try refStmt.bind(workspaceID, at: 1)
        try refStmt.bind(pageID.rawValue, at: 2)
        guard try refStmt.step() else { return nil }

        let versionIsNull = sqlite3_column_type(refStmt.handle, 0) == SQLITE_NULL
        let blobHashIsNull = sqlite3_column_type(refStmt.handle, 1) == SQLITE_NULL
        let versionID = versionIsNull ? nil : refStmt.text(at: 0)
        let blobHash = blobHashIsNull ? nil : refStmt.text(at: 1)
        refStmt.reset()

        if let versionID {
            // Existing page: read the version's blob.
            let blobStmt = try statement(
                "SELECT pv.blob_hash, b.content FROM page_versions pv "
                + "JOIN blobs b ON b.hash = pv.blob_hash WHERE pv.id = ?1;")
            defer { blobStmt.reset() }
            try blobStmt.bind(versionID, at: 1)
            guard try blobStmt.step() else { return nil }
            let data = blobStmt.blob(at: 1)
            return String(data: data, encoding: .utf8)
        }

        guard let blobHash else { return nil }
        // Created page: read the staged blob directly.
        let blobStmt = try statement("SELECT content FROM blobs WHERE hash = ?1;")
        defer { blobStmt.reset() }
        try blobStmt.bind(blobHash, at: 1)
        guard try blobStmt.step() else { return nil }
        let data = blobStmt.blob(at: 0)
        return String(data: data, encoding: .utf8)
    }

    /// Stage wiki-index changes into the workspace (`index_body` + the
    /// `index_base_version` snapshot taken at workspace creation). NO-EMIT:
    /// workspace writes are invisible to the File Provider token until merge.
    public func setWorkspaceIndexBody(
        workspaceID: String, indexBody: String, indexBaseVersion: String
    ) throws {
        try mutate(event: { _ in nil }) {
        let stmt = try statement("""
        UPDATE workspaces SET index_body = ?2, index_base_version = ?3, updated_at = ?4
        WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(workspaceID, at: 1)
        try stmt.bind(indexBody, at: 2)
        try stmt.bind(indexBaseVersion, at: 3)
        try stmt.bind(Date().timeIntervalSince1970, at: 4)
        _ = try stmt.step()
        }
    }

    @discardableResult
    public func workspaceMerge(workspaceID: String) throws -> [String] {
        // Phase 1: attempt the merge inside a transaction. If any page
        // conflicts, roll back the partial fast-forwards AND park the
        // workspace as 'conflicted' in a separate transaction.
        var conflicts: [(pageID: String, base: String?, wsVersion: String, mainVersion: String?)] = []
        var mergedPageIDs: [String] = []
        do {
            try mutate(event: { _ in nil }) {
            try withTransaction {
                // 1. Mark workspace as 'merging'.
                let markMerging = try statement(
                    "UPDATE workspaces SET status = 'merging', updated_at = ?2 WHERE id = ?1 AND status = 'open';")
                markMerging.reset()
                try markMerging.bind(workspaceID, at: 1)
                try markMerging.bind(Date().timeIntervalSince1970, at: 2)
                _ = try markMerging.step()
                guard sqlite3_changes(db) > 0 else {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) is not open (already merging/merged/conflicted/abandoned)")
                }

                // 2. For each workspace_ref, attempt fast-forward or mint.
                let refs = try statement("""
                SELECT owner_id, base_version_id, version_id, blob_hash, title
                FROM workspace_refs WHERE workspace_id = ?1;
                """)
                defer { refs.reset() }
                try refs.bind(workspaceID, at: 1)

                while try refs.step() {
                    let pageIDStr = refs.text(at: 0)
                    let baseIsNull = sqlite3_column_type(refs.handle, 1) == SQLITE_NULL
                    let base = baseIsNull ? nil : refs.text(at: 1)
                    let versionIdIsNull = sqlite3_column_type(refs.handle, 2) == SQLITE_NULL
                    let wsVersion = versionIdIsNull ? nil : refs.text(at: 2)
                    let blobHashIsNull = sqlite3_column_type(refs.handle, 3) == SQLITE_NULL
                    let blobHash = blobHashIsNull ? nil : refs.text(at: 3)
                    let title = refs.text(at: 4)
                    let pageID = PageID(rawValue: pageIDStr)

                    // Resolve main head.
                    let mainHead = try pageHeadVersionIDLocked(pageID: pageID)

                    if versionIdIsNull {
                        // Created page (v35 staging): content is in blob_hash +
                        // title, no page_version row. Mint the `pages` row +
                        // root version + page-content ref here.
                        guard let stagedHash = blobHash else {
                            throw WikiStoreError.unexpected("workspaceMerge: created page \(pageIDStr) has nil blob_hash")
                        }
                        // Conflict: a page-content ref already exists on main
                        // (another workspace created the same page identity). Park
                        // rather than creating a duplicate.
                        let mainRefExists = try statement("""
                        SELECT 1 FROM refs WHERE kind = 'page-content' AND owner_id = ?1;
                        """)
                        defer { mainRefExists.reset() }
                        try mainRefExists.bind(pageIDStr, at: 1)
                        if try mainRefExists.step() {
                            conflicts.append((pageIDStr, nil, stagedHash, mainHead))
                            continue
                        }
                        try mintCreatedPage(
                            pageID: pageID, blobHash: stagedHash, title: title)
                        mergedPageIDs.append(pageIDStr)
                    } else if base == nil {
                        // Old-style created page (pre-v35: version_id set, base
                        // nil). A placeholder `pages` row was created by the
                        // old workspaceWritePage. Fast-forward the existing
                        // version.
                        let mainRefExists = try statement("""
                        SELECT 1 FROM refs WHERE kind = 'page-content' AND owner_id = ?1;
                        """)
                        defer { mainRefExists.reset() }
                        try mainRefExists.bind(pageIDStr, at: 1)
                        if try mainRefExists.step() {
                            conflicts.append((pageIDStr, base, wsVersion!, mainHead))
                            continue
                        }
                        try fastForwardPage(
                            pageID: pageID, versionID: wsVersion!)
                        mergedPageIDs.append(pageIDStr)
                    } else if mainHead == base {
                        try fastForwardPage(
                            pageID: pageID, versionID: wsVersion!)
                        mergedPageIDs.append(pageIDStr)
                    } else {
                        // Divergence — attempt diff3 merge (W2).
                        let mergeResult = try diff3MergePage(
                            pageID: pageID, baseVersionID: base!,
                            mainVersionID: mainHead!, wsVersionID: wsVersion!)
                        switch mergeResult {
                        case .merged:
                            mergedPageIDs.append(pageIDStr)  // merge version created, mirror updated
                        case .conflict:
                            conflicts.append((pageIDStr, base, wsVersion!, mainHead))
                        }
                    }
                }

                // 2b. Wiki-index line-set three-way merge (Phase 6). If the
                //     workspace staged an index body (`index_body` non-null),
                //     merge it against main using `index_base_version` as the
                //     common ancestor. On conflict, park the workspace.
                let idxStmt = try statement("""
                SELECT index_body, index_base_version
                FROM workspaces WHERE id = ?1;
                """)
                defer { idxStmt.reset() }
                try idxStmt.bind(workspaceID, at: 1)
                if try idxStmt.step(),
                   sqlite3_column_type(idxStmt.handle, 0) != SQLITE_NULL {
                    let theirs = idxStmt.text(at: 0)
                    let base = idxStmt.text(at: 1)  // may be empty/seeded
                    // Read the current main wiki_index body (ours).
                    let mainIdx = try statement(
                        "SELECT COALESCE(body_markdown, '') FROM wiki_index WHERE id = 1;")
                    defer { mainIdx.reset() }
                    let ours: String
                    if try mainIdx.step() {
                        ours = mainIdx.text(at: 0)
                    } else {
                        ours = WikiIndex.defaultBody
                    }
                    switch Diff3.merge(base: base, ours: ours, theirs: theirs) {
                    case .clean(let mergedText):
                        // Write the merged result directly (bypass updateWikiIndex
                        // so we stay inside this transaction — no lock re-entry).
                        let upIdx = try statement("""
                        INSERT INTO wiki_index (id, body_markdown, updated_at, version)
                        VALUES (1, ?1, ?2, 1)
                        ON CONFLICT(id) DO UPDATE SET
                            body_markdown = excluded.body_markdown,
                            updated_at = excluded.updated_at,
                            version = wiki_index.version + 1;
                        """)
                        upIdx.reset()
                        defer { upIdx.reset() }
                        try upIdx.bind(mergedText, at: 1)
                        try upIdx.bind(Date().timeIntervalSince1970, at: 2)
                        _ = try upIdx.step()
                    case .conflict:
                        conflicts.append(("wiki_index", base, theirs, ours))
                    }
                }

                // 3. If any conflicts, abort the transaction (rolls back all
                //    partial fast-forwards). The 'conflicted' status is set
                //    in a follow-up transaction below.
                if !conflicts.isEmpty {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) merge: \(conflicts.count) conflict(s)")
                }

                // 4. All fast-forwarded → mark 'merged'.
                let markMerged = try statement(
                    "UPDATE workspaces SET status = 'merged', updated_at = ?2 WHERE id = ?1;")
                markMerged.reset()
                try markMerged.bind(workspaceID, at: 1)
                try markMerged.bind(Date().timeIntervalSince1970, at: 2)
                _ = try markMerged.step()
            }
            }
        } catch {
            // Only park if there were actual conflicts (not a different error).
            if !conflicts.isEmpty {
                let descriptions = conflicts.map { c in
                    "\(c.pageID): base=\(c.base ?? "nil") ws=\(c.wsVersion) main=\(c.mainVersion ?? "nil")"
                }.joined(separator: "; ")
                DebugLog.store("workspaceMerge: \(conflicts.count) conflict(s) — \(descriptions)")
                // Park in a separate transaction (the merge transaction
                // rolled back, so the workspace is still 'open'). Persist
                // the conflict details so they can be queried and resolved.
                try mutate(event: { _ in nil }) {
                let nowTS = Date().timeIntervalSince1970
                let park = try statement(
                    "UPDATE workspaces SET status = 'conflicted', updated_at = ?2 WHERE id = ?1;")
                park.reset()
                try park.bind(workspaceID, at: 1)
                try park.bind(nowTS, at: 2)
                _ = try park.step()

                // Clear any stale conflict rows, then persist the new ones.
                let delConflicts = try statement(
                    "DELETE FROM workspace_conflicts WHERE workspace_id = ?1;")
                delConflicts.reset()
                try delConflicts.bind(workspaceID, at: 1)
                _ = try delConflicts.step()

                let insConflict = try statement("""
                INSERT INTO workspace_conflicts (workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                """)
                for c in conflicts {
                    insConflict.reset()
                    try insConflict.bind(workspaceID, at: 1)
                    try insConflict.bind(c.pageID, at: 2)
                    if let b = c.base { try insConflict.bind(b, at: 3) }
                    if let m = c.mainVersion { try insConflict.bind(m, at: 4) }
                    try insConflict.bind(c.wsVersion, at: 5)
                    try insConflict.bind(nowTS, at: 6)
                    _ = try insConflict.step()
                }
                }
                return []  // parked as conflicted — no pages merged
            }
            throw error
        }

        // Post-merge completeness (Phase 6): re-embed merged pages and append a
        // log entry. Both are best-effort and run AFTER the merge transaction
        // commits (no inference-in-transaction). The lock has been released by
        // mutate() at this point, so appendLog/storePageChunks each re-enter it
        // cleanly.
        if !mergedPageIDs.isEmpty {
            for pageIDStr in mergedPageIDs {
                let pid = PageID(rawValue: pageIDStr)
                if let page = try? getPage(id: pid) {
                    let text = page.bodyMarkdown.isEmpty
                        ? page.title
                        : "\(page.title)\n\n\(page.bodyMarkdown)"
                    let chunks = EmbeddingService.chunkedEmbeddings(for: text)
                    if !chunks.isEmpty {
                        try? storePageChunks(id: pid, chunks: chunks)
                    }
                }
            }
            let note = "\(mergedPageIDs.count) page(s) merged"
            _ = try? appendLog(
                kind: .ingest,
                title: "Workspace merge completed",
                note: note)
        }

        return mergedPageIDs
    }

    /// Fast-forward an existing page: repoint the main `page-content` ref to
    /// the workspace's version + update the `pages` mirror from the version's
    /// blob. Assumes the lock + a transaction are held.
    private func fastForwardPage(pageID: PageID, versionID: String) throws {
        // Fetch the version's blob + title.
        let target = try statement("""
        SELECT pv.blob_hash, pv.title, b.content
        FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ?1 AND pv.page_id = ?2;
        """)
        defer { target.reset() }
        try target.bind(versionID, at: 1)
        try target.bind(pageID.rawValue, at: 2)
        guard try target.step() else {
            throw WikiStoreError.unexpected("workspaceMerge: version \(versionID) not found for page \(pageID.rawValue)")
        }
        let title = target.text(at: 1)
        let bodyData = target.blob(at: 2)
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        // Update the pages mirror.
        let slug = try uniqueSlug(from: WikiNameRules.sanitized(title), id: pageID)
        let now = Date().timeIntervalSince1970
        let upPage = try statement("""
        UPDATE pages
        SET title = ?2, slug = ?3, body_markdown = ?4,
            updated_at = ?5, version = version + 1
        WHERE id = ?1;
        """)
        upPage.reset()
        try upPage.bind(pageID.rawValue, at: 1)
        try upPage.bind(WikiNameRules.sanitized(title), at: 2)
        try upPage.bind(slug, at: 3)
        try upPage.bind(body, at: 4)
        try upPage.bind(now, at: 5)
        _ = try upPage.step()

        // Repoint the main page-content ref.
        let upRef = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?1, ?2, 1, ?3)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """)
        upRef.reset()
        try upRef.bind(pageID.rawValue, at: 1)
        try upRef.bind(versionID, at: 2)
        try upRef.bind(now, at: 3)
        _ = try upRef.step()
    }

    /// Fast-forward a page created in the workspace via the old (pre-v35)
    /// placeholder-row path. Since the old `workspaceWritePage` created a
    /// placeholder `pages` row, this is the same as `fastForwardPage` — just
    /// update the mirror + repoint the ref. Assumes lock + transaction held.
    private func fastForwardCreatePage(
        pageID: PageID, versionID: String, workspaceID: String
    ) throws {
        try fastForwardPage(pageID: pageID, versionID: versionID)
    }

    /// Mint a created page at merge time (v35 staged-page path). Creates the
    /// `pages` row, a root `page_versions` row from the staged blob, and a
    /// `page-content` ref pointing at it. This is the merge-time counterpart
    /// to the created-page staging in `workspaceWritePage` — until now, the
    /// page existed only as `workspace_refs.blob_hash` + `title`. Assumes the
    /// lock + a transaction are held.
    private func mintCreatedPage(
        pageID: PageID, blobHash: String, title: String
    ) throws {
        // Fetch the staged body from the blob.
        let bodyStmt = try statement(
            "SELECT content FROM blobs WHERE hash = ?1;")
        bodyStmt.reset()
        try bodyStmt.bind(blobHash, at: 1)
        guard try bodyStmt.step() else {
            throw WikiStoreError.unexpected("mintCreatedPage: blob \(blobHash) not found")
        }
        let bodyData = bodyStmt.blob(at: 0)
        bodyStmt.reset()
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        let now = Date().timeIntervalSince1970
        let slug = try uniqueSlug(from: title, id: pageID)

        // 1. Create the `pages` row.
        let insPage = try statement("""
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
        VALUES (?1, ?2, ?3, ?4, ?5, ?5, 1);
        """)
        insPage.reset()
        try insPage.bind(pageID.rawValue, at: 1)
        try insPage.bind(title, at: 2)
        try insPage.bind(slug, at: 3)
        try insPage.bind(body, at: 4)
        try insPage.bind(now, at: 5)
        _ = try insPage.step()

        // 2. Activity + agent.
        let agentID = try legacyImportAgentID()
        let activityID = ULID.generate()
        let insActivity = try statement("""
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?1, 'edit', ?2, ?3, ?3);
        """)
        insActivity.reset()
        try insActivity.bind(activityID, at: 1)
        try insActivity.bind(agentID, at: 2)
        try insActivity.bind(now, at: 3)
        _ = try insActivity.step()

        // 3. Root version (parent NULL — this is the first version).
        let versionID = ULID.generate()
        let insVersion = try statement("""
        INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
        VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6);
        """)
        insVersion.reset()
        try insVersion.bind(versionID, at: 1)
        try insVersion.bind(pageID.rawValue, at: 2)
        try insVersion.bind(blobHash, at: 3)
        try insVersion.bind(title, at: 4)
        try insVersion.bind(activityID, at: 5)
        try insVersion.bind(now, at: 6)
        _ = try insVersion.step()

        // 4. Page-content ref pointing at the new root version.
        let insRef = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?1, ?2, 1, ?3);
        """)
        insRef.reset()
        try insRef.bind(pageID.rawValue, at: 1)
        try insRef.bind(versionID, at: 2)
        try insRef.bind(now, at: 3)
        _ = try insRef.step()
    }

    /// The result of a diff3 merge attempt for a single page.
    private enum Diff3MergeResult {
        case merged
        case conflict
    }

    /// Attempt a three-way diff3 merge for a divergent page (W2). Fetches
    /// the three blobs (base, ours=main, theirs=workspace), runs `Diff3.merge`.
    /// If clean, creates a merge version (`parent_id = mainVersionID`,
    /// `merge_parent_id = wsVersionID`) with a merge PROV activity, updates the
    /// pages mirror + main ref, and regenerates links/embeddings.
    /// If conflict, returns `.conflict` (caller parks the workspace).
    /// Assumes lock + transaction held.
    private func diff3MergePage(
        pageID: PageID, baseVersionID: String,
        mainVersionID: String, wsVersionID: String
    ) throws -> Diff3MergeResult {
        // Fetch the three blobs.
        let baseText = try fetchVersionBody(versionID: baseVersionID)
        let oursText = try fetchVersionBody(versionID: mainVersionID)
        let theirsText = try fetchVersionBody(versionID: wsVersionID)

        // Run diff3.
        let result = Diff3.merge(base: baseText, ours: oursText, theirs: theirsText)
        guard case .clean(let mergedText) = result else {
            return .conflict
        }

        // Create the merge version.
        let mergedData = Data(mergedText.utf8)
        let hash = SHA256.hash(data: mergedData)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        // Blob.
        let insBlob = try statement(
            "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
        insBlob.reset()
        try insBlob.bind(hash, at: 1)
        try insBlob.bind(Int64(mergedData.count), at: 2)
        try insBlob.bind(mergedData, at: 3)
        _ = try insBlob.step()

        // Merge PROV activity.
        let agentID = try legacyImportAgentID()
        let activityID = ULID.generate()
        let insActivity = try statement("""
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?1, 'merge', ?2, ?3, ?3);
        """)
        insActivity.reset()
        try insActivity.bind(activityID, at: 1)
        try insActivity.bind(agentID, at: 2)
        try insActivity.bind(nowTS, at: 3)
        _ = try insActivity.step()

        // Fetch the title from theirs (the workspace's version) — the merge
        // preserves the workspace's title choice (the agent is the active writer).
        let titleStmt = try statement(
            "SELECT title FROM page_versions WHERE id = ?1;")
        titleStmt.reset()
        try titleStmt.bind(wsVersionID, at: 1)
        guard try titleStmt.step() else {
            throw WikiStoreError.unexpected("diff3Merge: workspace version \(wsVersionID) not found")
        }
        let title = titleStmt.text(at: 0)
        titleStmt.reset()

        // Merge version (two parents).
        let versionID = ULID.generate()
        let insVersion = try statement("""
        INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
        """)
        insVersion.reset()
        try insVersion.bind(versionID, at: 1)
        try insVersion.bind(pageID.rawValue, at: 2)
        try insVersion.bind(mainVersionID, at: 3)      // parent = main head
        try insVersion.bind(wsVersionID, at: 4)         // merge_parent = workspace version
        try insVersion.bind(hash, at: 5)
        try insVersion.bind(title, at: 6)
        try insVersion.bind(activityID, at: 7)
        try insVersion.bind(nowTS, at: 8)
        _ = try insVersion.step()

        // Update the pages mirror.
        let sanitizedTitle = WikiNameRules.sanitized(title)
        let slug = try uniqueSlug(from: sanitizedTitle, id: pageID)
        let upPage = try statement("""
        UPDATE pages
        SET title = ?2, slug = ?3, body_markdown = ?4,
            updated_at = ?5, version = version + 1
        WHERE id = ?1;
        """)
        upPage.reset()
        try upPage.bind(pageID.rawValue, at: 1)
        try upPage.bind(sanitizedTitle, at: 2)
        try upPage.bind(slug, at: 3)
        try upPage.bind(mergedText, at: 4)
        try upPage.bind(nowTS, at: 5)
        _ = try upPage.step()

        // Repoint the main page-content ref.
        let upRef = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?1, ?2, 1, ?3)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """)
        upRef.reset()
        try upRef.bind(pageID.rawValue, at: 1)
        try upRef.bind(versionID, at: 2)
        try upRef.bind(nowTS, at: 3)
        _ = try upRef.step()

        // Derived-data regeneration: re-parse wiki links from the merged body
        // (non-fatal — the FTS triggers fire automatically from the pages UPDATE).
        try? replaceLinks(from: pageID,
                          parsedLinks: WikiLinkParser.parse(mergedText))

        return .merged
    }

    /// Fetch the body text of a page version from its blob. Assumes lock held.
    private func fetchVersionBody(versionID: String) throws -> String {
        let stmt = try statement("""
        SELECT b.content FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(versionID, at: 1)
        guard try stmt.step() else {
            throw WikiStoreError.unexpected("version \(versionID) not found")
        }
        let data = stmt.blob(at: 0)
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func abandonWorkspace(id: String) throws {
        try mutate(event: { _ in nil }) {
        try withTransaction {
            // Delete workspace_refs (FK ON DELETE CASCADE would handle this,
            // but we're doing an UPDATE not DELETE, so do it explicitly).
            let delRefs = try statement(
                "DELETE FROM workspace_refs WHERE workspace_id = ?1;")
            delRefs.reset()
            try delRefs.bind(id, at: 1)
            _ = try delRefs.step()

            let now = Date().timeIntervalSince1970
            let stmt = try statement(
                "UPDATE workspaces SET status = 'abandoned', updated_at = ?2 WHERE id = ?1;")
            stmt.reset()
            try stmt.bind(id, at: 1)
            try stmt.bind(now, at: 2)
            _ = try stmt.step()
            guard sqlite3_changes(db) > 0 else {
                throw WikiStoreError.notFound(PageID(rawValue: id))
            }
        }
        }
    }

    /// Refresh (re-base) a workspace against the current main: for each
    /// workspace_ref, run diff3 with the new main head. If clean, update
    /// `base_version_id` to current main_head and store the merged version as
    /// the workspace's new version. If conflict on any page, park.
    /// The workspace must be `open` (not merging/merged/conflicted/abandoned).
    public func workspaceRefresh(workspaceID: String) throws {
        var conflicts: [(pageID: String, base: String?, wsVersion: String, mainVersion: String?)] = []
        do {
            try mutate(event: { _ in nil }) {
            try withTransaction {
                // Guard: must be open.
                let statusStmt = try statement(
                    "SELECT status FROM workspaces WHERE id = ?1;")
                statusStmt.reset()
                try statusStmt.bind(workspaceID, at: 1)
                guard try statusStmt.step(), statusStmt.text(at: 0) == "open" else {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) is not open")
                }
                statusStmt.reset()

                let refs = try statement("""
                SELECT owner_id, base_version_id, version_id
                FROM workspace_refs WHERE workspace_id = ?1;
                """)
                defer { refs.reset() }
                try refs.bind(workspaceID, at: 1)

                while try refs.step() {
                    let pageIDStr = refs.text(at: 0)
                    let baseIsNull = sqlite3_column_type(refs.handle, 1) == SQLITE_NULL
                    let base = baseIsNull ? nil : refs.text(at: 1)
                    let versionIdIsNull = sqlite3_column_type(refs.handle, 2) == SQLITE_NULL
                    let wsVersion = versionIdIsNull ? nil : refs.text(at: 2)
                    let pageID = PageID(rawValue: pageIDStr)

                    let mainHead = try pageHeadVersionIDLocked(pageID: pageID)

                    // Created pages (v35: version_id NULL) have no version to
                    // diff3; their staging stays in blob_hash until merge.
                    // Pages where base is already current have no divergence.
                    if versionIdIsNull || base == nil || mainHead == base {
                        // No divergence — base is already current.
                        continue
                    }

                    // Attempt diff3: base vs main (ours) vs workspace (theirs).
                    // The merged result becomes the workspace's NEW version,
                    // and base_version_id is updated to the current main head.
                    // Main is NOT modified during refresh.
                    let baseText = try fetchVersionBody(versionID: base!)
                    let oursText = try fetchVersionBody(versionID: mainHead!)
                    let theirText = try fetchVersionBody(versionID: wsVersion!)

                    let result = Diff3.merge(base: baseText, ours: oursText, theirs: theirText)
                    guard case .clean(let mergedText) = result else {
                        conflicts.append((pageIDStr, base, wsVersion!, mainHead))
                        continue
                    }

                    // Write the merged version as a new workspace version.
                    let mergedData = Data(mergedText.utf8)
                    let hash = SHA256.hash(data: mergedData)
                        .map { String(format: "%02x", $0) }.joined()
                    let nowTS = Date().timeIntervalSince1970

                    let insBlob = try statement(
                        "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
                    insBlob.reset()
                    try insBlob.bind(hash, at: 1)
                    try insBlob.bind(Int64(mergedData.count), at: 2)
                    try insBlob.bind(mergedData, at: 3)
                    _ = try insBlob.step()

                    let agentID = try legacyImportAgentID()
                    let activityID = ULID.generate()
                    let insActivity = try statement("""
                    INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                    VALUES (?1, 'refresh', ?2, ?3, ?3);
                    """)
                    insActivity.reset()
                    try insActivity.bind(activityID, at: 1)
                    try insActivity.bind(agentID, at: 2)
                    try insActivity.bind(nowTS, at: 3)
                    _ = try insActivity.step()

                    // Fetch the title from the workspace version.
                    let titleStmt = try statement("SELECT title FROM page_versions WHERE id = ?1;")
                    titleStmt.reset()
                    try titleStmt.bind(wsVersion!, at: 1)
                    guard try titleStmt.step() else { continue }
                    let title = titleStmt.text(at: 0)
                    titleStmt.reset()

                    let newVersionID = ULID.generate()
                    let insVersion = try statement("""
                    INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                    """)
                    insVersion.reset()
                    try insVersion.bind(newVersionID, at: 1)
                    try insVersion.bind(pageID.rawValue, at: 2)
                    try insVersion.bind(mainHead, at: 3)      // parent = main head (re-based)
                    try insVersion.bind(wsVersion!, at: 4)      // merge_parent = old workspace version
                    try insVersion.bind(hash, at: 5)
                    try insVersion.bind(title, at: 6)
                    try insVersion.bind(activityID, at: 7)
                    try insVersion.bind(nowTS, at: 8)
                    _ = try insVersion.step()

                    // Update the workspace_ref: new version + new base.
                    let upRef = try statement("""
                    UPDATE workspace_refs
                    SET base_version_id = ?2, version_id = ?3, updated_at = ?4
                    WHERE workspace_id = ?1 AND kind = 'page-content' AND owner_id = ?5;
                    """)
                    upRef.reset()
                    try upRef.bind(workspaceID, at: 1)
                    try upRef.bind(mainHead, at: 2)       // new base = current main head
                    try upRef.bind(newVersionID, at: 3)
                    try upRef.bind(nowTS, at: 4)
                    try upRef.bind(pageIDStr, at: 5)
                    _ = try upRef.step()
                }
                if !conflicts.isEmpty {
                    throw WikiStoreError.unexpected("refresh: \(conflicts.count) conflict(s)")
                }
            }
            }
        } catch {
            if !conflicts.isEmpty {
                try mutate(event: { _ in nil }) {
                let nowTS = Date().timeIntervalSince1970
                let park = try statement(
                    "UPDATE workspaces SET status = 'conflicted', updated_at = ?2 WHERE id = ?1;")
                park.reset()
                try park.bind(workspaceID, at: 1)
                try park.bind(nowTS, at: 2)
                _ = try park.step()

                // Persist conflict details.
                let delConflicts = try statement(
                    "DELETE FROM workspace_conflicts WHERE workspace_id = ?1;")
                delConflicts.reset()
                try delConflicts.bind(workspaceID, at: 1)
                _ = try delConflicts.step()

                let insConflict = try statement("""
                INSERT INTO workspace_conflicts (workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                """)
                for c in conflicts {
                    insConflict.reset()
                    try insConflict.bind(workspaceID, at: 1)
                    try insConflict.bind(c.pageID, at: 2)
                    if let b = c.base { try insConflict.bind(b, at: 3) }
                    if let m = c.mainVersion { try insConflict.bind(m, at: 4) }
                    try insConflict.bind(c.wsVersion, at: 5)
                    try insConflict.bind(nowTS, at: 6)
                    _ = try insConflict.step()
                }
                }
                return
            }
            throw error
        }
    }

    // MARK: - Conflict resolution (W3, PR #312)

    public func workspaceConflicts(workspaceID: String) throws -> [WorkspaceConflict] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at
        FROM workspace_conflicts WHERE workspace_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(workspaceID, at: 1)
        var out: [WorkspaceConflict] = []
        while try stmt.step() {
            let baseIsNull = sqlite3_column_type(stmt.handle, 2) == SQLITE_NULL
            let mainIsNull = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            out.append(WorkspaceConflict(
                workspaceID: stmt.text(at: 0),
                pageID: PageID(rawValue: stmt.text(at: 1)),
                baseVersionID: baseIsNull ? nil : stmt.text(at: 2),
                mainVersionID: mainIsNull ? nil : stmt.text(at: 3),
                wsVersionID: stmt.text(at: 4),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 5))))
        }
        return out
    }

    public func workspaceResolveConflict(
        workspaceID: String, pageID: PageID, body: String
    ) throws {
        try mutate(event: { _ in nil }) {
        let bodyData = Data(body.utf8)
        let hash = SHA256.hash(data: bodyData)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        try withTransaction {
            // 1. Blob.
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(hash, at: 1)
            try insBlob.bind(Int64(bodyData.count), at: 2)
            try insBlob.bind(bodyData, at: 3)
            _ = try insBlob.step()

            // 2. Activity.
            let agentID = try legacyImportAgentID()
            let activityID = ULID.generate()
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?1, 'resolve', ?2, ?3, ?3);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(agentID, at: 2)
            try insActivity.bind(nowTS, at: 3)
            _ = try insActivity.step()

            // 3. New workspace version (parent = workspace's current head).
            //    For created-page conflicts (v35: version_id NULL), wsHead
            //    is nil — read the title from workspace_refs.title instead.
            let wsHead = try workspacePageVersionLocked(
                workspaceID: workspaceID, pageID: pageID)
            let title: String
            if let wsHead {
                let titleStmt = try statement(
                    "SELECT title FROM page_versions WHERE id = ?1;")
                titleStmt.reset()
                try titleStmt.bind(wsHead, at: 1)
                _ = try titleStmt.step()
                title = titleStmt.text(at: 0)
                titleStmt.reset()
            } else {
                // Created-page staging: title lives in workspace_refs.title.
                let titleStmt = try statement("""
                SELECT title FROM workspace_refs
                WHERE workspace_id = ?1 AND kind = 'page-content' AND owner_id = ?2;
                """)
                titleStmt.reset()
                try titleStmt.bind(workspaceID, at: 1)
                try titleStmt.bind(pageID.rawValue, at: 2)
                _ = try titleStmt.step()
                title = titleStmt.text(at: 0)
                titleStmt.reset()
            }

            // 3a. For created-page conflicts, the page may not exist on main
            //     yet (the conflict was that a ref exists with the same page_id,
            //     or the page was created by another workspace). Create a
            //     placeholder if needed so the page_versions FK holds.
            let pageCheck = try statement("SELECT 1 FROM pages WHERE id = ?1;")
            defer { pageCheck.reset() }
            try pageCheck.bind(pageID.rawValue, at: 1)
            let pageExists = try pageCheck.step()
            pageCheck.reset()  // don't leave a cursor at SQLITE_ROW
            if !pageExists {
                let slug = try uniqueSlug(from: title, id: pageID)
                let insPage = try statement("""
                INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
                VALUES (?1, ?2, ?3, '', ?4, ?4, 1);
                """)
                insPage.reset()
                try insPage.bind(pageID.rawValue, at: 1)
                try insPage.bind(title, at: 2)
                try insPage.bind(slug, at: 3)
                try insPage.bind(nowTS, at: 4)
                _ = try insPage.step()
            }

            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(pageID.rawValue, at: 2)
            if let wsHead { try insVersion.bind(wsHead, at: 3) }
            try insVersion.bind(hash, at: 4)
            try insVersion.bind(title, at: 5)
            try insVersion.bind(activityID, at: 6)
            try insVersion.bind(nowTS, at: 7)
            _ = try insVersion.step()

            // 4. Update workspace_ref to point at the resolved version.
            //    Clear blob_hash + title to maintain the staging invariant
            //    (resolving converts a created-page staging to a version-based
            //    staging). Update base_version_id to current main head so the
            //    retry merge sees no divergence.
            let mainHead = try pageHeadVersionIDLocked(pageID: pageID)
            let upRef = try statement("""
            UPDATE workspace_refs
            SET version_id = ?2, base_version_id = ?3, blob_hash = NULL, title = NULL, updated_at = ?4
            WHERE workspace_id = ?1 AND kind = 'page-content' AND owner_id = ?5;
            """)
            upRef.reset()
            try upRef.bind(workspaceID, at: 1)
            try upRef.bind(versionID, at: 2)
            if let mainHead { try upRef.bind(mainHead, at: 3) }
            try upRef.bind(nowTS, at: 4)
            try upRef.bind(pageID.rawValue, at: 5)
            _ = try upRef.step()

            // 5. Delete the conflict row for this page.
            let delConflict = try statement(
                "DELETE FROM workspace_conflicts WHERE workspace_id = ?1 AND page_id = ?2;")
            delConflict.reset()
            try delConflict.bind(workspaceID, at: 1)
            try delConflict.bind(pageID.rawValue, at: 2)
            _ = try delConflict.step()
        }
        }
    }

    public func workspaceRetryMerge(workspaceID: String) throws {
        try mutate(event: { _ in nil }) {
        // Set status back to 'open' so workspaceMerge can run.
        let reopen = try statement(
            "UPDATE workspaces SET status = 'open', updated_at = ?2 WHERE id = ?1 AND status = 'conflicted';")
        reopen.reset()
        try reopen.bind(workspaceID, at: 1)
        try reopen.bind(Date().timeIntervalSince1970, at: 2)
        _ = try reopen.step()
        guard sqlite3_changes(db) > 0 else {
            throw WikiStoreError.unexpected("workspace \(workspaceID) is not conflicted")
        }
        }
        // Now attempt the merge again.
        try workspaceMerge(workspaceID: workspaceID)
    }

    public func reapStaleWorkspaces(ttl: TimeInterval) throws -> Int {
        try mutate(event: { _ in nil }) {
        let cutoff = Date().timeIntervalSince1970 - ttl
        // Select stale open workspace IDs.
        let select = try statement("""
        SELECT id FROM workspaces
        WHERE status = 'open' AND updated_at < ?1;
        """)
        defer { select.reset() }
        try select.bind(cutoff, at: 1)
        var staleIDs: [String] = []
        while try select.step() {
            staleIDs.append(select.text(at: 0))
        }

        var reaped = 0
        for id in staleIDs {
            // Delete workspace_refs + conflicts, then mark abandoned.
            let delRefs = try statement(
                "DELETE FROM workspace_refs WHERE workspace_id = ?1;")
            delRefs.reset()
            try delRefs.bind(id, at: 1)
            _ = try delRefs.step()

            let delConflicts = try statement(
                "DELETE FROM workspace_conflicts WHERE workspace_id = ?1;")
            delConflicts.reset()
            try delConflicts.bind(id, at: 1)
            _ = try delConflicts.step()

            let abandon = try statement(
                "UPDATE workspaces SET status = 'abandoned', updated_at = ?2 WHERE id = ?1;")
            abandon.reset()
            try abandon.bind(id, at: 1)
            try abandon.bind(Date().timeIntervalSince1970, at: 2)
            _ = try abandon.step()
            reaped += 1
        }
        return reaped
        }
    }

    public func deletePage(id: PageID) throws {
        try mutate(event: { _ in localEvent(.page, id: id.rawValue, change: .deleted) }) {
        // FK safety: `page_links`, `attachments`, and `source_links` all have
        // FKs onto `pages(id)` WITHOUT `ON DELETE CASCADE` (unlike `page_chunks`
        // which cascades). With `foreign_keys=ON`, deleting a page that still has
        // rows in any of those tables throws a constraint violation. So clear
        // every dependent row first, then delete the page — all in ONE
        // transaction so a failure can't leave dangling rows.
        try withTransaction {
            let unlink = try statement(
                "DELETE FROM page_links WHERE from_page_id = ?1 OR to_page_id = ?1;")
            unlink.reset()
            try unlink.bind(id.rawValue, at: 1)
            _ = try unlink.step()

            let deleteSourceLinks = try statement(
                "DELETE FROM source_links WHERE from_page_id = ?1;")
            deleteSourceLinks.reset()
            try deleteSourceLinks.bind(id.rawValue, at: 1)
            _ = try deleteSourceLinks.step()

            let deleteAttachments = try statement(
                "DELETE FROM attachments WHERE page_id = ?1;")
            deleteAttachments.reset()
            try deleteAttachments.bind(id.rawValue, at: 1)
            _ = try deleteAttachments.step()

            // `page-content` refs use the page id as `owner_id`. Like sources,
            // the `refs` table has no FK cascade onto `pages` (W0/#312 made
            // `owner_id` polymorphic), so a page with a CAS `page-content` ref
            // would leak the ref row on delete — orphaning `version_id` and
            // staling the changeToken. Delete it in the same transaction.
            let deleteRefs = try statement(
                "DELETE FROM refs WHERE owner_id = ?1 AND kind = 'page-content';")
            deleteRefs.reset()
            try deleteRefs.bind(id.rawValue, at: 1)
            _ = try deleteRefs.step()

            let stmt = try statement("DELETE FROM pages WHERE id = ?1;")
            stmt.reset()
            try stmt.bind(id.rawValue, at: 1)
            _ = try stmt.step()
        }
        }
    }

    // MARK: - Wiki links (Phase 4)

    public func resolveTitleToID(_ title: String) throws -> PageID? {
        lock.lock(); defer { lock.unlock() }
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
    /// Three passes: an exact match on `display_name` (falling back to
    /// `filename` when `display_name` is NULL); then — because legacy rows
    /// stored `display_name = filename` WITH the file extension while the
    /// canonical cite target drops it — a scan that matches the query against
    /// each candidate's name with its last extension removed, so
    /// `[[source:Some Paper]]` still resolves a row named `Some Paper.pdf`;
    /// then a LENIENT pass on `WikiNameRules.looseMatchKey` (extension AND a
    /// trailing "(…)" suffix stripped) that resolves ONLY when exactly one
    /// source matches — so an agent citing `Some Paper (2026)` still finds
    /// `Some Paper.pdf`, but a near-miss never guesses between two candidates.
    public func resolveSourceByName(_ displayName: String) throws -> PageID? {
        lock.lock(); defer { lock.unlock() }
        let exact = try statement("""
        SELECT id FROM sources
        WHERE COALESCE(display_name, filename) = ?1 COLLATE NOCASE
           OR filename = ?1 COLLATE NOCASE
        ORDER BY updated_at DESC LIMIT 1;
        """)
        defer { exact.reset() }
        try exact.bind(displayName, at: 1)
        if try exact.step() { return PageID(rawValue: exact.text(at: 0)) }

        let queryLooseKey = WikiNameRules.looseMatchKey(displayName)
        var looseMatches: [PageID] = []
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
            if !queryLooseKey.isEmpty, WikiNameRules.looseMatchKey(name) == queryLooseKey {
                looseMatches.append(PageID(rawValue: scan.text(at: 0)))
            }
        }
        // Pass 3: lenient, unique-only.
        return looseMatches.count == 1 ? looseMatches[0] : nil
    }

    /// Resolve a parsed link's target to an id, trying every candidate
    /// (name, fragment) reading of the raw target — longest name first — via
    /// `WikiLinkResolver`, so names containing `#` resolve whole. `resolve` is
    /// `resolveTitleToID` for page links, `resolveSourceByName` for citations.
    private func resolveLinkTarget(
        _ link: WikiLinkParser.ParsedLink,
        using resolve: (String) throws -> PageID?
    ) throws -> PageID? {
        let raw = link.fragment.map { "\(link.target)#\($0)" } ?? link.target
        for split in WikiLinkResolver.candidateSplits(of: raw) {
            if let id = try resolve(split.base) { return id }
        }
        return nil
    }

    /// If `link.target` is a canonical ULID naming an existing row, return that
    /// id directly (Phase 5). A stored `[[page:ULID|Title]]` resolves by id — a
    /// direct row fetch — instead of being dropped by name resolution (which
    /// matches on title, not id). Returns `nil` when the target is non-canonical
    /// OR the id names no row, so the caller can fall back to name resolution
    /// (collision safety: a title that happens to be ULID-shaped still links).
    private func canonicalLinkID(
        _ link: WikiLinkParser.ParsedLink
    ) throws -> PageID? {
        guard WikiLinkParser.isCanonicalULID(link.target) else { return nil }
        let id = PageID(rawValue: link.target)
        switch link.linkType {
        case .page:   return (try? getPage(id: id)) != nil ? id : nil
        case .source: return (try? getSource(id: id)) != nil ? id : nil
        case .chat:
            // Direct existence check — no `getChat` entity fetch needed; the
            // canonical resolver only needs to know whether the id is live.
            let stmt = try statement("SELECT 1 FROM chats WHERE id = ?1;")
            defer { stmt.reset() }
            try stmt.bind(id.rawValue, at: 1)
            return (try stmt.step()) ? id : nil
        }
    }

    public func replaceLinks(from pageID: PageID,
                             parsedLinks: [WikiLinkParser.ParsedLink]) throws {
        try mutate(event: { _ in localEvent(.page, id: pageID.rawValue, change: .updated) }) {
        // One transaction: wipe this page's outgoing links in BOTH tables, then
        // insert the resolved subsets. Unresolved targets are OMITTED.
        // `INSERT OR IGNORE` collapses duplicate (from,to) pairs.
        // `source_links` inherits the same alias-collapsing behavior as
        // `page_links` via its PRIMARY KEY (from_page_id, to_source_id).
        try withTransaction {
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
            INSERT OR IGNORE INTO source_links (from_page_id, to_source_id, link_text, pinned_version_id)
            VALUES (?1, ?2, ?3, ?4);
            """)
            // Embed source links (`![[source:…]]`) write a DISTINCT edge with
            // role='embed' — the `source_links_edge` unique index treats
            // (from, to, role, pin) as distinct, so a cite + embed to the same
            // source coexist as separate rows (Phase 4a, AC.3).
            let insSourceEmbed = try statement("""
            INSERT OR IGNORE INTO source_links (from_page_id, to_source_id, link_text, role, pinned_version_id)
            VALUES (?1, ?2, ?3, 'embed', ?4);
            """)
            // A `#` inside a page/source NAME mis-splits into base + fragment
            // at parse time. Resolve via WikiLinkResolver: try every reading
            // of the raw target (longest name first) and take the first that
            // names a real page/source.
            for link in parsedLinks {
                switch link.linkType {
                case .page:
                    // Canonical ULID targets validate by id (a direct row fetch);
                    // legacy and forward links resolve by name. A ULID that names
                    // no row falls back to name resolution so a ULID-shaped title
                    // never silently loses its edge (Phase 5).
                    let resolved: PageID?
                    if let id = try canonicalLinkID(link) {
                        resolved = id
                    } else {
                        resolved = try resolveLinkTarget(link, using: resolveTitleToID)
                    }
                    guard let resolved else { continue }
                    insPage.reset()
                    try insPage.bind(pageID.rawValue, at: 1)
                    try insPage.bind(resolved.rawValue, at: 2)
                    try insPage.bind(link.linkText, at: 3)
                    _ = try insPage.step()
                case .source:
                    let resolved: PageID?
                    if let id = try canonicalLinkID(link) {
                        resolved = id
                    } else {
                        resolved = try resolveLinkTarget(link, using: resolveSourceByName)
                    }
                    guard let resolved else { continue }
                    // Phase 6: resolve the `@vN` ordinal (1-based) to a concrete
                    // smv id; NULL when unpinned or out-of-range (follows the
                    // active ref). `replaceLinks` is the sole writer of
                    // `pinned_version_id` (the un-FK'd polymorphic column).
                    let pinID = try link.versionPin.flatMap {
                        try resolveVersionPin($0, sourceID: resolved)
                    }
                    let stmt = link.isEmbed ? insSourceEmbed : insSource
                    stmt.reset()
                    try stmt.bind(pageID.rawValue, at: 1)
                    try stmt.bind(resolved.rawValue, at: 2)
                    try stmt.bind(link.linkText, at: 3)
                    try stmt.bind(pinID?.rawValue, at: 4)
                    _ = try stmt.step()
                case .chat:
                    // Chat links are resolved at render time (no persisted graph
                    // edge in page_links/source_links today). Intentionally a
                    // no-op here so a `[[chat:…]]` in a page body never errors.
                    continue
                }
            }
        }
        }
    }

    /// All page→page link rows, ordered by `(from_page_id, to_page_id)`. Read-side
    /// helper for the File Provider projection's `links.jsonl` generator. Not on
    /// the `WikiStore` protocol — like `listAllPagesOrderedByID`, it is a
    /// read-projection helper, not part of the editing API.
    public func listAllLinks() throws -> [IndexGenerators.LinkRow] {
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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

    /// Read the `pinned_version_id` for a source-link edge `(from, to, role)`.
    /// Returns the resolved smv id, or nil when the edge has no pin (NULL) or
    /// doesn't exist. Phase 6: test/diagnostic accessor for pin write-back.
    public func sourceLinkPin(from pageID: PageID, to sourceID: PageID,
                              role: String = "cite") throws -> PageID? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT pinned_version_id FROM source_links
        WHERE from_page_id = ?1 AND to_source_id = ?2 AND role = ?3;
        """)
        defer { stmt.reset() }
        try stmt.bind(pageID.rawValue, at: 1)
        try stmt.bind(sourceID.rawValue, at: 2)
        try stmt.bind(role, at: 3)
        guard try stmt.step() else { return nil }
        return sqlite3_column_type(stmt.handle, 0) == SQLITE_NULL
            ? nil : PageID(rawValue: stmt.text(at: 0))
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
    ///
    /// Before inserting, `data` is hashed (SHA-256) and checked against every
    /// existing source's `content_hash`. A byte-identical match throws
    /// `WikiStoreError.duplicateContent(existing:)` instead of inserting a
    /// second copy — this is the ONE seam every ingest entry point (drag-drop,
    /// URL fetch, Zotero, folder import) funnels through, so the check applies
    /// everywhere automatically (issue #126).
    @discardableResult
    public func addSource(
        filename: String,
        data: Data,
        zoteroItemKey: String? = nil,
        zoteroItemTitle: String? = nil,
        mimeType: String? = nil,
        provenance: SourceProvenance? = nil,
        role: SourceRole = .primary,
        originalPath: String? = nil,
        activityID: String? = nil,
        /// Pre-resolved display name from ``DisplayNameResolver/resolve``.
        /// `nil` (default) → resolve in-method (still before the locked path).
        /// Non-`nil` → use directly, skipping the (potentially expensive PDFKit)
        /// parse — callers that pre-resolve off-main pass this to keep the
        /// store write fast (issue #229).
        resolvedDisplayName: String?? = nil
    ) throws -> SourceSummary {
        // Resolve the display name BEFORE entering the locked ``mutate`` path.
        // For PDFs, ``DisplayNameResolver`` invokes PDFKit — a multi-second,
        // whole-file parse. Running it under the recursive lock delays the
        // write transaction long enough to collide with another connection
        // (File Provider, daemon, concurrent write) holding the DB write lock
        // past the 5 s ``busy_timeout``, surfacing as "database is locked".
        // Callers that pre-resolve off-main (addURL, addFiles, Zotero) pass
        // ``resolvedDisplayName`` to skip the in-method parse entirely (#229).
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType
            ?? ContentSniff.mimeType(of: data)
            ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
        // The citable name (`[[source:name]]`) must stay linkable — see
        // WikiNameRules. Sanitize the resolved display name; when metadata
        // yields none and the raw FILENAME is unlinkable, store its sanitized
        // form as the display name (the filename itself stays verbatim — it is
        // the file's identity on the mount).
        let displayName: String?
        if let resolved = resolvedDisplayName ?? DisplayNameResolver.resolve(
            filename: filename, data: data, mimeType: mime,
            zoteroItemTitle: zoteroItemTitle) {
            displayName = WikiNameRules.sanitized(resolved)
        } else if !WikiNameRules.isLinkable(filename) {
            displayName = WikiNameRules.sanitized(filename)
        } else {
            displayName = nil
        }

        DebugLog.store("addSource ENTER filename=\(filename) bytes=\(data.count) thread=\(Thread.current)")
        return try mutate(event: { source in localEvent(.source, id: source.id.rawValue, change: .created) }) {
        guard data.count <= Self.ingestByteCap else {
            throw WikiStoreError.unexpected(
                "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
        }
        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dupStmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, role
        FROM sources WHERE content_hash = ?1 LIMIT 1;
        """)
        dupStmt.reset()
        try dupStmt.bind(contentHash, at: 1)
        if try dupStmt.step() {
            let existing = sourceSummary(from: dupStmt)
            dupStmt.reset()
            throw WikiStoreError.duplicateContent(existing: existing)
        }
        dupStmt.reset()

        let id = PageID(rawValue: ULID.generate())
        let now = Date()


        let stmt = try statement("""
        INSERT INTO sources
          (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
           zotero_item_key, zotero_item_title, display_name, content_hash, role)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, 1, ?7, ?8, ?9, ?10, ?11);
        """)
        // Graph-model Phase 1: the content bytes no longer live in `sources`.
        // In ONE transaction, write the blob (dedup via INSERT OR IGNORE), an
        // import activity, the v1 version, and the active ref — then the
        // `sources` identity row (byte_size/mime_type/content_hash are
        // denormalized mirrors of the v1 blob). The dedup check above already
        // ran against `sources.content_hash`, unchanged.
        try withTransaction {
            let sourceID = id.rawValue
            let nowTS = now.timeIntervalSince1970

            // 0. The `sources` identity row FIRST — `source_versions.source_id`
            //    and `refs.owner_id` FK onto it, so it must exist before they do.
            stmt.reset()
            try stmt.bind(id.rawValue, at: 1)
            try stmt.bind(filename, at: 2)
            try stmt.bind(ext, at: 3)
            if let mime { try stmt.bind(mime, at: 4) }  // else leave NULL
            try stmt.bind(Int64(data.count), at: 5)
            try stmt.bind(nowTS, at: 6)
            if let zoteroItemKey { try stmt.bind(zoteroItemKey, at: 7) }  // else leave NULL
            if let zoteroItemTitle { try stmt.bind(zoteroItemTitle, at: 8) }  // else leave NULL
            if let displayName { try stmt.bind(displayName, at: 9) }  // else leave NULL
            try stmt.bind(contentHash, at: 10)
            try stmt.bind(role.rawValue, at: 11)
            _ = try stmt.step()

            // 1. Blob (identical bytes = one row, ever).
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(contentHash, at: 1)
            try insBlob.bind(Int64(data.count), at: 2)
            try insBlob.bind(data, at: 3)
            _ = try insBlob.step()

            // 2. Import/fetch activity + associated agent. When provenance is
            //    present (Phase 3a), seed a REAL provider agent + an activity
            //    carrying plan/external_ref; otherwise fall back to the synthetic
            //    legacy-import agent + a bare 'import' activity (byte-identical
            //    to the pre-Phase-3 path). When `activityID` is provided (Phase 4
            //    snapshot path — the page shares the snapshot's pre-created
            //    activity), skip activity creation entirely and reuse it.
            let resolvedActivityID: String
            if let activityID {
                resolvedActivityID = activityID
            } else {
                let agentID: String
                let activityKind: String
                if let prov = provenance {
                    agentID = try ensureAgent(
                        name: prov.agentName, kind: prov.agentKind,
                        version: prov.agentVersion, externalRef: nil)
                    activityKind = prov.activityKind
                } else {
                    agentID = try legacyImportAgentID()
                    activityKind = "import"
                }
                resolvedActivityID = ULID.generate()
                let insActivity = try statement("""
                INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6);
                """)
                insActivity.reset()
                try insActivity.bind(resolvedActivityID, at: 1)
                try insActivity.bind(activityKind, at: 2)
                try insActivity.bind(agentID, at: 3)
                if let plan = provenance?.plan { try insActivity.bind(plan, at: 4) }
                if let extRef = provenance?.externalRef { try insActivity.bind(extRef, at: 5) }
                try insActivity.bind(nowTS, at: 6)
                _ = try insActivity.step()
            }

            // 3. v1 version (parent_id NULL, the content blob). external_identity
            //    is the canonical external id (resolved URL / Zotero key), NULL
            //    when no provenance is present. original_path is the relative
            //    sibling path (Phase 4 snapshot images); NULL for the page and
            //    all non-snapshot sources.
            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, original_path, activity_id, external_identity, fetched_at)
            VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(sourceID, at: 2)
            try insVersion.bind(contentHash, at: 3)
            if let mime { try insVersion.bind(mime, at: 4) }
            if let originalPath { try insVersion.bind(originalPath, at: 5) }
            try insVersion.bind(resolvedActivityID, at: 6)
            if let extID = provenance?.externalIdentity { try insVersion.bind(extID, at: 7) }
            try insVersion.bind(nowTS, at: 8)
            _ = try insVersion.step()

            // 4. Active ref (generation 1).
            let insRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, 1, ?3);
            """)
            insRef.reset()
            try insRef.bind(sourceID, at: 1)
            try insRef.bind(versionID, at: 2)
            try insRef.bind(nowTS, at: 3)
            _ = try insRef.step()
        }

        // Name-only full-text index entry so an un-extracted source is still
        // findable by filename/display name. The body is indexed once processed
        // markdown is appended (appendProcessedMarkdown → upsertSourceSearch).
        upsertSourceSearch(sourceID: id, body: "")

        return SourceSummary(
            id: id, filename: filename, ext: ext, mimeType: mime,
            byteSize: data.count, createdAt: now, updatedAt: now, version: 1,
            zoteroItemKey: zoteroItemKey, zoteroItemTitle: zoteroItemTitle,
            displayName: displayName, role: role
        )
        }
    }

    // MARK: - Graph-model Phase 4: website snapshot store primitives

    /// Create (or reuse) the shared fetch activity for a website snapshot. Opens
    /// its **own** `withTransaction` (commits the agent + activity FIRST so the
    /// `source_versions.activity_id` FK is satisfied before any image version is
    /// written). Returns the `activityID`. Used **only** by the snapshot path.
    @discardableResult
    public func ensureFetchActivity(provenance: SourceProvenance) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try withTransaction {
            let agentID = try ensureAgent(
                name: provenance.agentName, kind: provenance.agentKind,
                version: provenance.agentVersion, externalRef: nil)
            let activityID = ULID.generate()
            let nowTS = Date().timeIntervalSince1970
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(provenance.activityKind, at: 2)
            try insActivity.bind(agentID, at: 3)
            if let plan = provenance.plan { try insActivity.bind(plan, at: 4) }
            if let extRef = provenance.externalRef { try insActivity.bind(extRef, at: 5) }
            try insActivity.bind(nowTS, at: 6)
            _ = try insActivity.step()
            return activityID
        }
    }

    /// Store one snapshot image as a **per-snapshot** source (no source-level
    /// `content_hash` dedup — each snapshot owns its image source rows). The
    /// blob is still deduped (`INSERT OR IGNORE`). Writes a fresh `sources` row
    /// + blob + v1 version bound to the shared `activityID` + `originalPath` +
    /// `external_identity = sourceURL`, `role = .media`, + the active
    /// `source-content` ref, all in one `withTransaction`.
    ///
    /// This is the primitive that makes the activity-join resolver correct:
    /// each snapshot owns its image source/version rows, while identical bytes
    /// collapse to one blob.
    @discardableResult
    public func addSnapshotImage(
        filename: String,
        data: Data,
        mimeType: String,
        originalPath: String,
        sourceURL: URL,
        activityID: String,
        role: SourceRole = .media
    ) throws -> SourceSummary {
        // Resolve display name BEFORE the locked path (same discipline as
        // addSource — issue #229). Snapshot images are never PDFs, so this is
        // always fast, but the pattern is identical for consistency.
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = ContentSniff.mimeType(of: data) ?? mimeType
        let displayName: String?
        if let resolved = DisplayNameResolver.resolve(
            filename: filename, data: data, mimeType: mime, zoteroItemTitle: nil) {
            displayName = WikiNameRules.sanitized(resolved)
        } else if !WikiNameRules.isLinkable(filename) {
            displayName = WikiNameRules.sanitized(filename)
        } else {
            displayName = nil
        }

        return try mutate(event: { source in localEvent(.source, id: source.id.rawValue, change: .created) }) {
        guard data.count <= Self.ingestByteCap else {
            throw WikiStoreError.unexpected(
                "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
        }
        let contentHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let id = PageID(rawValue: ULID.generate())
        let now = Date()

        try withTransaction {
            let sourceID = id.rawValue
            let nowTS = now.timeIntervalSince1970

            // 0. Fresh `sources` identity row (NO content_hash dedup).
            let insSource = try statement("""
            INSERT INTO sources
              (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, content_hash, role)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, 1, NULL, NULL, ?7, ?8, ?9);
            """)
            insSource.reset()
            try insSource.bind(sourceID, at: 1)
            try insSource.bind(filename, at: 2)
            try insSource.bind(ext, at: 3)
            try insSource.bind(mime, at: 4)
            try insSource.bind(Int64(data.count), at: 5)
            try insSource.bind(nowTS, at: 6)
            if let displayName { try insSource.bind(displayName, at: 7) }
            try insSource.bind(contentHash, at: 8)
            try insSource.bind(role.rawValue, at: 9)
            _ = try insSource.step()

            // 1. Blob (identical bytes = one row, ever).
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(contentHash, at: 1)
            try insBlob.bind(Int64(data.count), at: 2)
            try insBlob.bind(data, at: 3)
            _ = try insBlob.step()

            // 2. v1 version bound to the shared activity + original_path +
            //    external_identity = the resolved source URL.
            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, original_path, activity_id, external_identity, fetched_at)
            VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(sourceID, at: 2)
            try insVersion.bind(contentHash, at: 3)
            try insVersion.bind(mime, at: 4)
            try insVersion.bind(originalPath, at: 5)
            try insVersion.bind(activityID, at: 6)
            try insVersion.bind(sourceURL.absoluteString, at: 7)
            try insVersion.bind(nowTS, at: 8)
            _ = try insVersion.step()

            // 3. Active ref (generation 1).
            let insRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, 1, ?3);
            """)
            insRef.reset()
            try insRef.bind(sourceID, at: 1)
            try insRef.bind(versionID, at: 2)
            try insRef.bind(nowTS, at: 3)
            _ = try insRef.step()
        }

        upsertSourceSearch(sourceID: id, body: "")

        return SourceSummary(
            id: id, filename: filename, ext: ext, mimeType: mime,
            byteSize: data.count, createdAt: now, updatedAt: now, version: 1,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            displayName: displayName, role: role
        )
        }
    }

    /// True when the source's active content version's `activity_id` has sibling
    /// versions with non-null `original_path` (i.e. this is a snapshot page with
    /// image siblings). Mirrors the resolver join. Used by the refresh guard.
    public func hasImageSiblings(sourceID: PageID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let active = try activeContentVersion(sourceID: sourceID),
              let activityID = active.activityID else { return false }
        let stmt = try statement("""
        SELECT COUNT(*) FROM source_versions
        WHERE activity_id = ?1 AND original_path IS NOT NULL;
        """)
        defer { stmt.reset() }
        try stmt.bind(activityID, at: 1)
        guard try stmt.step() else { return false }
        return stmt.int(at: 0) > 0
    }

    /// Batched sibling-image resolver maps: for each source, the
    /// `[original_path → sibling sourceID]` map built from its active content
    /// version's `activity_id`. Self-joins `source_versions` on the active
    /// activity, returns sibling versions (non-null `original_path`) ordered by
    /// `sv.id ASC` with first-wins per `original_path` (§7). The page's own
    /// version has `original_path = NULL` (excluded). Value-only return
    /// (sqlite-concurrency discipline: no statement/column state crosses the
    /// boundary).
    public func siblingImageResolvers() throws -> [PageID: [String: PageID]] {
        lock.lock(); defer { lock.unlock() }
        // One pass: for every source, resolve its active activity_id, then find
        // sibling versions sharing that activity with non-null original_path.
        // We do this in two steps to avoid a complex correlated subquery:
        //   1. Map: sourceID → active activity_id
        //   2. For each activity_id, collect [original_path → sourceID].
        // Then fold: sourceID → { activity's [original_path → sourceID] }.

        // Step 1: active version's activity_id per source (ref → else MAX(id)).
        let activeStmt = try statement("""
        SELECT s.id, (
            SELECT sv.activity_id FROM refs r
            JOIN source_versions sv ON sv.id = r.version_id
            WHERE r.kind = 'source-content' AND r.owner_id = s.id
        ) AS ref_activity,
        COALESCE((
            SELECT sv.activity_id FROM source_versions sv
            WHERE sv.source_id = s.id ORDER BY sv.id DESC LIMIT 1
        ), '') AS max_activity
        FROM sources s;
        """)
        activeStmt.reset()
        var sourceActivity: [(PageID, String)] = []
        while try activeStmt.step() {
            let sid = PageID(rawValue: activeStmt.text(at: 0))
            let refAct = sqlite3_column_type(activeStmt.handle, 1) == SQLITE_NULL
                ? nil : activeStmt.text(at: 1)
            let maxAct = activeStmt.text(at: 2)
            let activity = refAct ?? (maxAct.isEmpty ? nil : maxAct)
            if let activity { sourceActivity.append((sid, activity)) }
        }

        // Step 2: collect all [activity_id → [(original_path, sourceID, versionID)]]
        // ordered by versionID ASC for first-wins.
        let siblingStmt = try statement("""
        SELECT sv.activity_id, sv.original_path, sv.source_id, sv.id
        FROM source_versions sv
        WHERE sv.original_path IS NOT NULL AND sv.activity_id IS NOT NULL
        ORDER BY sv.id ASC;
        """)
        siblingStmt.reset()
        var byActivity: [String: [(String, PageID)]] = [:]
        while try siblingStmt.step() {
            let activity = siblingStmt.text(at: 0)
            let path = siblingStmt.text(at: 1)
            let sid = PageID(rawValue: siblingStmt.text(at: 2))
            byActivity[activity, default: []].append((path, sid))
        }

        // Step 3: fold — for each source, its activity's path→siblingID map
        // (first-wins per path, already ordered by id ASC).
        var result: [PageID: [String: PageID]] = [:]
        for (sid, activity) in sourceActivity {
            var map: [String: PageID] = [:]
            for (path, siblingID) in byActivity[activity] ?? [] {
                if map[path] == nil { map[path] = siblingID }
            }
            if !map.isEmpty { result[sid] = map }
        }
        return result
    }

    /// Store a **byteless** source — the §11 model for sources whose content is
    /// an external resource (e.g. an Apple Podcasts episode), not stored bytes.
    /// The source identity row + v1 content version carry `blob_hash = NULL`,
    /// `byte_size = 0`, `content_hash = NULL`; the derived alternative (the
    /// transcript markdown) is stored separately via `appendProcessedMarkdown`.
    ///
    /// Mirrors `addSource`'s transaction discipline EXACTLY, minus the blob/
    /// hash write. Dedups on `external_identity` among byteless sources (the
    /// partial index `source_versions_byteless_eid` keeps this O(log n)). The
    /// byteless dedup and `addSource`'s content-hash dedup are disjoint: content
    /// sources dedup on `content_hash`; byteless sources dedup on
    /// `external_identity`. SQL `NULL = '…'` is NULL, so `addSource`'s content-
    /// hash dedup never matches a byteless source.
    @discardableResult
    public func addBytelessSource(
        filename: String,
        mimeType: String? = nil,
        provenance: SourceProvenance,
        role: SourceRole = .primary
    ) throws -> SourceSummary {
        try mutate(event: { source in localEvent(.source, id: source.id.rawValue, change: .created) }) {

        // Byteless dedup: a byteless source with the same external_identity
        // already exists → reject (the partial index makes this lookup fast).
        if let extID = provenance.externalIdentity {
            let dupStmt = try statement("""
            SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size,
                   s.created_at, s.updated_at, s.version,
                   s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
            FROM sources s
            JOIN source_versions sv ON sv.source_id = s.id
            WHERE sv.external_identity = ?1 AND sv.blob_hash IS NULL
            LIMIT 1;
            """)
            dupStmt.reset()
            try dupStmt.bind(extID, at: 1)
            if try dupStmt.step() {
                let existing = sourceSummary(from: dupStmt)
                dupStmt.reset()
                throw WikiStoreError.duplicateContent(existing: existing)
            }
            dupStmt.reset()
        }

        let id = PageID(rawValue: ULID.generate())
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType
            ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
        let now = Date()
        // Display-name resolution mirrors addSource — pass empty Data (no bytes
        // to sniff); the resolver falls back to filename/extension inference.
        let displayName: String?
        if let resolved = DisplayNameResolver.resolve(
            filename: filename, data: Data(), mimeType: mime,
            zoteroItemTitle: nil) {
            displayName = WikiNameRules.sanitized(resolved)
        } else if !WikiNameRules.isLinkable(filename) {
            displayName = WikiNameRules.sanitized(filename)
        } else {
            displayName = nil
        }

        let insStmt = try statement("""
        INSERT INTO sources
          (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
           zotero_item_key, zotero_item_title, display_name, content_hash, role)
        VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5, 1, NULL, NULL, ?6, NULL, ?7);
        """)

        try withTransaction {
            let sourceID = id.rawValue
            let nowTS = now.timeIntervalSince1970

            // 0. The `sources` identity row FIRST (byte_size = 0, content_hash
            //    = NULL — no blob to hash).
            insStmt.reset()
            try insStmt.bind(sourceID, at: 1)
            try insStmt.bind(filename, at: 2)
            try insStmt.bind(ext, at: 3)
            if let mime { try insStmt.bind(mime, at: 4) }
            try insStmt.bind(nowTS, at: 5)
            if let displayName { try insStmt.bind(displayName, at: 6) }
            try insStmt.bind(role.rawValue, at: 7)
            _ = try insStmt.step()

            // 1. Fetch/import activity + real provider agent (provenance is
            //    required for byteless sources — there's no meaningful byteless
            //    source without external identity/provenance).
            let agentID = try ensureAgent(
                name: provenance.agentName, kind: provenance.agentKind,
                version: provenance.agentVersion, externalRef: nil)
            let activityID = ULID.generate()
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(provenance.activityKind, at: 2)
            try insActivity.bind(agentID, at: 3)
            if let plan = provenance.plan { try insActivity.bind(plan, at: 4) }
            if let extRef = provenance.externalRef { try insActivity.bind(extRef, at: 5) }
            try insActivity.bind(nowTS, at: 6)
            _ = try insActivity.step()

            // 2. v1 content version (blob_hash = NULL, external_identity set).
            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, activity_id, external_identity, fetched_at)
            VALUES (?1, ?2, NULL, NULL, ?3, ?4, ?5, ?6);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(sourceID, at: 2)
            if let mime { try insVersion.bind(mime, at: 3) }
            try insVersion.bind(activityID, at: 4)
            if let extID = provenance.externalIdentity { try insVersion.bind(extID, at: 5) }
            try insVersion.bind(nowTS, at: 6)
            _ = try insVersion.step()

            // 3. Active ref (generation 1).
            let insRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, 1, ?3);
            """)
            insRef.reset()
            try insRef.bind(sourceID, at: 1)
            try insRef.bind(versionID, at: 2)
            try insRef.bind(nowTS, at: 3)
            _ = try insRef.step()
        }

        // Name-only FTS index entry (no content text — the transcript lives in
        // the derived alternative, indexed when appendProcessedMarkdown runs).
        upsertSourceSearch(sourceID: id, body: "")

        return SourceSummary(
            id: id, filename: filename, ext: ext, mimeType: mime,
            byteSize: 0, createdAt: now, updatedAt: now, version: 1,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            displayName: displayName, role: role
        )
        }
    }

    /// All source summaries (NO content blob), most-recent-first for the
    /// management list. `id` is a ULID so `created_at DESC` orders by ingest.
    public func listSources() throws -> [SourceSummary] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, role
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
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, role
        FROM sources WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { throw WikiStoreError.notFound(id) }
        return sourceSummary(from: stmt)
    }

    /// The verbatim content bytes for one source, resolved through the graph
    /// model: ref → version → blob (§4.3). This is the single content read seam,
    /// so `wikictl cat`/`export`, the File Provider `contents(for:)`, and ingest
    /// staging all route through it unchanged.
    ///
    /// Resolution order:
    /// 1. The `source-content` ref → its version's `blob_hash` (the chosen
    ///    active version). Absent a ref row, fall back to the default-active
    ///    rule (§4.3): `MAX(id)` version for the source — this is the
    ///    "track latest" path an external writer (`wikictl` direct insert) or a
    ///    Phase 3 provider may legitimately produce.
    /// 2. A `NULL` blob_hash means a **byteless** source → return empty `Data()`
    ///    (never throws — the File Provider projection rule, §9).
    /// 3. Else read the blob bytes. Throws `.notFound` only when the source has
    ///    NO version rows at all (truly unknown id).
    public func sourceContent(id: PageID) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        // 1. Resolve the active version's blob_hash via the ref, else MAX(id).
        let refStmt = try statement("""
        SELECT sv.blob_hash
        FROM refs r
        JOIN source_versions sv ON sv.id = r.version_id
        WHERE r.kind = 'source-content' AND r.owner_id = ?1;
        """)
        defer { refStmt.reset() }
        try refStmt.bind(id.rawValue, at: 1)
        var blobHash: String?
        if try refStmt.step() {
            // blob_hash may be NULL (byteless) — read via column type.
            if sqlite3_column_type(refStmt.handle, 0) != SQLITE_NULL {
                blobHash = refStmt.text(at: 0)
            } else {
                blobHash = nil   // explicit byteless
            }
        } else {
            // No ref row → default-active rule: MAX(id) version.
            let maxStmt = try statement("""
            SELECT blob_hash FROM source_versions
            WHERE source_id = ?1 ORDER BY id DESC LIMIT 1;
            """)
            defer { maxStmt.reset() }
            try maxStmt.bind(id.rawValue, at: 1)
            if try maxStmt.step() {
                if sqlite3_column_type(maxStmt.handle, 0) != SQLITE_NULL {
                    blobHash = maxStmt.text(at: 0)
                } else {
                    blobHash = nil   // explicit byteless
                }
            } else {
                // No version rows at all → unknown source.
                throw WikiStoreError.notFound(id)
            }
        }

        // 2. Byteless source → empty Data (never throws).
        guard let blobHash else { return Data() }

        // 3. Read the blob bytes.
        let blobStmt = try statement("SELECT content FROM blobs WHERE hash = ?1;")
        defer { blobStmt.reset() }
        try blobStmt.bind(blobHash, at: 1)
        guard try blobStmt.step() else {
            // A version points at a blob that is missing — an integrity break
            // (blob writes always precede version writes). Treat as byteless
            // so the File Provider projection never throws (§9), but log it so
            // the corruption is observable rather than invisible.
            DebugLog.store("sourceContent: blob \(blobHash) missing for source \(id.rawValue) — returning empty Data (integrity break)")
            return Data()
        }
        return blobStmt.blob(at: 0)
    }

    /// The active content version for a source, resolved exactly like
    /// `sourceContent` (ref → version, else default-active `MAX(id)`). Returns
    /// nil when the source has no version rows at all.
    public func activeContentVersion(sourceID: PageID) throws -> SourceVersion? {
        lock.lock(); defer { lock.unlock() }
        // Prefer the ref; fall back to MAX(id) (default-active rule, §4.3).
        let refStmt = try statement("""
        SELECT sv.id, sv.source_id, sv.parent_id, sv.blob_hash, sv.mime_type,
               sv.activity_id, sv.external_identity, sv.fetched_at
        FROM refs r
        JOIN source_versions sv ON sv.id = r.version_id
        WHERE r.kind = 'source-content' AND r.owner_id = ?1;
        """)
        defer { refStmt.reset() }
        try refStmt.bind(sourceID.rawValue, at: 1)
        if try refStmt.step() {
            return sourceVersion(from: refStmt)
        }
        let maxStmt = try statement("""
        SELECT id, source_id, parent_id, blob_hash, mime_type,
               activity_id, external_identity, fetched_at
        FROM source_versions
        WHERE source_id = ?1 ORDER BY id DESC LIMIT 1;
        """)
        defer { maxStmt.reset() }
        try maxStmt.bind(sourceID.rawValue, at: 1)
        guard try maxStmt.step() else { return nil }
        return sourceVersion(from: maxStmt)
    }

    /// The full content-version chain for a source, newest-first (parallel to
    /// `processedMarkdownHistory`). Empty when the source has no versions.
    public func contentVersionHistory(sourceID: PageID) throws -> [SourceVersion] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, source_id, parent_id, blob_hash, mime_type,
               activity_id, external_identity, fetched_at
        FROM source_versions WHERE source_id = ?1 ORDER BY id DESC;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var out: [SourceVersion] = []
        while try stmt.step() {
            out.append(sourceVersion(from: stmt))
        }
        return out
    }

    /// Decode a `source_versions` row (column order: id, source_id, parent_id,
    /// blob_hash, mime_type, activity_id, external_identity, fetched_at) into a
    /// `SourceVersion`, reading NULLable columns by column type.
    private func sourceVersion(from stmt: SQLiteStatement) -> SourceVersion {
        func textOrNull(_ col: Int32) -> String? {
            sqlite3_column_type(stmt.handle, col) == SQLITE_NULL ? nil : stmt.text(at: col)
        }
        return SourceVersion(
            id: stmt.text(at: 0),
            sourceID: PageID(rawValue: stmt.text(at: 1)),
            parentID: textOrNull(2),
            blobHash: textOrNull(3),
            mimeType: textOrNull(4),
            activityID: textOrNull(5),
            externalIdentity: textOrNull(6),
            fetchedAt: Date(timeIntervalSince1970: stmt.double(at: 7))
        )
    }

    /// The origin provenance of a source: joined from the active content version
    /// (ref → else `MAX(id)`, mirroring `activeContentVersion`) → its `activities`
    /// row → the joined `agents` row. `plan`/`external_ref` are read from the
    /// **activity** (per-ingest), `agentName` from the **agent**. Returns `nil`
    /// when the source has no version rows at all (unknown id).
    public func sourceOrigin(sourceID: PageID) throws -> SourceOrigin? {
        lock.lock(); defer { lock.unlock() }
        // The columns selected here MUST stay in lockstep with `originFrom(stmt:)`.
        let columnList = """
            a.name, act.kind, act.plan, act.external_ref,
            sv.external_identity, sv.fetched_at
        """
        // 1. Prefer the active ref.
        let refStmt = try statement("""
        SELECT \(columnList)
        FROM refs r
        JOIN source_versions sv ON sv.id = r.version_id
        LEFT JOIN activities act ON act.id = sv.activity_id
        LEFT JOIN agents a ON a.id = act.agent_id
        WHERE r.kind = 'source-content' AND r.owner_id = ?1;
        """)
        defer { refStmt.reset() }
        try refStmt.bind(sourceID.rawValue, at: 1)
        if try refStmt.step() {
            return originFrom(stmt: refStmt)
        }
        // 2. Fall back to the default-active rule: MAX(id) version.
        let maxStmt = try statement("""
        SELECT \(columnList)
        FROM source_versions sv
        LEFT JOIN activities act ON act.id = sv.activity_id
        LEFT JOIN agents a ON a.id = act.agent_id
        WHERE sv.source_id = ?1 ORDER BY sv.id DESC LIMIT 1;
        """)
        defer { maxStmt.reset() }
        try maxStmt.bind(sourceID.rawValue, at: 1)
        guard try maxStmt.step() else { return nil }
        return originFrom(stmt: maxStmt)
    }

    /// Decode an origin row (column order: agent name, activity kind, plan,
    /// external_ref, external_identity, fetched_at). NULL activity/agent columns
    /// (a pre-graph-model or corrupted row) degrade gracefully.
    private func originFrom(stmt: SQLiteStatement) -> SourceOrigin {
        func textOrNull(_ col: Int32) -> String? {
            sqlite3_column_type(stmt.handle, col) == SQLITE_NULL ? nil : stmt.text(at: col)
        }
        return SourceOrigin(
            agentName: textOrNull(0) ?? "unknown",
            activityKind: textOrNull(1) ?? "import",
            plan: textOrNull(2),
            externalRef: textOrNull(3),
            externalIdentity: textOrNull(4),
            fetchedAt: Date(timeIntervalSince1970: stmt.double(at: 5))
        )
    }

    /// The embed descriptors for every **byteless** source, batched in one query
    /// (`[sourceID: SourceEmbedDescriptor]`). Joins the active content version
    /// (resolved with the same ref→else-MAX(id) rule as `sourceOrigin`) → its
    /// activity (`plan`) → agent (`name`), restricted to `blob_hash IS NULL`.
    ///
    /// Byteful sources are excluded — they embed via `wiki-blob://` and need no
    /// descriptor. Used by the page-reader precompute to feed
    /// `ExternalEmbed.target(for:)`. Returns `{}` on a query failure (defensive,
    /// matching `sourceDerivedChains`) so the reader simply has no external
    /// embeds rather than erroring. INTERNAL — values only cross the boundary.
    public func embedDescriptors() throws -> [PageID: SourceEmbedDescriptor] {
        lock.lock(); defer { lock.unlock() }
        // Column order: source_id, mime_type, external_identity, agent_name,
        // activity_plan — keep in lockstep with the decode below.
        guard let stmt = try? statement("""
        SELECT s.id, sv.mime_type, sv.external_identity, a.name, act.plan
        FROM sources s
        JOIN source_versions sv ON sv.source_id = s.id
            AND sv.id = (
                -- Active version: prefer the source-content ref, else MAX(id)
                -- (the same rule as sourceOrigin / activeContentVersion).
                SELECT COALESCE(
                    (SELECT r.version_id FROM refs r
                     WHERE r.kind = 'source-content' AND r.owner_id = s.id),
                    (SELECT MAX(sv2.id) FROM source_versions sv2
                     WHERE sv2.source_id = s.id)
                )
            )
        LEFT JOIN activities act ON act.id = sv.activity_id
        LEFT JOIN agents a ON a.id = act.agent_id
        WHERE sv.blob_hash IS NULL;
        """) else { return [:] }
        defer { stmt.reset() }
        func textOrNull(_ col: Int32) -> String? {
            sqlite3_column_type(stmt.handle, col) == SQLITE_NULL ? nil : stmt.text(at: col)
        }
        var out: [PageID: SourceEmbedDescriptor] = [:]
        while try stmt.step() {
            let id = PageID(rawValue: stmt.text(at: 0))
            out[id] = SourceEmbedDescriptor(
                id: id,
                mimeType: textOrNull(1),
                externalIdentity: textOrNull(2),
                agentName: textOrNull(3),
                planURL: textOrNull(4))
        }
        return out
    }

    /// Get-or-create the single legacy import agent (`kind='software'`,
    /// `name='legacy-import'`) that stands in for every pre-Phase-3 import (§3:
    /// no real extraction provenance exists). Idempotent: the v19→20 migration
    /// seeds one, and a fresh DB has none, so this lazily creates it on first
    /// `addSource`. INTERNAL — caller holds `lock`.
    private func legacyImportAgentID() throws -> String {
        let find = try statement(
            "SELECT id FROM agents WHERE name = 'legacy-import' LIMIT 1;")
        defer { find.reset() }
        if try find.step() { return find.text(at: 0) }
        let id = ULID.generate()
        let ins = try statement(
            "INSERT INTO agents (id, kind, name) VALUES (?1, 'software', 'legacy-import');")
        defer { ins.reset() }
        try ins.bind(id, at: 1)
        _ = try ins.step()
        return id
    }

    /// Get-or-create an agent by (name, kind), returning its id. Idempotent: a
    /// re-extract with the same backend reuses the same agent row. Optionally
    /// records `version` (e.g. the configured model id) and `external_ref`.
    /// INTERNAL — caller holds `lock`.
    private func ensureAgent(name: String, kind: String = "software",
                             version: String? = nil, externalRef: String? = nil) throws -> String {
        let find = try statement(
            "SELECT id FROM agents WHERE name = ?1 AND kind = ?2 LIMIT 1;")
        defer { find.reset() }
        try find.bind(name, at: 1)
        try find.bind(kind, at: 2)
        if try find.step() { return find.text(at: 0) }
        let id = ULID.generate()
        let ins = try statement("""
        INSERT INTO agents (id, kind, name, version, external_ref)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """)
        defer { ins.reset() }
        try ins.bind(id, at: 1)
        try ins.bind(kind, at: 2)
        try ins.bind(name, at: 3)
        if let version { try ins.bind(version, at: 4) }
        if let externalRef { try ins.bind(externalRef, at: 5) }
        _ = try ins.step()
        return id
    }

    public func deleteSource(id: PageID) throws {
        try mutate(event: { _ in localEvent(.source, id: id.rawValue, change: .deleted) }) {
        // The `refs` table has NO `owner_id REFERENCES sources(id) ON DELETE
        // CASCADE` FK — W0 (#312) dropped it because `owner_id` is polymorphic:
        // a source id for `source-content`/`source-derived` refs, a page id for
        // `page-content` refs. So deleting a source would otherwise orphan its
        // ref rows (the `version_id` they point at cascades away via
        // `source_versions`/`source_markdown_versions` FKs, but the ref row
        // itself survives), leaving `refsGenerationSum` — a changeToken fold —
        // stale and the File Provider's `files/` tree unrefreshed. Delete the
        // source's refs explicitly, in the same transaction as the source row.
        // Regression: `changeTokenAdvancesOnIngestAndDelete`,
        // `deleteSourceCascadesVersionsAndRefsKeepsBlobs`.
        try withTransaction {
            let deleteRefs = try statement(
                """
                DELETE FROM refs
                WHERE owner_id = ?1 AND kind IN ('source-content','source-derived');
                """)
            defer { deleteRefs.reset() }
            try deleteRefs.bind(id.rawValue, at: 1)
            _ = try deleteRefs.step()

            let stmt = try statement("DELETE FROM sources WHERE id = ?1;")
            defer { stmt.reset() }
            try stmt.bind(id.rawValue, at: 1)
            _ = try stmt.step()
        }
        }
    }

    // MARK: - Blob GC (graph-model §13 / issue #253)

    /// A blob is orphaned when no version row references its hash. The
    /// reachability edges into `blobs` are `source_versions.blob_hash`,
    /// `source_versions.thumbnail_hash`, `source_markdown_versions.blob_hash`,
    /// and `page_versions.blob_hash` (chunks/embeddings/attachments store
    /// bytes inline, so they don't count). Each subquery filters out NULLs:
    /// without that, SQLite's three-valued `NOT IN (…, NULL, …)` logic would
    /// suppress live orphans. Shared by the count SELECT and the DELETE so the
    /// report always matches what's reclaimed.
    ///
    /// **Bug fix (#multi-writer-hardening Phase 0):** the `page_versions.blob_hash`
    /// edge was MISSING from the original predicate, so `vacuum-blobs --apply`
    /// deleted blobs still referenced by page history — silent page-version
    /// data loss. It is included here too; after v35 lands, `workspace_refs.blob_hash`
    /// (staged created-page bodies) is a further edge.
    private static let orphanBlobPredicate = """
        hash NOT IN (SELECT blob_hash        FROM source_versions            WHERE blob_hash IS NOT NULL)
        AND hash NOT IN (SELECT thumbnail_hash FROM source_versions          WHERE thumbnail_hash IS NOT NULL)
        AND hash NOT IN (SELECT blob_hash      FROM source_markdown_versions WHERE blob_hash IS NOT NULL)
        AND hash NOT IN (SELECT blob_hash      FROM page_versions             WHERE blob_hash IS NOT NULL)
        AND hash NOT IN (SELECT blob_hash      FROM workspace_refs            WHERE blob_hash IS NOT NULL)
    """

    /// Sweep **orphaned** blob rows — blobs no version references. Deleting a
    /// source cascades its `source_versions`/`source_markdown_versions` rows but
    /// leaves their blobs behind; this is the lazy reclamation for that leak.
    /// `dryRun == true` (the `wikictl admin vacuum-blobs` default) reports the
    /// orphan count + reclaimable bytes WITHOUT deleting; `dryRun == false`
    /// (`--apply`) deletes them. Count + delete run in ONE transaction, so the
    /// report is always exactly what was (or would be) reclaimed.
    ///
    /// **NO_EMIT** (see `StoreEmissionExhaustivenessTests`): vacuuming orphans
    /// changes no projected `ResourceKind` — blobs fold into the changeToken only
    /// through their referencing version rows, so the served tree and token are
    /// unaffected. It does NOT route through `mutate()` and emits no event.
    @discardableResult
    public func vacuumBlobs(dryRun: Bool) throws -> BlobVacuumReport {
        try withTransaction {
            let counter = try statement(
                "SELECT COUNT(*), COALESCE(SUM(byte_size), 0) FROM blobs WHERE \(Self.orphanBlobPredicate);")
            defer { counter.reset() }
            _ = try counter.step()   // COUNT always yields exactly one row.
            let orphanCount = Int(counter.int(at: 0))
            let bytes = Int(counter.int(at: 1))

            if !dryRun {
                let deleter = try statement("DELETE FROM blobs WHERE \(Self.orphanBlobPredicate);")
                defer { deleter.reset() }
                _ = try deleter.step()
            }
            return BlobVacuumReport(orphanCount: orphanCount, bytesReclaimed: bytes, applied: !dryRun)
        }
    }

    // MARK: - Activity GC (graph-model §13 / issue #257)

    /// An activity is orphaned when no version row references its id. The two
    /// reachability edges into `activities` are
    /// `source_versions.activity_id` and `source_markdown_versions.activity_id`.
    /// Each subquery filters out NULLs: without that, SQLite's three-valued
    /// `NOT IN (…, NULL, …)` logic would suppress live orphans. Shared by the
    /// count SELECT and the DELETE so the report always matches what's reclaimed.
    private static let orphanActivityPredicate = """
        id NOT IN (SELECT activity_id FROM source_versions            WHERE activity_id IS NOT NULL)
        AND id NOT IN (SELECT activity_id FROM source_markdown_versions WHERE activity_id IS NOT NULL)
        AND id NOT IN (SELECT activity_id FROM page_versions           WHERE activity_id IS NOT NULL)
    """

    /// Sweep **orphaned** activity rows — activities no version references.
    /// Deleting a source cascades its `source_versions`/
    /// `source_markdown_versions` rows but leaves their activities behind; this
    /// is the lazy reclamation for that leak (#257). Mirrors `vacuumBlobs`:
    /// `dryRun == true` (the `wikictl admin vacuum-activities` default) reports
    /// the orphan count WITHOUT deleting; `dryRun == false` (`--apply`) deletes
    /// them. Count + delete run in ONE transaction, so the report is always
    /// exactly what was (or would be) reclaimed.
    ///
    /// **NO_EMIT** (see `StoreEmissionExhaustivenessTests`): vacuuming orphans
    /// changes no projected `ResourceKind` — activities fold into the
    /// changeToken only through their referencing version rows, so the served
    /// tree and token are unaffected by a count-only change. It does NOT route
    /// through `mutate()` and emits no event.
    @discardableResult
    public func vacuumActivities(dryRun: Bool) throws -> ActivityVacuumReport {
        try withTransaction {
            let counter = try statement(
                "SELECT COUNT(*) FROM activities WHERE \(Self.orphanActivityPredicate);")
            defer { counter.reset() }
            _ = try counter.step()
            let orphanCount = Int(counter.int(at: 0))

            if !dryRun {
                let deleter = try statement(
                    "DELETE FROM activities WHERE \(Self.orphanActivityPredicate);")
                defer { deleter.reset() }
                _ = try deleter.step()
            }
            return ActivityVacuumReport(orphanCount: orphanCount, applied: !dryRun)
        }
    }

    // MARK: - Page-version GC (Phase 4 — multi-writer hardening)

    /// The set of reachable `page_versions` ids — those targeted directly by a
    /// `page-content` ref, or transitively reachable via `parent_id` /
    /// `merge_parent_id` chains from a ref target, or referenced by any
    /// `workspace_refs` row (`version_id` or `base_version_id`). Used as a
    /// NOT IN predicate to identify orphans: everything NOT in the reachable set
    /// is garbage. Shared by the count SELECT and the DELETE so the report
    /// always matches what's reclaimed.
    private func orphanPageVersionIDs() throws -> Set<String> {
        // Start with the direct ref targets.
        let refTargets = try statement("""
        SELECT version_id FROM refs WHERE kind = 'page-content' AND version_id IS NOT NULL;
        """)
        defer { refTargets.reset() }
        var reachable: Set<String> = []
        while try refTargets.step() {
            reachable.insert(refTargets.text(at: 0))
        }

        // Workspace-refenced versions (version_id and base_version_id).
        let wsVersions = try statement("""
        SELECT version_id FROM workspace_refs WHERE version_id IS NOT NULL
        UNION
        SELECT base_version_id FROM workspace_refs WHERE base_version_id IS NOT NULL;
        """)
        defer { wsVersions.reset() }
        while try wsVersions.step() {
            reachable.insert(wsVersions.text(at: 0))
        }

        // Transitively walk the ancestor chain from each reachable version.
        // This is a BFS: for each version in the frontier, find its parent_id
        // and merge_parent_id (walking UP the chain toward the root).
        var frontier = reachable
        while !frontier.isEmpty {
            let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
            // Find the parent_id / merge_parent_id OF the frontier versions
            // (walking UP the chain, not down to children).
            let parents = try statement("""
            SELECT DISTINCT parent_id FROM page_versions
            WHERE id IN (\(placeholders)) AND parent_id IS NOT NULL
            UNION
            SELECT DISTINCT merge_parent_id FROM page_versions
            WHERE id IN (\(placeholders)) AND merge_parent_id IS NOT NULL;
            """)
            defer { parents.reset() }
            for (i, id) in frontier.enumerated() {
                try parents.bind(id, at: Int32(i + 1))           // parent_id binds
            }
            let frontierCount = frontier.count
            for (i, id) in frontier.enumerated() {
                try parents.bind(id, at: Int32(frontierCount + i + 1))  // merge_parent_id binds
            }
            var newReachable: Set<String> = []
            while try parents.step() {
                let pid = parents.text(at: 0)
                if !reachable.contains(pid) {
                    newReachable.insert(pid)
                }
            }
            reachable.formUnion(newReachable)
            frontier = newReachable
        }

        return reachable
    }

    /// Sweep **orphaned** `page_versions` rows — versions not reachable from
    /// any `page-content` ref target (via `parent_id`/`merge_parent_id`
    /// chains), and not referenced by any `workspace_refs` row. `dryRun ==
    /// true` (the CLI default) reports the orphan count WITHOUT deleting;
    /// `dryRun == false` (`--apply`) deletes them. Count + delete run in ONE
    /// transaction, so the report is always exactly what was (or would be)
    /// reclaimed.
    ///
    /// **NO_EMIT** (see `StoreEmissionExhaustivenessTests`): vacuuming orphaned
    /// versions changes no projected `ResourceKind` — the served tree is
    /// determined by the `page-content` ref targets, which are all in the
    /// reachable set. It does NOT route through `mutate()` and emits no event.
    @discardableResult
    public func vacuumPageVersions(dryRun: Bool) throws -> PageVersionVacuumReport {
        try withTransaction {
            let reachable = try orphanPageVersionIDs()

            // Orphan = every page_versions row whose id is NOT in the reachable set.
            // If the reachable set is empty (no pages at all), everything is orphaned.
            let orphanCount: Int
            if reachable.isEmpty {
                let counter = try statement("SELECT COUNT(*) FROM page_versions;")
                defer { counter.reset() }
                _ = try counter.step()
                orphanCount = Int(counter.int(at: 0))
            } else {
                let placeholders = reachable.map { _ in "?" }.joined(separator: ",")
                let counter = try statement(
                    "SELECT COUNT(*) FROM page_versions WHERE id NOT IN (\(placeholders));")
                defer { counter.reset() }
                for (i, id) in reachable.enumerated() {
                    try counter.bind(id, at: Int32(i + 1))
                }
                _ = try counter.step()
                orphanCount = Int(counter.int(at: 0))
            }

            if !dryRun && orphanCount > 0 {
                if reachable.isEmpty {
                    let deleter = try statement("DELETE FROM page_versions;")
                    defer { deleter.reset() }
                    _ = try deleter.step()
                } else {
                    let placeholders = reachable.map { _ in "?" }.joined(separator: ",")
                    let deleter = try statement(
                        "DELETE FROM page_versions WHERE id NOT IN (\(placeholders));")
                    defer { deleter.reset() }
                    for (i, id) in reachable.enumerated() {
                        try deleter.bind(id, at: Int32(i + 1))
                    }
                    _ = try deleter.step()
                }
            }
            return PageVersionVacuumReport(deletedCount: orphanCount, applied: !dryRun)
        }
    }

    // MARK: - Graph-model Phase 1: content versioning primitives

    /// Append a new content version for a source (the store-level refresh/
    /// re-ingest primitive; Phase 3 wires the provider refresh UI/verb). Hashes
    /// the bytes → `INSERT OR IGNORE` into `blobs` (identical bytes = zero new
    /// blob bytes, the dedup win) → a new `source_versions` row whose
    /// `parent_id` is the current active version → `UPSERT` the `source-content`
    /// ref (generation + 1) → refresh the denormalized `sources` mirror
    /// (`byte_size`/`mime_type`/`version`/`updated_at`). All in ONE transaction.
    ///
    /// Throws `.unexpected` if `data` exceeds `ingestByteCap`. Returns the new
    /// version. The history chain is append-only — nothing is ever updated or
    /// deleted (a rollback is a pointer repoint, see `rollbackSourceContent`).
    @discardableResult
    public func appendContentVersion(
        sourceID: PageID, data: Data, mimeType: String? = nil,
        provenance: SourceProvenance? = nil
    ) throws -> SourceVersion {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        guard data.count <= Self.ingestByteCap else {
            throw WikiStoreError.unexpected(
                "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
        }
        let contentHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        return try withTransaction {
            // Resolve the current active version (for parent_id + generation).
            let parent = try activeContentVersion(sourceID: sourceID)
            let prevGeneration = try refGeneration(sourceID: sourceID)

            // 1. Blob (identical bytes = one row, ever).
            let insBlob = try statement(
                "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
            insBlob.reset()
            try insBlob.bind(contentHash, at: 1)
            try insBlob.bind(Int64(data.count), at: 2)
            try insBlob.bind(data, at: 3)
            _ = try insBlob.step()

            // 2. Fetch/import activity + agent. Provenance-present seeds a real
            //    provider agent; otherwise the legacy-import fallback (the
            //    nil-provenance path stays byte-identical to pre-Phase-3).
            let agentID: String
            let activityKind: String
            if let prov = provenance {
                agentID = try ensureAgent(
                    name: prov.agentName, kind: prov.agentKind,
                    version: prov.agentVersion, externalRef: nil)
                activityKind = prov.activityKind
            } else {
                agentID = try legacyImportAgentID()
                activityKind = "fetch"
            }
            let activityID = ULID.generate()
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(activityKind, at: 2)
            try insActivity.bind(agentID, at: 3)
            if let plan = provenance?.plan { try insActivity.bind(plan, at: 4) }
            if let extRef = provenance?.externalRef { try insActivity.bind(extRef, at: 5) }
            try insActivity.bind(nowTS, at: 6)
            _ = try insActivity.step()

            // 3. New version (parent = current active).
            let versionID = ULID.generate()
            let insVersion = try statement("""
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, activity_id, external_identity, fetched_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
            """)
            insVersion.reset()
            try insVersion.bind(versionID, at: 1)
            try insVersion.bind(sourceID.rawValue, at: 2)
            if let parent { try insVersion.bind(parent.id, at: 3) }
            try insVersion.bind(contentHash, at: 4)
            if let mime = mimeType ?? parent?.mimeType {
                try insVersion.bind(mime, at: 5)
            }
            try insVersion.bind(activityID, at: 6)
            if let extID = provenance?.externalIdentity { try insVersion.bind(extID, at: 7) }
            try insVersion.bind(nowTS, at: 8)
            _ = try insVersion.step()

            // 4. UPSERT the active ref (generation + 1).
            let nextGeneration = (prevGeneration ?? 0) + 1
            let upRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, ?3, ?4)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = excluded.generation,
                updated_at = excluded.updated_at;
            """)
            upRef.reset()
            try upRef.bind(sourceID.rawValue, at: 1)
            try upRef.bind(versionID, at: 2)
            try upRef.bind(Int64(nextGeneration), at: 3)
            try upRef.bind(nowTS, at: 4)
            _ = try upRef.step()

            // 5. Refresh the denormalized `sources` mirror (byte_size,
            //    mime_type, AND content_hash — the latter so addSource's dedup
            //    check against the indexed `content_hash` stays consistent with
            //    the new active blob).
            let upSource = try statement("""
            UPDATE sources SET byte_size = ?2, content_hash = ?3, updated_at = ?4,
                                version = version + 1
            WHERE id = ?1;
            """)
            upSource.reset()
            try upSource.bind(sourceID.rawValue, at: 1)
            try upSource.bind(Int64(data.count), at: 2)
            try upSource.bind(contentHash, at: 3)
            try upSource.bind(nowTS, at: 4)
            _ = try upSource.step()
            if let mime = mimeType ?? parent?.mimeType {
                let upMime = try statement(
                    "UPDATE sources SET mime_type = ?2 WHERE id = ?1;")
                upMime.reset()
                try upMime.bind(sourceID.rawValue, at: 1)
                try upMime.bind(mime, at: 2)
                _ = try upMime.step()
            }

            return SourceVersion(
                id: versionID, sourceID: sourceID, parentID: parent?.id,
                blobHash: contentHash,
                mimeType: mimeType ?? parent?.mimeType,
                activityID: activityID,
                externalIdentity: provenance?.externalIdentity, fetchedAt: now
            )
        }
        }
    }

    /// Roll a source's active content back to a prior version — a pointer
    /// repoint (§4.3): the `source-content` ref is repointed at `versionID`
    /// (generation + 1) and the denormalized `sources` mirror is refreshed from
    /// the target version's blob. The history chain is untouched (append-only).
    /// Throws `.notFound` if `versionID` does not belong to `sourceID`.
    public func rollbackSourceContent(sourceID: PageID, to versionID: PageID) throws {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        try withTransaction {
            // Validate the target version belongs to this source; read its blob.
            let target = try statement("""
            SELECT blob_hash, mime_type FROM source_versions
            WHERE id = ?1 AND source_id = ?2;
            """)
            defer { target.reset() }
            try target.bind(versionID.rawValue, at: 1)
            try target.bind(sourceID.rawValue, at: 2)
            guard try target.step() else {
                throw WikiStoreError.notFound(versionID)
            }
            let blobHashIsNull = sqlite3_column_type(target.handle, 0) == SQLITE_NULL
            let blobHash = blobHashIsNull ? nil : target.text(at: 0)
            let mimeIsNull = sqlite3_column_type(target.handle, 1) == SQLITE_NULL
            let mime = mimeIsNull ? nil : target.text(at: 1)

            // Resolve the target blob's byte_size (0 for a byteless version).
            var byteSize: Int64 = 0
            if let blobHash {
                let bs = try statement("SELECT byte_size FROM blobs WHERE hash = ?1;")
                defer { bs.reset() }
                try bs.bind(blobHash, at: 1)
                if try bs.step() { byteSize = bs.int(at: 0) }
            }

            // Repoint the ref (generation + 1). UPSERT creates the row if absent.
            let prevGeneration = try refGeneration(sourceID: sourceID)
            let nextGeneration = (prevGeneration ?? 0) + 1
            let nowTS = Date().timeIntervalSince1970
            let upRef = try statement("""
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?1, ?2, ?3, ?4)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = excluded.generation,
                updated_at = excluded.updated_at;
            """)
            upRef.reset()
            try upRef.bind(sourceID.rawValue, at: 1)
            try upRef.bind(versionID.rawValue, at: 2)
            try upRef.bind(Int64(nextGeneration), at: 3)
            try upRef.bind(nowTS, at: 4)
            _ = try upRef.step()

            // Refresh the denormalized mirror from the target version
            // (byte_size, mime_type, AND content_hash — keep addSource dedup
            // consistent with the now-active blob; NULL for a byteless target).
            let upSource = try statement("""
            UPDATE sources SET byte_size = ?2, content_hash = ?3, updated_at = ?4,
                                version = version + 1
            WHERE id = ?1;
            """)
            upSource.reset()
            try upSource.bind(sourceID.rawValue, at: 1)
            try upSource.bind(byteSize, at: 2)
            if let blobHash { try upSource.bind(blobHash, at: 3) }
            try upSource.bind(nowTS, at: 4)
            _ = try upSource.step()
            let upMime = try statement(
                "UPDATE sources SET mime_type = ?2 WHERE id = ?1;")
            upMime.reset()
            try upMime.bind(sourceID.rawValue, at: 1)
            if let mime { try upMime.bind(mime, at: 2) }
            _ = try upMime.step()
        }
        }
    }

    /// The current `generation` of the `source-content` ref for a source, or nil
    /// when no ref row exists (default-active rule). INTERNAL — caller holds lock.
    private func refGeneration(sourceID: PageID) throws -> Int? {
        let stmt = try statement("""
        SELECT generation FROM refs
        WHERE kind = 'source-content' AND owner_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        if try stmt.step() { return Int(stmt.int(at: 0)) }
        return nil
    }

    /// Rename a source's `display_name` and rewrite every
    /// `[[source:<old>…]]` link that points at it. Bumps `sources.version` (→
    /// `changeToken` moves → File Provider refreshes).
    ///
    /// Rewrites only links whose base equals the old display name (or filename
    /// fallback). Filename-form links keep resolving (filename is immutable).
    /// Fragment and alias are preserved byte-for-byte.
    ///
    /// **Atomic** (graph-model Phase 0): the old-name read, the source UPDATE,
    /// and every page rewrite commit in ONE `withTransaction` — the nested
    /// `replaceLinks` transactions become savepoints, which is what the phase-d
    /// design wanted but raw `BEGIN IMMEDIATE` couldn't nest. Reading `oldBase`
    /// INSIDE the transaction matters: `wikictl` is a second writer process, and
    /// a rename it commits between our read and our `BEGIN IMMEDIATE` would make
    /// the rewrite loop match a stale base and rewrite nothing (cross-process
    /// TOCTOU). The embedding + FTS side effects run AFTER the commit
    /// (best-effort, and MLX inference must never run under an open write
    /// transaction — it would stall `wikictl`).
    public func renameSource(id: PageID, to newDisplayName: String) throws {
        try mutate(event: { _ in localEvent(.source, id: id.rawValue, change: .updated) }) {
        // Display names must stay citable (`[[source:name]]`) — see WikiNameRules.
        let newDisplayName = WikiNameRules.sanitized(newDisplayName)
        let renamed = try withTransaction { () -> Bool in
            // Read the old name under the write lock's snapshot.
            let old = try getSource(id: id)
            let oldBase = old.displayName ?? old.filename
            guard oldBase != newDisplayName else { return false }

            // Update the source row first.
            let stmt = try statement("""
            UPDATE sources SET display_name = ?2, updated_at = ?3, version = version + 1 WHERE id = ?1;
            """)
            defer { stmt.reset() }
            try stmt.bind(id.rawValue, at: 1)
            try stmt.bind(newDisplayName, at: 2)
            try stmt.bind(Date().timeIntervalSince1970, at: 3)
            _ = try stmt.step()

            // Phase 5: NO body rewrite. Stored aliases like
            // `[[source:ULID|Old Name]]` self-heal to the new name at render
            // (WikiLinkMarkdown.linkified resolves the ULID → current display
            // name), so a source rename is a one-row metadata update. The old
            // rewriteSourceBase loop that walked every linking page is gone —
            // zero bodies rewritten, zero ghosts.
            return true
        }
        guard renamed else { return }   // no-op rename: skip re-embed/FTS work

        // The title changed, so re-embed. Use the current processed-markdown HEAD
        // (if any) so the embedding reflects both the new name and the content;
        // embed name-only when there is no markdown yet.
        let headBody = (try? processedMarkdownHead(sourceID: id)?.content) ?? ""
        reembedSource(sourceID: id, body: headBody)
        // The FTS index title tracks the rename too (resolves display_name ?? filename).
        upsertSourceSearch(sourceID: id, body: headBody)
        }
    }

    /// Set a source's `display_name` without the link-rewrite/FTS machinery of
    /// `renameSource`. Used at ingest time when the display name is known before
    /// any links exist (e.g. a URL-ingested HTML page whose storage filename has
    /// `.md` appended but whose display name should be the clean page title).
    public func setSourceDisplayName(id: PageID, displayName: String) throws {
        try mutate(event: { _ in localEvent(.source, id: id.rawValue, change: .updated) }) {
        let stmt = try statement("""
        UPDATE sources SET display_name = ?2, updated_at = ?3, version = version + 1 WHERE id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(WikiNameRules.sanitized(displayName), at: 2)
        try stmt.bind(Date().timeIntervalSince1970, at: 3)
        _ = try stmt.step()
        }
    }

    /// Stamp a source as summarized-into-the-wiki. Idempotent and a no-op
    /// for an unknown id. Called from `wikictl log append --kind ingest --source`.
    public func markSourceIngested(id: PageID) throws {
        try mutate(event: { _ in localEvent(.source, id: id.rawValue, change: .updated) }) {
        let stmt = try statement(
            "UPDATE sources SET ingested_at = ?2 WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(Date().timeIntervalSince1970, at: 2)
        _ = try stmt.step()
        }
    }

    /// IDs of sources the agent has marked ingested — the authoritative
    /// status the UI's "Processed" badge reads.
    public func markedSourceIDs() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
    /// zotero_item_key, zotero_item_title, display_name, role) to a summary.
    /// `mime_type` and the two Zotero columns are read as NULL→nil via the column type.
    /// `role` is a NOT NULL TEXT column decoded via `SourceRole(rawValue:)`.
    private func sourceSummary(from stmt: SQLiteStatement) -> SourceSummary {
        let mime = sqlite3_column_type(stmt.handle, 3) == SQLITE_NULL
            ? nil : stmt.text(at: 3)
        let zoteroItemKey = sqlite3_column_type(stmt.handle, 8) == SQLITE_NULL
            ? nil : stmt.text(at: 8)
        let zoteroItemTitle = sqlite3_column_type(stmt.handle, 9) == SQLITE_NULL
            ? nil : stmt.text(at: 9)
        let displayName = sqlite3_column_type(stmt.handle, 10) == SQLITE_NULL
            ? nil : stmt.text(at: 10)
        let role = SourceRole(rawValue: stmt.text(at: 11)) ?? .primary
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
            displayName: displayName,
            role: role
        )
    }

    // MARK: - System prompt (singleton document, v3)

    /// Read the singleton system-prompt document. Returns the seeded default if
    /// no row exists yet (defensive — the v2→3 migration seeds one). The caller
    /// (read projection) wraps this in `try?` and falls back to the default if
    /// the table itself is absent on a not-yet-migrated read connection.
    public func getSystemPrompt() throws -> SystemPrompt {
        lock.lock(); defer { lock.unlock() }
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
        try mutate(event: { _ in localEvent(.systemPrompt, id: "system-prompt", change: .updated) }) {
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
    }

    // MARK: - Log (append-only chronological log, Phase B)

    /// Append one row to the `log` table. The id is a fresh ULID (sortable ==
    /// chronological); `ts` is "now". `kind` is the stable rawValue of the closed
    /// `LogEntry.Kind` set. Returns the inserted entry (so the CLI can echo its
    /// id). Append-only: this never updates or UPSERTs.
    @discardableResult
    public func appendLog(kind: LogEntry.Kind, title: String, note: String?) throws -> LogEntry {
        try mutate(event: { entry in localEvent(.log, id: entry.id.rawValue, change: .created) }) {
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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
        try mutate(event: { _ in localEvent(.wikiIndex, id: "wiki-index", change: .updated) }) {
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

    // MARK: - Bookmark nodes

    public func listBookmarkNodes() throws -> [BookmarkNode] {
        lock.lock(); defer { lock.unlock() }
        // Order root nodes (parent_id IS NULL) first, then by position within
        // each parent. SQLite lacks NULLS FIRST, so `parent_id IS NULL DESC`
        // sorts NULL parents before non-NULL.
        let stmt = try statement("""
        SELECT id, parent_id, position, kind, label, target_id, created_at, updated_at
        FROM bookmark_nodes
        ORDER BY parent_id IS NULL DESC, parent_id, position;
        """)
        defer { stmt.reset() }
        var out: [BookmarkNode] = []
        while try stmt.step() {
            out.append(BookmarkNode(
                id: stmt.text(at: 0),
                parentID: sqlite3_column_type(stmt.handle, 1) == SQLITE_NULL ? nil : stmt.text(at: 1),
                position: Int(stmt.int(at: 2)),
                kind: BookmarkNodeKind(rawValue: stmt.text(at: 3)) ?? .folder,
                label: sqlite3_column_type(stmt.handle, 4) == SQLITE_NULL ? nil : stmt.text(at: 4),
                targetID: sqlite3_column_type(stmt.handle, 5) == SQLITE_NULL ? nil : PageID(rawValue: stmt.text(at: 5)),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 7))
            ))
        }
        return out
    }

    public func createBookmarkNode(
        parentID: String?,
        position: Int,
        kind: BookmarkNodeKind,
        label: String?,
        targetID: PageID?
    ) throws -> BookmarkNode {
        try mutate(event: { node in localEvent(.bookmark, id: node.id, change: .created) }) {
        let id = ULID.generate()
        let now = Date().timeIntervalSince1970
        try withTransaction {
            // Shift siblings at >= position up by 1 within the same parent.
            // SQLite's `IS` operator matches NULL=NULL (unlike `=`), so
            // `parent_id IS ?1` correctly groups root siblings.
            let shift = try statement("""
            UPDATE bookmark_nodes SET position = position + 1
            WHERE parent_id IS ?1 AND position >= ?2;
            """)
            shift.reset()
            if let parentID {
                try shift.bind(parentID, at: 1)
            } else {
                sqlite3_bind_null(shift.handle, 1)
            }
            try shift.bind(Int64(position), at: 2)
            _ = try shift.step()

            let ins = try statement("""
            INSERT INTO bookmark_nodes (id, parent_id, position, kind, label, target_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
            """)
            ins.reset()
            try ins.bind(id, at: 1)
            if let parentID {
                try ins.bind(parentID, at: 2)
            } else {
                sqlite3_bind_null(ins.handle, 2)
            }
            try ins.bind(Int64(position), at: 3)
            try ins.bind(kind.rawValue, at: 4)
            if let label {
                try ins.bind(label, at: 5)
            } else {
                sqlite3_bind_null(ins.handle, 5)
            }
            if let targetID {
                try ins.bind(targetID.rawValue, at: 6)
            } else {
                sqlite3_bind_null(ins.handle, 6)
            }
            try ins.bind(now, at: 7)
            try ins.bind(now, at: 8)
            _ = try ins.step()

            // Defense-in-depth: renumber siblings so positions stay contiguous
            // even if a caller passes a stale or out-of-range position.
            if let parentID {
                try renumberSiblings(parentID: parentID)
            } else {
                try renumberRootSiblings()
            }
        }
        let stamp = Date(timeIntervalSince1970: now)
        return BookmarkNode(id: id, parentID: parentID, position: position, kind: kind,
                        label: label, targetID: targetID, createdAt: stamp, updatedAt: stamp)
        }
    }

    public func updateBookmarkNode(id: String, label: String?) throws {
        try mutate(event: { _ in localEvent(.bookmark, id: id, change: .updated) }) {
        let now = Date().timeIntervalSince1970
        let stmt = try statement("""
        UPDATE bookmark_nodes SET label = ?2, updated_at = ?3 WHERE id = ?1;
        """)
        stmt.reset()
        try stmt.bind(id, at: 1)
        if let label {
            try stmt.bind(label, at: 2)
        } else {
            sqlite3_bind_null(stmt.handle, 2)
        }
        try stmt.bind(now, at: 3)
        _ = try stmt.step()
        }
    }

    public func deleteBookmarkNode(id: String) throws {
        try mutate(event: { _ in localEvent(.bookmark, id: id, change: .deleted) }) {
        try withTransaction {
            // Capture the parent for sibling renumbering after the delete.
            let info = try statement(
                "SELECT parent_id FROM bookmark_nodes WHERE id = ?1;")
            defer { info.reset() }
            try info.bind(id, at: 1)
            var oldParent: String? = nil
            if try info.step() {
                oldParent = sqlite3_column_type(info.handle, 0) == SQLITE_NULL ? nil : info.text(at: 0)
            }

            let del = try statement("DELETE FROM bookmark_nodes WHERE id = ?1;")
            del.reset()
            try del.bind(id, at: 1)
            _ = try del.step()

            // Renumber old siblings to be contiguous.
            if let oldParent {
                try renumberSiblings(parentID: oldParent)
            } else {
                try renumberRootSiblings()
            }
        }
        }
    }

    public func moveBookmarkNode(id: String, toParentID: String?, position: Int) throws {
        try mutate(event: { _ in localEvent(.bookmark, id: id, change: .updated) }) {
        try withTransaction {
            // Read the node's current parent + position.
            let info = try statement(
                "SELECT parent_id, position FROM bookmark_nodes WHERE id = ?1;")
            defer { info.reset() }
            try info.bind(id, at: 1)
            guard try info.step() else {
                throw WikiStoreError.unexpected("moveBookmarkNode: node \(id) not found")
            }
            let oldParent = sqlite3_column_type(info.handle, 0) == SQLITE_NULL ? nil : info.text(at: 0)

            // Cycle prevention: reject moving a node into itself or any of its
            // descendants. Walk up the parent chain from toParentID — if we
            // encounter `id`, it's a descendant (or the node itself).
            if let toParentID {
                var ancestor: String? = toParentID
                let ancestorStmt = try statement(
                    "SELECT parent_id FROM bookmark_nodes WHERE id = ?1;")
                defer { ancestorStmt.reset() }
                while let current = ancestor {
                    if current == id {
                        throw WikiStoreError.unexpected(
                            "moveBookmarkNode: cannot move \(id) into its own descendant \(toParentID)")
                    }
                    ancestorStmt.reset()
                    try ancestorStmt.bind(current, at: 1)
                    if try ancestorStmt.step() {
                        ancestor = sqlite3_column_type(ancestorStmt.handle, 0) == SQLITE_NULL
                            ? nil : ancestorStmt.text(at: 0)
                    } else {
                        break
                    }
                }
            }

            let sameParent: Bool
            if let oldParent, let toParentID {
                sameParent = oldParent == toParentID
            } else {
                sameParent = oldParent == nil && toParentID == nil
            }

            // Step 1: Shift siblings at >= position up by 1 in the NEW parent
            // (excluding the moving node itself). This is REQUIRED, not
            // redundant: without it, setting the moved node's position creates a
            // tie with an existing sibling, and the subsequent renumber's
            // `ORDER BY position` has ambiguous ordering for tied rows.
            let shift = try statement("""
            UPDATE bookmark_nodes SET position = position + 1
            WHERE parent_id IS ?1 AND position >= ?2 AND id != ?3;
            """)
            shift.reset()
            if let toParentID {
                try shift.bind(toParentID, at: 1)
            } else {
                sqlite3_bind_null(shift.handle, 1)
            }
            try shift.bind(Int64(position), at: 2)
            try shift.bind(id, at: 3)
            _ = try shift.step()

            // Step 2: Update the node's parent + position.
            let upd = try statement("""
            UPDATE bookmark_nodes SET parent_id = ?2, position = ?3 WHERE id = ?1;
            """)
            upd.reset()
            try upd.bind(id, at: 1)
            if let toParentID {
                try upd.bind(toParentID, at: 2)
            } else {
                sqlite3_bind_null(upd.handle, 2)
            }
            try upd.bind(Int64(position), at: 3)
            _ = try upd.step()

            // Step 2b: A move to a NEW parent is a meaningful change — bump
            // updated_at so a "date updated" sort reflects it. A pure same-
            // parent reorder is NOT bumped (organizing siblings shouldn't
            // reshuffle the recency view). See BookmarkNode.updatedAt.
            if !sameParent {
                let bump = try statement(
                    "UPDATE bookmark_nodes SET updated_at = ?2 WHERE id = ?1;")
                bump.reset()
                try bump.bind(id, at: 1)
                try bump.bind(Date().timeIntervalSince1970, at: 2)
                _ = try bump.step()
            }

            // Step 3: Renumber siblings on both old and new parent (or root) so
            // positions are contiguous. The shift in step 1 may leave a gap at
            // the old position.
            if let toParentID {
                try renumberSiblings(parentID: toParentID)
            } else {
                try renumberRootSiblings()
            }
            if !sameParent {
                if let oldParent {
                    try renumberSiblings(parentID: oldParent)
                } else {
                    try renumberRootSiblings()
                }
            }
        }
        }
    }

    /// Renumber all children of `parentID` so their positions are contiguous
    /// (0, 1, 2, …), preserving their current order.
    private func renumberSiblings(parentID: String) throws {
        let sel = try statement("""
        SELECT id FROM bookmark_nodes WHERE parent_id = ?1 ORDER BY position ASC;
        """)
        sel.reset()
        try sel.bind(parentID, at: 1)
        var ids: [String] = []
        while try sel.step() {
            ids.append(sel.text(at: 0))
        }
        let upd = try statement("UPDATE bookmark_nodes SET position = ?2 WHERE id = ?1;")
        for (i, childID) in ids.enumerated() {
            upd.reset()
            try upd.bind(childID, at: 1)
            try upd.bind(Int64(i), at: 2)
            _ = try upd.step()
        }
    }

    /// Renumber all root-level (parent_id IS NULL) nodes to be contiguous.
    private func renumberRootSiblings() throws {
        let sel = try statement("""
        SELECT id FROM bookmark_nodes WHERE parent_id IS NULL ORDER BY position ASC;
        """)
        sel.reset()
        var ids: [String] = []
        while try sel.step() {
            ids.append(sel.text(at: 0))
        }
        let upd = try statement("UPDATE bookmark_nodes SET position = ?2 WHERE id = ?1;")
        for (i, childID) in ids.enumerated() {
            upd.reset()
            try upd.bind(childID, at: 1)
            try upd.bind(Int64(i), at: 2)
            _ = try upd.step()
        }
    }

    // MARK: - Persisted chats (v23)

    @discardableResult
    public func createChat(kind: ChatKind, title: String) throws -> ChatSummary {
        try mutate(event: { chat in localEvent(.chat, id: chat.id.rawValue, change: .created) }) {
        let id = PageID(rawValue: ULID.generate())
        let now = Date()
        let stmt = try statement("""
        INSERT INTO chats (id, kind, title, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(kind.rawValue, at: 2)
        try stmt.bind(title, at: 3)
        try stmt.bind(now.timeIntervalSince1970, at: 4)
        try stmt.bind(now.timeIntervalSince1970, at: 5)
        _ = try stmt.step()
        return ChatSummary(id: id, kind: kind, title: title, createdAt: now, updatedAt: now, messageCount: 0)
        }
    }

    /// Empty `events` is a no-op (returns `[]` without touching `updated_at`) —
    /// checked BEFORE opening a transaction, so an idle flush never bumps
    /// `updated_at` and reorders the history list.
    @discardableResult
    public func appendChatMessages(chatID: PageID, events: [AgentEvent]) throws -> [ChatMessage] {
        guard !events.isEmpty else { return [] }
        return try mutate(event: { _ in localEvent(.chat, id: chatID.rawValue, change: .updated) }) {
        let inserted = try withTransaction {
            let exists = try statement("SELECT 1 FROM chats WHERE id = ?1;")
            defer { exists.reset() }
            try exists.bind(chatID.rawValue, at: 1)
            guard try exists.step() else {
                throw WikiStoreError.notFound(chatID)
            }

            // Dense per-chat seq, continuing from the current max (-1 when empty
            // so the first row lands at 0).
            let maxSeq = try statement(
                "SELECT COALESCE(MAX(seq), -1) FROM chat_messages WHERE chat_id = ?1;")
            defer { maxSeq.reset() }
            try maxSeq.bind(chatID.rawValue, at: 1)
            _ = try maxSeq.step()
            var nextSeq = Int(maxSeq.int(at: 0)) + 1

            let now = Date()
            let encoder = JSONEncoder()
            let ins = try statement("""
            INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
            """)
            var inserted: [ChatMessage] = []
            for event in events {
                let json = String(data: try encoder.encode(event), encoding: .utf8) ?? "{}"
                let messageID = PageID(rawValue: ULID.generate())
                ins.reset()
                try ins.bind(messageID.rawValue, at: 1)
                try ins.bind(chatID.rawValue, at: 2)
                try ins.bind(Int64(nextSeq), at: 3)
                try ins.bind(event.chatRole, at: 4)
                try ins.bind(json, at: 5)
                try ins.bind(event.plainText, at: 6)
                try ins.bind(now.timeIntervalSince1970, at: 7)
                _ = try ins.step()
                inserted.append(ChatMessage(
                    id: messageID, chatID: chatID, seq: nextSeq, event: event, createdAt: now))
                nextSeq += 1
            }

            let touch = try statement("UPDATE chats SET updated_at = ?2 WHERE id = ?1;")
            touch.reset()
            try touch.bind(chatID.rawValue, at: 1)
            try touch.bind(now.timeIntervalSince1970, at: 2)
            _ = try touch.step()

            // Keep the chat full-text index fresh (title + the now-concatenated
            // message body) so keyword search finds the new messages immediately.
            // Inside the same transaction so the FTS sidecar never lags the rows.
            upsertChatSearch(chatID: chatID)

            return inserted
        }
        // Incrementally re-embed only the newly-appended conversational messages
        // (user/assistant) so semantic search finds them. Embedding is inference
        // — run outside the transaction (like reembedSource), still inside
        // mutate so the chunk write is serialized with other store calls.
        reembedChatMessages(chatID: chatID, events: events)
        return inserted
        }
    }

    /// Rebuild the one-row-per-chat full-text sidecar: title (current) + the
    /// concatenated `plainText` of every message in `seq` order. `INSERT OR
    /// REPLACE` fires the ad+ai triggers, so `chats_fts` updates automatically.
    /// Best-effort (mirrors `upsertSourceSearch`). Called from
    /// `appendChatMessages` (inside the insert transaction) and `renameChat`.
    private func upsertChatSearch(chatID: PageID) {
        guard let titleStmt = try? statement("SELECT title FROM chats WHERE id = ?1;") else { return }
        defer { titleStmt.reset() }
        let title: String
        let body: String
        do {
            try titleStmt.bind(chatID.rawValue, at: 1)
            guard try titleStmt.step() else { return }
            title = titleStmt.text(at: 0)
        } catch {
            DebugLog.store("upsertChatSearch[\(chatID.rawValue)] title lookup failed — \(error)")
            return
        }
        do {
            let bodyStmt = try statement(
                "SELECT COALESCE(GROUP_CONCAT(text, '\n'), '') FROM chat_messages WHERE chat_id = ?1;")
            defer { bodyStmt.reset() }
            try bodyStmt.bind(chatID.rawValue, at: 1)
            _ = try bodyStmt.step()
            body = bodyStmt.text(at: 0)
        } catch {
            DebugLog.store("upsertChatSearch[\(chatID.rawValue)] body lookup failed — \(error)")
            return
        }
        guard let stmt = try? statement("""
        INSERT OR REPLACE INTO chat_search (chat_id, title, body) VALUES (?1, ?2, ?3);
        """) else { return }
        defer { stmt.reset() }
        do {
            try stmt.bind(chatID.rawValue, at: 1)
            try stmt.bind(title, at: 2)
            try stmt.bind(body, at: 3)
            _ = try stmt.step()
        } catch {
            DebugLog.store("upsertChatSearch[\(chatID.rawValue)] insert failed — \(error)")
        }
    }

    /// Incrementally embed only the newly-appended messages (not the whole
    /// conversation). Chats are append-only and grow over a session; unlike
    /// pages/sources (which re-chunk the whole document on content change), a
    /// chat append must NOT re-embed prior turns. Only `user`/`assistant`
    /// messages are embedded — that is the "what was discussed" prose a query
    /// recalls; tool/system chatter is noise for semantic ranking (it is still
    /// in the FTS body for lexical search). Each message's `plainText` is chunked
    /// + embedded, then appended at continuing `chunk_idx` (after the chat's
    /// current max). Best-effort: a no-op when vec is unavailable or the model
    /// returns nothing (the version still commits; chunks fill in on the next
    /// search-index upgrade). Mirrors `reembedSource`.
    private func reembedChatMessages(chatID: PageID, events: [AgentEvent]) {
        guard isVecAvailable() else { return }
        // Collect the embeddable text from new user/assistant messages only.
        let texts = events.compactMap { event -> String? in
            let role = event.chatRole
            guard role == "user" || role == "assistant" else { return nil }
            let text = event.plainText
            return text.isEmpty ? nil : text
        }
        guard !texts.isEmpty else { return }
        // Embed each message and flatten into one ordered chunk list.
        var chunks: [Data] = []
        for text in texts {
            chunks.append(contentsOf: EmbeddingService.chunkedEmbeddings(for: text))
        }
        guard !chunks.isEmpty else {
            DebugLog.store("reembedChatMessages[\(chatID.rawValue)] no chunks (model unavailable?) msgs=\(texts.count)")
            return
        }
        DebugLog.store("reembedChatMessages[\(chatID.rawValue)] msgs=\(texts.count) chunks=\(chunks.count)")
        try? appendChatChunks(chatID: chatID, chunks: chunks)
    }

    public func listChats() throws -> [ChatSummary] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
               (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id)
        FROM chats c
        ORDER BY c.updated_at DESC, c.rowid DESC;
        """)
        defer { stmt.reset() }
        var out: [ChatSummary] = []
        while try stmt.step() {
            out.append(ChatSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                kind: ChatKind(rawValue: stmt.text(at: 1)) ?? .edit,
                title: stmt.text(at: 2),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
                messageCount: Int(stmt.int(at: 5))
            ))
        }
        return out
    }

    /// Tolerant read: a row whose `event_json` fails to decode (a future event
    /// case, or hand-corrupted data) is skipped rather than failing the whole
    /// read — a bad row must never brick the rest of a chat's history.
    public func chatMessages(chatID: PageID) throws -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT id, seq, event_json, created_at FROM chat_messages
        WHERE chat_id = ?1 ORDER BY seq ASC;
        """)
        defer { stmt.reset() }
        try stmt.bind(chatID.rawValue, at: 1)
        let decoder = JSONDecoder()
        var out: [ChatMessage] = []
        while try stmt.step() {
            guard
                let data = stmt.text(at: 2).data(using: .utf8),
                let event = try? decoder.decode(AgentEvent.self, from: data)
            else { continue }
            out.append(ChatMessage(
                id: PageID(rawValue: stmt.text(at: 0)),
                chatID: chatID,
                seq: Int(stmt.int(at: 1)),
                event: event,
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3))
            ))
        }
        return out
    }

    public func renameChat(id: PageID, to title: String) throws {
        try mutate(event: { _ in localEvent(.chat, id: id.rawValue, change: .updated) }) {
        try withTransaction {
            let exists = try statement("SELECT 1 FROM chats WHERE id = ?1;")
            defer { exists.reset() }
            try exists.bind(id.rawValue, at: 1)
            guard try exists.step() else {
                throw WikiStoreError.notFound(id)
            }
            let upd = try statement("UPDATE chats SET title = ?2, updated_at = ?3 WHERE id = ?1;")
            upd.reset()
            try upd.bind(id.rawValue, at: 1)
            try upd.bind(title, at: 2)
            try upd.bind(Date().timeIntervalSince1970, at: 3)
            _ = try upd.step()
            // Refresh the FTS sidecar title so keyword search reflects the new
            // name (the body is unchanged; upsertChatSearch rebuilds title+body
            // in one row). A no-op if no chat_search row exists yet (a chat with
            // no messages has nothing to index; it gets created on first append).
            upsertChatSearch(chatID: id)
        }
        }
    }

    /// `ON DELETE CASCADE` (`PRAGMA foreign_keys=ON`, set at open) removes the
    /// chat's messages. No error if `id` doesn't exist.
    public func deleteChat(id: PageID) throws {
        try mutate(event: { _ in localEvent(.chat, id: id.rawValue, change: .deleted) }) {
        let stmt = try statement("DELETE FROM chats WHERE id = ?1;")
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        _ = try stmt.step()
        }
    }

    /// All chat summaries ordered by ULID (creation order) — for the File
    /// Provider projection, which needs stable creation-order enumeration (not
    /// the sidebar's most-recently-updated-first). Mirrors
    /// `listAllPagesOrderedByID()`.
    public func listAllChatsOrderedByID() throws -> [ChatSummary] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
        SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
               (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id)
        FROM chats c
        ORDER BY c.id ASC;
        """)
        defer { stmt.reset() }
        var out: [ChatSummary] = []
        while try stmt.step() {
            out.append(ChatSummary(
                id: PageID(rawValue: stmt.text(at: 0)),
                kind: ChatKind(rawValue: stmt.text(at: 1)) ?? .edit,
                title: stmt.text(at: 2),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 3)),
                updatedAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
                messageCount: Int(stmt.int(at: 5))
            ))
        }
        return out
    }

    /// Resolve a `[[chat:…]]` target to a chat id. Case-insensitive; on a
    /// duplicate-title collision, the oldest chat wins (lowest ULID — stable
    /// identity, like `resolveTitleToID` for pages). Used by the wikilink
    /// resolution path and the `WikiLinkRewriter` canonicalizer.
    public func resolveChatByTitle(_ title: String) throws -> PageID? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(
            "SELECT id FROM chats WHERE title = ?1 COLLATE NOCASE ORDER BY id ASC LIMIT 1;")
        defer { stmt.reset() }
        try stmt.bind(title, at: 1)
        guard try stmt.step() else { return nil }
        return PageID(rawValue: stmt.text(at: 0))
    }

    // MARK: - Transactions

    /// Run `body` atomically. The outermost call issues `BEGIN IMMEDIATE`
    /// (grab the write lock up front — the discipline the six historical raw
    /// transaction sites used); nested calls issue `SAVEPOINT`s, so public
    /// methods that own transactions compose (`renameSource` wraps
    /// `replaceLinks`, an outer batch may wrap `storePageChunks`, …). A nested
    /// failure rolls back only its savepoint and rethrows — best-effort callers
    /// (`try?`) keep exactly their old semantics; an outermost failure rolls
    /// back everything.
    ///
    /// Internal (not private) so tests can exercise nesting directly.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let depth = transactionDepth
        let savepoint = "wiki_txn_\(depth)"
        if depth == 0 {
            #if DEBUG
            try assertNoBusyStatements()
            #endif
            let start = DispatchTime.now()
            do {
                try exec("BEGIN IMMEDIATE;")
            } catch {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                DebugLog.store("withTransaction BEGIN IMMEDIATE failed after \(elapsedMs)ms — \(error)")
                throw error
            }
        } else {
            try exec("SAVEPOINT \(savepoint);")
        }
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            if depth == 0 {
                try exec("COMMIT;")
            } else {
                try exec("RELEASE \(savepoint);")
            }
            return result
        } catch {
            if depth == 0 {
                try? exec("ROLLBACK;")
            } else {
                try? exec("ROLLBACK TO \(savepoint);")
                try? exec("RELEASE \(savepoint);")
            }
            throw error
        }
    }

    // MARK: - Resource-change emission seam (mutate)

    /// The single lock/flush seam for every public mutating method. `body` runs
    /// under the recursive `lock` (it may call `withTransaction`, which re-enters
    /// the recursive lock, and may compose other public methods that themselves
    /// route through `mutate`). `event` computes the event from the result WHILE
    /// STILL LOCKED (so it reads committed, in-transaction state). The event is
    /// flushed to `eventBus` ONLY when `mutate`'s own nesting depth returns to 0
    /// — the outermost `mutate()` — and strictly AFTER `lock.unlock()` has
    /// released the outermost acquisition and the whole transaction is committed.
    ///
    /// This makes the §3 guarantees structural, not conventional:
    /// (a) no handler runs under the lock → no deadlock under recursive
    ///     composition or nested `withTransaction`;
    /// (b) subscribers read **committed** state (the flush is post-commit);
    /// (c) nested public-calls-public emits exactly once at the outermost exit
    ///     (the inner event is computed but never flushed).
    ///
    /// The flush depth is keyed off `mutate`'s OWN counter, **not**
    /// `transactionDepth`: that counter decrements to 0 *inside*
    /// `withTransaction`'s `defer`, *before* the lock is released, so keying off
    /// it would emit under the lock — the exact deadlock this avoids.
    ///
    /// On throw, no event is flushed (the buffered event is discarded), so no
    /// subscriber ever acts on a rolled-back change. A throwing `event` builder
    /// is swallowed via `try?` — the write already succeeded; event construction
    /// must never suppress a committed mutation.
    private func mutate<T>(
        event: (T) throws -> ResourceChangeEvent?,
        _ body: () throws -> T
    ) rethrows -> T {
        lock.lock()
        let bus = _eventBus
        mutateDepth += 1
        do {
            let result = try body()
            let pending = try? event(result)
            mutateDepth -= 1
            let outermost = mutateDepth == 0
            lock.unlock()
            if outermost, let pending {
                bus?.emit(pending)
            }
            return result
        } catch {
            mutateDepth -= 1
            lock.unlock()
            throw error
        }
    }

    /// Build a `.local` event for emission by ``mutate``. `seq` is filled by the
    /// bus on emit (the bus owns the monotone counter); `wikiID` comes from the
    /// store's (per-wiki) bus. Callers pass the resource's concrete `kind` and
    /// `id`; a `nil` bus (e.g. `wikictl`) is handled at the `mutate` flush.
    private func localEvent(_ kind: ResourceKind, id: String, change: ChangeKind) -> ResourceChangeEvent {
        ResourceChangeEvent(wikiID: _eventBus?.wikiID ?? "", kind: kind, id: id, change: change)
    }

    // MARK: - Statement helpers

    private func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = statements[sql] { return cached }
        let stmt = try SQLiteStatement(db: db, sql: sql)
        statements[sql] = stmt
        return stmt
    }

    #if DEBUG
    /// Assert no cached statement is left busy. A busy statement pins the
    /// connection's WAL read snapshot, causing stale reads and write-lock
    /// failures after external commits (#332). Acquires the recursive lock
    /// internally — safe from within `withTransaction` (re-entrant) and
    /// from bare test calls.
    internal func assertNoBusyStatements() throws {
        lock.lock(); defer { lock.unlock() }
        for (sql, stmt) in statements {
            if stmt.isBusy {
                throw WikiStoreError.unexpected(
                    "Busy cached statement detected: \(sql.prefix(80))")
            }
        }
    }

    /// Test-only seam: prepare-and-step a SQL string without resetting,
    /// so `testAssertNoBusyStatementsDetectsLeak` can trigger a busy state.
    internal func _testProbeBusyStatement(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql)
        _ = try stmt.step()   // intentionally NOT reset — simulates the bug
    }
    #endif

    /// Execute a statement that returns no rows (DDL / PRAGMA assignment).
    /// Not cached — these run once at open time.
    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        defer { sqlite3_free(errmsg) }
        guard rc == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? SQLiteStatement.message(db)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                DebugLog.store("exec BUSY/LOCKED rc=\(rc) sql=\(sql) thread=\(Thread.current) msg=\(msg)")
            }
            throw WikiStoreError.sqlite(code: rc, message: msg)
        }
    }

    /// Test hook: read a one-row PRAGMA on the store's OWN connection. Pragmas
    /// like `foreign_keys` are per-connection, so they can't be observed from a
    /// separately-opened connection — tests must ask the live store.
    func pragmaValue(_ name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? queryScalarText("PRAGMA \(name);")) ?? ""
    }

    /// Test hook: run a one-row SELECT and return column 0 as text. Used by tests
    /// to assert row counts (e.g. `SELECT COUNT(*) FROM blobs`).
    func scalarText(_ sql: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? queryScalarText(sql)) ?? ""
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
        try withTransaction {
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
        }
    }

    /// Store/replace all chunk embeddings for a page. Public so tests + the
    /// embedding maintenance path can drive it directly.
    public func storePageChunks(id: PageID, chunks: [Data]) throws {
        lock.lock(); defer { lock.unlock() }
        try replaceChunks(table: "page_chunks", idColumn: "page_id", id: id, chunks: chunks)
    }

    /// Store/replace ALL chunk embeddings for a chat (delete-then-insert, via
    /// `replaceChunks`). Used by the bulk search-index upgrade
    /// (`missingChatEmbeddingWork` → `upgradeSearchIndex`). Incremental appends
    /// go through `appendChatChunks` instead (chats are append-only).
    public func storeChatChunks(id: PageID, chunks: [Data]) throws {
        lock.lock(); defer { lock.unlock() }
        try replaceChunks(table: "chat_chunks", idColumn: "chat_id", id: id, chunks: chunks)
    }

    /// Append chunk blobs to a chat WITHOUT deleting existing rows, continuing
    /// `chunk_idx` after the chat's current max. This is the incremental write
    /// path: a chat append embeds only the new messages and appends their
    /// chunks, never touching prior turns (unlike `replaceChunks`). Owns its own
    /// transaction so the chunk insert is atomic. Internal callers only.
    private func appendChatChunks(chatID: PageID, chunks: [Data]) throws {
        try withTransaction {
            let maxStmt = try statement(
                "SELECT COALESCE(MAX(chunk_idx), -1) FROM chat_chunks WHERE chat_id = ?1;")
            defer { maxStmt.reset() }
            try maxStmt.bind(chatID.rawValue, at: 1)
            _ = try maxStmt.step()
            var idx = Int(maxStmt.int(at: 0)) + 1
            let ins = try statement("""
            INSERT INTO chat_chunks (chat_id, chunk_idx, embedding) VALUES (?1, ?2, ?3);
            """)
            defer { ins.reset() }
            for blob in chunks {
                try ins.bind(chatID.rawValue, at: 1)
                try ins.bind(Int64(idx), at: 2)
                try ins.bind(blob, at: 3)
                _ = try ins.step()
                ins.reset()
                idx += 1
            }
        }
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
        lock.lock(); defer { lock.unlock() }
        return try hybridSearch(
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
               s.version, s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
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
        lock.lock(); defer { lock.unlock() }
        do {
            try exec("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');")
        } catch { DebugLog.store("rebuildFTS: pages rebuild failed — \(error)") }
        do {
            let stmt = try statement("""
            INSERT OR IGNORE INTO source_search (source_id, title, body)
            SELECT s.id, COALESCE(s.display_name, s.filename),
                   \(Self.smvHeadBodySQL)
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
    /// Check the stored embedder identifier in `embedding_meta` against the
    /// currently selected embedder. On mismatch, wipes `page_chunks` and
    /// `source_chunks` so the async backfill re-embeds everything with the new
    /// embedder. Called as step 0 of `ensureSearchIndexesPopulated()`.
    ///
    /// `activeIdentifierOverride` is injected by tests; production passes `nil`
    /// and the live `EmbeddingService.selectedEmbedderIdentifier()` is used.
    func ensureEmbedderConsistency(activeIdentifierOverride: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        // Only the app owns embeddings — it's the sole producer of chunk vectors —
        // so only it reconciles `embedding_meta`. The CLI (`wikictl`) and the File
        // Provider extension open the store writable too, but they never embed; in
        // those contexts `selectedEmbedderIdentifier()` returns the NLEmbedder
        // fallback (no bundled model). Letting them assert that fallback would
        // create an app⇄CLI tug-of-war that wipes every chunk on each launch
        // (issue #165). Tests inject `activeIdentifierOverride` to bypass this gate.
        guard activeIdentifierOverride != nil
                || Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let activeIdentifier = activeIdentifierOverride ?? EmbeddingService.selectedEmbedderIdentifier()
        do {
            let stored = (try? queryScalarText("SELECT embedder FROM embedding_meta WHERE id = 1;")) ?? ""
            guard stored != activeIdentifier else { return }
            try exec("DELETE FROM page_chunks;")
            try exec("DELETE FROM source_chunks;")
            try exec("DELETE FROM chat_chunks;")
            let stmt = try statement("INSERT OR REPLACE INTO embedding_meta(id, embedder) VALUES (1, ?1);")
            defer { stmt.reset() }
            try stmt.bind(activeIdentifier, at: 1)
            _ = try stmt.step()
            DebugLog.store("ensureEmbedderConsistency: \(stored.isEmpty ? "(empty)" : stored) -> \(activeIdentifier), chunks wiped")
        } catch {
            DebugLog.store("ensureEmbedderConsistency: failed — \(error)")
        }
    }

    private func ensureSearchIndexesPopulated() {
        // 0. Wipe chunks if the active embedder changed since the last open.
        ensureEmbedderConsistency()

        // 0a. Ensure the byteless-source dedup UNIQUE partial index exists.
        //     Fresh DBs get it in createObjectsTablesV20; existing v21 DBs that
        //     predate Phase 3b need it created here. If an older non-UNIQUE
        //     version of the index exists (shouldn't happen — it's new), the
        //     CREATE UNIQUE IF NOT EXISTS is a no-op (the name already exists).
        //     Idempotent: a no-op once the index exists.
        do {
            try exec("""
            CREATE UNIQUE INDEX IF NOT EXISTS source_versions_byteless_eid
                ON source_versions(external_identity) WHERE blob_hash IS NULL;
            """)
        } catch {
            DebugLog.store("ensureSearchIndexes: byteless index create failed — \(error)")
        }

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
                   \(Self.smvHeadBodySQL)
            FROM sources s;
            """)
            defer { stmt.reset() }
            _ = try stmt.step()
        } catch {
            DebugLog.store("ensureSearchIndexes: source_search backfill failed — \(error)")
        }

        // 2b. Backfill the chat full-text sidecar for any chat still lacking a
        //     row (a chat created before v28, or one whose append predates the
        //     sidecar). One row per chat: title + concatenated message text. The
        //     AFTER-INSERT trigger on chat_search keeps chats_fts in sync.
        do {
            let stmt = try statement("""
            INSERT OR IGNORE INTO chat_search (chat_id, title, body)
            SELECT c.id, c.title,
                   COALESCE((SELECT GROUP_CONCAT(m.text, '\n')
                             FROM chat_messages m WHERE m.chat_id = c.id), '')
            FROM chats c
            WHERE c.id NOT IN (SELECT chat_id FROM chat_search);
            """)
            defer { stmt.reset() }
            _ = try stmt.step()
        } catch {
            DebugLog.store("ensureSearchIndexes: chat_search backfill failed — \(error)")
        }

        // 3. Rebuild an FTS index only when its term index is empty. NOTE: a bare
        //    `count(*)` on an *external-content* FTS5 table is optimized to read
        //    the CONTENT table, so `count(*) FROM pages_fts` always equals
        //    `count(*) FROM pages` — a rowid-count health check can NEVER detect
        //    an empty index. The launch ranking bug: a DB whose pages predated the
        //    FTS triggers reported pages_fts=232/232 (looked healthy) but had ZERO
        //    indexed terms → MATCH returned nothing → search degraded to
        //    semantic-only and ranked short queries arbitrarily. The `_idx` shadow
        //    b-tree holds the actual terms; 0 there means "never built" → rebuild.
        if rowCount("pages") > 0 && ftsIndexRowCount("pages_fts") == 0 {
            do { try exec("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');")
            } catch { DebugLog.store("ensureSearchIndexes: pages_fts rebuild failed — \(error)") }
        }
        if rowCount("sources") > 0 && ftsIndexRowCount("sources_fts") == 0 {
            do { try exec("INSERT INTO sources_fts(sources_fts) VALUES ('rebuild');")
            } catch { DebugLog.store("ensureSearchIndexes: sources_fts rebuild failed — \(error)") }
        }
        if rowCount("chats") > 0 && ftsIndexRowCount("chats_fts") == 0 {
            do { try exec("INSERT INTO chats_fts(chats_fts) VALUES ('rebuild');")
            } catch { DebugLog.store("ensureSearchIndexes: chats_fts rebuild failed — \(error)") }
        }

        // 4. Chunk embeddings are NOT computed here. The bulk embed is a one-time,
        //    blocking, main-thread-only upgrade (`WikiStoreModel.upgradeSearchIndex`)
        //    driven by the app layer; new content embeds inline at write time. FTS
        //    search works immediately; semantic search fills in once the upgrade
        //    has run. See `docs/skills/sqlite-concurrency/SKILL.md`.

        DebugLog.store("ensureSearchIndexes: pages_fts=\(rowCount("pages_fts"))/\(rowCount("pages")) sources_fts=\(rowCount("sources_fts"))/\(rowCount("sources")) chats_fts=\(rowCount("chats_fts"))/\(rowCount("chats")) pageChunks=\(rowCount("page_chunks")) sourceChunks=\(rowCount("source_chunks")) chatChunks=\(rowCount("chat_chunks"))")
    }

    /// Snapshot of pages that have no chunk embeddings yet: `(id, embeddable
    /// text)`. The text is `title\n\nbody` (title-only when the body is empty).
    /// Read on the main actor by `upgradeSearchIndex`; the MLX inference runs
    /// off-main but the SQLite read/write stays on main.
    public func missingPageEmbeddingWork() -> [(id: PageID, text: String)] {
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
        var out: [(id: PageID, text: String)] = []
        guard let stmt = try? statement("""
        SELECT s.id, COALESCE(s.display_name, s.filename),
               \(Self.smvHeadBodySQL)
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

    /// Snapshot of chats that have no chunk embeddings yet: `(id, embeddable
    /// text)`. The text is the chat title + the `plainText` of its user +
    /// assistant messages (the conversational prose a query recalls — tool/
    /// system chatter is excluded, matching the incremental write path). Read on
    /// the main actor by `upgradeSearchIndex`; the MLX inference runs off-main
    /// but the SQLite read/write stays on main. Mirrors
    /// ``missingPageEmbeddingWork``/``missingSourceEmbeddingWork``.
    public func missingChatEmbeddingWork() -> [(id: PageID, text: String)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(id: PageID, text: String)] = []
        guard let stmt = try? statement("""
        SELECT c.id, c.title,
               COALESCE((SELECT GROUP_CONCAT(m.text, '\n')
                         FROM chat_messages m
                         WHERE m.chat_id = c.id AND m.role IN ('user', 'assistant')), '')
        FROM chats c
        LEFT JOIN chat_chunks cc ON cc.chat_id = c.id
        WHERE cc.chat_id IS NULL;
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

    /// Row count of an FTS5 table's `_idx` shadow segment b-tree. This is NOT the
    /// distinct-term count (that's the `fts5vocab` virtual table) — but it IS a
    /// reliable emptiness probe: `_idx == 0` iff the index was never built, while
    /// `_idx > 0` iff it holds at least one segment. Unlike `rowCount` (which on
    /// an *external-content* FTS5 table reads the content table and so can never
    /// be 0 while content exists), this reflects the REAL index state. Used by
    /// `ensureSearchIndexes` step 3 to detect content rows that predate the FTS
    /// triggers (the launch ranking bug) and trigger a rebuild.
    private func ftsIndexRowCount(_ table: String) -> Int {
        (Int((try? queryScalarText("SELECT count(*) FROM \(table)_idx;")) ?? "")) ?? 0
    }

    #if DEBUG
    /// Test-only: recreate `pages_fts` as an external-content table with an
    /// EMPTY term index, reproducing the launch ranking bug (content rows that
    /// predate the FTS triggers). The triggers remain; the index simply has no
    /// terms until `ensureSearchIndexes` rebuilds it on the next open. Used by
    /// `FullTextSearchTests.emptyFtsTermIndexIsHealedOnOpen`.
    internal func _breakPagesFtsIndexForTesting() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DROP TABLE pages_fts;")
        try exec("""
            CREATE VIRTUAL TABLE pages_fts USING fts5(
                title, body_markdown,
                content='pages', content_rowid='rowid',
                tokenize='porter');
            """)
    }
    #endif

    // MARK: - Source embeddings (v12, semantic source search)

    /// Store/replace all chunk embeddings for a source. Public so tests + the
    /// embedding maintenance path can drive it directly. Mirrors
    /// `storePageChunks` — both route through the generic `replaceChunks`.
    public func storeSourceChunks(id: PageID, chunks: [Data]) throws {
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
        return try hybridSearch(
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
               s.version, s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
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

    // MARK: - Chat search (issue #245: semantic + FTS over chats)

    /// Hybrid search over chats — the same RRF fusion as pages/sources. Lexical
    /// (FTS over the `chat_search` sidecar) + semantic (vec0 cosine over
    /// `chat_chunks`, ranked by each chat's best-matching message chunk). Falls
    /// back to FTS-only when vec or the model is unavailable. Mirrors
    /// `searchSimilar`/`searchSimilarSources`.
    public func searchSimilarChats(query: String, limit: Int) throws -> [ChatSummary] {
        lock.lock(); defer { lock.unlock() }
        return try hybridSearch(
            kind: "chats", query: query, limit: limit, id: \.id,
            fts: { try searchChatsFTS(query: query, limit: $0) },
            semantic: { try searchChatsSemantic(blob: $0, limit: $1) })
    }

    /// Lexical search over chats (FTS5 bm25) via the `chat_search` sidecar.
    /// Mirrors `searchSourcesFTS`.
    private func searchChatsFTS(query: String, limit: Int) throws -> [ChatSummary] {
        let q = Self.ftsMatch(query)
        guard !q.isEmpty else { return [] }
        let sql = """
        SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
               (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id)
        FROM chats_fts
        JOIN chat_search cs ON cs.rowid = chats_fts.rowid
        JOIN chats c ON c.id = cs.chat_id
        WHERE chats_fts MATCH ?1
        ORDER BY rank
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(q, at: 1)
        try stmt.bind(Int64(limit), at: 2)
        var out: [ChatSummary] = []
        while try stmt.step() { out.append(Self.chatSummary(from: stmt)) }
        return out
    }

    /// Semantic (vec0 cosine) pass over chats. Ranks by each chat's
    /// BEST-matching message chunk (lowest cosine distance over all its chunks).
    /// Best-first. Only chats with at least one chunk appear here. Mirrors
    /// `searchSourcesSemantic`.
    private func searchChatsSemantic(blob queryBlob: Data, limit: Int) throws -> [ChatSummary] {
        let sql = """
        SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
               (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id)
        FROM (
            SELECT chat_id, MIN(vec_distance_cosine(embedding, ?1)) AS best
            FROM chat_chunks GROUP BY chat_id
        ) r
        JOIN chats c ON c.id = r.chat_id
        ORDER BY r.best ASC
        LIMIT ?2;
        """
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(queryBlob, at: 1)
        try stmt.bind(Int64(limit), at: 2)
        var out: [ChatSummary] = []
        while try stmt.step() { out.append(Self.chatSummary(from: stmt)) }
        return out
    }

    /// Decode a `ChatSummary` from the shared 6-column SELECT
    /// `(id, kind, title, created_at, updated_at, message_count)`. Used by both
    /// `searchChatsFTS` and `searchChatsSemantic` so the column order can never
    /// drift between them.
    private static func chatSummary(from stmt: SQLiteStatement) -> ChatSummary {
        ChatSummary(
            id: PageID(rawValue: stmt.text(at: 0)),
            kind: ChatKind(rawValue: stmt.text(at: 1)) ?? .edit,
            title: stmt.text(at: 2),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 3)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 4)),
            messageCount: Int(stmt.int(at: 5))
        )
    }

    /// Best-effort re-chunk + re-embed of a source after its content/name
    /// changed. No-op when vec is unavailable (the version still commits; the
    /// chunks are filled in by the next search-index upgrade). Called from
    /// `appendProcessedMarkdown` (covers extraction seeding,
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

    /// Read one `source_markdown_versions` row from the current statement position.
    /// Column order (the SELECT must match):
    ///   0 id, 1 file_id, 2 parent_id, 3 content(resolved), 4 origin, 5 note,
    ///   6 created_at, 7 activity_id, 8 source_version_id, 9 blob_hash, 10 mime_type.
    ///
    /// The `content` column passed in MUST be the resolved body — i.e. the
    /// SELECT computes `COALESCE(CAST(blobs.content AS TEXT), '')` (CAS-only:
    /// the inline `source_markdown_versions.content` column was dropped at v24,
    /// so the body lives only in `blobs`). This keeps `.content` always the full
    /// text (the resolved-body invariant) without a per-row blob read inside the
    /// caller's cursor.
    private func sourceMarkdownVersion(from stmt: SQLiteStatement) -> SourceMarkdownVersion {
        func textOrNull(_ col: Int32) -> String? {
            sqlite3_column_type(stmt.handle, col) == SQLITE_NULL ? nil : stmt.text(at: col)
        }
        let parentID = textOrNull(2).map(PageID.init(rawValue:))
        return SourceMarkdownVersion(
            id: PageID(rawValue: stmt.text(at: 0)),
            sourceID: PageID(rawValue: stmt.text(at: 1)),
            parentID: parentID,
            content: stmt.text(at: 3),
            origin: stmt.text(at: 4),
            note: textOrNull(5),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
            activityID: textOrNull(7),
            sourceVersionID: textOrNull(8),
            blobHash: textOrNull(9),
            mimeType: textOrNull(10) ?? "text/markdown",
            technique: textOrNull(11)
        )
    }

    /// The shared SELECT-list + LEFT JOIN that resolves a CAS'd row's content from
    /// its blob (falling back to the inline column for any unmigrated row). Used by
    /// every Swift-decode reader so they all honor the resolved-body invariant.
    private static let smvSelectColumns = """
    smv.id, smv.file_id, smv.parent_id,
    COALESCE(CAST(b.content AS TEXT), ''),
    smv.origin, smv.note, smv.created_at,
    smv.activity_id, smv.source_version_id, smv.blob_hash, smv.mime_type,
    smv.technique
    """
    private static let smvBlobJoin = "LEFT JOIN blobs b ON b.hash = smv.blob_hash"

    /// SQL fragment: the resolved HEAD body for source `s.id`, for embedding in a
    /// larger INSERT...SELECT. Resolves the active row via the default-active rule
    /// (`source-derived` ref → else MAX(id)), then reads its blob-decoded body via
    /// CAST (CAS rows store `''` inline). Empty string when the source has no
    /// markdown. Post-v21 every CAS'd HEAD has `content=''`, so the blobs JOIN is
    /// mandatory here — without it FTS/embedding text would silently go empty.
    private static let smvHeadBodySQL = """
    COALESCE((
      SELECT CAST(b.content AS TEXT)
      FROM source_markdown_versions smv
      LEFT JOIN blobs b ON b.hash = smv.blob_hash
      WHERE smv.id = COALESCE(
        (SELECT r.version_id FROM refs r
         WHERE r.kind = 'source-derived' AND r.owner_id = s.id
         AND EXISTS (SELECT 1 FROM source_markdown_versions smv3
                     WHERE smv3.id = r.version_id)),
        (SELECT MAX(smv2.id) FROM source_markdown_versions smv2
         WHERE smv2.file_id = s.id)
      )
    ), '')
    """

    /// CAS-store a markdown body: SHA-256 (UTF-8) → `INSERT OR IGNORE` blob →
    /// return the hex hash. Identical bodies share one blob row (dedup win).
    /// INTERNAL — caller holds `lock`.
    private func storeMarkdownBlob(_ content: String) throws -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let ins = try statement(
            "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?1, ?2, ?3);")
        ins.reset()
        try ins.bind(hash, at: 1)
        try ins.bind(Int64(data.count), at: 2)
        try ins.bind(data, at: 3)
        _ = try ins.step()
        ins.reset()
        return hash
    }

    public func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion? {
        lock.lock(); defer { lock.unlock() }
        // Prefer the `source-derived` ref; fall back to MAX(id) (default-active
        // rule, §4.3 — byte-identical to the old behavior until a ref is written).
        if let refStmt = try? statement("""
        SELECT \(Self.smvSelectColumns)
        FROM refs r
        JOIN source_markdown_versions smv ON smv.id = r.version_id
        \(Self.smvBlobJoin)
        WHERE r.kind = 'source-derived' AND r.owner_id = ?1;
        """) {
            defer { refStmt.reset() }
            try refStmt.bind(sourceID.rawValue, at: 1)
            if try refStmt.step() {
                return sourceMarkdownVersion(from: refStmt)
            }
        }
        guard let stmt = try? statement("""
        SELECT \(Self.smvSelectColumns)
        FROM source_markdown_versions smv
        \(Self.smvBlobJoin)
        WHERE smv.file_id = ?1 ORDER BY smv.id DESC LIMIT 1;
        """) else { return nil }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        guard try stmt.step() else { return nil }
        return sourceMarkdownVersion(from: stmt)
    }

    public func hasProcessedMarkdown(sourceID: PageID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? statement("""
        SELECT 1 FROM source_markdown_versions WHERE file_id = ?1 LIMIT 1;
        """) else { return false }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        return try stmt.step()
    }

    /// Read a single resolved-markdown version by its smv id (Phase 6). Returns
    /// the blob-decoded `SourceMarkdownVersion`, or `nil` when no row matches.
    /// Used by the pinned-extraction viewer to load the exact extraction a quote
    /// was written against. INTERNAL-friendly: shares `smvSelectColumns` +
    /// `smvBlobJoin` with the other readers.
    public func processedMarkdownVersion(id: PageID) throws -> SourceMarkdownVersion? {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? statement("""
        SELECT \(Self.smvSelectColumns)
        FROM source_markdown_versions smv
        \(Self.smvBlobJoin)
        WHERE smv.id = ?1;
        """) else { return nil }
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        guard try stmt.step() else { return nil }
        return sourceMarkdownVersion(from: stmt)
    }

    /// The derived-markdown version ids for `sourceID` in ULID-ascending
    /// (chronological) order — index 0 = `v1` (oldest). Phase 6: resolves an
    /// `@vN` ordinal to a concrete smv id for `source_links.pinned_version_id`.
    /// INTERNAL — caller holds `lock`.
    private func derivedVersionIDs(sourceID: PageID) throws -> [PageID] {
        let stmt = try statement("""
        SELECT id FROM source_markdown_versions WHERE file_id = ?1 ORDER BY id ASC;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var ids: [PageID] = []
        while try stmt.step() {
            ids.append(PageID(rawValue: stmt.text(at: 0)))
        }
        return ids
    }

    /// Resolve an `@vN` ordinal (1-based) to the concrete smv id for `sourceID`,
    /// or `nil` when out of range. ULID-asc = chronological. Phase 6.
    /// INTERNAL — caller holds `lock`.
    private func resolveVersionPin(_ pin: String, sourceID: PageID) throws -> PageID? {
        guard let ordinal = Int(pin), ordinal >= 1 else { return nil }
        let ids = try derivedVersionIDs(sourceID: sourceID)
        let idx = ordinal - 1
        return idx < ids.count ? ids[idx] : nil
    }

    /// Every source's derived-markdown chain as `[sourceID: [smvID]]`, ULID-asc
    /// per source (chronological; index 0 = v1). Phase 6: the render precompute
    /// builds the `sourceID → [smvID]` map in one query so `linkified` can
    /// resolve `@vN` per occurrence without per-link SQL.
    public func sourceDerivedChains() throws -> [PageID: [PageID]] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? statement("""
        SELECT file_id, id FROM source_markdown_versions ORDER BY file_id ASC, id ASC;
        """) else { return [:] }
        defer { stmt.reset() }
        var chains: [PageID: [PageID]] = [:]
        while try stmt.step() {
            let sourceID = PageID(rawValue: stmt.text(at: 0))
            let smvID = PageID(rawValue: stmt.text(at: 1))
            chains[sourceID, default: []].append(smvID)
        }
        return chains
    }

    public func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? statement("""
        SELECT \(Self.smvSelectColumns)
        FROM source_markdown_versions smv
        \(Self.smvBlobJoin)
        WHERE smv.file_id = ?1 ORDER BY smv.id DESC;
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
    /// The active HEAD for a source, resolved via the default-active rule
    /// (`source-derived` ref → else MAX(id)). Returns nil when the source has no
    /// processed markdown.
    public func processedMarkdownHeadID(sourceID: PageID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let refStmt = try? statement("""
        SELECT version_id FROM refs
        WHERE kind = 'source-derived' AND owner_id = ?1;
        """) {
            defer { refStmt.reset() }
            try refStmt.bind(sourceID.rawValue, at: 1)
            if try refStmt.step() { return refStmt.text(at: 0) }
        }
        let maxStmt = try statement("""
        SELECT id FROM source_markdown_versions
        WHERE file_id = ?1 ORDER BY id DESC LIMIT 1;
        """)
        defer { maxStmt.reset() }
        try maxStmt.bind(sourceID.rawValue, at: 1)
        if try maxStmt.step() { return maxStmt.text(at: 0) }
        return nil
    }

    /// Resolve the producing agent name for each of a source's processed-markdown
    /// versions (smv.id → agents.name), via activity_id. Used by the alternatives
    /// UI to label each extraction with its backend. INTERNAL-friendly; best-effort.
    public func processedMarkdownAgentNames(sourceID: PageID) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? statement("""
        SELECT smv.id, a.name
        FROM source_markdown_versions smv
        LEFT JOIN activities act ON act.id = smv.activity_id
        LEFT JOIN agents a ON a.id = act.agent_id
        WHERE smv.file_id = ?1;
        """) else { return [:] }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var out: [String: String] = [:]
        while try stmt.step() {
            let smvID = stmt.text(at: 0)
            if sqlite3_column_type(stmt.handle, 1) != SQLITE_NULL {
                out[smvID] = stmt.text(at: 1)
            }
        }
        return out
    }

    /// All extraction alternatives for a source, newest first, each bundled with
    /// its provenance (agent name + version) and active-HEAD flag. One join
    /// (smv → activity → agent) over the resolved-body SELECT. For track C.
    public func processedMarkdownAlternatives(sourceID: PageID) throws -> [ExtractionAlternative] {
        lock.lock(); defer { lock.unlock() }
        let headID = try? processedMarkdownHeadID(sourceID: sourceID)
        guard let stmt = try? statement("""
        SELECT \(Self.smvSelectColumns), a.name, a.version
        FROM source_markdown_versions smv
        \(Self.smvBlobJoin)
        LEFT JOIN activities act ON act.id = smv.activity_id
        LEFT JOIN agents a ON a.id = act.agent_id
        WHERE smv.file_id = ?1 ORDER BY smv.id DESC;
        """) else { return [] }
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        var out: [ExtractionAlternative] = []
        while try stmt.step() {
            let version = sourceMarkdownVersion(from: stmt)
            // Columns 0–11 are the smv row (see `smvSelectColumns`); 12/13 are
            // the agent name/version from the join.
            let agentName = (sqlite3_column_type(stmt.handle, 12) == SQLITE_NULL)
                ? "unknown" : stmt.text(at: 12)
            let modelVersion: String? = (sqlite3_column_type(stmt.handle, 13) == SQLITE_NULL)
                ? nil : stmt.text(at: 13)
            out.append(ExtractionAlternative(
                version: version,
                backendDisplayName: ExtractionAlternative.backendDisplayName(agentName: agentName),
                agentName: agentName,
                modelVersion: modelVersion,
                charCount: version.content.count,
                isActive: headID.map { $0 == version.id.rawValue } ?? false))
        }
        return out
    }

    public func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion] {
        lock.lock(); defer { lock.unlock() }
        // Ref-resolved HEAD per source: the `source-derived` ref's version_id if
        // present, else MAX(id) (default-active rule). A CTE computes the head id
        // per source, then we join the resolved row + its blob.
        guard let stmt = try? statement("""
        WITH heads(source_id, head_id) AS (
            SELECT s.id,
                   COALESCE(
                     (SELECT r.version_id FROM refs r
                      WHERE r.kind = 'source-derived' AND r.owner_id = s.id),
                     (SELECT MAX(id) FROM source_markdown_versions WHERE file_id = s.id)
                   )
            FROM sources s
        )
        SELECT \(Self.smvSelectColumns)
        FROM heads
        JOIN source_markdown_versions smv ON smv.id = heads.head_id
        \(Self.smvBlobJoin);
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
                                        origin: String, note: String?,
                                        technique: String? = nil) throws -> SourceMarkdownVersion {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        let id = PageID(rawValue: ULID.generate())
        let parentID = try processedMarkdownHead(sourceID: sourceID)?.id
        let now = Date()
        // CAS the body: hash → INSERT OR IGNORE blob → store blob_hash; leave the
        // inline column `''` (the resolved-body invariant lives in the readers).
        let blobHash = try storeMarkdownBlob(content)

        let stmt = try statement("""
        INSERT INTO source_markdown_versions
          (id, file_id, parent_id, origin, note, created_at,
           blob_hash, mime_type, technique)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'text/markdown', ?8);
        """)
        defer { stmt.reset() }
        try stmt.bind(id.rawValue, at: 1)
        try stmt.bind(sourceID.rawValue, at: 2)
        if let parentID { try stmt.bind(parentID.rawValue, at: 3) }
        try stmt.bind(origin, at: 4)
        if let note { try stmt.bind(note, at: 5) }
        try stmt.bind(now.timeIntervalSince1970, at: 6)
        try stmt.bind(blobHash, at: 7)
        if let technique { try stmt.bind(technique, at: 8) } else { try stmt.bind(nil, at: 8) }
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
            content: content, origin: origin, note: note, createdAt: now,
            blobHash: blobHash, mimeType: "text/markdown", technique: technique
        )
        }
    }

    /// Record a provenance-carrying extraction alternative (§4.5, §4.7). Creates
    /// the backend's Agent + an `extract` Activity + a CAS'd smv row in ONE
    /// transaction. Does NOT write the `source-derived` ref — alternatives
    /// coexist; the first becomes HEAD by the default-active rule (MAX id), later
    /// ones are alternatives until nominated via `setActiveMarkdown`. Returns the
    /// new version. Best-effort re-embed/search-index only when this row becomes
    /// the active head (no ref points elsewhere).
    @discardableResult
    public func recordMarkdownExtraction(
        sourceID: PageID, content: String, backend: ExtractionBackend,
        sourceVersionID: String? = nil, note: String? = nil,
        modelVersion: String? = nil
    ) throws -> SourceMarkdownVersion {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        let id = PageID(rawValue: ULID.generate())
        let parentID = try processedMarkdownHead(sourceID: sourceID)?.id
        let now = Date()
        let nowTS = now.timeIntervalSince1970
        // Resolve the source's active content version when the caller didn't
        // supply one (the model layer can't reach `activeContentVersion`).
        let resolvedSourceVersionID = sourceVersionID
            ?? (try? activeContentVersion(sourceID: sourceID))?.id

        var storedBlobHash: String = ""
        var storedActivityID: String = ""
        try withTransaction {
            // Agent (idempotent by name) + a single extract activity.
            let agentID = try ensureAgent(
                name: backend.agentName, version: modelVersion)
            let activityID = ULID.generate()
            storedActivityID = activityID
            let plan = "{\"backend\":\"\(backend.rawValue)\""
                + (modelVersion.map { ",\"model\":\"\($0)\"" } ?? "")
                + "}"
            let insActivity = try statement("""
            INSERT INTO activities (id, kind, agent_id, plan, started_at, ended_at)
            VALUES (?1, 'extract', ?2, ?3, ?4, ?4);
            """)
            insActivity.reset()
            try insActivity.bind(activityID, at: 1)
            try insActivity.bind(agentID, at: 2)
            try insActivity.bind(plan, at: 3)
            try insActivity.bind(nowTS, at: 4)
            _ = try insActivity.step()
            insActivity.reset()

            // CAS the body, then append the smv row.
            let blobHash = try storeMarkdownBlob(content)
            storedBlobHash = blobHash
            let ins = try statement("""
            INSERT INTO source_markdown_versions
              (id, file_id, parent_id, origin, note, created_at,
               activity_id, source_version_id, blob_hash, mime_type, technique)
            VALUES (?1, ?2, ?3, 'extraction', ?4, ?5, ?6, ?7, ?8, 'text/markdown', ?9);
            """)
            ins.reset()
            try ins.bind(id.rawValue, at: 1)
            try ins.bind(sourceID.rawValue, at: 2)
            if let parentID { try ins.bind(parentID.rawValue, at: 3) }
            if let note { try ins.bind(note, at: 4) }
            try ins.bind(nowTS, at: 5)
            try ins.bind(activityID, at: 6)
            if let resolvedSourceVersionID { try ins.bind(resolvedSourceVersionID, at: 7) }
            try ins.bind(blobHash, at: 8)
            try ins.bind(backend.rawValue, at: 9)
            _ = try ins.step()
            ins.reset()
        }

        // Re-embed / index only when this row is now the active head (default-
        // active rule: it is MAX(id); if a ref nominates a different row, this is
        // just a coexisting alternative and must not disturb the active index).
        let refExists = (try? markdownDerivedRef(sourceID: sourceID)) != nil
        if !refExists {
            reembedSource(sourceID: sourceID, body: content)
            upsertSourceSearch(sourceID: sourceID, body: content)
        }

        return SourceMarkdownVersion(
            id: id, sourceID: sourceID, parentID: parentID,
            content: content, origin: "extraction", note: note, createdAt: now,
            activityID: storedActivityID, sourceVersionID: resolvedSourceVersionID,
            blobHash: storedBlobHash, mimeType: "text/markdown",
            technique: backend.rawValue
        )
        }
    }

    /// True when a `source-derived` ref exists for the source (i.e. an
    /// alternative has been explicitly nominated). INTERNAL — caller holds `lock`.
    private func markdownDerivedRef(sourceID: PageID) throws -> String? {
        let stmt = try statement("""
        SELECT version_id FROM refs
        WHERE kind = 'source-derived' AND owner_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        if try stmt.step() { return stmt.text(at: 0) }
        return nil
    }

    /// Revert to an older version by appending a NEW row that reuses the target's
    /// `blob_hash` (a pointer copy — no blob bytes re-stored), then nominating it
    /// the active HEAD via the `source-derived` ref. History is preserved.
    @discardableResult
    public func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        // Read the target row — must exist and belong to sourceID. Resolve its
        // body from the blob so the returned version carries real content.
        guard let target = try? statement("""
        SELECT \(Self.smvSelectColumns)
        FROM source_markdown_versions smv
        \(Self.smvBlobJoin)
        WHERE smv.id = ?1 AND smv.file_id = ?2;
        """) else {
            throw WikiStoreError.unexpected("source_markdown_versions table not found")
        }
        defer { target.reset() }
        try target.bind(versionID.rawValue, at: 1)
        try target.bind(sourceID.rawValue, at: 2)
        guard try target.step() else {
            throw WikiStoreError.notFound(versionID)
        }
        let targetVersion = sourceMarkdownVersion(from: target)
        guard let targetBlobHash = targetVersion.blobHash else {
            // A target without a blob_hash is unmigrated/legacy — fall back to the
            // append-copy path (rare; only pre-v21 rows that escaped backfill).
            return try appendProcessedMarkdown(
                sourceID: sourceID, content: targetVersion.content,
                origin: "revert", note: "revert to \(versionID.rawValue)")
        }
        // All values extracted — release the read snapshot before the write
        // transaction so `target` is not left busy through BEGIN IMMEDIATE (#332).
        target.reset()

        // Append a new row reusing the target's blob_hash (INSERT OR IGNORE on the
        // existing hash is a no-op — zero new blob bytes), then repoint the ref.
        let id = PageID(rawValue: ULID.generate())
        let parentID = try processedMarkdownHead(sourceID: sourceID)?.id
        let now = Date()
        let nowTS = now.timeIntervalSince1970
        try withTransaction {
            let ins = try statement("""
            INSERT INTO source_markdown_versions
              (id, file_id, parent_id, origin, note, created_at,
               activity_id, source_version_id, blob_hash, mime_type)
            VALUES (?1, ?2, ?3, 'revert', ?4, ?5, ?6, ?7, ?8, ?9);
            """)
            ins.reset()
            try ins.bind(id.rawValue, at: 1)
            try ins.bind(sourceID.rawValue, at: 2)
            if let parentID { try ins.bind(parentID.rawValue, at: 3) }
            try ins.bind("revert to \(versionID.rawValue)", at: 4)
            try ins.bind(nowTS, at: 5)
            if let activityID = targetVersion.activityID { try ins.bind(activityID, at: 6) }
            if let svID = targetVersion.sourceVersionID { try ins.bind(svID, at: 7) }
            try ins.bind(targetBlobHash, at: 8)
            try ins.bind(targetVersion.mimeType, at: 9)
            _ = try ins.step()
            ins.reset()
            try upsertMarkdownDerivedRef(sourceID: sourceID, versionID: id.rawValue, now: nowTS)
        }

        // Refresh the search indexes for the now-active body.
        reembedSource(sourceID: sourceID, body: targetVersion.content)
        upsertSourceSearch(sourceID: sourceID, body: targetVersion.content)

        return SourceMarkdownVersion(
            id: id, sourceID: sourceID, parentID: parentID,
            content: targetVersion.content, origin: "revert",
            note: "revert to \(versionID.rawValue)", createdAt: now,
            activityID: targetVersion.activityID,
            sourceVersionID: targetVersion.sourceVersionID,
            blobHash: targetBlobHash, mimeType: targetVersion.mimeType
        )
        }
    }

    /// UPSERT the `source-derived` ref (generation + 1). INTERNAL — caller holds
    /// `lock` and is inside a `withTransaction` when a transactional context is
    /// required. Used by `setActiveMarkdown` and `revertProcessedMarkdown`.
    private func upsertMarkdownDerivedRef(sourceID: PageID, versionID: String, now: Double) throws {
        let prevGeneration = try markdownDerivedGeneration(sourceID: sourceID)
        let nextGeneration = (prevGeneration ?? 0) + 1
        let up = try statement("""
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('source-derived', ?1, ?2, ?3, ?4)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = excluded.generation,
            updated_at = excluded.updated_at;
        """)
        up.reset()
        try up.bind(sourceID.rawValue, at: 1)
        try up.bind(versionID, at: 2)
        try up.bind(Int64(nextGeneration), at: 3)
        try up.bind(now, at: 4)
        _ = try up.step()
        up.reset()
    }

    /// The current `generation` of the `source-derived` ref, or nil when none.
    private func markdownDerivedGeneration(sourceID: PageID) throws -> Int? {
        let stmt = try statement("""
        SELECT generation FROM refs
        WHERE kind = 'source-derived' AND owner_id = ?1;
        """)
        defer { stmt.reset() }
        try stmt.bind(sourceID.rawValue, at: 1)
        if try stmt.step() { return Int(stmt.int(at: 0)) }
        return nil
    }

    /// Nominate an existing smv row as the active HEAD for a source: validate the
    /// target belongs to the source, then UPSERT the `source-derived` ref. The
    /// changeToken already folds `refs.generation_sum`, so a repoint moves it.
    public func setActiveMarkdown(sourceID: PageID, to versionID: PageID) throws {
        try mutate(event: { _ in localEvent(.source, id: sourceID.rawValue, change: .updated) }) {
        try withTransaction {
            // Validate the target belongs to this source.
            let check = try statement("""
            SELECT 1 FROM source_markdown_versions
            WHERE id = ?1 AND file_id = ?2;
            """)
            defer { check.reset() }
            try check.bind(versionID.rawValue, at: 1)
            try check.bind(sourceID.rawValue, at: 2)
            guard try check.step() else {
                throw WikiStoreError.notFound(versionID)
            }
            try upsertMarkdownDerivedRef(
                sourceID: sourceID, versionID: versionID.rawValue,
                now: Date().timeIntervalSince1970)
        }
        // Refresh the search indexes for the newly-active body.
        if let head = try? processedMarkdownHead(sourceID: sourceID) {
            reembedSource(sourceID: sourceID, body: head.content)
            upsertSourceSearch(sourceID: sourceID, body: head.content)
        }
        }
    }
}
