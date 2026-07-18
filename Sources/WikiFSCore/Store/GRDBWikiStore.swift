import Foundation
import CryptoKit
import CSqliteVec

// `internal import` (SE-0409, Swift 6.0+) keeps GRDB types from leaking into
// downstream modules — the same discipline as `QueueStore.swift`. Without
// this, GRDB's `SQL` type (which is `ExpressibleByStringInterpolation`)
// competes with `String` in string interpolation contexts in WikiCtlCore/
// WikiFS, causing type mismatches.
internal import GRDB

/// A GRDB-backed implementation of the ``WikiStore`` protocol.
///
/// This is a **parallel implementation** — it does NOT replace
/// ``SQLiteWikiStore``. Both implementations exist; ``WikiStoreModel`` injects
/// whichever store it's given at construction (`init(store: WikiStore)`).
/// The default is still `SQLiteWikiStore`; this store is opt-in.
///
/// **Architecture** (per `plans/grdb-adoption.md`):
/// - `DatabaseQueue` serializes all reads/writes through one dispatch queue —
///   no external `NSRecursiveLock` needed (replaces `SQLiteWikiStore`'s lock).
/// - `DatabaseMigrator` provides named, idempotent, auto-tracked migrations
///   (via the `grdb_migrations` table), replacing the 37-version `user_version`
///   ladder. One consolidated fresh-schema migration mirrors
///   `createFreshSchemaV20()`; it is `IF NOT EXISTS`-guarded so existing DBs
///   (already at v37 from the hand-rolled ladder) are a no-op.
/// - The `mutate()` seam (§2, Approach B) survives as a thin wrapper around
///   `dbQueue.write { }`. The event is computed inside the transaction
///   (committed state) and emitted AFTER the write returns (post-commit), so
///   subscribers always read committed state and no handler runs under the
///   writer queue.
/// - `WikiEventBus` + `ResourceChangeEvent` are retained as-is —
///   `ValueObservation` is a complement, not a replacement, because the event
///   carries domain metadata `(wikiID, kind, id, change)` the File Provider
///   needs for scoped invalidation.
/// - sqlite-vec registers on the raw `sqlite3*` handle via
///   `db.sqliteConnection` in `prepareDatabase` — one registration site per
///   connection (better than the prior manual call in each init).
///
/// **Implementation status:**
/// - Infrastructure: connection setup, PRAGMAs, vec registration, migrator,
///   `mutate()` seam — DONE.
/// - Pages CRUD (listPages, getPage, createPage, updatePage, deletePage,
///   resolveTitleToID) — DONE (translated from proven SQL).
/// - Singletons (system prompt, wiki index, log, metadata) — DONE.
/// - All other protocol methods — safe stubs that throw
///   `WikiStoreError.unexpected("TODO: …")` (or return empty for the
///   non-throwing embed-work methods). The build compiles; methods are
///   implemented incrementally.
public final class GRDBWikiStore: WikiStore, @unchecked Sendable {

    // MARK: - Stored properties

    /// The serial GRDB connection. All reads and writes are serialized through
    /// GRDB's internal dispatch queue — no external `NSRecursiveLock` needed
    /// (the equivalent of `SQLiteWikiStore.lock`).
    private let dbQueue: DatabaseQueue

    /// Guards against double-close (`close()` then `deinit`).
    private let closeLock = NSLock()
    private var closed = false

    /// Per-wiki resource-change bus. Set once during wiki open (main actor);
    /// `nil` in `wikictl` (emit is a silent no-op). Read inside `mutate()`
    /// after the write commits — always post-commit, always outside the
    /// writer queue.
    public var eventBus: WikiEventBus?

    /// The wiki ID this store belongs to (stamped onto emitted events).
    /// Defaults to empty when the bus is nil (mirrors `SQLiteWikiStore`'s
    /// `localEvent` fallback).
    private var wikiID: String { eventBus?.wikiID ?? "" }

    // MARK: - Init

    /// Open (creating if needed) the database at `databaseURL`, run migrations,
    /// and register the sqlite-vec extension. Mirrors
    /// `SQLiteWikiStore.init(databaseURL:)`.
    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)

        // Performance PRAGMAs matching SQLiteWikiStore (#523).
        // `prepareDatabase` runs on the connection before any app code.
        // journal_mode is set to WAL by GRDB when requested, but we also
        // set it explicitly here for clarity (matching QueueStore).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-65536")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }

        // Register the statically-linked sqlite-vec on this connection
        // (connection-scoped). Non-fatal: FTS5 remains the fallback.
        // `db.sqliteConnection` is `OpaquePointer?` (GRDB's
        // `SQLiteConnection` typealias) — the raw `sqlite3*` handle.
        config.prepareDatabase { db in
            guard let handle = db.sqliteConnection else { return }
            let rc = wikifs_vec_register(UnsafeMutableRawPointer(handle))
            if rc == 0 {
                DebugLog.store("GRDBWikiStore: sqlite-vec registered on connection (vec_distance_cosine available)")
            } else {
                DebugLog.store("GRDBWikiStore: sqlite3_vec_init FAILED rc=\(rc) — semantic search disabled, FTS5 fallback active")
            }
        }

        do {
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try Self.migrator.migrate(dbQueue)
        } catch {
            throw WikiStoreError.open("\(error)")
        }
    }

    /// Open the database at `readOnlyURL` as a **read-only** store, for the
    /// File Provider extension. Uses `PRAGMA query_only=ON` on a read-write
    /// handle (same design choice as `SQLiteWikiStore.init(readOnlyURL:)` — a
    /// pure read-only connection to a WAL DB can fail to create `-shm` when no
    /// writer has set it up).
    public init(readOnlyURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)

        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-65536")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }

        // Register vec on read-only connections too (pooled readers need it
        // for `vec_distance_cosine` in search queries).
        config.prepareDatabase { db in
            guard let handle = db.sqliteConnection else { return }
            _ = wikifs_vec_register(UnsafeMutableRawPointer(handle))
        }

        do {
            dbQueue = try DatabaseQueue(path: readOnlyURL.path, configuration: config)
            // Do NOT run migrations on a read-only connection — the File
            // Provider must never author schema.
        } catch {
            throw WikiStoreError.open("\(error)")
        }
    }

    deinit {
        checkpoint()
    }

    /// Explicitly close the database connection. After calling this, the store
    /// must not be used further. Mirrors `QueueStore.close()` /
    /// `SQLiteWikiStore.close()`.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        checkpoint()
    }

    /// Force-checkpoint the WAL to zero length. Mirrors `QueueStore.checkpoint()`
    /// — the explicit TRUNCATE checkpoint flushes committed frames into the
    /// main file first so reopening the same file has nothing pending (avoids
    /// intermittent `SQLITE_ERROR` under CI load — #223, #234). Best-effort:
    /// errors are logged, not thrown.
    private func checkpoint() {
        do {
            try dbQueue.writeWithoutTransaction { db in
                if let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") {
                    let busy: Int = row["busy"]
                    if busy != 0 {
                        let log: Int = row["log"]
                        let checkpointed: Int = row["checkpointed"]
                        DebugLog.store("GRDBWikiStore WAL checkpoint busy: busy=\(busy) log=\(log) checkpointed=\(checkpointed)")
                    }
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore WAL checkpoint failed: \(error)")
        }
    }

    // MARK: - The mutate() seam (design doc §2, Approach B)

    /// Wraps a write mutation in a GRDB transaction, computes the change event
    /// from the committed result, and emits it AFTER the write returns
    /// (post-commit, outside the writer queue).
    ///
    /// **Guarantees preserved** (per design doc §2):
    /// - (a) No handler runs under the lock — `emit()` runs after
    ///   `dbQueue.write` returns, outside the serial queue.
    /// - (b) Subscribers read committed state — `dbQueue.write` commits
    ///   before returning; `emit()` is post-commit.
    /// - (d) No event on throw — `dbQueue.write` rethrows; the emit code
    ///   after it is unreachable on throw.
    ///
    /// **Nesting (c):** `dbQueue.write` is NOT reentrant — calling
    /// `dbQueue.write` from inside `dbQueue.write` deadlocks. Public methods
    /// that compose (call other public mutating methods) must pass the
    /// `Database` handle to internal helpers rather than re-entering `mutate`.
    /// This matches design doc Approach A for composing methods; Approach B's
    /// `pendingEvent` buffer is used for the non-composing case (the common
    /// case). For this pilot, all implemented methods are non-composing.
    private func mutate<T>(
        event: (T) throws -> ResourceChangeEvent?,
        _ body: (Database) throws -> T
    ) throws -> T {
        var pending: ResourceChangeEvent?
        let result = try dbQueue.write { db -> T in
            let r = try body(db)
            // Compute the event inside the transaction (committed state).
            pending = try? event(r)
            return r
        }   // COMMIT happens here
        // Post-commit: emit outside the writer queue.
        if let pending {
            eventBus?.emit(pending)
        }
        return result
    }

    /// Build a `ResourceChangeEvent` for a local mutation. `seq` is stamped by
    /// the bus on emit; `wikiID` comes from the bus (or "" when nil, e.g.
    /// `wikictl`). Mirrors `SQLiteWikiStore.localEvent`.
    private func localEvent(
        _ kind: ResourceKind, id: String, change: ChangeKind
    ) -> ResourceChangeEvent {
        ResourceChangeEvent(wikiID: wikiID, kind: kind, id: id, change: change)
    }

    // MARK: - Migrations

    /// Named, auto-tracked migrations replacing the `PRAGMA user_version` ladder.
    ///
    /// Uses one consolidated fresh-schema migration that mirrors
    /// `SQLiteWikiStore.createFreshSchemaV20()` (all 37 versions of schema,
    /// the end-state shape). All DDL is `IF NOT EXISTS`-guarded, so:
    /// - A FRESH DB: runs the one migration, creating everything.
    /// - An EXISTING DB (already at v37 from the hand-rolled ladder): the
    ///   `grdb_migrations` table doesn't exist yet, so GRDB runs all
    ///   registered migrations — but the `IF NOT EXISTS` guards make them
    ///   no-ops on an already-current schema. The only mutation that runs is
    ///   seeding the singleton rows (system_prompt, wiki_index) — guarded by
    ///   `INSERT OR IGNORE` so existing rows are untouched.
    ///
    /// This eliminates the fresh-schema-vs-ladder duality: one path for all
    /// DBs, enforced by `DatabaseMigrator`'s per-migration tracking.
    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        m.registerMigration("v1_fresh_schema") { db in
            try createFreshSchema(on: db)
        }

        return m
    }()

    /// Build the complete current schema (v37 end-state) on a fresh `Database`.
    /// Mirrors `SQLiteWikiStore.createFreshSchemaV20()` + the additive tables
    /// from v23–v37. All DDL is `IF NOT EXISTS`-guarded so re-running on an
    /// already-current DB is a no-op (idempotent for GRDB's migrator).
    private static func createFreshSchema(on db: Database) throws {
        let now = Date().timeIntervalSince1970

        // Core page model.
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS pages (
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
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS pages_slug_unique ON pages(slug);")

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS attachments (
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

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS page_links (
            from_page_id TEXT NOT NULL,
            to_page_id TEXT NOT NULL,
            link_text TEXT NOT NULL,
            PRIMARY KEY (from_page_id, to_page_id),
            FOREIGN KEY(from_page_id) REFERENCES pages(id),
            FOREIGN KEY(to_page_id) REFERENCES pages(id)
        );
        """)

        // Sources — final shape (v2 + v6 + v9 + v10 + v19 + v20).
        // v20: the `content` column is GONE — bytes live in immutable `blobs`.
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS sources (
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
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS ingested_files_created ON sources(created_at);")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS sources_content_hash ON sources(content_hash);")

        // Processed-markdown version chain (v8, v10 rename).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS source_markdown_versions (
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
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS file_markdown_versions_file
            ON source_markdown_versions(file_id, id);
        """)

        // source_links (v10 create, v11 cascade, v22 rowid + role/pin).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS source_links (
            from_page_id TEXT NOT NULL REFERENCES pages(id),
            to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            link_text    TEXT NOT NULL,
            role         TEXT NOT NULL DEFAULT 'cite',
            pinned_version_id TEXT
        );
        """)
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS source_links_edge
            ON source_links(from_page_id, to_source_id, role,
                            COALESCE(pinned_version_id, ''));
        """)

        // Singleton documents (seeded) + append-only log.
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS system_prompt (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        );
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS log (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            note TEXT
        );
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS wiki_index (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        );
        """)
        // Seed the singletons (guarded so existing rows are untouched).
        try db.execute(sql: """
        INSERT OR IGNORE INTO system_prompt (id, body_markdown, updated_at, version)
        VALUES (1, ?, ?, 1);
        """, arguments: [SystemPrompt.defaultBody, now])
        try db.execute(sql: """
        INSERT OR IGNORE INTO wiki_index (id, body_markdown, updated_at, version)
        VALUES (1, ?, ?, 1);
        """, arguments: [WikiIndex.defaultBody, now])

        // Per-chunk embeddings (v14).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS page_chunks (
            page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (page_id, chunk_idx)
        ) WITHOUT ROWID;
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS source_chunks (
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (source_id, chunk_idx)
        ) WITHOUT ROWID;
        """)

        // FTS5/BM25 (v13): pages (external-content) + sources (sidecar).
        try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(
            title, body_markdown,
            content='pages', content_rowid='rowid',
            tokenize='porter');
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS pages_fts_ai AFTER INSERT ON pages BEGIN
          INSERT INTO pages_fts(rowid, title, body_markdown)
            VALUES (new.rowid, new.title, new.body_markdown);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS pages_fts_ad AFTER DELETE ON pages BEGIN
          INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
            VALUES ('delete', old.rowid, old.title, old.body_markdown);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS pages_fts_au AFTER UPDATE ON pages BEGIN
          INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
            VALUES ('delete', old.rowid, old.title, old.body_markdown);
          INSERT INTO pages_fts(rowid, title, body_markdown)
            VALUES (new.rowid, new.title, new.body_markdown);
        END;
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS source_search (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            title     TEXT NOT NULL,
            body      TEXT NOT NULL
        );
        """)
        try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS sources_fts USING fts5(
            title, body,
            content='source_search', content_rowid='rowid',
            tokenize='porter');
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS sources_fts_ai AFTER INSERT ON source_search BEGIN
          INSERT INTO sources_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS sources_fts_ad AFTER DELETE ON source_search BEGIN
          INSERT INTO sources_fts(sources_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS sources_fts_au AFTER UPDATE ON source_search BEGIN
          INSERT INTO sources_fts(sources_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
          INSERT INTO sources_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS embedding_meta (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            embedder TEXT NOT NULL
        );
        """)
        try db.execute(sql: "INSERT OR IGNORE INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")

        // Bookmark nodes (Bookmarks sidebar tree).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS bookmark_nodes (
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
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS bookmark_nodes_parent ON bookmark_nodes(parent_id, position);")

        // v20: graph-model objects tables (blobs, agents, activities,
        // source_versions, refs).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS blobs (
            hash       TEXT PRIMARY KEY,
            byte_size  INTEGER NOT NULL,
            content    BLOB NOT NULL
        );
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS agents (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            name         TEXT NOT NULL,
            version      TEXT,
            external_ref TEXT
        );
        """)
        try db.execute(sql: """
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
        try db.execute(sql: """
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
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS source_versions_source ON source_versions(source_id, id);")
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS source_versions_byteless_eid
            ON source_versions(external_identity) WHERE blob_hash IS NULL;
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS refs (
            kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
            owner_id   TEXT NOT NULL,
            version_id TEXT NOT NULL,
            generation INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL,
            PRIMARY KEY (kind, owner_id)
        );
        """)

        // v25: persisted chat history (chats + chat_messages).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chats (
            id         TEXT PRIMARY KEY,
            kind       TEXT NOT NULL,
            title      TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            summary    TEXT,
            summary_at REAL
        );
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS chats_updated ON chats(updated_at);")
        try db.execute(sql: """
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
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_seq ON chat_messages(chat_id, seq);")

        // v28: chat search (chat_chunks + chat_search + chats_fts).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chat_chunks (
            chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            chunk_idx INTEGER NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (chat_id, chunk_idx)
        ) WITHOUT ROWID;
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chat_search (
            chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
            title   TEXT NOT NULL,
            body    TEXT NOT NULL
        );
        """)
        try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS chats_fts USING fts5(
            title, body,
            content='chat_search', content_rowid='rowid',
            tokenize='porter');
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS chats_fts_ai AFTER INSERT ON chat_search BEGIN
          INSERT INTO chats_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS chats_fts_ad AFTER DELETE ON chat_search BEGIN
          INSERT INTO chats_fts(chats_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
        END;
        """)
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS chats_fts_au AFTER UPDATE ON chat_search BEGIN
          INSERT INTO chats_fts(chats_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
          INSERT INTO chats_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END;
        """)

        // v30: page versions (W0).
        try db.execute(sql: """
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
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS page_versions_page ON page_versions(page_id, id);")

        // v31: workspaces (W1).
        try db.execute(sql: """
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
        try db.execute(sql: """
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

        // v32: workspace conflicts (W3).
        try db.execute(sql: """
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

        // v37: wiki metadata (key-value table for one-time work flags).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS wiki_metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Internal helpers (mirrors of SQLiteWikiStore privates)

    /// Derive a slug from a title, appending a ULID suffix on collision.
    /// Mirrors `SQLiteWikiStore.uniqueSlug`.
    private func uniqueSlug(from title: String, id: PageID, on db: Database) throws -> String {
        let base = Self.slugify(title)
        if try !slugExists(base, excluding: id, on: db) { return base }
        let suffix = String(id.rawValue.prefix(6)).lowercased()
        return "\(base)-\(suffix)"
    }

    /// Lowercased, space→`-`, stripped to `[a-z0-9-]`. Mirrors
    /// `SQLiteWikiStore.slugify`.
    private static func slugify(_ title: String) -> String {
        let collapsed = SlugUtils.slugBase(title)
        return collapsed.isEmpty ? "untitled" : collapsed
    }

    /// True when a page (other than `excluding`) already has `slug`.
    private func slugExists(_ slug: String, excluding id: PageID, on db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pages WHERE slug = ? AND id != ?;",
            arguments: [slug, id.rawValue]
        ) ?? 0
        return count > 0
    }

    /// Get-or-create the `legacy-import` agent row, returning its id.
    /// Mirrors `SQLiteWikiStore.legacyImportAgentID`.
    private func legacyImportAgentID(on db: Database) throws -> String {
        if let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM agents WHERE name = 'legacy-import' LIMIT 1;"
        ) {
            return id
        }
        let id = ULID.generate()
        try db.execute(sql: """
        INSERT INTO agents (id, kind, name) VALUES (?, 'software', 'legacy-import');
        """, arguments: [id])
        return id
    }

    // MARK: - WikiStore protocol: Pages

    public func listPages(sortBy: PageSortOrder) throws -> [WikiPageSummary] {
        try dbQueue.read { db in
            let orderClause: String
            switch sortBy {
            case .lastUpdated:
                orderClause = "ORDER BY updated_at DESC"
            case .newestFirst:
                orderClause = "ORDER BY created_at DESC"
            case .titleAZ:
                orderClause = "ORDER BY title COLLATE NOCASE ASC"
            }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, title, updated_at, created_at FROM pages \(orderClause);"
            )
            return rows.map { row in
                WikiPageSummary(
                    id: PageID(rawValue: row["id"]),
                    title: row["title"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                )
            }
        }
    }

    public func getPage(id: PageID) throws -> WikiPage {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, title, slug, body_markdown, created_at, updated_at, version, created_by, last_edited_by
                FROM pages WHERE id = ?;
                """,
                arguments: [id.rawValue]
            ) else {
                throw WikiStoreError.notFound(id)
            }
            let createdBy: String? = row["created_by"]
            let lastEditedBy: String? = row["last_edited_by"]
            return WikiPage(
                id: PageID(rawValue: row["id"]),
                title: row["title"],
                slug: row["slug"],
                bodyMarkdown: row["body_markdown"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                version: row["version"],
                createdBy: createdBy,
                lastEditedBy: lastEditedBy
            )
        }
    }

    public func createPage(title: String, createdBy: String?) throws -> WikiPage {
        try mutate(event: { page in
            self.localEvent(.page, id: page.id.rawValue, change: .created)
        }) { db in
            let title = WikiNameRules.sanitized(title)
            let id = PageID(rawValue: ULID.generate())
            let slug = try self.uniqueSlug(from: title, id: id, on: db)
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            try db.execute(sql: """
            INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version, created_by, last_edited_by)
            VALUES (?, ?, ?, '', ?, ?, 1, ?, ?);
            """, arguments: [id.rawValue, title, slug, nowTS, nowTS,
                            createdBy, createdBy])

            // Phase 3 (head-ref invariant): seed a root version + page-content
            // ref atomically so the page has a ref from birth. The empty body
            // is the initial blob.
            let bodyData = Data("".utf8)
            let hash = SHA256.hash(data: bodyData)
                .map { String(format: "%02x", $0) }.joined()

            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(0), bodyData])

            let legacyAgentID = try self.legacyImportAgentID(on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'import', ?, ?, ?);
            """, arguments: [activityID, legacyAgentID, nowTS, nowTS])

            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?, ?, NULL, ?, ?, ?, ?);
            """, arguments: [versionID, id.rawValue, hash, title, activityID, nowTS])

            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?, ?, 1, ?);
            """, arguments: [id.rawValue, versionID, nowTS])

            return WikiPage(
                id: id, title: title, slug: slug, bodyMarkdown: "",
                createdAt: now, updatedAt: now, version: 1,
                createdBy: createdBy, lastEditedBy: createdBy
            )
        }
    }

    public func updatePage(id: PageID, title: String, body: String, lastEditedBy: String?) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: id.rawValue, change: .updated)
        }) { db in
            let title = WikiNameRules.sanitized(title)
            let slug = try self.uniqueSlug(from: title, id: id, on: db)
            try db.execute(sql: """
            UPDATE pages
            SET title = ?, slug = ?, body_markdown = ?,
                updated_at = ?, version = version + 1, last_edited_by = ?
            WHERE id = ?;
            """, arguments: [title, slug, body,
                            Date().timeIntervalSince1970, lastEditedBy,
                            id.rawValue])
        }
    }

    public func deletePage(id: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: id.rawValue, change: .deleted)
        }) { db in
            // FK safety: page_links, attachments, source_links all have FKs
            // onto pages(id) WITHOUT ON DELETE CASCADE (unlike page_chunks).
            // Clear every dependent row first, then delete the page — all in
            // ONE transaction (dbQueue.write provides this).
            try db.execute(sql: "DELETE FROM page_links WHERE from_page_id = ? OR to_page_id = ?;",
                           arguments: [id.rawValue, id.rawValue])
            try db.execute(sql: "DELETE FROM source_links WHERE from_page_id = ?;",
                           arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM attachments WHERE page_id = ?;",
                           arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM refs WHERE owner_id = ? AND kind = 'page-content';",
                           arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM pages WHERE id = ?;",
                           arguments: [id.rawValue])
        }
    }

    public func resolveTitleToID(_ title: String) throws -> PageID? {
        try dbQueue.read { db in
            // Lowest ULID == oldest page on a duplicate-title collision.
            // COLLATE NOCASE: case-insensitive so [[home]] → "Home".
            if let id = try String.fetchOne(
                db,
                sql: "SELECT id FROM pages WHERE title = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1;",
                arguments: [title]
            ) {
                return PageID(rawValue: id)
            }
            return nil
        }
    }

    public func resolveSourceByName(_ displayName: String) throws -> PageID? {
        // TODO: complex three-pass resolution (exact, extension-stripped, lenient).
        // For now, the exact-match pass (most common case).
        try dbQueue.read { db in
            if let id = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM sources
                WHERE COALESCE(display_name, filename) = ? COLLATE NOCASE
                   OR filename = ? COLLATE NOCASE
                ORDER BY updated_at DESC LIMIT 1;
                """,
                arguments: [displayName, displayName]
            ) {
                return PageID(rawValue: id)
            }
            return nil
        }
    }

    public func replaceLinks(from pageID: PageID, parsedLinks: [ParsedLink]) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            // Delete all existing outgoing links, then insert the resolved
            // subset. Targets that don't resolve to a page are omitted (the
            // schema forbids a NULL to_page_id). Self-links allowed.
            try db.execute(sql: "DELETE FROM page_links WHERE from_page_id = ?;",
                           arguments: [pageID.rawValue])
            for link in parsedLinks {
                guard let target = try self.resolveTitleToID(link.target) else { continue }
                try db.execute(sql: """
                INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text)
                VALUES (?, ?, ?);
                """, arguments: [pageID.rawValue, target.rawValue, link.linkText])
            }
        }
    }

    // MARK: - WikiStore protocol: Sources (stubs)

    public func addSource(
        filename: String, data: Data,
        zoteroItemKey: String?, zoteroItemTitle: String?,
        mimeType: String?, provenance: SourceProvenance?,
        role: SourceRole, originalPath: String?,
        activityID: String?, resolvedDisplayName: String??
    ) throws -> SourceSummary {
        // TODO: CAS blob dedup + source_versions chain + refs + sources mirror.
        throw WikiStoreError.unexpected("GRDBWikiStore.addSource not yet implemented")
    }

    public func addBytelessSource(
        filename: String, mimeType: String?,
        provenance: SourceProvenance, role: SourceRole
    ) throws -> SourceSummary {
        throw WikiStoreError.unexpected("GRDBWikiStore.addBytelessSource not yet implemented")
    }

    public func listSources() throws -> [SourceSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at,
                   version, ingested_at, zotero_item_key, zotero_item_title,
                   display_name, content_hash, role
            FROM sources ORDER BY updated_at DESC;
            """)
            return try rows.map { row in
                try Self.readSourceSummary(from: row)
            }
        }
    }

    public func sourceContent(id: PageID) throws -> Data {
        try dbQueue.read { db in
            // Resolve the active content version → blob.
            guard let versionID = try String.fetchOne(
                db,
                sql: "SELECT version_id FROM refs WHERE kind = 'source-content' AND owner_id = ?;",
                arguments: [id.rawValue]
            ) else {
                throw WikiStoreError.notFound(id)
            }
            guard let blobHash = try String.fetchOne(
                db,
                sql: "SELECT blob_hash FROM source_versions WHERE id = ?;",
                arguments: [versionID]
            ) else {
                throw WikiStoreError.notFound(id)
            }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT content FROM blobs WHERE hash = ?;",
                arguments: [blobHash]
            ) else {
                throw WikiStoreError.notFound(id)
            }
            let data: Data = row["content"]
            return data
        }
    }

    public func deleteSource(id: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.source, id: id.rawValue, change: .deleted)
        }) { db in
            // source_versions cascade on DELETE, but blobs and activities do
            // not — they're left for lazy GC (vacuumBlobs/vacuumActivities).
            try db.execute(sql: "DELETE FROM sources WHERE id = ?;",
                           arguments: [id.rawValue])
        }
    }

    public func sourceOrigin(sourceID: PageID) throws -> SourceOrigin? {
        throw WikiStoreError.unexpected("GRDBWikiStore.sourceOrigin not yet implemented")
    }

    public func renameSource(id: PageID, to newDisplayName: String) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.renameSource not yet implemented")
    }

    public func setSourceDisplayName(id: PageID, displayName: String) throws {
        try mutate(event: { _ in
            self.localEvent(.source, id: id.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE sources SET display_name = ?, updated_at = ?, version = version + 1
            WHERE id = ?;
            """, arguments: [displayName, Date().timeIntervalSince1970, id.rawValue])
        }
    }

    public func markSourceIngested(id: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.source, id: id.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE sources SET ingested_at = ?, updated_at = ?
            WHERE id = ?;
            """, arguments: [Date().timeIntervalSince1970,
                            Date().timeIntervalSince1970, id.rawValue])
        }
    }

    public func markedSourceIDs() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT id FROM sources WHERE ingested_at IS NOT NULL;"
            )
            return Set(rows)
        }
    }

    // MARK: - WikiStore protocol: Processed markdown versions (stubs)

    public func appendContentVersion(
        sourceID: PageID, data: Data, mimeType: String?,
        provenance: SourceProvenance?
    ) throws -> SourceVersion {
        throw WikiStoreError.unexpected("GRDBWikiStore.appendContentVersion not yet implemented")
    }

    public func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion? {
        throw WikiStoreError.unexpected("GRDBWikiStore.processedMarkdownHead not yet implemented")
    }

    public func hasProcessedMarkdown(sourceID: PageID) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_markdown_versions WHERE file_id = ?;",
                arguments: [sourceID.rawValue]
            ) ?? 0
            return count > 0
        }
    }

    public func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion] {
        throw WikiStoreError.unexpected("GRDBWikiStore.processedMarkdownHistory not yet implemented")
    }

    public func processedMarkdownVersion(id: PageID) throws -> SourceMarkdownVersion? {
        throw WikiStoreError.unexpected("GRDBWikiStore.processedMarkdownVersion not yet implemented")
    }

    public func sourceDerivedChains() throws -> [PageID: [PageID]] {
        throw WikiStoreError.unexpected("GRDBWikiStore.sourceDerivedChains not yet implemented")
    }

    public func embedDescriptors() throws -> [PageID: SourceEmbedDescriptor] {
        throw WikiStoreError.unexpected("GRDBWikiStore.embedDescriptors not yet implemented")
    }

    // MARK: - WikiStore protocol: Website snapshots (stubs)

    public func ensureFetchActivity(provenance: SourceProvenance) throws -> String {
        throw WikiStoreError.unexpected("GRDBWikiStore.ensureFetchActivity not yet implemented")
    }

    public func addSnapshotImage(
        filename: String, data: Data, mimeType: String,
        originalPath: String, sourceURL: URL,
        activityID: String, role: SourceRole
    ) throws -> SourceSummary {
        throw WikiStoreError.unexpected("GRDBWikiStore.addSnapshotImage not yet implemented")
    }

    public func hasImageSiblings(sourceID: PageID) throws -> Bool {
        throw WikiStoreError.unexpected("GRDBWikiStore.hasImageSiblings not yet implemented")
    }

    public func siblingImageResolvers() throws -> [PageID: [String: PageID]] {
        throw WikiStoreError.unexpected("GRDBWikiStore.siblingImageResolvers not yet implemented")
    }

    public func processedMarkdownAgentNames(sourceID: PageID) throws -> [String: String] {
        throw WikiStoreError.unexpected("GRDBWikiStore.processedMarkdownAgentNames not yet implemented")
    }

    public func processedMarkdownAlternatives(sourceID: PageID) throws -> [ExtractionAlternative] {
        throw WikiStoreError.unexpected("GRDBWikiStore.processedMarkdownAlternatives not yet implemented")
    }

    public func appendProcessedMarkdown(
        sourceID: PageID, content: String,
        origin: SourceMarkdownOrigin, note: String?,
        technique: String?
    ) throws -> SourceMarkdownVersion {
        throw WikiStoreError.unexpected("GRDBWikiStore.appendProcessedMarkdown not yet implemented")
    }

    public func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion {
        throw WikiStoreError.unexpected("GRDBWikiStore.revertProcessedMarkdown not yet implemented")
    }

    public func recordMarkdownExtraction(
        sourceID: PageID, content: String, backend: ExtractionBackend,
        sourceVersionID: String?, note: String?, modelVersion: String?
    ) throws -> SourceMarkdownVersion {
        throw WikiStoreError.unexpected("GRDBWikiStore.recordMarkdownExtraction not yet implemented")
    }

    public func setActiveMarkdown(sourceID: PageID, to versionID: PageID) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.setActiveMarkdown not yet implemented")
    }

    // MARK: - WikiStore protocol: Page versions + workspaces (stubs)

    public func appendPageVersion(
        pageID: PageID, title: String, body: String,
        expectedHeadVersionID: String?,
        lastEditedBy: String?
    ) throws -> String {
        throw WikiStoreError.unexpected("GRDBWikiStore.appendPageVersion not yet implemented")
    }

    public func pageHeadVersionID(pageID: PageID) throws -> String? {
        try dbQueue.read { db in
            // ref → version_id, or MAX(id) if no ref (default-active rule).
            if let vid = try String.fetchOne(
                db,
                sql: "SELECT version_id FROM refs WHERE kind = 'page-content' AND owner_id = ?;",
                arguments: [pageID.rawValue]
            ) {
                return vid
            }
            return try String.fetchOne(
                db,
                sql: "SELECT MAX(id) FROM page_versions WHERE page_id = ?;",
                arguments: [pageID.rawValue]
            )
        }
    }

    public func pageVersionHistory(pageID: PageID) throws -> [PageVersionSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.pageVersionHistory not yet implemented")
    }

    public func revertPage(pageID: PageID, to versionID: String) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.revertPage not yet implemented")
    }

    public func createWorkspace(name: String?, activityID: String?) throws -> String {
        let id = ULID.generate()
        let now = Date().timeIntervalSince1970
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: """
            INSERT INTO workspaces (id, name, status, activity_id, created_at, updated_at)
            VALUES (?, ?, 'open', ?, ?, ?);
            """, arguments: [id, name, activityID, now, now])
        }
        return id
    }

    public func workspaceSummary(id: String) throws -> WorkspaceSummary? {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceSummary not yet implemented")
    }

    public func workspaceRefs(workspaceID: String) throws -> [WorkspaceRef] {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceRefs not yet implemented")
    }

    public func workspaceWritePage(
        workspaceID: String, pageID: PageID, title: String, body: String
    ) throws -> String {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceWritePage not yet implemented")
    }

    public func workspacePageVersion(workspaceID: String, pageID: PageID) throws -> String? {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspacePageVersion not yet implemented")
    }

    public func workspacePageBody(workspaceID: String, pageID: PageID) throws -> String? {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspacePageBody not yet implemented")
    }

    public func setWorkspaceIndexBody(
        workspaceID: String, indexBody: String, indexBaseVersion: String
    ) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.setWorkspaceIndexBody not yet implemented")
    }

    public func workspaceMerge(workspaceID: String) throws -> [String] {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceMerge not yet implemented")
    }

    public func abandonWorkspace(id: String) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: "UPDATE workspaces SET status = 'abandoned', updated_at = ? WHERE id = ?;",
                           arguments: [Date().timeIntervalSince1970, id])
            try db.execute(sql: "DELETE FROM workspace_refs WHERE workspace_id = ?;",
                           arguments: [id])
        }
    }

    public func workspaceRefresh(workspaceID: String) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceRefresh not yet implemented")
    }

    public func workspaceConflicts(workspaceID: String) throws -> [WorkspaceConflict] {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceConflicts not yet implemented")
    }

    public func workspaceResolveConflict(
        workspaceID: String, pageID: PageID, body: String
    ) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceResolveConflict not yet implemented")
    }

    public func workspaceRetryMerge(workspaceID: String) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.workspaceRetryMerge not yet implemented")
    }

    public func reapStaleWorkspaces(ttl: TimeInterval) throws -> Int {
        try mutate(event: { count in
            count > 0 ? self.localEvent(.page, id: "workspace-reap", change: .updated) : nil
        }) { db in
            let cutoff = Date().timeIntervalSince1970 - ttl
            try db.execute(sql: """
            UPDATE workspaces SET status = 'abandoned', updated_at = ?
            WHERE status = 'open' AND updated_at < ?;
            """, arguments: [Date().timeIntervalSince1970, cutoff])
            return db.changesCount
        }
    }

    // MARK: - WikiStore protocol: System prompt + log + wiki index

    public func getSystemPrompt() throws -> SystemPrompt {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT body_markdown, updated_at, version FROM system_prompt WHERE id = 1;"
            ) else {
                return SystemPrompt(body: SystemPrompt.defaultBody,
                                    updatedAt: Date(timeIntervalSince1970: 0), version: 0)
            }
            return SystemPrompt(
                body: row["body_markdown"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                version: row["version"]
            )
        }
    }

    public func updateSystemPrompt(body: String) throws {
        try mutate(event: { _ in
            self.localEvent(.systemPrompt, id: "system-prompt", change: .updated)
        }) { db in
            try db.execute(sql: """
            INSERT INTO system_prompt (id, body_markdown, updated_at, version)
            VALUES (1, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET
                body_markdown = excluded.body_markdown,
                updated_at = excluded.updated_at,
                version = system_prompt.version + 1;
            """, arguments: [body, Date().timeIntervalSince1970])
        }
    }

    public func appendLog(kind: LogEntry.Kind, title: String, note: String?) throws -> LogEntry {
        try mutate(event: { entry in
            self.localEvent(.log, id: entry.id.rawValue, change: .created)
        }) { db in
            let id = PageID(rawValue: ULID.generate())
            let now = Date()
            try db.execute(sql: """
            INSERT INTO log (id, ts, kind, title, note)
            VALUES (?, ?, ?, ?, ?);
            """, arguments: [id.rawValue, now.timeIntervalSince1970,
                            kind.rawValue, title, note])
            return LogEntry(id: id, timestamp: now, kind: kind, title: title, note: note)
        }
    }

    public func recentLogEntries(limit: Int) throws -> [LogEntry] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, ts, kind, title, note FROM log ORDER BY ts DESC, rowid DESC LIMIT ?;",
                arguments: [limit]
            )
            // newest-first query → reverse to chronological for the tail.
            return rows.reversed().map { row in
                let note: String? = row["note"]
                let kindRaw: String = row["kind"]
                return LogEntry(
                    id: PageID(rawValue: row["id"]),
                    timestamp: Date(timeIntervalSince1970: row["ts"]),
                    kind: LogEntry.Kind(rawValue: kindRaw) ?? .ingest,
                    title: row["title"],
                    note: note
                )
            }
        }
    }

    public func getWikiIndex() throws -> WikiIndex {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT body_markdown, updated_at, version FROM wiki_index WHERE id = 1;"
            ) else {
                return WikiIndex(body: WikiIndex.defaultBody,
                                 updatedAt: Date(timeIntervalSince1970: 0), version: 0)
            }
            return WikiIndex(
                body: row["body_markdown"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                version: row["version"]
            )
        }
    }

    public func updateWikiIndex(body: String) throws {
        try mutate(event: { _ in
            self.localEvent(.wikiIndex, id: "wiki-index", change: .updated)
        }) { db in
            try db.execute(sql: """
            INSERT INTO wiki_index (id, body_markdown, updated_at, version)
            VALUES (1, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET
                body_markdown = excluded.body_markdown,
                updated_at = excluded.updated_at,
                version = wiki_index.version + 1;
            """, arguments: [body, Date().timeIntervalSince1970])
        }
    }

    // MARK: - WikiStore protocol: Semantic search (stubs)

    public func storePageChunks(id: PageID, chunks: [Data]) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: "DELETE FROM page_chunks WHERE page_id = ?;",
                           arguments: [id.rawValue])
            for (idx, embedding) in chunks.enumerated() {
                try db.execute(sql: """
                INSERT INTO page_chunks (page_id, chunk_idx, embedding)
                VALUES (?, ?, ?);
                """, arguments: [id.rawValue, idx, embedding])
            }
        }
    }

    public func missingPageEmbeddingWork() -> [(id: PageID, text: String)] {
        // Non-throwing — return empty safely when the query fails (e.g.
        // read-only connection on a not-yet-migrated DB).
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.title || '\n' || p.body_markdown AS text
                FROM pages p
                WHERE NOT EXISTS (
                    SELECT 1 FROM page_chunks WHERE page_id = p.id
                )
                ORDER BY p.id;
                """)
                return rows.map { row in
                    (id: PageID(rawValue: row["id"]), text: row["text"])
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore.missingPageEmbeddingWork failed: \(error)")
            return []
        }
    }

    public func searchSimilar(query: String, limit: Int) throws -> [WikiPageSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.searchSimilar not yet implemented")
    }

    public func storeSourceChunks(id: PageID, chunks: [Data]) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: "DELETE FROM source_chunks WHERE source_id = ?;",
                           arguments: [id.rawValue])
            for (idx, embedding) in chunks.enumerated() {
                try db.execute(sql: """
                INSERT INTO source_chunks (source_id, chunk_idx, embedding)
                VALUES (?, ?, ?);
                """, arguments: [id.rawValue, idx, embedding])
            }
        }
    }

    public func missingSourceEmbeddingWork() -> [(id: PageID, text: String)] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, COALESCE(s.display_name, s.filename) AS text
                FROM sources s
                WHERE NOT EXISTS (
                    SELECT 1 FROM source_chunks WHERE source_id = s.id
                )
                ORDER BY s.id;
                """)
                return rows.map { row in
                    (id: PageID(rawValue: row["id"]), text: row["text"])
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore.missingSourceEmbeddingWork failed: \(error)")
            return []
        }
    }

    public func searchSimilarSources(query: String, limit: Int) throws -> [SourceSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.searchSimilarSources not yet implemented")
    }

    // MARK: - WikiStore protocol: Bookmark nodes (stubs)

    public func listBookmarkNodes() throws -> [BookmarkNode] {
        throw WikiStoreError.unexpected("GRDBWikiStore.listBookmarkNodes not yet implemented")
    }

    public func createBookmarkNode(
        parentID: String?, position: Int,
        kind: BookmarkNodeKind, label: String?,
        targetID: PageID?
    ) throws -> BookmarkNode {
        throw WikiStoreError.unexpected("GRDBWikiStore.createBookmarkNode not yet implemented")
    }

    public func updateBookmarkNode(id: String, label: String?) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.updateBookmarkNode not yet implemented")
    }

    public func deleteBookmarkNode(id: String) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.deleteBookmarkNode not yet implemented")
    }

    public func moveBookmarkNode(id: String, toParentID: String?, position: Int) throws {
        throw WikiStoreError.unexpected("GRDBWikiStore.moveBookmarkNode not yet implemented")
    }

    // MARK: - WikiStore protocol: Persisted chats (stubs)

    public func createChat(kind: ChatKind, title: String) throws -> ChatSummary {
        throw WikiStoreError.unexpected("GRDBWikiStore.createChat not yet implemented")
    }

    public func appendChatMessages(chatID: PageID, events: [AgentEvent]) throws -> [ChatMessage] {
        throw WikiStoreError.unexpected("GRDBWikiStore.appendChatMessages not yet implemented")
    }

    public func listChats() throws -> [ChatSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.listChats not yet implemented")
    }

    public func chatMessages(chatID: PageID) throws -> [ChatMessage] {
        throw WikiStoreError.unexpected("GRDBWikiStore.chatMessages not yet implemented")
    }

    public func renameChat(id: PageID, to title: String) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: id.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE chats SET title = ?, updated_at = ?
            WHERE id = ?;
            """, arguments: [title, Date().timeIntervalSince1970, id.rawValue])
        }
    }

    public func deleteChat(id: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: id.rawValue, change: .deleted)
        }) { db in
            // chat_messages cascade on DELETE.
            try db.execute(sql: "DELETE FROM chats WHERE id = ?;",
                           arguments: [id.rawValue])
        }
    }

    public func updateChatSummary(chatID: PageID, summary: String) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE chats SET summary = ?, summary_at = ?, updated_at = ?
            WHERE id = ?;
            """, arguments: [summary, Date().timeIntervalSince1970,
                            Date().timeIntervalSince1970, chatID.rawValue])
        }
    }

    public func listAllChatsOrderedByID() throws -> [ChatSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.listAllChatsOrderedByID not yet implemented")
    }

    public func resolveChatByTitle(_ title: String) throws -> PageID? {
        try dbQueue.read { db in
            if let id = try String.fetchOne(
                db,
                sql: "SELECT id FROM chats WHERE title = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1;",
                arguments: [title]
            ) {
                return PageID(rawValue: id)
            }
            return nil
        }
    }

    // MARK: - WikiStore protocol: Semantic chat search (stubs)

    public func storeChatChunks(id: PageID, chunks: [Data]) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: "DELETE FROM chat_chunks WHERE chat_id = ?;",
                           arguments: [id.rawValue])
            for (idx, embedding) in chunks.enumerated() {
                try db.execute(sql: """
                INSERT INTO chat_chunks (chat_id, chunk_idx, embedding)
                VALUES (?, ?, ?);
                """, arguments: [id.rawValue, idx, embedding])
            }
        }
    }

    public func missingChatEmbeddingWork() -> [(id: PageID, text: String)] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.title AS text
                FROM chats c
                WHERE NOT EXISTS (
                    SELECT 1 FROM chat_chunks WHERE chat_id = c.id
                )
                ORDER BY c.id;
                """)
                return rows.map { row in
                    (id: PageID(rawValue: row["id"]), text: row["text"])
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore.missingChatEmbeddingWork failed: \(error)")
            return []
        }
    }

    public func searchSimilarChats(query: String, limit: Int) throws -> [ChatSummary] {
        throw WikiStoreError.unexpected("GRDBWikiStore.searchSimilarChats not yet implemented")
    }

    // MARK: - WikiStore protocol: Blob GC (stubs)

    public func vacuumBlobs(dryRun: Bool) throws -> BlobVacuumReport {
        throw WikiStoreError.unexpected("GRDBWikiStore.vacuumBlobs not yet implemented")
    }

    public func vacuumActivities(dryRun: Bool) throws -> ActivityVacuumReport {
        throw WikiStoreError.unexpected("GRDBWikiStore.vacuumActivities not yet implemented")
    }

    public func vacuumPageVersions(dryRun: Bool) throws -> PageVersionVacuumReport {
        throw WikiStoreError.unexpected("GRDBWikiStore.vacuumPageVersions not yet implemented")
    }

    // MARK: - WikiStore protocol: Wiki metadata

    public func getMetadata(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM wiki_metadata WHERE key = ?;",
                arguments: [key]
            )
        }
    }

    public func setMetadata(_ key: String, value: String) throws {
        // NO-EMIT: metadata flags don't change projected content.
        try dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO wiki_metadata (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, arguments: [key, value])
        }
    }

    // MARK: - Row decoding helpers

    /// Read a `SourceSummary` from a GRDB `Row` (named column access, not
    /// positional). Mirrors QueueStore's `readItem(from:)` pattern.
    private static func readSourceSummary(from row: Row) throws -> SourceSummary {
        let id: String = row["id"]
        let filename: String = row["filename"]
        let ext: String = row["ext"]
        let mime: String? = row["mime_type"]
        let byteSize: Int64 = row["byte_size"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        let version: Int = row["version"]
        let zoteroKey: String? = row["zotero_item_key"]
        let zoteroTitle: String? = row["zotero_item_title"]
        let displayName: String? = row["display_name"]
        let roleRaw: String = row["role"]

        return SourceSummary(
            id: PageID(rawValue: id),
            filename: filename,
            ext: ext,
            mimeType: mime,
            byteSize: Int(byteSize),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            version: version,
            zoteroItemKey: zoteroKey,
            zoteroItemTitle: zoteroTitle,
            displayName: displayName,
            role: SourceRole(rawValue: roleRaw) ?? .primary
        )
    }
}
