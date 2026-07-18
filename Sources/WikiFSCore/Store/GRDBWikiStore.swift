import Foundation
import CryptoKit
import UniformTypeIdentifiers
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

    // MARK: - WikiStore protocol: Sources

    public func addSource(
        filename: String, data: Data,
        zoteroItemKey: String?, zoteroItemTitle: String?,
        mimeType: String?, provenance: SourceProvenance?,
        role: SourceRole, originalPath: String?,
        activityID: String?, resolvedDisplayName: String??
    ) throws -> SourceSummary {
        // Resolve the display name BEFORE entering the locked mutate path
        // (a CSV-ish PDFKit parse would extend the write transaction past the
        // 5 s busy_timeout — issue #229).
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType
            ?? ContentSniff.mimeType(of: data)
            ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
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

        return try mutate(event: { source in
            self.localEvent(.source, id: source.id.rawValue, change: .created)
        }) { db in
            guard data.count <= Self.ingestByteCap else {
                throw WikiStoreError.unexpected(
                    "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
            }
            let contentHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()

            // Dedup against sources.content_hash.
            if let dupRow = try Row.fetchOne(
                db,
                sql: """
                SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
                       zotero_item_key, zotero_item_title, display_name, role
                FROM sources WHERE content_hash = ? LIMIT 1;
                """,
                arguments: [contentHash]
            ) {
                let existing = try Self.readSourceSummary(from: dupRow)
                throw WikiStoreError.duplicateContent(existing: existing)
            }

            let id = PageID(rawValue: ULID.generate())
            let now = Date()
            let nowTS = now.timeIntervalSince1970
            let sourceID = id.rawValue

            // 0. The sources identity row FIRST (FK target for source_versions
            //    and refs).
            try db.execute(sql: """
            INSERT INTO sources
              (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, content_hash, role)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?);
            """, arguments: [sourceID, filename, ext, mime, Int64(data.count),
                            nowTS, nowTS,
                            zoteroItemKey, zoteroItemTitle, displayName,
                            contentHash, role.rawValue])

            // 1. Blob (identical bytes = one row, ever).
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [contentHash, Int64(data.count), data])

            // 2. Import/fetch activity + associated agent. When provenance is
            //    present, seed a real provider agent + activity carrying
            //    plan/external_ref; otherwise the synthetic legacy-import agent
            //    + a bare 'import' activity (byte-identical to pre-Phase-3).
            //    When activityID is provided (Phase 4 snapshot), reuse it.
            let resolvedActivityID: String
            if let activityID {
                resolvedActivityID = activityID
            } else {
                let agentID: String
                let activityKind: String
                if let prov = provenance {
                    agentID = try self.ensureAgent(
                        name: prov.agentName, kind: prov.agentKind,
                        version: prov.agentVersion, externalRef: nil, on: db)
                    activityKind = prov.activityKind
                } else {
                    agentID = try self.legacyImportAgentID(on: db)
                    activityKind = "import"
                }
                resolvedActivityID = ULID.generate()
                try db.execute(sql: """
                INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, arguments: [resolvedActivityID, activityKind, agentID,
                                provenance?.plan, provenance?.externalRef, nowTS, nowTS])
            }

            // 3. v1 version (parent_id NULL, the content blob).
            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, original_path, activity_id, external_identity, fetched_at)
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?);
            """, arguments: [versionID, sourceID, contentHash, mime,
                            originalPath, resolvedActivityID,
                            provenance?.externalIdentity, nowTS])

            // 4. Active ref (generation 1).
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?, ?, 1, ?);
            """, arguments: [sourceID, versionID, nowTS])

            // Name-only FTS index entry (the body is indexed once processed
            // markdown is appended). Best-effort; inline (pure SQL).
            self.upsertSourceSearch(sourceID: id, body: "", on: db)

            return SourceSummary(
                id: id, filename: filename, ext: ext, mimeType: mime,
                byteSize: data.count, createdAt: now, updatedAt: now, version: 1,
                zoteroItemKey: zoteroItemKey, zoteroItemTitle: zoteroItemTitle,
                displayName: displayName, role: role
            )
        }
    }


    public func addBytelessSource(
        filename: String, mimeType: String?,
        provenance: SourceProvenance, role: SourceRole
    ) throws -> SourceSummary {
        try mutate(event: { source in
            self.localEvent(.source, id: source.id.rawValue, change: .created)
        }) { db in
            // Byteless dedup: same external_identity among blob_hash IS NULL versions.
            if let extID = provenance.externalIdentity {
                if let dupRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size,
                           s.created_at, s.updated_at, s.version,
                           s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
                    FROM sources s
                    JOIN source_versions sv ON sv.source_id = s.id
                    WHERE sv.external_identity = ? AND sv.blob_hash IS NULL
                    LIMIT 1;
                    """,
                    arguments: [extID]
                ) {
                    let existing = try Self.readSourceSummary(from: dupRow)
                    throw WikiStoreError.duplicateContent(existing: existing)
                }
            }

            let id = PageID(rawValue: ULID.generate())
            let ext = (filename as NSString).pathExtension.lowercased()
            let mime = mimeType
                ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
            let now = Date()
            // Display-name resolution mirrors addSource — pass empty Data.
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
            let nowTS = now.timeIntervalSince1970
            let sourceID = id.rawValue

            // 0. The sources identity row FIRST (byte_size = 0, content_hash NULL).
            try db.execute(sql: """
            INSERT INTO sources
              (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, content_hash, role)
            VALUES (?, ?, ?, ?, 0, ?, ?, 1, NULL, NULL, ?, NULL, ?);
            """, arguments: [sourceID, filename, ext, mime, nowTS, nowTS,
                            displayName, role.rawValue])

            // 1. Fetch/import activity + real provider agent (provenance is
            //    required for byteless sources).
            let agentID = try self.ensureAgent(
                name: provenance.agentName, kind: provenance.agentKind,
                version: provenance.agentVersion, externalRef: nil, on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, arguments: [activityID, provenance.activityKind, agentID,
                            provenance.plan, provenance.externalRef, nowTS, nowTS])

            // 2. v1 content version (blob_hash NULL, external_identity set).
            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, activity_id, external_identity, fetched_at)
            VALUES (?, ?, NULL, NULL, ?, ?, ?, ?);
            """, arguments: [versionID, sourceID, mime, activityID,
                            provenance.externalIdentity, nowTS])

            // 3. Active ref (generation 1).
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?, ?, 1, ?);
            """, arguments: [sourceID, versionID, nowTS])

            // Name-only FTS entry (the transcript is indexed when
            // appendProcessedMarkdown runs). Best-effort; inline.
            self.upsertSourceSearch(sourceID: id, body: "", on: db)

            return SourceSummary(
                id: id, filename: filename, ext: ext, mimeType: mime,
                byteSize: 0, createdAt: now, updatedAt: now, version: 1,
                zoteroItemKey: nil, zoteroItemTitle: nil,
                displayName: displayName, role: role
            )
        }
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
        try dbQueue.read { db in
            let cols = """
            a.name, act.kind, act.plan, act.external_ref,
            sv.external_identity, sv.fetched_at
            """
            // 1. Prefer the active ref.
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(cols)
                FROM refs r
                JOIN source_versions sv ON sv.id = r.version_id
                LEFT JOIN activities act ON act.id = sv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE r.kind = 'source-content' AND r.owner_id = ?;
                """,
                arguments: [sourceID.rawValue]
            ) {
                return Self.originFrom(row: row)
            }
            // 2. Fall back to the default-active rule: MAX(id) version.
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(cols)
                FROM source_versions sv
                LEFT JOIN activities act ON act.id = sv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE sv.source_id = ? ORDER BY sv.id DESC LIMIT 1;
                """,
                arguments: [sourceID.rawValue]
            ) else { return nil }
            return Self.originFrom(row: row)
        }
    }

    /// Decode an origin row. NULL activity/agent columns degrade gracefully.


    public func renameSource(id: PageID, to newDisplayName: String) throws {
        let renamed: Bool = try mutate(event: { _ in
            self.localEvent(.source, id: id.rawValue, change: .updated)
        }) { db in
            // Display names must stay citable ([[source:name]]) — WikiNameRules.
            let newDisplayName = WikiNameRules.sanitized(newDisplayName)
            // Read the old name under the write lock's snapshot (cross-process TOCTOU).
            let old = try Self.getSourceSummary(id: id, on: db)
            let oldBase = old.displayName ?? old.filename
            guard oldBase != newDisplayName else { return false }
            try db.execute(sql: """
            UPDATE sources SET display_name = ?, updated_at = ?, version = version + 1 WHERE id = ?;
            """, arguments: [newDisplayName, Date().timeIntervalSince1970, id.rawValue])
            return true
        }
        // No-op rename: skip the re-embed/FTS work (mirrors the original's
        // `guard renamed else { return }`).
        guard renamed else { return }
        // Post-commit: re-embed + refresh FTS for the new title (best-effort),
        // using the current processed-markdown HEAD body so embedding reflects
        // both the new name and the content.
        let headBody = (try? processedMarkdownHead(sourceID: id)?.content) ?? ""
        reembedSource(sourceID: id, body: headBody)
        upsertSourceSearchPostCommit(sourceID: id, body: headBody)
    }

    /// Post-commit FTS upsert for `source_search` (opens its own write so it
    /// must be called AFTER `mutate` returns, never inside).
    private func upsertSourceSearchPostCommit(sourceID: PageID, body: String) {
        do {
            try dbQueue.write { db in
                self.upsertSourceSearch(sourceID: sourceID, body: body, on: db)
            }
        } catch {
            DebugLog.store("GRDBWikiStore.upsertSourceSearch[\(sourceID.rawValue)] post-commit failed: \(error)")
        }
    }

    /// Fetch one source summary by id on an open `db`. `db:`-taking so it is
    /// safe inside `mutate`. Mirrors `SQLiteWikiStore.getSource`.


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

    // MARK: - WikiStore protocol: Processed markdown versions

    public func appendContentVersion(
        sourceID: PageID, data: Data, mimeType: String?,
        provenance: SourceProvenance?
    ) throws -> SourceVersion {
        try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            guard data.count <= Self.ingestByteCap else {
                throw WikiStoreError.unexpected(
                    "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
            }
            let contentHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // Resolve the current active version (for parent_id + generation).
            let parent = try self.activeContentVersion(sourceID: sourceID, on: db)
            let prevGeneration = try self.refGeneration(sourceID: sourceID, on: db)

            // 1. Blob (identical bytes = one row, ever).
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [contentHash, Int64(data.count), data])

            // 2. Fetch/import activity + agent. Provenance-present seeds a real
            //    provider agent; otherwise the legacy-import fallback.
            let agentID: String
            let activityKind: String
            if let prov = provenance {
                agentID = try self.ensureAgent(
                    name: prov.agentName, kind: prov.agentKind,
                    version: prov.agentVersion, externalRef: nil, on: db)
                activityKind = prov.activityKind
            } else {
                agentID = try self.legacyImportAgentID(on: db)
                activityKind = "fetch"
            }
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, arguments: [activityID, activityKind, agentID,
                            provenance?.plan, provenance?.externalRef, nowTS, nowTS])

            // 3. New version (parent = current active).
            let versionID = ULID.generate()
            let resolvedMime = mimeType ?? parent?.mimeType
            try db.execute(sql: """
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, activity_id, external_identity, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, arguments: [versionID, sourceID.rawValue, parent?.id,
                            contentHash, resolvedMime, activityID,
                            provenance?.externalIdentity, nowTS])

            // 4. UPSERT the active ref (generation + 1).
            let nextGeneration = (prevGeneration ?? 0) + 1
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?, ?, ?, ?)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = excluded.generation,
                updated_at = excluded.updated_at;
            """, arguments: [sourceID.rawValue, versionID, Int64(nextGeneration), nowTS])

            // 5. Refresh the denormalized sources mirror (byte_size, content_hash,
            //    mime_type — keep addSource dedup consistent with the new blob).
            try db.execute(sql: """
            UPDATE sources SET byte_size = ?, content_hash = ?, updated_at = ?,
                                version = version + 1
            WHERE id = ?;
            """, arguments: [Int64(data.count), contentHash, nowTS,
                            sourceID.rawValue])
            if let resolvedMime {
                try db.execute(sql: "UPDATE sources SET mime_type = ? WHERE id = ?;",
                               arguments: [resolvedMime, sourceID.rawValue])
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


    public func processedMarkdownHead(sourceID: PageID) throws -> SourceMarkdownVersion? {
        try dbQueue.read { db in
            // 1. Prefer the source-derived ref.
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.smvSelectColumns)
                FROM refs r
                JOIN source_markdown_versions smv ON smv.id = r.version_id
                \(Self.smvBlobJoin)
                WHERE r.kind = 'source-derived' AND r.owner_id = ?;
                """,
                arguments: [sourceID.rawValue]
            ) {
                return Self.readMarkdownVersion(from: row)
            }
            // 2. Fall back to MAX(id).
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.smvSelectColumns)
                FROM source_markdown_versions smv
                \(Self.smvBlobJoin)
                WHERE smv.file_id = ? ORDER BY smv.id DESC LIMIT 1;
                """,
                arguments: [sourceID.rawValue]
            ) else { return nil }
            return Self.readMarkdownVersion(from: row)
        }
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
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(Self.smvSelectColumns)
                FROM source_markdown_versions smv
                \(Self.smvBlobJoin)
                WHERE smv.file_id = ? ORDER BY smv.id DESC;
                """,
                arguments: [sourceID.rawValue]
            )
            return rows.map { Self.readMarkdownVersion(from: $0) }
        }
    }


    public func processedMarkdownVersion(id: PageID) throws -> SourceMarkdownVersion? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.smvSelectColumns)
                FROM source_markdown_versions smv
                \(Self.smvBlobJoin)
                WHERE smv.id = ?;
                """,
                arguments: [id.rawValue]
            ) else { return nil }
            return Self.readMarkdownVersion(from: row)
        }
    }


    public func sourceDerivedChains() throws -> [PageID: [PageID]] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT file_id, id FROM source_markdown_versions ORDER BY file_id ASC, id ASC;
                """)
                var chains: [PageID: [PageID]] = [:]
                for row in rows {
                    let sourceID: String = row["file_id"]
                    let smvID: String = row["id"]
                    chains[PageID(rawValue: sourceID), default: []]
                        .append(PageID(rawValue: smvID))
                }
                return chains
            }
        } catch {
            DebugLog.store("GRDBWikiStore.sourceDerivedChains failed: \(error)")
            return [:]
        }
    }


    public func embedDescriptors() throws -> [PageID: SourceEmbedDescriptor] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, sv.mime_type, sv.external_identity, a.name, act.plan
                FROM sources s
                JOIN source_versions sv ON sv.source_id = s.id
                    AND sv.id = (
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
                """)
                var out: [PageID: SourceEmbedDescriptor] = [:]
                for row in rows {
                    let idStr: String = row["id"]
                    let mime: String? = row["mime_type"]
                    let externalIdentity: String? = row["external_identity"]
                    let agentName: String? = row["name"]
                    let planURL: String? = row["plan"]
                    let id = PageID(rawValue: idStr)
                    out[id] = SourceEmbedDescriptor(
                        id: id,
                        mimeType: mime,
                        externalIdentity: externalIdentity,
                        agentName: agentName,
                        planURL: planURL)
                }
                return out
            }
        } catch {
            DebugLog.store("GRDBWikiStore.embedDescriptors failed: \(error)")
            return [:]
        }
    }


    // MARK: - WikiStore protocol: Website snapshots

    public func ensureFetchActivity(provenance: SourceProvenance) throws -> String {
        try mutate(event: { _ in nil }) { db in
            let agentID = try self.ensureAgent(
                name: provenance.agentName, kind: provenance.agentKind,
                version: provenance.agentVersion, externalRef: nil, on: db)
            let activityID = ULID.generate()
            let nowTS = Date().timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, arguments: [activityID, provenance.activityKind, agentID,
                            provenance.plan, provenance.externalRef, nowTS, nowTS])
            return activityID
        }
    }


    public func addSnapshotImage(
        filename: String, data: Data, mimeType: String,
        originalPath: String, sourceURL: URL,
        activityID: String, role: SourceRole
    ) throws -> SourceSummary {
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

        return try mutate(event: { source in
            self.localEvent(.source, id: source.id.rawValue, change: .created)
        }) { db in
            guard data.count <= Self.ingestByteCap else {
                throw WikiStoreError.unexpected(
                    "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
            }
            let contentHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            let id = PageID(rawValue: ULID.generate())
            let now = Date()
            let nowTS = now.timeIntervalSince1970
            let sourceID = id.rawValue

            // 0. Fresh sources identity row (NO content_hash dedup).
            try db.execute(sql: """
            INSERT INTO sources
              (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
               zotero_item_key, zotero_item_title, display_name, content_hash, role)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, NULL, NULL, ?, ?, ?);
            """, arguments: [sourceID, filename, ext, mime, Int64(data.count),
                            nowTS, nowTS,
                            displayName, contentHash, role.rawValue])

            // 1. Blob (identical bytes = one row, ever).
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [contentHash, Int64(data.count), data])

            // 2. v1 version bound to the shared activity + original_path +
            //    external_identity = the resolved source URL.
            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                         mime_type, original_path, activity_id, external_identity, fetched_at)
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?);
            """, arguments: [versionID, sourceID, contentHash, mime,
                            originalPath, activityID,
                            sourceURL.absoluteString, nowTS])

            // 3. Active ref (generation 1).
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?, ?, 1, ?);
            """, arguments: [sourceID, versionID, nowTS])

            // Name-only FTS entry. Best-effort; inline.
            self.upsertSourceSearch(sourceID: id, body: "", on: db)

            return SourceSummary(
                id: id, filename: filename, ext: ext, mimeType: mime,
                byteSize: data.count, createdAt: now, updatedAt: now, version: 1,
                zoteroItemKey: nil, zoteroItemTitle: nil,
                displayName: displayName, role: role
            )
        }
    }


    public func hasImageSiblings(sourceID: PageID) throws -> Bool {
        try dbQueue.read { db in
            guard let active = try self.activeContentVersion(sourceID: sourceID, on: db),
                  let activityID = active.activityID else { return false }
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM source_versions
                WHERE activity_id = ? AND original_path IS NOT NULL;
                """,
                arguments: [activityID]
            ) ?? 0
            return count > 0
        }
    }


    public func siblingImageResolvers() throws -> [PageID: [String: PageID]] {
        try dbQueue.read { db in
            // Step 1: active version's activity_id per source (ref → else MAX(id)).
            let activeRows = try Row.fetchAll(db, sql: """
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
            var sourceActivity: [(PageID, String)] = []
            for row in activeRows {
                let sid = PageID(rawValue: row["id"])
                let refAct: String? = row["ref_activity"]
                let maxAct: String = row["max_activity"]
                if let refAct {
                    sourceActivity.append((sid, refAct))
                } else if !maxAct.isEmpty {
                    sourceActivity.append((sid, maxAct))
                }
            }

            // Step 2: collect all [activity_id → [(original_path, sourceID)]]
            // ordered by versionID ASC for first-wins.
            let siblingRows = try Row.fetchAll(db, sql: """
            SELECT sv.activity_id, sv.original_path, sv.source_id, sv.id
            FROM source_versions sv
            WHERE sv.original_path IS NOT NULL AND sv.activity_id IS NOT NULL
            ORDER BY sv.id ASC;
            """)
            var byActivity: [String: [(String, PageID)]] = [:]
            for row in siblingRows {
                let activity: String = row["activity_id"]
                let path: String = row["original_path"]
                let sid = PageID(rawValue: row["source_id"])
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
    }


    public func processedMarkdownAgentNames(sourceID: PageID) throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT smv.id, a.name
            FROM source_markdown_versions smv
            LEFT JOIN activities act ON act.id = smv.activity_id
            LEFT JOIN agents a ON a.id = act.agent_id
            WHERE smv.file_id = ?;
            """, arguments: [sourceID.rawValue])
            var out: [String: String] = [:]
            for row in rows {
                let smvID: String = row["id"]
                let name: String? = row["name"]
                if let name { out[smvID] = name }
            }
            return out
        }
    }


    public func processedMarkdownAlternatives(sourceID: PageID) throws -> [ExtractionAlternative] {
        try dbQueue.read { db in
            // Resolve the active HEAD id (default-active rule).
            let headID: String?
            if let vid = try String.fetchOne(
                db,
                sql: "SELECT version_id FROM refs WHERE kind = 'source-derived' AND owner_id = ?;",
                arguments: [sourceID.rawValue]
            ) {
                headID = vid
            } else {
                headID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM source_markdown_versions WHERE file_id = ? ORDER BY id DESC LIMIT 1;",
                    arguments: [sourceID.rawValue]
                )
            }

            let rows = try Row.fetchAll(db, sql: """
            SELECT \(Self.smvSelectColumns), a.name, a.version
            FROM source_markdown_versions smv
            \(Self.smvBlobJoin)
            LEFT JOIN activities act ON act.id = smv.activity_id
            LEFT JOIN agents a ON a.id = act.agent_id
            WHERE smv.file_id = ? ORDER BY smv.id DESC;
            """, arguments: [sourceID.rawValue])

            return rows.map { row in
                let version = Self.readMarkdownVersion(from: row)
                // `a.name` / `a.version` are the only columns with those names in
                // this query (smvSelectColumns has no `name`/`version` col).
                let agentName: String = (row["name"] as String?) ?? "unknown"
                let modelVersion: String? = row["version"]
                return ExtractionAlternative(
                    version: version,
                    backendDisplayName: ExtractionAlternative.backendDisplayName(agentName: agentName),
                    agentName: agentName,
                    modelVersion: modelVersion,
                    charCount: version.content.count,
                    isActive: headID.map { $0 == version.id.rawValue } ?? false
                )
            }
        }
    }


    public func appendProcessedMarkdown(
        sourceID: PageID, content: String,
        origin: SourceMarkdownOrigin, note: String?,
        technique: String?
    ) throws -> SourceMarkdownVersion {
        let version: SourceMarkdownVersion = try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            let id = PageID(rawValue: ULID.generate())
            let parentID = try self.processedMarkdownHead(sourceID: sourceID, on: db)?.id
            let now = Date()
            // CAS the body: hash → INSERT OR IGNORE blob.
            let blobHash = try self.storeMarkdownBlob(content, on: db)

            try db.execute(sql: """
            INSERT INTO source_markdown_versions
              (id, file_id, parent_id, origin, note, created_at,
               blob_hash, mime_type, technique)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'text/markdown', ?);
            """, arguments: [id.rawValue, sourceID.rawValue, parentID?.rawValue,
                            origin.rawValue, note, now.timeIntervalSince1970,
                            blobHash, technique])

            // FTS refresh inline (pure SQL) so keyword search finds the new content.
            self.upsertSourceSearch(sourceID: sourceID, body: content, on: db)

            return SourceMarkdownVersion(
                id: id, sourceID: sourceID, parentID: parentID,
                content: content, origin: origin, note: note, createdAt: now,
                blobHash: blobHash, mimeType: MimeType.markdown, technique: technique
            )
        }
        // Post-commit: re-embed from the just-written content + name.
        reembedSource(sourceID: sourceID, body: content)
        return version
    }

    /// `db:`-taking HEAD read for use inside `mutate` (cannot call the public
    /// `processedMarkdownHead` — it re-enters `dbQueue.read` and deadlocks).


    public func revertProcessedMarkdown(sourceID: PageID, to versionID: PageID) throws -> SourceMarkdownVersion {
        let result: SourceMarkdownVersion = try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            // Read the target row — must exist and belong to sourceID. Resolve
            // its body from the blob so the returned version carries real content.
            guard let targetRow = try Row.fetchOne(
                db,
                sql: """
                SELECT \(Self.smvSelectColumns)
                FROM source_markdown_versions smv
                \(Self.smvBlobJoin)
                WHERE smv.id = ? AND smv.file_id = ?;
                """,
                arguments: [versionID.rawValue, sourceID.rawValue]
            ) else {
                throw WikiStoreError.notFound(versionID)
            }
            let targetVersion = Self.readMarkdownVersion(from: targetRow)
            guard let targetBlobHash = targetVersion.blobHash else {
                // A target without a blob_hash is unmigrated/legacy — fall back to
                // the append-copy path (rare; only pre-v21 rows that escaped backfill).
                // Cannot call public appendProcessedMarkdown here (reentrant), so
                // inline the append + return; the caller's post-commit embed still runs.
                return try self.appendProcessedMarkdownInline(
                    sourceID: sourceID, content: targetVersion.content,
                    origin: .revert, note: "revert to \(versionID.rawValue)",
                    technique: nil, parentID: try self.processedMarkdownHead(sourceID: sourceID, on: db)?.id,
                    db: db)
            }

            // Append a new row reusing the target's blob_hash (INSERT OR IGNORE on
            // the existing hash is a no-op — zero new blob bytes), then repoint.
            let id = PageID(rawValue: ULID.generate())
            let parentID = try self.processedMarkdownHead(sourceID: sourceID, on: db)?.id
            let now = Date()
            let nowTS = now.timeIntervalSince1970
            let revertNote = "revert to \(versionID.rawValue)"
            try db.execute(sql: """
            INSERT INTO source_markdown_versions
              (id, file_id, parent_id, origin, note, created_at,
               activity_id, source_version_id, blob_hash, mime_type)
            VALUES (?, ?, ?, 'revert', ?, ?, ?, ?, ?, ?);
            """, arguments: [id.rawValue, sourceID.rawValue, parentID?.rawValue,
                            revertNote, nowTS,
                            targetVersion.activityID, targetVersion.sourceVersionID,
                            targetBlobHash, targetVersion.mimeType])
            try self.upsertMarkdownDerivedRef(sourceID: sourceID, versionID: id.rawValue, now: nowTS, on: db)

            // FTS refresh inline (pure SQL).
            self.upsertSourceSearch(sourceID: sourceID, body: targetVersion.content, on: db)

            return SourceMarkdownVersion(
                id: id, sourceID: sourceID, parentID: parentID,
                content: targetVersion.content, origin: .revert,
                note: revertNote, createdAt: now,
                activityID: targetVersion.activityID,
                sourceVersionID: targetVersion.sourceVersionID,
                blobHash: targetBlobHash, mimeType: targetVersion.mimeType
            )
        }
        // Post-commit: refresh embed + FTS for the now-active body.
        reembedSource(sourceID: sourceID, body: result.content)
        return result
    }

    /// Inline append for the revert fallback (target had no blob_hash). `db:`-
    /// taking; emits FTS inline. The caller's post-commit re-embed runs on
    /// `result.content`.


    public func recordMarkdownExtraction(
        sourceID: PageID, content: String, backend: ExtractionBackend,
        sourceVersionID: String?, note: String?, modelVersion: String?
    ) throws -> SourceMarkdownVersion {
        let (version, reembed): (SourceMarkdownVersion, Bool) = try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            let id = PageID(rawValue: ULID.generate())
            let parentID = try self.processedMarkdownHead(sourceID: sourceID, on: db)?.id
            let now = Date()
            let nowTS = now.timeIntervalSince1970
            // Resolve the source's active content version when the caller didn't
            // supply one.
            let resolvedSourceVersionID = sourceVersionID
                ?? (try? self.activeContentVersion(sourceID: sourceID, on: db))?.id

            // Agent (idempotent by name) + a single extract activity.
            let agentID = try self.ensureAgent(
                name: backend.agentName, version: modelVersion, on: db)
            let activityID = ULID.generate()
            let plan = "{\"backend\":\"\(backend.rawValue)\""
                + (modelVersion.map { ",\"model\":\"\($0)\"" } ?? "")
                + "}"
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, plan, started_at, ended_at)
            VALUES (?, 'extract', ?, ?, ?, ?);
            """, arguments: [activityID, agentID, plan, nowTS, nowTS])

            // CAS the body, then append the smv row.
            let blobHash = try self.storeMarkdownBlob(content, on: db)
            try db.execute(sql: """
            INSERT INTO source_markdown_versions
              (id, file_id, parent_id, origin, note, created_at,
               activity_id, source_version_id, blob_hash, mime_type, technique)
            VALUES (?, ?, ?, 'extraction', ?, ?, ?, ?, ?, 'text/markdown', ?);
            """, arguments: [id.rawValue, sourceID.rawValue, parentID?.rawValue,
                            note, nowTS, activityID, resolvedSourceVersionID,
                            blobHash, backend.rawValue])

            // Re-embed/index only when this row is now the active head (default-
            // active rule: it is MAX(id); if a ref nominates a different row, this
            // is just a coexisting alternative and must not disturb the active index).
            let refExists = (try? self.markdownDerivedRef(sourceID: sourceID, on: db)) != nil
            if !refExists {
                self.upsertSourceSearch(sourceID: sourceID, body: content, on: db)
            }

            let version = SourceMarkdownVersion(
                id: id, sourceID: sourceID, parentID: parentID,
                content: content, origin: .extraction, note: note, createdAt: now,
                activityID: activityID, sourceVersionID: resolvedSourceVersionID,
                blobHash: blobHash, mimeType: MimeType.markdown,
                technique: backend.rawValue
            )
            return (version, !refExists)
        }
        // Post-commit: re-embed only when this row became the active head.
        if reembed {
            reembedSource(sourceID: sourceID, body: version.content)
        }
        return version
    }


    public func setActiveMarkdown(sourceID: PageID, to versionID: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            // Validate the target belongs to this source.
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM source_markdown_versions WHERE id = ? AND file_id = ?;",
                arguments: [versionID.rawValue, sourceID.rawValue]
            ) ?? 0
            guard exists == 1 else {
                throw WikiStoreError.notFound(versionID)
            }
            try self.upsertMarkdownDerivedRef(
                sourceID: sourceID, versionID: versionID.rawValue,
                now: Date().timeIntervalSince1970, on: db)
        }
        // Post-commit: refresh the search indexes for the newly-active body.
        if let head = try? processedMarkdownHead(sourceID: sourceID) {
            reembedSource(sourceID: sourceID, body: head.content)
            upsertSourceSearchPostCommit(sourceID: sourceID, body: head.content)
        }
    }


    // MARK: - WikiStore protocol: Page versions + workspaces

    public func appendPageVersion(
        pageID: PageID, title: String, body: String,
        expectedHeadVersionID: String?,
        lastEditedBy: String?
    ) throws -> String {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            let title = WikiNameRules.sanitized(title)
            let slug = try self.uniqueSlug(from: title, id: pageID, on: db)
            let bodyData = Data(body.utf8)
            let hash = SHA256.hash(data: bodyData)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // 1. CAS check: resolve current head (ref → version_id, or MAX(id)).
            let head = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)
            if let expected = expectedHeadVersionID, expected != head {
                throw PageConflictError(
                    pageID: pageID, expectedVersionID: expected, actualVersionID: head)
            }

            // 1b. Amend check (autosave coalescing). Same-actor saves within a
            //     short coalescing window amend the head version in place.
            if let amendVersionID = try self.tryAmendPageVersion(
                db: db, pageID: pageID, head: head, title: title, slug: slug,
                body: body, bodyData: bodyData, hash: hash,
                lastEditedBy: lastEditedBy, now: now, nowTS: nowTS)
            {
                return amendVersionID
            }

            // 2. Blob (identical body = one row, ever).
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(bodyData.count), bodyData])

            // 3. Legacy-import agent + activity.
            let agentID = try self.legacyImportAgentID(on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'edit', ?, ?, ?);
            """, arguments: [activityID, agentID, nowTS, nowTS])

            // 4. New version (parent = current head).
            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?);
            """, arguments: [versionID, pageID.rawValue, head, hash, title, activityID, nowTS])

            // 5. Update the denormalized pages mirror.
            try db.execute(sql: """
            UPDATE pages
            SET title = ?, slug = ?, body_markdown = ?,
                updated_at = ?, version = version + 1, last_edited_by = ?
            WHERE id = ?;
            """, arguments: [title, slug, body, nowTS, lastEditedBy, pageID.rawValue])
            guard db.changesCount > 0 else { throw WikiStoreError.notFound(pageID) }

            // 6. Write the page-content ref.
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?, ?, 1, ?)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = generation + 1,
                updated_at = excluded.updated_at;
            """, arguments: [pageID.rawValue, versionID, nowTS])

            return versionID
        }
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
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at
            FROM page_versions
            WHERE page_id = ?
            ORDER BY id ASC;
            """, arguments: [pageID.rawValue])
            return rows.map { row in
                PageVersionSummary(
                    id: row["id"],
                    pageID: PageID(rawValue: row["page_id"]),
                    parentID: row["parent_id"],
                    mergeParentID: row["merge_parent_id"],
                    blobHash: row["blob_hash"],
                    title: row["title"],
                    activityID: row["activity_id"],
                    savedAt: Date(timeIntervalSince1970: row["saved_at"])
                )
            }
        }
    }


    public func revertPage(pageID: PageID, to versionID: String) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            // Fetch the target version's blob + title.
            guard let row = try Row.fetchOne(db, sql: """
            SELECT pv.blob_hash, pv.title, b.content
            FROM page_versions pv
            JOIN blobs b ON b.hash = pv.blob_hash
            WHERE pv.id = ? AND pv.page_id = ?;
            """, arguments: [versionID, pageID.rawValue]) else {
                throw WikiStoreError.unexpected("version \(versionID) not found for page \(pageID.rawValue)")
            }
            let title: String = row["title"]
            let bodyData: Data = row["content"]
            let body = String(data: bodyData, encoding: .utf8) ?? ""

            // Update the denormalized pages mirror.
            let sanitizedTitle = WikiNameRules.sanitized(title)
            let slug = try self.uniqueSlug(from: sanitizedTitle, id: pageID, on: db)
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            UPDATE pages
            SET title = ?, slug = ?, body_markdown = ?,
                updated_at = ?, version = version + 1
            WHERE id = ?;
            """, arguments: [sanitizedTitle, slug, body, now, pageID.rawValue])
            guard db.changesCount > 0 else { throw WikiStoreError.notFound(pageID) }

            // Repoint the page-content ref to the target version.
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?, ?, 1, ?)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = generation + 1,
                updated_at = excluded.updated_at;
            """, arguments: [pageID.rawValue, versionID, now])
        }
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
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
            SELECT id, name, status, activity_id, created_at, updated_at
            FROM workspaces WHERE id = ?;
            """, arguments: [id]) else { return nil }
            let name: String? = row["name"]
            let statusRaw: String = row["status"]
            let activityID: String? = row["activity_id"]
            return WorkspaceSummary(
                id: row["id"],
                name: name,
                status: WorkspaceStatus(rawValue: statusRaw) ?? .open,
                activityID: activityID,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }


    public func workspaceRefs(workspaceID: String) throws -> [WorkspaceRef] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT workspace_id, owner_id, base_version_id, version_id, blob_hash, title, updated_at
            FROM workspace_refs WHERE workspace_id = ?;
            """, arguments: [workspaceID])
            return rows.map { row in
                WorkspaceRef(
                    workspaceID: row["workspace_id"],
                    ownerID: PageID(rawValue: row["owner_id"]),
                    baseVersionID: row["base_version_id"],
                    versionID: row["version_id"],
                    blobHash: row["blob_hash"],
                    title: row["title"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
        }
    }


    public func workspaceWritePage(
        workspaceID: String, pageID: PageID, title: String, body: String
    ) throws -> String {
        try mutate(event: { _ in nil }) { db in
            let title = WikiNameRules.sanitized(title)
            let bodyData = Data(body.utf8)
            let hash = SHA256.hash(data: bodyData)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // Guard: workspace must be 'open'.
            guard let statusRaw = try String.fetchOne(
                db, sql: "SELECT status FROM workspaces WHERE id = ?;",
                arguments: [workspaceID]
            ), WorkspaceStatus(rawValue: statusRaw) == .open else {
                throw WikiStoreError.unexpected("workspace \(workspaceID) is not open")
            }

            // 0. Determine whether the page exists on main.
            let existsOnMain = try Int.fetchOne(
                db, sql: "SELECT 1 FROM pages WHERE id = ?;",
                arguments: [pageID.rawValue]
            ) != nil

            if !existsOnMain {
                // Created page: stage entirely in workspace_refs.
                try db.execute(sql: """
                INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
                """, arguments: [hash, Int64(bodyData.count), bodyData])

                // UPSERT workspace_refs: blob_hash + title set, version_id NULL.
                try db.execute(sql: """
                INSERT INTO workspace_refs (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
                VALUES (?, 'page-content', ?, NULL, NULL, ?, ?, ?)
                ON CONFLICT(workspace_id, kind, owner_id) DO UPDATE SET
                    version_id = NULL,
                    blob_hash = excluded.blob_hash,
                    title = excluded.title,
                    updated_at = excluded.updated_at;
                """, arguments: [workspaceID, pageID.rawValue, hash, title, nowTS])

                try db.execute(sql: """
                UPDATE workspaces SET updated_at = ? WHERE id = ?;
                """, arguments: [nowTS, workspaceID])

                return hash
            }

            // Existing page: append page_versions row + UPSERT workspace_refs.
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(bodyData.count), bodyData])

            let agentID = try self.legacyImportAgentID(on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'edit', ?, ?, ?);
            """, arguments: [activityID, agentID, nowTS, nowTS])

            let wsHead = try Self.workspacePageVersionLocked(
                workspaceID: workspaceID, pageID: pageID, on: db)
            let mainHead = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)

            let versionID = ULID.generate()
            let parent = wsHead ?? mainHead
            try db.execute(sql: """
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?);
            """, arguments: [versionID, pageID.rawValue, parent, hash, title, activityID, nowTS])

            // UPSERT workspace_refs. On first touch, record base_version_id = main head.
            // On subsequent touches, keep the original base (NULL = no-op in ON CONFLICT).
            let hasWsRef = wsHead != nil
            let baseToRecord: String? = hasWsRef ? nil : mainHead

            try db.execute(sql: """
            INSERT INTO workspace_refs (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
            VALUES (?, 'page-content', ?, ?, ?, NULL, NULL, ?)
            ON CONFLICT(workspace_id, kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                blob_hash = NULL,
                title = NULL,
                updated_at = excluded.updated_at;
            """, arguments: [workspaceID, pageID.rawValue, baseToRecord, versionID, nowTS])

            try db.execute(sql: """
            UPDATE workspaces SET updated_at = ? WHERE id = ?;
            """, arguments: [nowTS, workspaceID])

            return versionID
        }
    }


    public func workspacePageVersion(workspaceID: String, pageID: PageID) throws -> String? {
        try dbQueue.read { db in
            try Self.workspacePageVersionLocked(workspaceID: workspaceID, pageID: pageID, on: db)
        }
    }


    public func workspacePageBody(workspaceID: String, pageID: PageID) throws -> String? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
            SELECT version_id, blob_hash FROM workspace_refs
            WHERE workspace_id = ? AND kind = 'page-content' AND owner_id = ?;
            """, arguments: [workspaceID, pageID.rawValue]) else { return nil }

            let versionID: String? = row["version_id"]
            let blobHash: String? = row["blob_hash"]

            if let versionID {
                // Existing page: read the version's blob.
                if let blobRow = try Row.fetchOne(db, sql: """
                SELECT pv.blob_hash, b.content FROM page_versions pv
                JOIN blobs b ON b.hash = pv.blob_hash WHERE pv.id = ?;
                """, arguments: [versionID]) {
                    let data: Data = blobRow["content"]
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }

            guard let blobHash else { return nil }
            // Created page: read the staged blob directly.
            if let blobRow = try Row.fetchOne(db, sql: """
            SELECT content FROM blobs WHERE hash = ?;
            """, arguments: [blobHash]) {
                let data: Data = blobRow["content"]
                return String(data: data, encoding: .utf8)
            }
            return nil
        }
    }


    public func setWorkspaceIndexBody(
        workspaceID: String, indexBody: String, indexBaseVersion: String
    ) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: """
            UPDATE workspaces SET index_body = ?, index_base_version = ?, updated_at = ?
            WHERE id = ?;
            """, arguments: [indexBody, indexBaseVersion,
                             Date().timeIntervalSince1970, workspaceID])
        }
    }


    public func workspaceMerge(workspaceID: String) throws -> [String] {
        var conflicts: [(pageID: String, base: String?, wsVersion: String, mainVersion: String?)] = []
        var mergedPageIDs: [String] = []
        do {
            try mutate(event: { _ in nil }) { db in
                // 1. Mark workspace as 'merging'.
                try db.execute(sql: """
                UPDATE workspaces SET status = 'merging', updated_at = ?
                WHERE id = ? AND status = 'open';
                """, arguments: [Date().timeIntervalSince1970, workspaceID])
                guard db.changesCount > 0 else {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) is not open (already merging/merged/conflicted/abandoned)")
                }

                // 2. For each workspace_ref, attempt fast-forward or mint.
                let refs = try Row.fetchAll(db, sql: """
                SELECT owner_id, base_version_id, version_id, blob_hash, title
                FROM workspace_refs WHERE workspace_id = ?;
                """, arguments: [workspaceID])

                for ref in refs {
                    let pageIDStr: String = ref["owner_id"]
                    let base: String? = ref["base_version_id"]
                    let wsVersion: String? = ref["version_id"]
                    let blobHash: String? = ref["blob_hash"]
                    let title: String = ref["title"]
                    let pageID = PageID(rawValue: pageIDStr)

                    // Resolve main head.
                    let mainHead = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)

                    if wsVersion == nil {
                        // Created page (v35 staging): mint the pages row + root version + ref.
                        guard let stagedHash = blobHash else {
                            throw WikiStoreError.unexpected("workspaceMerge: created page \(pageIDStr) has nil blob_hash")
                        }
                        // Conflict: a page-content ref already exists on main.
                        let mainRefExists = try Int.fetchOne(
                            db, sql: "SELECT 1 FROM refs WHERE kind = 'page-content' AND owner_id = ?;",
                            arguments: [pageIDStr]) != nil
                        if mainRefExists {
                            conflicts.append((pageIDStr, nil, stagedHash, mainHead))
                            continue
                        }
                        try self.mintCreatedPage(db: db, pageID: pageID, blobHash: stagedHash, title: title)
                        mergedPageIDs.append(pageIDStr)
                    } else if base == nil {
                        // Old-style created page (pre-v35: version_id set, base nil).
                        let mainRefExists = try Int.fetchOne(
                            db, sql: "SELECT 1 FROM refs WHERE kind = 'page-content' AND owner_id = ?;",
                            arguments: [pageIDStr]) != nil
                        if mainRefExists {
                            conflicts.append((pageIDStr, base, wsVersion!, mainHead))
                            continue
                        }
                        try self.fastForwardPage(db: db, pageID: pageID, versionID: wsVersion!)
                        mergedPageIDs.append(pageIDStr)
                    } else if mainHead == base {
                        try self.fastForwardPage(db: db, pageID: pageID, versionID: wsVersion!)
                        mergedPageIDs.append(pageIDStr)
                    } else {
                        // Divergence — attempt diff3 merge (W2).
                        let mergeResult = try self.diff3MergePage(
                            db: db, pageID: pageID, baseVersionID: base!,
                            mainVersionID: mainHead!, wsVersionID: wsVersion!)
                        switch mergeResult {
                        case .merged:
                            mergedPageIDs.append(pageIDStr)
                        case .conflict:
                            conflicts.append((pageIDStr, base, wsVersion!, mainHead))
                        }
                    }
                }

                // 2b. Wiki-index line-set three-way merge (Phase 6).
                if let idxRow = try Row.fetchOne(db, sql: """
                SELECT index_body, index_base_version FROM workspaces WHERE id = ?;
                """, arguments: [workspaceID]) {
                    if let theirs: String = idxRow["index_body"] {
                        let baseIdx: String = idxRow["index_base_version"] ?? ""
                        let ours: String
                        if let mainIdxRow = try Row.fetchOne(db, sql: """
                        SELECT COALESCE(body_markdown, '') AS body_markdown FROM wiki_index WHERE id = 1;
                        """) {
                            ours = mainIdxRow["body_markdown"]
                        } else {
                            ours = WikiIndex.defaultBody
                        }
                        switch Diff3.merge(base: baseIdx, ours: ours, theirs: theirs) {
                        case .clean(let mergedText):
                            try db.execute(sql: """
                            INSERT INTO wiki_index (id, body_markdown, updated_at, version)
                            VALUES (1, ?, ?, 1)
                            ON CONFLICT(id) DO UPDATE SET
                                body_markdown = excluded.body_markdown,
                                updated_at = excluded.updated_at,
                                version = wiki_index.version + 1;
                            """, arguments: [mergedText, Date().timeIntervalSince1970])
                        case .conflict:
                            conflicts.append(("wiki_index", baseIdx, theirs, ours))
                        }
                    }
                }

                // 3. If any conflicts, abort the transaction.
                if !conflicts.isEmpty {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) merge: \(conflicts.count) conflict(s)")
                }

                // 4. All fast-forwarded → mark 'merged'.
                try db.execute(sql: """
                UPDATE workspaces SET status = 'merged', updated_at = ? WHERE id = ?;
                """, arguments: [Date().timeIntervalSince1970, workspaceID])
            }
        } catch {
            // Only park if there were actual conflicts (not a different error).
            if !conflicts.isEmpty {
                let descriptions = conflicts.map { c in
                    "\(c.pageID): base=\(c.base ?? "nil") ws=\(c.wsVersion) main=\(c.mainVersion ?? "nil")"
                }.joined(separator: "; ")
                DebugLog.store("workspaceMerge: \(conflicts.count) conflict(s) — \(descriptions)")
                // Park in a separate transaction.
                try mutate(event: { _ in nil }) { db in
                    let nowTS = Date().timeIntervalSince1970
                    try db.execute(sql: """
                    UPDATE workspaces SET status = 'conflicted', updated_at = ? WHERE id = ?;
                    """, arguments: [nowTS, workspaceID])

                    try db.execute(sql: """
                    DELETE FROM workspace_conflicts WHERE workspace_id = ?;
                    """, arguments: [workspaceID])

                    for c in conflicts {
                        try db.execute(sql: """
                        INSERT INTO workspace_conflicts (workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """, arguments: [workspaceID, c.pageID, c.base, c.mainVersion, c.wsVersion, nowTS])
                    }
                }
                return []
            }
            throw error
        }

        // Post-merge: re-embed merged pages + append log entry (best-effort).
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
            _ = try? appendLog(kind: .ingest, title: "Workspace merge completed", note: note)
        }

        return mergedPageIDs
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
        var conflicts: [(pageID: String, base: String?, wsVersion: String, mainVersion: String?)] = []
        do {
            try mutate(event: { _ in nil }) { db in
                // Guard: must be open.
                guard let statusRaw = try String.fetchOne(
                    db, sql: "SELECT status FROM workspaces WHERE id = ?;",
                    arguments: [workspaceID]
                ), WorkspaceStatus(rawValue: statusRaw) == .open else {
                    throw WikiStoreError.unexpected("workspace \(workspaceID) is not open")
                }

                let refs = try Row.fetchAll(db, sql: """
                SELECT owner_id, base_version_id, version_id
                FROM workspace_refs WHERE workspace_id = ?;
                """, arguments: [workspaceID])

                for ref in refs {
                    let pageIDStr: String = ref["owner_id"]
                    let base: String? = ref["base_version_id"]
                    let wsVersion: String? = ref["version_id"]
                    let pageID = PageID(rawValue: pageIDStr)

                    let mainHead = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)

                    // Created pages (version_id NULL) have no version to diff3;
                    // pages where base is already current have no divergence.
                    if wsVersion == nil || base == nil || mainHead == base {
                        continue
                    }

                    // Attempt diff3: base vs main (ours) vs workspace (theirs).
                    let baseText = try self.fetchVersionBody(db: db, versionID: base!)
                    let oursText = try self.fetchVersionBody(db: db, versionID: mainHead!)
                    let theirText = try self.fetchVersionBody(db: db, versionID: wsVersion!)

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

                    try db.execute(sql: """
                    INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
                    """, arguments: [hash, Int64(mergedData.count), mergedData])

                    let agentID = try self.legacyImportAgentID(on: db)
                    let activityID = ULID.generate()
                    try db.execute(sql: """
                    INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                    VALUES (?, 'refresh', ?, ?, ?);
                    """, arguments: [activityID, agentID, nowTS, nowTS])

                    // Fetch the title from the workspace version.
                    guard let title: String = try String.fetchOne(
                        db, sql: "SELECT title FROM page_versions WHERE id = ?;",
                        arguments: [wsVersion!]
                    ) else { continue }

                    let newVersionID = ULID.generate()
                    try db.execute(sql: """
                    INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """, arguments: [newVersionID, pageID.rawValue, mainHead, wsVersion!,
                                     hash, title, activityID, nowTS])

                    // Update the workspace_ref: new version + new base.
                    try db.execute(sql: """
                    UPDATE workspace_refs
                    SET base_version_id = ?, version_id = ?, updated_at = ?
                    WHERE workspace_id = ? AND kind = 'page-content' AND owner_id = ?;
                    """, arguments: [mainHead, newVersionID, nowTS, workspaceID, pageIDStr])
                }

                if !conflicts.isEmpty {
                    throw WikiStoreError.unexpected("refresh: \(conflicts.count) conflict(s)")
                }
            }
        } catch {
            if !conflicts.isEmpty {
                try mutate(event: { _ in nil }) { db in
                    let nowTS = Date().timeIntervalSince1970
                    try db.execute(sql: """
                    UPDATE workspaces SET status = 'conflicted', updated_at = ? WHERE id = ?;
                    """, arguments: [nowTS, workspaceID])

                    try db.execute(sql: """
                    DELETE FROM workspace_conflicts WHERE workspace_id = ?;
                    """, arguments: [workspaceID])

                    for c in conflicts {
                        try db.execute(sql: """
                        INSERT INTO workspace_conflicts (workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?);
                        """, arguments: [workspaceID, c.pageID, c.base, c.mainVersion, c.wsVersion, nowTS])
                    }
                }
                return
            }
            throw error
        }
    }


    public func workspaceConflicts(workspaceID: String) throws -> [WorkspaceConflict] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT workspace_id, page_id, base_version_id, main_version_id, ws_version_id, created_at
            FROM workspace_conflicts WHERE workspace_id = ?;
            """, arguments: [workspaceID])
            return rows.map { row in
                WorkspaceConflict(
                    workspaceID: row["workspace_id"],
                    pageID: PageID(rawValue: row["page_id"]),
                    baseVersionID: row["base_version_id"],
                    mainVersionID: row["main_version_id"],
                    wsVersionID: row["ws_version_id"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }


    public func workspaceResolveConflict(
        workspaceID: String, pageID: PageID, body: String
    ) throws {
        try mutate(event: { _ in nil }) { db in
            let bodyData = Data(body.utf8)
            let hash = SHA256.hash(data: bodyData)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // 1. Blob.
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(bodyData.count), bodyData])

            // 2. Activity.
            let agentID = try self.legacyImportAgentID(on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'resolve', ?, ?, ?);
            """, arguments: [activityID, agentID, nowTS, nowTS])

            // 3. New workspace version (parent = workspace's current head).
            let wsHead = try Self.workspacePageVersionLocked(
                workspaceID: workspaceID, pageID: pageID, on: db)
            let title: String
            if let wsHead {
                title = try String.fetchOne(
                    db, sql: "SELECT title FROM page_versions WHERE id = ?;",
                    arguments: [wsHead]) ?? ""
            } else {
                // Created-page staging: title lives in workspace_refs.title.
                title = try String.fetchOne(
                    db, sql: """
                    SELECT title FROM workspace_refs
                    WHERE workspace_id = ? AND kind = 'page-content' AND owner_id = ?;
                    """, arguments: [workspaceID, pageID.rawValue]) ?? ""
            }

            // 3a. For created-page conflicts, the page may not exist on main yet.
            let pageExists = try Int.fetchOne(
                db, sql: "SELECT 1 FROM pages WHERE id = ?;",
                arguments: [pageID.rawValue]) != nil
            if !pageExists {
                let slug = try self.uniqueSlug(from: title, id: pageID, on: db)
                try db.execute(sql: """
                INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
                VALUES (?, ?, ?, '', ?, ?, 1);
                """, arguments: [pageID.rawValue, title, slug, nowTS, nowTS])
            }

            let versionID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?);
            """, arguments: [versionID, pageID.rawValue, wsHead, hash, title, activityID, nowTS])

            // 4. Update workspace_ref to point at the resolved version.
            let mainHead = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)
            try db.execute(sql: """
            UPDATE workspace_refs
            SET version_id = ?, base_version_id = ?, blob_hash = NULL, title = NULL, updated_at = ?
            WHERE workspace_id = ? AND kind = 'page-content' AND owner_id = ?;
            """, arguments: [versionID, mainHead, nowTS, workspaceID, pageID.rawValue])

            // 5. Delete the conflict row for this page.
            try db.execute(sql: """
            DELETE FROM workspace_conflicts WHERE workspace_id = ? AND page_id = ?;
            """, arguments: [workspaceID, pageID.rawValue])
        }
    }


    public func workspaceRetryMerge(workspaceID: String) throws {
        try mutate(event: { _ in nil }) { db in
            try db.execute(sql: """
            UPDATE workspaces SET status = 'open', updated_at = ?
            WHERE id = ? AND status = 'conflicted';
            """, arguments: [Date().timeIntervalSince1970, workspaceID])
            guard db.changesCount > 0 else {
                throw WikiStoreError.unexpected("workspace \(workspaceID) is not conflicted")
            }
        }
        // Now attempt the merge again.
        _ = try workspaceMerge(workspaceID: workspaceID)
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

    // MARK: - WikiStore protocol: Semantic search

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
        try dbQueue.read { db in
            let pool = max(limit * 2, limit)
            // --- FTS (lexical) pass ---
            let q = Self.ftsMatch(query)
            var ftsRows: [WikiPageSummary] = []
            if !q.isEmpty {
                ftsRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT p.id, p.title, p.updated_at, p.created_at
                    FROM pages_fts
                    JOIN pages p ON p.rowid = pages_fts.rowid
                    WHERE pages_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?;
                    """,
                    arguments: [q, pool]
                ).map { row in
                    WikiPageSummary(
                        id: PageID(rawValue: row["id"]),
                        title: row["title"],
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
            }

            // --- Semantic (vec cosine) pass + RRF ---
            if Self.isVecAvailable(db),
               let queryBlob = EmbeddingService.embeddingBlob(for: query) {
                DebugLog.store("search[pages]: query=\(query) hybrid (semantic+FTS) → RRF, vec=true")
                let semRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT p.id, p.title, p.updated_at, p.created_at
                    FROM (
                        SELECT page_id, MIN(vec_distance_cosine(embedding, ?)) AS best
                        FROM page_chunks GROUP BY page_id
                    ) r
                    JOIN pages p ON p.id = r.page_id
                    ORDER BY r.best ASC
                    LIMIT ?;
                    """,
                    arguments: [queryBlob, pool]
                ).map { row in
                    WikiPageSummary(
                        id: PageID(rawValue: row["id"]),
                        title: row["title"],
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[pages]: query=\(query) FTS-only, vec=false")
            return Array(ftsRows.prefix(limit))
        }
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
        try dbQueue.read { db in
            let pool = max(limit * 2, limit)
            // --- FTS (lexical) pass ---
            let q = Self.ftsMatch(query)
            var ftsRows: [SourceSummary] = []
            if !q.isEmpty {
                ftsRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
                           s.version, s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
                    FROM sources_fts
                    JOIN source_search ss ON ss.rowid = sources_fts.rowid
                    JOIN sources s ON s.id = ss.source_id
                    WHERE sources_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?;
                    """,
                    arguments: [q, pool]
                ).map { row in
                    try Self.readSourceSummary(from: row)
                }
            }

            // --- Semantic (vec cosine) pass + RRF ---
            if Self.isVecAvailable(db),
               let queryBlob = EmbeddingService.embeddingBlob(for: query) {
                DebugLog.store("search[sources]: query=\(query) hybrid (semantic+FTS) → RRF, vec=true")
                let semRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
                           s.version, s.zotero_item_key, s.zotero_item_title, s.display_name, s.role
                    FROM (
                        SELECT source_id, MIN(vec_distance_cosine(embedding, ?)) AS best
                        FROM source_chunks GROUP BY source_id
                    ) r
                    JOIN sources s ON s.id = r.source_id
                    ORDER BY r.best ASC
                    LIMIT ?;
                    """,
                    arguments: [queryBlob, pool]
                ).map { row in
                    try Self.readSourceSummary(from: row)
                }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[sources]: query=\(query) FTS-only, vec=false")
            return Array(ftsRows.prefix(limit))
        }
    }


    // MARK: - WikiStore protocol: Bookmark nodes

    public func listBookmarkNodes() throws -> [BookmarkNode] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, parent_id, position, kind, label, target_id, created_at, updated_at
            FROM bookmark_nodes
            ORDER BY parent_id IS NULL DESC, parent_id, position;
            """)
            return rows.map { row in
                BookmarkNode(
                    id: row["id"],
                    parentID: row["parent_id"],
                    position: row["position"],
                    kind: BookmarkNodeKind(rawValue: row["kind"]) ?? .folder,
                    label: row["label"],
                    targetID: (row["target_id"] as String?).map { PageID(rawValue: $0) },
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }


    public func createBookmarkNode(
        parentID: String?, position: Int,
        kind: BookmarkNodeKind, label: String?,
        targetID: PageID?
    ) throws -> BookmarkNode {
        try mutate(event: { node in
            self.localEvent(.bookmark, id: node.id, change: .created)
        }) { db in
            let id = ULID.generate()
            let now = Date().timeIntervalSince1970

            // Shift siblings at >= position up by 1 within the same parent.
            // `IS` matches NULL=NULL (unlike `=`), correctly grouping root siblings.
            try db.execute(sql: """
            UPDATE bookmark_nodes SET position = position + 1
            WHERE parent_id IS ? AND position >= ?;
            """, arguments: [parentID as String?, position])

            try db.execute(sql: """
            INSERT INTO bookmark_nodes (id, parent_id, position, kind, label, target_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, arguments: [
                id, parentID as String?, position, kind.rawValue,
                label as String?, targetID?.rawValue as String?, now, now
            ])

            // Defense-in-depth: renumber siblings so positions stay contiguous.
            let parentColumn: String
            let parentArg: String?
            if let parentID {
                parentColumn = "parent_id = ?"
                parentArg = parentID
            } else {
                parentColumn = "parent_id IS NULL"
                parentArg = nil
            }
            let sibRows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM bookmark_nodes WHERE \(parentColumn) ORDER BY position ASC;",
                arguments: parentArg.map { [$0] } ?? []
            )
            for (i, row) in sibRows.enumerated() {
                let childID: String = row["id"]
                try db.execute(
                    sql: "UPDATE bookmark_nodes SET position = ? WHERE id = ?;",
                    arguments: [i, childID]
                )
            }

            let stamp = Date(timeIntervalSince1970: now)
            return BookmarkNode(
                id: id, parentID: parentID, position: position, kind: kind,
                label: label, targetID: targetID, createdAt: stamp, updatedAt: stamp
            )
        }
    }


    public func updateBookmarkNode(id: String, label: String?) throws {
        try mutate(event: { _ in
            self.localEvent(.bookmark, id: id, change: .updated)
        }) { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            UPDATE bookmark_nodes SET label = ?, updated_at = ? WHERE id = ?;
            """, arguments: [label as String?, now, id])
        }
    }


    public func deleteBookmarkNode(id: String) throws {
        try mutate(event: { _ in
            self.localEvent(.bookmark, id: id, change: .deleted)
        }) { db in
            // Capture the parent for sibling renumbering after the delete.
            let oldParent: String? = try String.fetchOne(
                db,
                sql: "SELECT parent_id FROM bookmark_nodes WHERE id = ?;",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM bookmark_nodes WHERE id = ?;",
                arguments: [id]
            )
            // Renumber old siblings to be contiguous.
            let parentColumn: String
            let parentArg: String?
            if let oldParent {
                parentColumn = "parent_id = ?"
                parentArg = oldParent
            } else {
                parentColumn = "parent_id IS NULL"
                parentArg = nil
            }
            let sibRows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM bookmark_nodes WHERE \(parentColumn) ORDER BY position ASC;",
                arguments: parentArg.map { [$0] } ?? []
            )
            for (i, row) in sibRows.enumerated() {
                let childID: String = row["id"]
                try db.execute(
                    sql: "UPDATE bookmark_nodes SET position = ? WHERE id = ?;",
                    arguments: [i, childID]
                )
            }
        }
    }


    public func moveBookmarkNode(id: String, toParentID: String?, position: Int) throws {
        try mutate(event: { _ in
            self.localEvent(.bookmark, id: id, change: .updated)
        }) { db in
            // Read the node's current parent.
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_id, position FROM bookmark_nodes WHERE id = ?;",
                arguments: [id]
            ) else {
                throw WikiStoreError.unexpected("moveBookmarkNode: node \(id) not found")
            }
            let oldParent: String? = row["parent_id"]

            // Cycle prevention: reject moving a node into itself or any of its
            // descendants. Walk up the parent chain from toParentID — if we
            // encounter `id`, it's a descendant (or the node itself).
            if let toParentID {
                var ancestor: String? = toParentID
                while let current = ancestor {
                    if current == id {
                        throw WikiStoreError.unexpected(
                            "moveBookmarkNode: cannot move \(id) into its own descendant \(toParentID)"
                        )
                    }
                    ancestor = try String.fetchOne(
                        db,
                        sql: "SELECT parent_id FROM bookmark_nodes WHERE id = ?;",
                        arguments: [current]
                    )
                }
            }

            let sameParent: Bool
            if let oldParent, let toParentID {
                sameParent = oldParent == toParentID
            } else {
                sameParent = oldParent == nil && toParentID == nil
            }

            // Step 1: Shift siblings at >= position up by 1 in the NEW parent
            // (excluding the moving node itself, to avoid ambiguous ties).
            try db.execute(sql: """
            UPDATE bookmark_nodes SET position = position + 1
            WHERE parent_id IS ? AND position >= ? AND id != ?;
            """, arguments: [toParentID as String?, position, id])

            // Step 2: Update the node's parent + position.
            try db.execute(sql: """
            UPDATE bookmark_nodes SET parent_id = ?, position = ? WHERE id = ?;
            """, arguments: [toParentID as String?, position, id])

            // Step 2b: A move to a NEW parent bumps updated_at; a pure same-parent
            // reorder does NOT (organizing siblings shouldn't reshuffle the recency view).
            if !sameParent {
                try db.execute(sql: """
                UPDATE bookmark_nodes SET updated_at = ? WHERE id = ?;
                """, arguments: [Date().timeIntervalSince1970, id])
            }

            // Step 3: Renumber siblings on both old and new parent (or root).
            for parent in [toParentID, sameParent ? nil : oldParent].compactMap({ $0 }) {
                let sibRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id FROM bookmark_nodes WHERE parent_id = ? ORDER BY position ASC;",
                    arguments: [parent]
                )
                for (i, sibRow) in sibRows.enumerated() {
                    let childID: String = sibRow["id"]
                    try db.execute(
                        sql: "UPDATE bookmark_nodes SET position = ? WHERE id = ?;",
                        arguments: [i, childID]
                    )
                }
            }
            // Renumber root siblings if either old or new parent is root.
            for renumberRoot in [toParentID == nil, !sameParent && oldParent == nil] {
                guard renumberRoot else { continue }
                let sibRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id FROM bookmark_nodes WHERE parent_id IS NULL ORDER BY position ASC;"
                )
                for (i, sibRow) in sibRows.enumerated() {
                    let childID: String = sibRow["id"]
                    try db.execute(
                        sql: "UPDATE bookmark_nodes SET position = ? WHERE id = ?;",
                        arguments: [i, childID]
                    )
                }
            }
        }
    }


    // MARK: - WikiStore protocol: Persisted chats

    public func createChat(kind: ChatKind, title: String) throws -> ChatSummary {
        try mutate(event: { chat in
            self.localEvent(.chat, id: chat.id.rawValue, change: .created)
        }) { db in
            let id = PageID(rawValue: ULID.generate())
            let now = Date()
            try db.execute(sql: """
            INSERT INTO chats (id, kind, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """, arguments: [
                id.rawValue, kind.rawValue, title,
                now.timeIntervalSince1970, now.timeIntervalSince1970
            ])
            return ChatSummary(
                id: id, kind: kind, title: title,
                createdAt: now, updatedAt: now, messageCount: 0
            )
        }
    }


    public func appendChatMessages(chatID: PageID, events: [AgentEvent]) throws -> [ChatMessage] {
        guard !events.isEmpty else { return [] }
        return try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            // Existence check.
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM chats WHERE id = ?;",
                arguments: [chatID.rawValue]
            ) ?? 0
            guard exists != 0 else {
                throw WikiStoreError.notFound(chatID)
            }

            // Dense per-chat seq, continuing from the current max (-1 when empty
            // so the first row lands at 0).
            let maxSeq = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), -1) FROM chat_messages WHERE chat_id = ?;",
                arguments: [chatID.rawValue]
            ) ?? -1
            var nextSeq = maxSeq + 1

            let now = Date()
            let encoder = JSONEncoder()
            var inserted: [ChatMessage] = []
            for event in events {
                let json = String(data: try encoder.encode(event), encoding: .utf8) ?? "{}"
                let messageID = PageID(rawValue: ULID.generate())
                try db.execute(sql: """
                INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, arguments: [
                    messageID.rawValue, chatID.rawValue, nextSeq,
                    event.chatRole, json, event.plainText, now.timeIntervalSince1970
                ])
                inserted.append(ChatMessage(
                    id: messageID, chatID: chatID, seq: nextSeq, event: event, createdAt: now
                ))
                nextSeq += 1
            }

            try db.execute(sql: """
            UPDATE chats SET updated_at = ? WHERE id = ?;
            """, arguments: [now.timeIntervalSince1970, chatID.rawValue])

            // Keep the chat FTS sidecar fresh (title + concatenated message body).
            // Best-effort, inside the same transaction so the FTS index never lags.
            do {
                if let titleRow = try Row.fetchOne(
                    db,
                    sql: "SELECT title FROM chats WHERE id = ?;",
                    arguments: [chatID.rawValue]
                ) {
                    let title: String = titleRow["title"]
                    let body: String = (try String.fetchOne(
                        db,
                        sql: "SELECT COALESCE(GROUP_CONCAT(text, '\n'), '') FROM chat_messages WHERE chat_id = ?;",
                        arguments: [chatID.rawValue]
                    )) ?? ""
                    try db.execute(sql: """
                    INSERT OR REPLACE INTO chat_search (chat_id, title, body) VALUES (?, ?, ?);
                    """, arguments: [chatID.rawValue, title, body])
                }
            } catch {
                DebugLog.store("upsertChatSearch[\(chatID.rawValue)] failed — \(error)")
            }

            // NOTE: eager re-embed omitted — GRDB store uses lazy embedding via
            // missingChatEmbeddingWork + storeChatChunks (matching the source
            // embedding design). New messages are picked up by the next backfill.
            return inserted
        }
    }


    public func listChats() throws -> [ChatSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                   (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                   c.summary, c.summary_at
            FROM chats c
            ORDER BY c.updated_at DESC, c.rowid DESC;
            """)
            return rows.map { row in
                let summary: String? = row["summary"]
                let summaryAt: Double? = row["summary_at"]
                return Self.readChatSummary(
                    from: row,
                    summary: summary,
                    summaryAt: summaryAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }


    public func chatMessages(chatID: PageID) throws -> [ChatMessage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, seq, event_json, created_at FROM chat_messages
            WHERE chat_id = ? ORDER BY seq ASC;
            """, arguments: [chatID.rawValue])
            let decoder = JSONDecoder()
            var out: [ChatMessage] = []
            for row in rows {
                guard
                    let json: String = row["event_json"],
                    let data = json.data(using: .utf8),
                    let event = try? decoder.decode(AgentEvent.self, from: data)
                else { continue }
                out.append(ChatMessage(
                    id: PageID(rawValue: row["id"]),
                    chatID: chatID,
                    seq: row["seq"],
                    event: event,
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                ))
            }
            return out
        }
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
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                   (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                   c.summary, c.summary_at
            FROM chats c
            ORDER BY c.id ASC;
            """)
            return rows.map { row in
                let summary: String? = row["summary"]
                let summaryAt: Double? = row["summary_at"]
                return Self.readChatSummary(
                    from: row,
                    summary: summary,
                    summaryAt: summaryAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
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

    // MARK: - WikiStore protocol: Semantic chat search

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
        try dbQueue.read { db in
            let pool = max(limit * 2, limit)
            // --- FTS (lexical) pass ---
            let q = Self.ftsMatch(query)
            var ftsRows: [ChatSummary] = []
            if !q.isEmpty {
                ftsRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                           (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count
                    FROM chats_fts
                    JOIN chat_search cs ON cs.rowid = chats_fts.rowid
                    JOIN chats c ON c.id = cs.chat_id
                    WHERE chats_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?;
                    """,
                    arguments: [q, pool]
                ).map { row in
                    Self.readChatSummary(from: row, summary: nil, summaryAt: nil)
                }
            }

            // --- Semantic (vec cosine) pass + RRF ---
            if Self.isVecAvailable(db),
               let queryBlob = EmbeddingService.embeddingBlob(for: query) {
                DebugLog.store("search[chats]: query=\(query) hybrid (semantic+FTS) → RRF, vec=true")
                let semRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                           (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count
                    FROM (
                        SELECT chat_id, MIN(vec_distance_cosine(embedding, ?)) AS best
                        FROM chat_chunks GROUP BY chat_id
                    ) r
                    JOIN chats c ON c.id = r.chat_id
                    ORDER BY r.best ASC
                    LIMIT ?;
                    """,
                    arguments: [queryBlob, pool]
                ).map { row in
                    Self.readChatSummary(from: row, summary: nil, summaryAt: nil)
                }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[chats]: query=\(query) FTS-only, vec=false")
            return Array(ftsRows.prefix(limit))
        }
    }


    // MARK: - WikiStore protocol: Blob GC

    public func vacuumBlobs(dryRun: Bool) throws -> BlobVacuumReport {
        try dbQueue.write { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS orphan_count, COALESCE(SUM(byte_size), 0) AS bytes
            FROM blobs
            WHERE hash NOT IN (SELECT blob_hash        FROM source_versions            WHERE blob_hash IS NOT NULL)
              AND hash NOT IN (SELECT thumbnail_hash FROM source_versions          WHERE thumbnail_hash IS NOT NULL)
              AND hash NOT IN (SELECT blob_hash      FROM source_markdown_versions WHERE blob_hash IS NOT NULL)
              AND hash NOT IN (SELECT blob_hash      FROM page_versions             WHERE blob_hash IS NOT NULL)
              AND hash NOT IN (SELECT blob_hash      FROM workspace_refs            WHERE blob_hash IS NOT NULL);
            """)
            let orphanCount: Int = (row?["orphan_count"]) ?? 0
            let bytes: Int = (row?["bytes"]) ?? 0

            if !dryRun {
                try db.execute(sql: """
                DELETE FROM blobs
                WHERE hash NOT IN (SELECT blob_hash        FROM source_versions            WHERE blob_hash IS NOT NULL)
                  AND hash NOT IN (SELECT thumbnail_hash FROM source_versions          WHERE thumbnail_hash IS NOT NULL)
                  AND hash NOT IN (SELECT blob_hash      FROM source_markdown_versions WHERE blob_hash IS NOT NULL)
                  AND hash NOT IN (SELECT blob_hash      FROM page_versions             WHERE blob_hash IS NOT NULL)
                  AND hash NOT IN (SELECT blob_hash      FROM workspace_refs            WHERE blob_hash IS NOT NULL);
                """)
            }
            return BlobVacuumReport(
                orphanCount: orphanCount, bytesReclaimed: bytes, applied: !dryRun
            )
        }
    }


    public func vacuumActivities(dryRun: Bool) throws -> ActivityVacuumReport {
        try dbQueue.write { db in
            let orphanPredicate = """
            id NOT IN (SELECT activity_id FROM source_versions            WHERE activity_id IS NOT NULL)
            AND id NOT IN (SELECT activity_id FROM source_markdown_versions WHERE activity_id IS NOT NULL)
            AND id NOT IN (SELECT activity_id FROM page_versions           WHERE activity_id IS NOT NULL)
            """
            let orphanCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM activities WHERE \(orphanPredicate);"
            ) ?? 0

            if !dryRun {
                try db.execute(
                    sql: "DELETE FROM activities WHERE \(orphanPredicate);"
                )
            }
            return ActivityVacuumReport(
                orphanCount: orphanCount, applied: !dryRun
            )
        }
    }


    public func vacuumPageVersions(dryRun: Bool) throws -> PageVersionVacuumReport {
        try dbQueue.write { db in
            // --- Compute reachable set (orphanPageVersionIDs) ---

            // Start with the direct ref targets.
            var reachable: Set<String> = []
            let refRows = try Row.fetchAll(db, sql: """
            SELECT version_id FROM refs WHERE kind = 'page-content' AND version_id IS NOT NULL;
            """)
            for row in refRows {
                if let vid: String = row["version_id"] { reachable.insert(vid) }
            }

            // Workspace-referenced versions (version_id and base_version_id).
            let wsRows = try Row.fetchAll(db, sql: """
            SELECT version_id FROM workspace_refs WHERE version_id IS NOT NULL
            UNION
            SELECT base_version_id FROM workspace_refs WHERE base_version_id IS NOT NULL;
            """)
            for row in wsRows {
                if let vid: String = row["version_id"] { reachable.insert(vid) }
            }

            // Transitively walk the ancestor chain from each reachable version (BFS
            // walking UP via parent_id / merge_parent_id toward the root).
            var frontier = reachable
            while !frontier.isEmpty {
                let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
                let parentRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT parent_id AS pid FROM page_versions
                    WHERE id IN (\(placeholders)) AND parent_id IS NOT NULL
                    UNION
                    SELECT DISTINCT merge_parent_id AS pid FROM page_versions
                    WHERE id IN (\(placeholders)) AND merge_parent_id IS NOT NULL;
                    """,
                    arguments: StatementArguments([String](frontier) + [String](frontier))
                )
                var newReachable: Set<String> = []
                for row in parentRows {
                    if let pid: String = row["pid"], !reachable.contains(pid) {
                        newReachable.insert(pid)
                    }
                }
                reachable.formUnion(newReachable)
                frontier = newReachable
            }

            // --- Count + delete orphans ---
            let orphanCount: Int
            if reachable.isEmpty {
                orphanCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_versions;") ?? 0
            } else {
                let placeholders = reachable.map { _ in "?" }.joined(separator: ",")
                orphanCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM page_versions WHERE id NOT IN (\(placeholders));",
                    arguments: StatementArguments([String](reachable))
                ) ?? 0
            }

            if !dryRun && orphanCount > 0 {
                if reachable.isEmpty {
                    try db.execute(sql: "DELETE FROM page_versions;")
                } else {
                    let placeholders = reachable.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM page_versions WHERE id NOT IN (\(placeholders));",
                        arguments: StatementArguments([String](reachable))
                    )
                }
            }
            return PageVersionVacuumReport(
                deletedCount: orphanCount, applied: !dryRun
            )
        }
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

    // MARK: - GRDB implementation helpers

    /// Sanitize free text into a safe FTS5 MATCH expression: keep alphanumerics
    /// and whitespace, drop operator characters so user input can't inject query
    /// syntax. Returns "" when nothing useful remains. Mirrors
    /// SQLiteWikiStore.ftsMatch.
    private static func ftsMatch(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let kept = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whether the sqlite-vec scalar functions are registered on this connection.
    /// Probed the same way as SQLiteWikiStore.isVecAvailable: `vec_distance_cosine`
    /// exists iff the query resolves without error. Called inside dbQueue.read.
    private static func isVecAvailable(_ db: Database) -> Bool {
        (try? Row.fetchOne(db, sql: "SELECT vec_distance_cosine(x'00000000', x'00000000');")) != nil
    }

    /// Read a ChatSummary from a GRDB Row. The `summary` and `summaryAt` columns
    /// are passed in so this works for both the 6-column search variants (nil) and
    /// the 8-column list variants. Mirrors SQLiteWikiStore.chatSummary(from:).
    /// Columns (named): id, kind, title, created_at, updated_at, + an unnamed
    /// message-count subquery at index 5.
    private static func readChatSummary(
        from row: Row, summary: String?, summaryAt: Date?
    ) -> ChatSummary {
        ChatSummary(
            id: PageID(rawValue: row["id"]),
            kind: ChatKind(rawValue: row["kind"]) ?? .edit,
            title: row["title"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            messageCount: row["msg_count"],
            summary: summary,
            summaryAt: summaryAt
        )
    }


    /// The ingest byte cap (100 MiB). Mirrors `SQLiteWikiStore.ingestByteCap`
    /// — defined locally so GRDBWikiStore is self-contained (no cross-store
    /// reference).
    private static let ingestByteCap = 100 * 1024 * 1024

    /// Get-or-create an agent by (name, kind), returning its id. Idempotent.
    /// Mirrors `SQLiteWikiStore.ensureAgent`. `db:`-taking so it is safe inside
    /// `mutate`.


    /// Get-or-create an agent by (name, kind), returning its id. Idempotent.
    /// Mirrors `SQLiteWikiStore.ensureAgent`. `db:`-taking so it is safe inside
    /// `mutate`.
    private func ensureAgent(
        name: String, kind: String = "software",
        version: String? = nil, externalRef: String? = nil,
        on db: Database
    ) throws -> String {
        if let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM agents WHERE name = ? AND kind = ? LIMIT 1;",
            arguments: [name, kind]
        ) {
            return id
        }
        let id = ULID.generate()
        try db.execute(sql: """
        INSERT INTO agents (id, kind, name, version, external_ref)
        VALUES (?, ?, ?, ?, ?);
        """, arguments: [id, kind, name, version, externalRef])
        return id
    }

    /// CAS-store a markdown body: SHA-256 (UTF-8) → `INSERT OR IGNORE` blob →
    /// return the hex hash. Mirrors `SQLiteWikiStore.storeMarkdownBlob`.


    /// CAS-store a markdown body: SHA-256 (UTF-8) → `INSERT OR IGNORE` blob →
    /// return the hex hash. Mirrors `SQLiteWikiStore.storeMarkdownBlob`.
    private func storeMarkdownBlob(_ content: String, on db: Database) throws -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        try db.execute(sql: """
        INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
        """, arguments: [hash, Int64(data.count), data])
        return hash
    }

    /// The active content version for `sourceID`: prefer the `source-content`
    /// ref, else `MAX(id)` (the default-active rule, §4.3). `db:`-taking.
    /// Mirrors `SQLiteWikiStore.activeContentVersion`.


    /// The active content version for `sourceID`: prefer the `source-content`
    /// ref, else `MAX(id)` (the default-active rule, §4.3). `db:`-taking.
    /// Mirrors `SQLiteWikiStore.activeContentVersion`.
    private func activeContentVersion(sourceID: PageID, on db: Database) throws -> SourceVersion? {
        let cols = """
        id, source_id, parent_id, blob_hash, mime_type,
        activity_id, external_identity, fetched_at
        """
        if let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(cols)
            FROM refs r
            JOIN source_versions sv ON sv.id = r.version_id
            WHERE r.kind = 'source-content' AND r.owner_id = ?;
            """,
            arguments: [sourceID.rawValue]
        ) {
            return try Self.readSourceVersion(from: row)
        }
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(cols)
            FROM source_versions
            WHERE source_id = ? ORDER BY id DESC LIMIT 1;
            """,
            arguments: [sourceID.rawValue]
        ) else { return nil }
        return try Self.readSourceVersion(from: row)
    }

    /// The `generation` of the `source-content` ref for `sourceID`, or nil.
    /// Mirrors `SQLiteWikiStore.refGeneration`.


    /// The `generation` of the `source-content` ref for `sourceID`, or nil.
    /// Mirrors `SQLiteWikiStore.refGeneration`.
    private func refGeneration(sourceID: PageID, on db: Database) throws -> Int? {
        try Int.fetchOne(
            db,
            sql: "SELECT generation FROM refs WHERE kind = 'source-content' AND owner_id = ?;",
            arguments: [sourceID.rawValue]
        )
    }

    /// Decode a `source_versions` row (named columns) into a `SourceVersion`.
    /// NULLable columns read as optionals via `row["col"]`.


    /// Decode a `source_versions` row (named columns) into a `SourceVersion`.
    /// NULLable columns read as optionals via `row["col"]`.
    private static func readSourceVersion(from row: Row) throws -> SourceVersion {
        let id: String = row["id"]
        let sourceIDStr: String = row["source_id"]
        let parentID: String? = row["parent_id"]
        let blobHash: String? = row["blob_hash"]
        let mimeType: String? = row["mime_type"]
        let activityID: String? = row["activity_id"]
        let externalIdentity: String? = row["external_identity"]
        let fetchedAt: Double = row["fetched_at"]
        return SourceVersion(
            id: id,
            sourceID: PageID(rawValue: sourceIDStr),
            parentID: parentID,
            blobHash: blobHash,
            mimeType: mimeType,
            activityID: activityID,
            externalIdentity: externalIdentity,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt)
        )
    }

    /// The shared SELECT-list + LEFT JOIN that resolves a CAS'd markdown row's
    /// content from its blob (the resolved-body invariant). Column order MUST
    /// stay in lockstep with `readMarkdownVersion(from:)`. The resolved body
    /// is aliased `body` so it is accessible by name (POSITIONAL access on a
    /// COALESCE expression without an alias is fragile).


    /// The shared SELECT-list + LEFT JOIN that resolves a CAS'd markdown row's
    /// content from its blob (the resolved-body invariant). Column order MUST
    /// stay in lockstep with `readMarkdownVersion(from:)`. The resolved body
    /// is aliased `body` so it is accessible by name (POSITIONAL access on a
    /// COALESCE expression without an alias is fragile).
    private static let smvSelectColumns = """
    smv.id, smv.file_id, smv.parent_id,
    COALESCE(CAST(b.content AS TEXT), '') AS body,
    smv.origin, smv.note, smv.created_at,
    smv.activity_id, smv.source_version_id, smv.blob_hash, smv.mime_type,
    smv.technique
    """

    private static let smvBlobJoin = "LEFT JOIN blobs b ON b.hash = smv.blob_hash"

    /// Read one `source_markdown_versions` row from a GRDB `Row` (named columns
    /// — `body` is the aliased COALESCE expression from `smvSelectColumns`).
    /// Mirrors `sourceMarkdownVersion(from:)`.


    /// Read one `source_markdown_versions` row from a GRDB `Row` (named columns
    /// — `body` is the aliased COALESCE expression from `smvSelectColumns`).
    /// Mirrors `sourceMarkdownVersion(from:)`.
    private static func readMarkdownVersion(from row: Row) -> SourceMarkdownVersion {
        let parentID: String? = row["parent_id"]
        let content: String = row["body"]
        let originRaw: String = row["origin"]
        let note: String? = row["note"]
        let createdAt: Double = row["created_at"]
        let activityID: String? = row["activity_id"]
        let sourceVersionID: String? = row["source_version_id"]
        let blobHash: String? = row["blob_hash"]
        let mimeType: String = row["mime_type"]
        let technique: String? = row["technique"]
        return SourceMarkdownVersion(
            id: PageID(rawValue: row["id"]),
            sourceID: PageID(rawValue: row["file_id"]),
            parentID: parentID.map { PageID(rawValue: $0) },
            content: content,
            origin: SourceMarkdownOrigin(rawValue: originRaw) ?? .extraction,
            note: note,
            createdAt: Date(timeIntervalSince1970: createdAt),
            activityID: activityID,
            sourceVersionID: sourceVersionID,
            blobHash: blobHash,
            mimeType: mimeType.isEmpty ? MimeType.markdown : mimeType,
            technique: technique
        )
    }

    /// UPSERT the `source_search` FTS backing row (title + body). The FTS5
    /// triggers on `source_search` keep `sources_fts` fresh. Best-effort: a
    /// failure is logged, never thrown (mirrors SQLiteWikiStore's `try?` guard).


    /// UPSERT the `source_search` FTS backing row (title + body). The FTS5
    /// triggers on `source_search` keep `sources_fts` fresh. Best-effort: a
    /// failure is logged, never thrown (mirrors SQLiteWikiStore's `try?` guard).
    private func upsertSourceSearch(sourceID: PageID, body: String, on db: Database) {
        guard let title = try? String.fetchOne(
            db,
            sql: "SELECT COALESCE(display_name, filename) FROM sources WHERE id = ?;",
            arguments: [sourceID.rawValue]
        ) else { return }
        do {
            try db.execute(sql: """
            INSERT OR REPLACE INTO source_search (source_id, title, body) VALUES (?, ?, ?);
            """, arguments: [sourceID.rawValue, title, body])
        } catch {
            DebugLog.store("GRDBWikiStore.upsertSourceSearch[\(sourceID.rawValue)] failed: \(error)")
        }
    }

    /// Whether sqlite-vec scalar functions are registered on this connection.
    /// Mirrors `SQLiteWikiStore.isVecAvailable`. Best-effort.


    /// Best-effort re-embed of `sourceID` from `body`. Runs POST-commit (never
    /// inside `mutate`): reads the source name on its own, runs MLX chunked
    /// embeddings out-of-transaction, then writes via the existing public
    /// `storeSourceChunks` (its own transaction). Gated on vec availability.
    /// Mirrors `SQLiteWikiStore.reembedSource` minus the lock-holding.
    private func reembedSource(sourceID: PageID, body: String) {
        guard let title = try? dbQueue.read({ db in
            try String.fetchOne(
                db,
                sql: "SELECT COALESCE(display_name, filename) FROM sources WHERE id = ?;",
                arguments: [sourceID.rawValue]
            )
        }) else { return }
        let vecOK: Bool = (try? dbQueue.read { db in Self.isVecAvailable(db) }) ?? false
        guard vecOK else { return }
        let text = body.isEmpty ? title : "\(title)\n\n\(body)"
        let chunks = EmbeddingService.chunkedEmbeddings(for: text)
        guard !chunks.isEmpty else {
            DebugLog.store("GRDBWikiStore.reembedSource[\(sourceID.rawValue)] no chunks bodyLen=\(body.count)")
            return
        }
        DebugLog.store("GRDBWikiStore.reembedSource[\(sourceID.rawValue)] bodyLen=\(body.count) chunks=\(chunks.count)")
        do {
            try storeSourceChunks(id: sourceID, chunks: chunks)
        } catch {
            DebugLog.store("GRDBWikiStore.reembedSource[\(sourceID.rawValue)] storeSourceChunks failed: \(error)")
        }
    }

    /// The `version_id` of the `source-derived` ref for `sourceID`, or nil.
    /// Mirrors `SQLiteWikiStore.markdownDerivedRef`.


    /// The `version_id` of the `source-derived` ref for `sourceID`, or nil.
    /// Mirrors `SQLiteWikiStore.markdownDerivedRef`.
    private func markdownDerivedRef(sourceID: PageID, on db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT version_id FROM refs WHERE kind = 'source-derived' AND owner_id = ?;",
            arguments: [sourceID.rawValue]
        )
    }

    /// The current `generation` of the `source-derived` ref, or nil.
    /// Mirrors `SQLiteWikiStore.markdownDerivedGeneration`.


    /// The current `generation` of the `source-derived` ref, or nil.
    /// Mirrors `SQLiteWikiStore.markdownDerivedGeneration`.
    private func markdownDerivedGeneration(sourceID: PageID, on db: Database) throws -> Int? {
        try Int.fetchOne(
            db,
            sql: "SELECT generation FROM refs WHERE kind = 'source-derived' AND owner_id = ?;",
            arguments: [sourceID.rawValue]
        )
    }

    /// UPSERT the `source-derived` ref (generation + 1). `db:`-taking.
    /// Mirrors `SQLiteWikiStore.upsertMarkdownDerivedRef`.
    /// CONTRACT: caller is inside `mutate`.


    /// UPSERT the `source-derived` ref (generation + 1). `db:`-taking.
    /// Mirrors `SQLiteWikiStore.upsertMarkdownDerivedRef`.
    /// CONTRACT: caller is inside `mutate`.
    private func upsertMarkdownDerivedRef(
        sourceID: PageID, versionID: String, now: Double, on db: Database
    ) throws {
        let prevGeneration = try markdownDerivedGeneration(sourceID: sourceID, on: db)
        let nextGeneration = (prevGeneration ?? 0) + 1
        try db.execute(sql: """
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('source-derived', ?, ?, ?, ?)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = excluded.generation,
            updated_at = excluded.updated_at;
        """, arguments: [sourceID.rawValue, versionID, Int64(nextGeneration), now])
    }


    /// Decode an origin row. NULL activity/agent columns degrade gracefully.
    private static func originFrom(row: Row) -> SourceOrigin {
        let agentName: String? = row[0]
        let activityKind: String? = row[1]
        let plan: String? = row[2]
        let externalRef: String? = row[3]
        let externalIdentity: String? = row[4]
        let fetchedAt: Double = row[5]
        return SourceOrigin(
            agentName: agentName ?? "unknown",
            activityKind: activityKind ?? "import",
            plan: plan,
            externalRef: externalRef,
            externalIdentity: externalIdentity,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt)
        )
    }


    /// Fetch one source summary by id on an open `db`. `db:`-taking so it is
    /// safe inside `mutate`. Mirrors `SQLiteWikiStore.getSource`.
    private static func getSourceSummary(id: PageID, on db: Database) throws -> SourceSummary {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
                   zotero_item_key, zotero_item_title, display_name, role
            FROM sources WHERE id = ?;
            """,
            arguments: [id.rawValue]
        ) else {
            throw WikiStoreError.notFound(id)
        }
        return try Self.readSourceSummary(from: row)
    }

    /// Post-commit FTS upsert for `source_search` (opens its own write so it
    /// must be called AFTER `mutate` returns, never inside).


    /// `db:`-taking HEAD read for use inside `mutate` (cannot call the public
    /// `processedMarkdownHead` — it re-enters `dbQueue.read` and deadlocks).
    private func processedMarkdownHead(sourceID: PageID, on db: Database) throws -> SourceMarkdownVersion? {
        if let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(Self.smvSelectColumns)
            FROM refs r
            JOIN source_markdown_versions smv ON smv.id = r.version_id
            \(Self.smvBlobJoin)
            WHERE r.kind = 'source-derived' AND r.owner_id = ?;
            """,
            arguments: [sourceID.rawValue]
        ) {
            return Self.readMarkdownVersion(from: row)
        }
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(Self.smvSelectColumns)
            FROM source_markdown_versions smv
            \(Self.smvBlobJoin)
            WHERE smv.file_id = ? ORDER BY smv.id DESC LIMIT 1;
            """,
            arguments: [sourceID.rawValue]
        ) else { return nil }
        return Self.readMarkdownVersion(from: row)
    }


    /// Inline append for the revert fallback (target had no blob_hash). `db:`-
    /// taking; emits FTS inline. The caller's post-commit re-embed runs on
    /// `result.content`.
    private func appendProcessedMarkdownInline(
        sourceID: PageID, content: String,
        origin: SourceMarkdownOrigin, note: String?, technique: String?,
        parentID: PageID?, db: Database
    ) throws -> SourceMarkdownVersion {
        let id = PageID(rawValue: ULID.generate())
        let now = Date()
        let blobHash = try self.storeMarkdownBlob(content, on: db)
        try db.execute(sql: """
        INSERT INTO source_markdown_versions
          (id, file_id, parent_id, origin, note, created_at,
           blob_hash, mime_type, technique)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'text/markdown', ?);
        """, arguments: [id.rawValue, sourceID.rawValue, parentID?.rawValue,
                        origin.rawValue, note, now.timeIntervalSince1970,
                        blobHash, technique])
        self.upsertSourceSearch(sourceID: sourceID, body: content, on: db)
        return SourceMarkdownVersion(
            id: id, sourceID: sourceID, parentID: parentID,
            content: content, origin: origin, note: note, createdAt: now,
            blobHash: blobHash, mimeType: MimeType.markdown, technique: technique
        )
    }

    /// Static version of `pageHeadVersionIDLocked` that operates on a `Database`
    /// handle (usable inside `mutate`/`read` bodies). Mirrors
    /// `SQLiteWikiStore.pageHeadVersionIDLocked`.
    private static func pageHeadVersionIDLocked(pageID: PageID, on db: Database) throws -> String? {
        // Try the explicit ref first.
        if let vid = try String.fetchOne(
            db,
            sql: "SELECT version_id FROM refs WHERE kind = 'page-content' AND owner_id = ?;",
            arguments: [pageID.rawValue]
        ) {
            return vid
        }
        // No ref → default-active = MAX(id) for this page.
        DebugLog.store("pageHeadVersionIDLocked: MAX(id) fallback for page \(pageID.rawValue) — no page-content ref found (should not happen after v34 migration)")
        return try String.fetchOne(
            db,
            sql: "SELECT id FROM page_versions WHERE page_id = ? ORDER BY id DESC LIMIT 1;",
            arguments: [pageID.rawValue]
        )
    }

    /// Internal: resolve the workspace's current version for a page.
    /// Returns nil if the page has no workspace_ref or if the page is staged as
    /// a created page (version_id is NULL — content lives in blob_hash).


    /// Internal: resolve the workspace's current version for a page.
    /// Returns nil if the page has no workspace_ref or if the page is staged as
    /// a created page (version_id is NULL — content lives in blob_hash).
    private static func workspacePageVersionLocked(
        workspaceID: String, pageID: PageID, on db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
            SELECT version_id FROM workspace_refs
            WHERE workspace_id = ? AND kind = 'page-content' AND owner_id = ?;
            """,
            arguments: [workspaceID, pageID.rawValue]
        )
        // NOTE: SQLiteWikiStore returns nil when version_id column is NULL.
        // GRDB's String.fetchOne returns nil for both "no row" and "NULL value",
        // which matches the desired behavior exactly.
    }

    /// Fetch the body text of a page version from its blob.


    /// Fetch the body text of a page version from its blob.
    private func fetchVersionBody(db: Database, versionID: String) throws -> String {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT b.content FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ?;
        """, arguments: [versionID]) else {
            throw WikiStoreError.unexpected("version \(versionID) not found")
        }
        let data: Data = row["content"]
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Coalescing window for autosave amend (Phase 4). Same-actor saves within
    /// this window amend the head version in place instead of appending.


    /// Coalescing window for autosave amend (Phase 4). Same-actor saves within
    /// this window amend the head version in place instead of appending.
    private static let amendCoalescingWindow: TimeInterval = 5.0

    /// Attempt to amend the head page version in place instead of appending.
    /// Returns the (unchanged) version id if amend succeeded, or nil to fall
    /// through to the append path. All five conditions must hold:
    /// 1. Same actor (pages.last_edited_by == incoming lastEditedBy).
    /// 2. Head saved within the coalescing window.
    /// 3. Head has no children (no parent_id/merge_parent_id points at it).
    /// 4. No workspace_refs row references the head.
    /// 5. Blind-write guard: pages.body_markdown matches the head blob.


    /// Attempt to amend the head page version in place instead of appending.
    /// Returns the (unchanged) version id if amend succeeded, or nil to fall
    /// through to the append path. All five conditions must hold:
    /// 1. Same actor (pages.last_edited_by == incoming lastEditedBy).
    /// 2. Head saved within the coalescing window.
    /// 3. Head has no children (no parent_id/merge_parent_id points at it).
    /// 4. No workspace_refs row references the head.
    /// 5. Blind-write guard: pages.body_markdown matches the head blob.
    private func tryAmendPageVersion(
        db: Database, pageID: PageID, head: String?, title: String, slug: String,
        body: String, bodyData: Data, hash: String,
        lastEditedBy: String?, now: Date, nowTS: Double
    ) throws -> String? {
        // Need a head to amend.
        guard let head else { return nil }

        // 1. Same-actor check.
        guard let lastEditedBy else { return nil }
        guard let existingActor = try String.fetchOne(
            db, sql: "SELECT last_edited_by FROM pages WHERE id = ?;",
            arguments: [pageID.rawValue]
        ), existingActor == lastEditedBy else { return nil }

        // 2. Within the coalescing window.
        guard let savedAt = try Double.fetchOne(
            db, sql: "SELECT saved_at FROM page_versions WHERE id = ?;",
            arguments: [head]
        ) else { return nil }
        let elapsed = nowTS - savedAt
        guard elapsed >= 0 && elapsed <= Self.amendCoalescingWindow else { return nil }

        // 3. Head has no children.
        let childCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM page_versions WHERE parent_id = ? OR merge_parent_id = ?;",
            arguments: [head, head]
        ) ?? 0
        guard childCount == 0 else { return nil }

        // 4. No workspace_refs row references the head.
        let wsCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM workspace_refs WHERE version_id = ? OR base_version_id = ?;",
            arguments: [head, head]
        ) ?? 0
        guard wsCount == 0 else { return nil }

        // 5. Blind-write guard: pages.body_markdown must match the head blob.
        guard let headBlobRow = try Row.fetchOne(db, sql: """
        SELECT b.content FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ?;
        """, arguments: [head]) else { return nil }
        let headBlobData: Data = headBlobRow["content"]
        guard let mirrorBody = try String.fetchOne(
            db, sql: "SELECT body_markdown FROM pages WHERE id = ?;",
            arguments: [pageID.rawValue]
        ) else { return nil }
        guard Data(mirrorBody.utf8) == headBlobData else { return nil }

        // All conditions hold — amend in place.
        DebugLog.store("appendPageVersion: amending head \(head) for page \(pageID.rawValue) (same-actor coalescing, \(String(format: "%.2f", elapsed))s since last save)")

        // Insert the new blob.
        try db.execute(sql: """
        INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
        """, arguments: [hash, Int64(bodyData.count), bodyData])

        // Update the head version's blob_hash + title in place.
        try db.execute(sql: """
        UPDATE page_versions SET blob_hash = ?, title = ? WHERE id = ?;
        """, arguments: [hash, title, head])

        // Update the denormalized pages mirror.
        try db.execute(sql: """
        UPDATE pages
        SET title = ?, slug = ?, body_markdown = ?,
            updated_at = ?, version = version + 1, last_edited_by = ?
        WHERE id = ?;
        """, arguments: [title, slug, body, nowTS, lastEditedBy, pageID.rawValue])
        guard db.changesCount > 0 else { throw WikiStoreError.notFound(pageID) }

        // Bump the page-content ref generation.
        try db.execute(sql: """
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?, ?, 1, ?)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """, arguments: [pageID.rawValue, head, nowTS])

        return head
    }

    /// Fast-forward an existing page: repoint the main page-content ref to the
    /// workspace's version + update the pages mirror from the version's blob.


    /// Fast-forward an existing page: repoint the main page-content ref to the
    /// workspace's version + update the pages mirror from the version's blob.
    private func fastForwardPage(
        db: Database, pageID: PageID, versionID: String
    ) throws {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT pv.blob_hash, pv.title, b.content
        FROM page_versions pv
        JOIN blobs b ON b.hash = pv.blob_hash
        WHERE pv.id = ? AND pv.page_id = ?;
        """, arguments: [versionID, pageID.rawValue]) else {
            throw WikiStoreError.unexpected("workspaceMerge: version \(versionID) not found for page \(pageID.rawValue)")
        }
        let title: String = row["title"]
        let bodyData: Data = row["content"]
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        // Update the pages mirror.
        let sanitizedTitle = WikiNameRules.sanitized(title)
        let slug = try self.uniqueSlug(from: sanitizedTitle, id: pageID, on: db)
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
        UPDATE pages
        SET title = ?, slug = ?, body_markdown = ?,
            updated_at = ?, version = version + 1
        WHERE id = ?;
        """, arguments: [sanitizedTitle, slug, body, now, pageID.rawValue])

        // Repoint the main page-content ref.
        try db.execute(sql: """
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?, ?, 1, ?)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """, arguments: [pageID.rawValue, versionID, now])
    }

    /// Mint a created page at merge time (v35 staged-page path). Creates the
    /// pages row, a root page_versions row from the staged blob, and a
    /// page-content ref pointing at it.


    /// Mint a created page at merge time (v35 staged-page path). Creates the
    /// pages row, a root page_versions row from the staged blob, and a
    /// page-content ref pointing at it.
    private func mintCreatedPage(
        db: Database, pageID: PageID, blobHash: String, title: String
    ) throws {
        // Fetch the staged body from the blob.
        guard let blobRow = try Row.fetchOne(
            db, sql: "SELECT content FROM blobs WHERE hash = ?;",
            arguments: [blobHash]
        ) else {
            throw WikiStoreError.unexpected("mintCreatedPage: blob \(blobHash) not found")
        }
        let bodyData: Data = blobRow["content"]
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        let now = Date().timeIntervalSince1970
        let slug = try self.uniqueSlug(from: title, id: pageID, on: db)

        // 1. Create the pages row.
        try db.execute(sql: """
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
        VALUES (?, ?, ?, ?, ?, ?, 1);
        """, arguments: [pageID.rawValue, title, slug, body, now, now])

        // 2. Activity + agent.
        let agentID = try self.legacyImportAgentID(on: db)
        let activityID = ULID.generate()
        try db.execute(sql: """
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?, 'edit', ?, ?, ?);
        """, arguments: [activityID, agentID, now, now])

        // 3. Root version (parent NULL).
        let versionID = ULID.generate()
        try db.execute(sql: """
        INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
        VALUES (?, ?, NULL, ?, ?, ?, ?);
        """, arguments: [versionID, pageID.rawValue, blobHash, title, activityID, now])

        // 4. Page-content ref.
        try db.execute(sql: """
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?, ?, 1, ?);
        """, arguments: [pageID.rawValue, versionID, now])
    }

    /// The result of a diff3 merge attempt for a single page.


    /// The result of a diff3 merge attempt for a single page.
    private enum Diff3MergeResult {
        case merged
        case conflict
    }

    /// Attempt a three-way diff3 merge for a divergent page (W2). Fetches the
    /// three blobs (base, ours=main, theirs=workspace), runs Diff3.merge. If clean,
    /// creates a merge version + updates mirror + ref + regenerates links. If
    /// conflict, returns .conflict (caller parks).


    /// Attempt a three-way diff3 merge for a divergent page (W2). Fetches the
    /// three blobs (base, ours=main, theirs=workspace), runs Diff3.merge. If clean,
    /// creates a merge version + updates mirror + ref + regenerates links. If
    /// conflict, returns .conflict (caller parks).
    private func diff3MergePage(
        db: Database, pageID: PageID, baseVersionID: String,
        mainVersionID: String, wsVersionID: String
    ) throws -> Diff3MergeResult {
        // Fetch the three blobs.
        let baseText = try self.fetchVersionBody(db: db, versionID: baseVersionID)
        let oursText = try self.fetchVersionBody(db: db, versionID: mainVersionID)
        let theirsText = try self.fetchVersionBody(db: db, versionID: wsVersionID)

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
        try db.execute(sql: """
        INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
        """, arguments: [hash, Int64(mergedData.count), mergedData])

        // Merge PROV activity.
        let agentID = try self.legacyImportAgentID(on: db)
        let activityID = ULID.generate()
        try db.execute(sql: """
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?, 'merge', ?, ?, ?);
        """, arguments: [activityID, agentID, nowTS, nowTS])

        // Fetch the title from theirs (workspace version).
        let title = try String.fetchOne(
            db, sql: "SELECT title FROM page_versions WHERE id = ?;",
            arguments: [wsVersionID]
        ) ?? ""

        // Merge version (two parents).
        let versionID = ULID.generate()
        try db.execute(sql: """
        INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, arguments: [versionID, pageID.rawValue, mainVersionID, wsVersionID,
                         hash, title, activityID, nowTS])

        // Update the pages mirror.
        let sanitizedTitle = WikiNameRules.sanitized(title)
        let slug = try self.uniqueSlug(from: sanitizedTitle, id: pageID, on: db)
        try db.execute(sql: """
        UPDATE pages
        SET title = ?, slug = ?, body_markdown = ?,
            updated_at = ?, version = version + 1
        WHERE id = ?;
        """, arguments: [sanitizedTitle, slug, mergedText, nowTS, pageID.rawValue])

        // Repoint the main page-content ref.
        try db.execute(sql: """
        INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
        VALUES ('page-content', ?, ?, 1, ?)
        ON CONFLICT(kind, owner_id) DO UPDATE SET
            version_id = excluded.version_id,
            generation = generation + 1,
            updated_at = excluded.updated_at;
        """, arguments: [pageID.rawValue, versionID, nowTS])

        // Derived-data regeneration: re-parse wiki links (non-fatal).
        // NOTE: Cannot call self.replaceLinks here — it re-enters mutate/dbQueue.write
        // and would deadlock. Inline the logic on the same db handle.
        do {
            let parsedLinks = WikiLinkParser.parse(mergedText)
            try db.execute(sql: "DELETE FROM page_links WHERE from_page_id = ?;",
                           arguments: [pageID.rawValue])
            for link in parsedLinks {
                // Resolve title → page id inline (lowest ULID, case-insensitive).
                if let targetID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM pages WHERE title = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1;",
                    arguments: [link.target]
                ) {
                    try db.execute(sql: """
                    INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text)
                    VALUES (?, ?, ?);
                    """, arguments: [pageID.rawValue, targetID, link.linkText])
                }
            }
        } catch {
            DebugLog.store("diff3MergePage: link replacement failed for page \(pageID.rawValue): \(error)")
        }

        return .merged
    }

}
