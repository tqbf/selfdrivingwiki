import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

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
/// - `DatabasePool` serializes all reads/writes through one dispatch queue —
///   no external `NSRecursiveLock` needed (replaces `SQLiteWikiStore`'s lock).
/// - `DatabaseMigrator` provides named, idempotent, auto-tracked migrations
///   (via the `grdb_migrations` table), replacing the 37-version `user_version`
///   ladder. One consolidated fresh-schema migration mirrors
///   `createFreshSchemaV20()`; it is `IF NOT EXISTS`-guarded so existing DBs
///   (already at v38 from the hand-rolled ladder) are a no-op.
/// - The `mutate()` seam (§2, Approach B) survives as a thin wrapper around
///   `dbWriter.write { }`. The event is computed inside the transaction
///   (committed state) and emitted AFTER the write returns (post-commit), so
///   subscribers always read committed state and no handler runs under the
///   writer queue.
/// - `WikiEventBus` + `ResourceChangeEvent` are retained as-is —
///   `ValueObservation` is a complement, not a replacement, because the event
///   carries domain metadata `(wikiID, kind, id, change)` the File Provider
///   needs for scoped invalidation.
/// - Semantic search is pure Swift: `VectorCosine` (in `WikiFSSearch`) computes
///   cosine similarity as a vDSP dot product over L2-normalized chunk-embedding
///   BLOBs read directly from `*_chunks` (issue #628 — the vendored C scalar
///   target is retired; no extension is registered on any connection).
///
/// **Implementation status:**
/// - Infrastructure: connection setup, PRAGMAs, migrator, `mutate()` seam — DONE.
/// - Pages CRUD (listPages, getPage, createPage, updatePage, deletePage,
///   resolveTitleToID) — DONE (translated from proven SQL).
/// - Singletons (system prompt, wiki index, log, metadata) — DONE.
/// - All other protocol methods — safe stubs that throw
///   `WikiStoreError.unexpected("TODO: …")` (or return empty for the
///   non-throwing embed-work methods). The build compiles; methods are
///   implemented incrementally.
public final class GRDBWikiStore: WikiStore, @unchecked Sendable {

    // MARK: - Stored properties

    /// The latest schema version stamped by `createFreshSchema()` (for a fresh
    /// DB) and by `migrateIfNeeded(_:in:)` after running the ladder (for an
    /// existing DB). MUST match `SQLiteWikiStore.currentSchemaVersion`: existing
    /// databases produced by that store carry `PRAGMA user_version` up to 37, and
    /// this store must recognize them as already-current so the ladder is a no-op
    /// on re-open (the proven `if version < N`)
    private static let currentSchemaVersion = 44
    /// The current schema version (mirrors the former
    /// `SQLiteWikiStore.currentSchemaVersion`). Public so tests can assert the
    /// migration ladder landed at the expected `user_version`.
    public static var schemaVersion: Int { currentSchemaVersion }

    /// Read a `PRAGMA` value as text (e.g. `user_version`). Resilient: returns
    /// `""` on error. Mirrors the former `SQLiteWikiStore.pragmaValue`.
    public func pragmaValue(_ name: String) -> String {
        do {
            return try dbWriter.read { db in
                try String.fetchOne(db, sql: "PRAGMA \(name);") ?? ""
            }
        } catch { return "" }
    }

    /// Read one scalar text value from `sql`. Resilient: returns `""` on
    /// error. Mirrors the former `SQLiteWikiStore.scalarText` (used by tests).
    public func scalarText(_ sql: String) -> String {
        do {
            return try dbWriter.read { db in try Self.queryScalarText(sql, in: db) }
        } catch { return "" }
    }

    /// The serial GRDB connection. All reads and writes are serialized through
    /// GRDB's internal dispatch queue — no external `NSRecursiveLock` needed
    /// (the equivalent of `SQLiteWikiStore.lock`). Typed as `any DatabaseWriter`
    /// so unit tests can inject a `DatabaseQueue` (`:memory:`, single serialized
    /// connection) instead of the production `DatabasePool` (file-only, WAL,
    /// pooled readers). Every method `GRDBWikiStore` calls on its connection
    /// (`read`, `write`, `writeWithoutTransaction`, `unsafeReentrantWrite`) is
    /// available on the existential (protocol requirements + one extension
    /// default that internally calls a requirement) — see issue #651.
    private let dbWriter: any DatabaseWriter
    /// True for read-only connections (File Provider). `checkpoint()` skips on
    /// read-only connections (DatabasePool with readonly=true).
    private let isReadOnly: Bool
    /// True for any file-backed connection (DatabasePool or a file-backed
    /// DatabaseQueue — production paths). False for the in-memory DEBUG `init()`
    /// (`:memory:` via DatabaseQueue) — `checkpoint()` and any other WAL-only
    /// path must skip when false, since an in-memory database has no WAL frames
    /// and `PRAGMA wal_checkpoint(TRUNCATE)` errors out on it. See issue #651.
    private let isFileBacked: Bool

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
    /// and bootstrap search indexes. Mirrors `SQLiteWikiStore.init(databaseURL:)`.
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

        // No C extension registration anymore — the vendored scalar target is
        // retired (issue #628). Semantic-cosine ranking is now pure Swift
        // (`VectorCosine`), so the connection setup is plain PRAGMAs only.

        do {
            dbWriter = try DatabasePool(path: databaseURL.path, configuration: config)
            isReadOnly = false
            isFileBacked = true
            // Mirrors `SQLiteWikiStore.bootstrapSchema`: a FRESH db (user_version
            // 0) gets the consolidated current schema in one block; an EXISTING db
            // at any version runs the proven 38-step `if version < N` ladder
            // translated to GRDB's API. Either path stamps `user_version` to
            // `currentSchemaVersion`, so re-opening is a no-op (idempotent,
            // exactly like the `SQLiteWikiStore` store).
            //
            // `writeWithoutTransaction` (not `write`): the proven ladder commits
            // each step independently — `PRAGMA user_version = N` is stamped
            // inside each helper's `db.inTransaction(.immediate)`. If we wrapped
            // the whole migration in one outer transaction, a failure in step
            // N+1 would roll back steps 1..N (and their `user_version` bumps),
            // forcing a full restart-from-scratch on retry. The per-step commit
            // (matching `SQLiteWikiStore.withTransaction`) lets a retry resume
            // from the last successfully-stamped version.
            //
            // This deliberately replaces the prior single consolidated
            // `DatabaseMigrator`: it was unsound for a pre-existing DB (the
            // `grdb_migrations` table absence made every migration "unrun", but
            // `IF NOT EXISTS` guards cannot reproduce the data-backfill steps
            // (v18 name sanitize, v19 content_hash backfill, v20–23 graph-model
            // CAS-moves, v29 chat-kind sweep, v33→34 ref seeding) — those MUST
            // actually run once for a genuine upgrade). The ladder is PROVEN
            // (running fine in `SQLiteWikiStore` across 38 versions in
            // production); we reuse it verbatim, only translating the API calls.
            try dbWriter.writeWithoutTransaction { db in
                try migrateIfNeeded(db)
            }
            // Self-heal search indexes on open (Tantivy sidecar + chunk
            // embedding gaps). The FTS5 self-heal that ran here before #634 is
            // gone: FTS5 is dropped at v37→v38 and Tantivy is now the sole BM25
            // leg. NOT run by the read-only File Provider open.
            ensureSearchIndexesPopulated()
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
        // `readonly = true` opens the connection with SQLITE_OPEN_READONLY —
        // DatabasePool needs this (not just PRAGMA query_only) because
        // DatabasePool's pool setup writes WAL metadata (BEGIN IMMEDIATE)
        // which fails on a read-only file.
        config.readonly = true

        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-65536")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }

        // No C extension registration on read-only connections either — pure
        // Swift cosine (issue #628) reads `*_chunks.embedding` directly.

        do {
            dbWriter = try DatabasePool(path: readOnlyURL.path, configuration: config)
            isReadOnly = true
            isFileBacked = true
            // Do NOT run migrations on a read-only connection — the File
            // Provider must never author schema.
        } catch {
            throw WikiStoreError.open("\(error)")
        }
    }

    /// Open an in-memory database for tests. Runs the full migration ladder
    /// exactly like the file-backed init, but on a `DatabaseQueue` (single
    /// serialized connection). `DatabasePool` cannot back `:memory:` because it
    /// spawns independent reader connections — each `:memory:` connection is a
    /// separate empty DB. `DatabaseQueue` serializes all access through one
    /// connection, so a single in-memory DB is shared across every `read` /
    /// `write` on the store.
    ///
    /// `#if DEBUG`-gated — production never constructs a store without a
    /// file. Tests should route through `TestStoreFactory.inMemory()` rather
    /// than calling this directly (single switch point — issue #651).
    ///
    /// WAL-specific PRAGMAs are deliberately omitted: an in-memory DB has no
    /// WAL (the journal mode returns `"memory"`), and `wal_checkpoint(TRUNCATE)`
    /// errors on it — `isFileBacked` is `false` so `checkpoint()` is a no-op.
    /// The remaining PRAGMAs (`temp_store=MEMORY`, `cache_size=...`) apply
    /// unchanged.
    #if DEBUG
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)

        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-65536")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }
        // No C extension registration — vendored scalar retired (issue #628).

        do {
            // `named: nil` opens a standalone `:memory:` database — each
            // instance is an independent empty DB (no inter-test bleed, no
            // shared cache). The GRDB 7.x entry point is
            // `init(named:configuration:)`; `init(configuration:)` does NOT
            // exist.
            dbWriter = try DatabaseQueue(named: nil, configuration: config)
            isReadOnly = false
            isFileBacked = false
            try dbWriter.writeWithoutTransaction { db in
                try migrateIfNeeded(db)
            }
            ensureSearchIndexesPopulated()
        } catch {
            throw WikiStoreError.open("\(error)")
        }
    }
    #endif

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
        // Skip checkpoint on read-only connections (DatabasePool with
        // readonly=true) and on in-memory DEBUG stores (no WAL frames to
        // checkpoint — `PRAGMA wal_checkpoint(TRUNCATE)` errors on `:memory:`,
        // generating pointless noise with no functional effect). See #651.
        guard isFileBacked, !isReadOnly else { return }
        do {
            try dbWriter.writeWithoutTransaction { db in
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
    ///   `dbWriter.write` returns, outside the serial queue.
    /// - (b) Subscribers read committed state — `dbWriter.write` commits
    ///   before returning; `emit()` is post-commit.
    /// - (d) No event on throw — `dbWriter.write` rethrows; the emit code
    ///   after it is unreachable on throw.
    ///
    /// **Nesting (c):** `dbWriter.write` is NOT reentrant — calling
    /// `dbWriter.write` from inside `dbWriter.write` deadlocks. Public methods
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
        var result: T!
        // Use `unsafeReentrantWrite` + `db.inSavepoint` (instead of
        // `dbWriter.write`) so that `mutate` is **truly reentrant**: when called
        // from inside `withTransaction` (which already opened a write on the
        // serial queue), `unsafeReentrantWrite` runs inline (GRDB Case 2) and
        // `inSavepoint` nests as a SAVEPOINT — no reentrance trap, no "cannot
        // start a transaction within a transaction". When called standalone
        // (the common case), `unsafeReentrantWrite` dispatches normally (GRDB
        // Case 1) and `inSavepoint` opens its own IMMEDIATE transaction. The
        // event is computed inside the transaction (committed state) and
        // emitted after the write returns.
        try dbWriter.unsafeReentrantWrite { db in
            try db.inSavepoint {
                let r = try body(db)
                result = r
                // Compute the event inside the transaction (committed state).
                pending = try? event(r)
                return .commit
            }
        }
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

    /// The schema-bootstrap entry point — the GRDB equivalent of
    /// `SQLiteWikiStore.bootstrapSchema`. Reads `PRAGMA user_version` and:
    /// - **Fresh DB (version == 0):** runs `createFreshSchema(on:)` (the v37
    ///   end-state in one consolidated block) and stamps
    ///   `user_version = currentSchemaVersion`. The fresh path skips the
    ///   historical create→rename→drop churn of the ladder, exactly as
    ///   `createFreshSchemaV20()` does.
    /// - **Existing DB (version >= 1):** runs `migrate(from:in:)`, the proven
    ///   37-step `if version < N` ladder translated to GRDB's API. Each step
    ///   is guarded so a re-open at the same version (the steady-state case
    ///   for a store that's already migrated) is a no-op; genuine upgrades run
    ///   only the steps they owe.
    ///
    /// Both paths end at `user_version = currentSchemaVersion` (39), so the
    /// File Provider's read-only handle to the same WAL file never sees a
    /// half-migrated schema.
    ///
    /// `"PRAGMA user_version"` returns an `Int32` (SQLite pragma scalar). GRDB
    /// binds it as `Int` directly — `Int.fetchOne` avoids the
    /// `queryScalarText`→`Int(...) ?? 0` round-trip used by `SQLiteWikiStore`.
    private func migrateIfNeeded(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard version < Self.currentSchemaVersion else { return }
        if version == 0 {
            // Fresh DB: create the complete v38 schema in one block, then stamp.
            try Self.createFreshSchema(on: db)
            try db.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion);")
            return
        }
        // Existing DB: run the stepwise ladder (data-preserving). A rewind-of-
        // select steps never runs for a genuinely-current DB (the early-return
        // `guard` above fired).
        var v = version
        try migrate(from: &v, in: db)
    }

    /// The stepwise, idempotent migration ladder keyed on `PRAGMA user_version`.
    ///
    /// This is a faithful, line-by-line translation of
    /// `SQLiteWikiStore.migrate(from:)` to GRDB's API. Every SQL statement is
    /// preserved verbatim — the ladder is PROVEN (running in production across
    /// 37 schema versions); only the API calls change:
    /// - `exec(sql)` → `db.execute(sql: sql)`
    /// - `statement(sql)` + `bind(x, at: n)` + `step()` →
    ///   `db.execute(sql: sql, arguments: [x])` (one-shot; GRDB caches
    ///   prepared statements internally, no manual reset needed)
    /// - cursor `while try select.step()` loops → `Row.fetchAll(db, sql:)` into
    ///   a Swift array first (the SQLite statement discipline forbids stepping a
    ///   cursor at `SQLITE_ROW` across other operations on the same connection;
    ///   materializing first is the documented workaround, and GRDB's
    ///   `Row.fetchAll` does this by construction)
    /// - `withTransaction` → `db.inTransaction(.immediate)` (BEGIN IMMEDIATE →
    ///   savepoint nesting via `db.execute(sql: "SAVEPOINT …")` is automatic
    ///   in GRDB when nesting `inTransaction`, see `Database.inTransaction`)
    /// - `queryScalarText` COUNT checks → `Int.fetchOne(db, sql:) ?? 0`
    ///
    /// **Do not collapse these steps.** Each performs irreversible data
    /// migrations (renames, column adds, table rebuilds, content-addressed
    /// CAS-moves) that databases at every intermediate version depend on running
    /// in order. The `if version < N` guards keep a re-open idempotent.
    private func migrate(from version: inout Int, in db: Database) throws {

        // Step 0 → 1: the original v0 schema — pages, the unique slug index,
        // attachments, page_links. UNCHANGED from the v0 cut.
        if version < 1 {
            try db.execute(sql: """
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
            try db.execute(sql: "CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);")
            try db.execute(sql: """
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
            try db.execute(sql: """
            CREATE TABLE page_links (
                from_page_id TEXT NOT NULL,
                to_page_id TEXT NOT NULL,
                link_text TEXT NOT NULL,
                PRIMARY KEY (from_page_id, to_page_id),
                FOREIGN KEY(from_page_id) REFERENCES pages(id),
                FOREIGN KEY(to_page_id) REFERENCES pages(id)
            );
            """)
            try db.execute(sql: "PRAGMA user_version = 1;")
            version = 1
        }

        // Step 1 → 2 (Phase 5): the `ingested_files` table holds verbatim
        // dropped files — raw bytes + metadata, a NEW object kind, NOT tied to
        // a page (so it does NOT reuse `attachments`, which has a `page_id` FK).
        // Stored and served byte-for-byte; surfaced read-only under the
        // `sources/` tree.
        if version < 2 {
            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX ingested_files_created ON ingested_files(created_at);")
            try db.execute(sql: "PRAGMA user_version = 2;")
            version = 2
        }

        // Step 2 → 3: the singleton `system_prompt` table — the user-editable
        // "system prompt" document the managing agent reads each run,
        // projected read-only at the wiki root as `CLAUDE.md` AND `AGENTS.md`.
        // One row, pinned to `id = 1` by a CHECK so there can only ever be one.
        // Seeded with `SystemPrompt.defaultBody` so the document exists from
        // day one.
        if version < 3 {
            try db.execute(sql: """
            CREATE TABLE system_prompt (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                body_markdown TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1
            );
            """)
            // Seed the singleton via a bound statement (the default body has
            // quotes/newlines — never interpolate it into the DDL string).
            try db.execute(sql: """
            INSERT INTO system_prompt (id, body_markdown, updated_at, version)
            VALUES (1, ?, ?, 1);
            """, arguments: [SystemPrompt.defaultBody, Date().timeIntervalSince1970])
            try db.execute(sql: "PRAGMA user_version = 3;")
            version = 3
        }

        // Step 3 → 4 (Phase B): the append-only `log` table — one ULID-keyed
        // row per agent operation (an ingest, a query, a lint). `id` is a ULID
        // so it sorts == chronological; `ts` carries the wall-clock time the
        // row was appended; `note` is optional. NOT a singleton: each
        // `wikictl log append` INSERTs a fresh row. Projected read-only at the
        // root as `log.md`.
        if version < 4 {
            try db.execute(sql: """
            CREATE TABLE log (
                id TEXT PRIMARY KEY,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                note TEXT
            );
            """)
            try db.execute(sql: "PRAGMA user_version = 4;")
            version = 4
        }

        // Step 4 → 5 (Phase B): the singleton `wiki_index` table — the curated
        // catalog document the managing agent rewrites wholesale on each ingest,
        // projected read-only at the root as `index.md`. Modeled EXACTLY on
        // `system_prompt` (v2→3): one row pinned to `id = 1` by a CHECK, a
        // `version` bumped on every write, seeded with
        // `WikiIndex.defaultBody` so the document exists from day one.
        if version < 5 {
            try db.execute(sql: """
            CREATE TABLE wiki_index (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                body_markdown TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL,
                version INTEGER NOT NULL DEFAULT 1
            );
            """)
            // Seed the singleton via a bound statement (the default body has
            // newlines — never interpolate it into the DDL string).
            try db.execute(sql: """
            INSERT INTO wiki_index (id, body_markdown, updated_at, version)
            VALUES (1, ?, ?, 1);
            """, arguments: [WikiIndex.defaultBody, Date().timeIntervalSince1970])
            try db.execute(sql: "PRAGMA user_version = 5;")
            version = 5
        }

        // Step 5 → 6: record WHICH ingested files the agent has actually
        // summarized into the wiki. `ingested_at` stays NULL until the agent
        // finishes an ingest and stamps it via `wikictl log append --kind
        // ingest --source <id>`. The UI's "Processed" badge reads this
        // deterministic flag instead of fuzzy-matching the agent's free-text
        // log titles (which the agent is free to phrase however it likes, so
        // the match silently failed).
        if version < 6 {
            try db.execute(sql: "ALTER TABLE ingested_files ADD COLUMN ingested_at REAL;")
            try db.execute(sql: "PRAGMA user_version = 6;")
            version = 6
        }

        // v6 → v7: page embeddings for semantic search.
        // The BLOB holds 512 × Float32 (2048 bytes) produced by Apple
        // NLEmbedding. ON DELETE CASCADE mirrors the v0 attachment FK:
        // removing a page removes its embedding.
        if version < 7 {
            try db.execute(sql: """
            CREATE TABLE page_embeddings (
                page_id TEXT PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL
            );
            """)
            try db.execute(sql: "PRAGMA user_version = 7;")
            version = 7
        }

        // v7 → v8: append-only version chain for processed markdown.
        // Full-text snapshots (never deltas). ULID-sorted: MAX(id) == HEAD.
        // ON DELETE CASCADE so removing a file cleans up its version chain.
        // Migration is additive; no backfill — versions are seeded lazily.
        if version < 8 {
            try db.execute(sql: """
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
            try db.execute(sql: """
            CREATE INDEX file_markdown_versions_file
                ON file_markdown_versions(file_id, id);
            """)
            try db.execute(sql: "PRAGMA user_version = 8;")
            version = 8
        }

        // v8 → v9: provenance for files ingested from Zotero. Two nullable TEXT
        // columns capture the parent library item at ingest time so the detail
        // view can show "From Zotero: <title>" and link back without re-hitting
        // the API (the item could be renamed/deleted between ingest and view).
        // NULL for drag-drop / URL / folder-import (no Zotero provenance).
        if version < 9 {
            try db.execute(sql: "ALTER TABLE ingested_files ADD COLUMN zotero_item_key TEXT;")
            try db.execute(sql: "ALTER TABLE ingested_files ADD COLUMN zotero_item_title TEXT;")
            try db.execute(sql: "PRAGMA user_version = 9;")
            version = 9
        }

        // v9 → v10: rename "ingested file" → "source" throughout. The main
        // table becomes `sources`; the processed-markdown version chain
        // becomes `source_markdown_versions`. A new `display_name` column
        // defaults to the original filename. `source_links` records
        // [[source:…]] references from wiki pages (mirrors `page_links` but
        // FKs to `sources(id)`).
        // SQLite's ALTER TABLE RENAME TO automatically updates FK references
        // in `source_markdown_versions.file_id` to point to `sources(id)`.
        if version < 10 {
            try db.execute(sql: "ALTER TABLE ingested_files RENAME TO sources;")
            try db.execute(sql: "ALTER TABLE sources ADD COLUMN display_name TEXT;")
            try db.execute(sql: "UPDATE sources SET display_name = filename;")
            try db.execute(sql: "ALTER TABLE file_markdown_versions RENAME TO source_markdown_versions;")
            try db.execute(sql: """
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id),
                link_text    TEXT NOT NULL,
                PRIMARY KEY (from_page_id, to_source_id)
            );
            """)
            try db.execute(sql: "PRAGMA user_version = 10;")
            version = 10
        }

        // v10 → v11: add ON DELETE CASCADE to source_links.to_source_id.
        // SQLite cannot ALTER an FK constraint in place, so rebuild the table
        // (rename old → create new with the cascade → copy rows → drop old).
        // source_links is a leaf join table (nothing FKs to it), so the rename
        // is safe. The rebuild is data-preserving for DBs that already have
        // Phase B rows, and a no-op rebuild on empty ones. Mirrors the cascade
        // already on source_markdown_versions (v8).
        if version < 11 {
            try db.execute(sql: "ALTER TABLE source_links RENAME TO source_links_v10;")
            try db.execute(sql: """
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                link_text    TEXT NOT NULL,
                PRIMARY KEY (from_page_id, to_source_id)
            );
            """)
            try db.execute(sql: """
            INSERT INTO source_links (from_page_id, to_source_id, link_text)
            SELECT from_page_id, to_source_id, link_text FROM source_links_v10;
            """)
            try db.execute(sql: "DROP TABLE source_links_v10;")
            try db.execute(sql: "PRAGMA user_version = 11;")
            version = 11
        }

        // v11 → v12: source embeddings for semantic source search.
        // Mirrors page_embeddings (v7). ON DELETE CASCADE:
        // removing a source removes its embedding. FK target is sources(id)
        // (renamed from ingested_files in v10). `foreign_keys=ON` is set in
        // the configuration block.
        if version < 12 {
            try db.execute(sql: """
            CREATE TABLE source_embeddings (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL
            );
            """)
            try db.execute(sql: "PRAGMA user_version = 12;")
            version = 12
        }

        // v12 → v13: FTS5/BM25 full-text search over title + body.
        // HISTORICAL: this step shipped FTS5 (phase 1 of the original search
        // stack). #634 dropped FTS5 — the v37→v38 migration step now `DROP`s
        // these tables + triggers on existing DBs, and `createFreshSchema`
        // never creates them. The historical step is preserved verbatim so a
        // DB at v12 follows the proven upgrade path; the v38 cleanup then
        // takes them away cleanly. The prose below describes the historical
        // intent — FTS5 is GONE post-#634 (Tantivy is the sole BM25 leg), and
        // the semantic cosine leg is now Swift-side (`VectorCosine`,
        // issue #628). `RankFusion.rrf` fuses the two legs unchanged.
        //
        // PAGES: body (body_markdown) is inline on `pages`, so use
        // external-content FTS5 keyed on pages.rowid, maintained by AFTER
        // INSERT/UPDATE/DELETE triggers. This needs NO changes to the
        // page-write path — createPage / updatePage / deletePage already write
        // `pages`, so the triggers fire. Existing rows were backfilled lazily by
        // the (now-removed) `rebuildFTS()` via the FTS5 'rebuild' command; new
        // rows indexed immediately.
        //
        // SOURCES: body is the HEAD of the version chain
        // (source_markdown_versions), NOT inline on `sources`, so we index a
        // sidecar `source_search` — one row per source holding the current
        // title + head body — maintained by appendProcessedMarkdown /
        // renameSource via upsertSourceSearch(). The trigger kept sources_fts
        // in sync; deleting a source cascaded to source_search (FK ON DELETE
        // CASCADE) whose trigger removed the FTS row.
        if version < 13 {
            try db.execute(sql: """
            CREATE VIRTUAL TABLE pages_fts USING fts5(
                title, body_markdown,
                content='pages', content_rowid='rowid',
                tokenize='porter');
            """)
            try db.execute(sql: """
            CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
              INSERT INTO pages_fts(rowid, title, body_markdown)
                VALUES (new.rowid, new.title, new.body_markdown);
            END;
            """)
            try db.execute(sql: """
            CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
              INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
                VALUES ('delete', old.rowid, old.title, old.body_markdown);
            END;
            """)
            try db.execute(sql: """
            CREATE TRIGGER pages_fts_au AFTER UPDATE ON pages BEGIN
              INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
                VALUES ('delete', old.rowid, old.title, old.body_markdown);
              INSERT INTO pages_fts(rowid, title, body_markdown)
                VALUES (new.rowid, new.title, new.body_markdown);
            END;
            """)

            try db.execute(sql: """
            CREATE TABLE source_search (
                source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                title     TEXT NOT NULL,
                body      TEXT NOT NULL
            );
            """)
            try db.execute(sql: """
            CREATE VIRTUAL TABLE sources_fts USING fts5(
                title, body,
                content='source_search', content_rowid='rowid',
                tokenize='porter');
            """)
            try db.execute(sql: """
            CREATE TRIGGER sources_fts_ai AFTER INSERT ON source_search BEGIN
              INSERT INTO sources_fts(rowid, title, body)
                VALUES (new.rowid, new.title, new.body);
            END;
            """)
            try db.execute(sql: """
            CREATE TRIGGER sources_fts_ad AFTER DELETE ON source_search BEGIN
              INSERT INTO sources_fts(sources_fts, rowid, title, body)
                VALUES ('delete', old.rowid, old.title, old.body);
            END;
            """)
            try db.execute(sql: """
            CREATE TRIGGER sources_fts_au AFTER UPDATE ON source_search BEGIN
              INSERT INTO sources_fts(sources_fts, rowid, title, body)
                VALUES ('delete', old.rowid, old.title, old.body);
              INSERT INTO sources_fts(rowid, title, body)
                VALUES (new.rowid, new.title, new.body);
            END;
            """)
            try db.execute(sql: "PRAGMA user_version = 13;")
            version = 13
        }

        // v13 → v14: per-chunk embeddings (RAG-style). Replaces the old
        // one-embedding-per-document model (`page_embeddings`,
        // `source_embeddings`) with one embedding BLOB per text chunk, so a
        // query can match the single best passage of a large document
        // (best-chunk-per-doc ranking) instead of a blurry document centroid.
        // Also fixes NLEmbedding's hard limit: a whole document fed to
        // NLEmbedding throws an uncatchable std::bad_alloc above ~250k chars;
        // chunking keeps each embedding input small.
        //
        // FK ON DELETE CASCADE: deleting a page/source removes its chunks. The
        // semantic query ranks by each document's best-matching chunk (Swift-side
        // dot product over the L2-normalized BLOBs — `VectorCosine`,
        // issue #628).
        if version < 14 {
            try db.execute(sql: """
            CREATE TABLE page_chunks (
                page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (page_id, chunk_idx)
            ) WITHOUT ROWID;
            """)
            try db.execute(sql: """
            CREATE TABLE source_chunks (
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (source_id, chunk_idx)
            ) WITHOUT ROWID;
            """)
            // The old single-embedding tables are superseded and unused after
            // v14.
            try db.execute(sql: "DROP TABLE IF EXISTS page_embeddings;")
            try db.execute(sql: "DROP TABLE IF EXISTS source_embeddings;")
            try db.execute(sql: "PRAGMA user_version = 14;")
            version = 14
        }

        if version < 15 {
            try db.execute(sql: """
            CREATE TABLE embedding_meta (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                embedder TEXT NOT NULL
            );
            """)
            try db.execute(sql: "INSERT INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")
            try db.execute(sql: "PRAGMA user_version = 15;")
            version = 15
        }

        if version < 16 {
            try db.execute(sql: """
            CREATE TABLE view_nodes (
                id            TEXT PRIMARY KEY,
                parent_id     TEXT REFERENCES view_nodes(id) ON DELETE CASCADE,
                position      INTEGER NOT NULL DEFAULT 0,
                kind          TEXT NOT NULL,
                label         TEXT,
                target_id     TEXT
            );
            """)
            try db.execute(sql: "CREATE INDEX view_nodes_parent ON view_nodes(parent_id, position);")
            try db.execute(sql: "PRAGMA user_version = 16;")
            version = 16
        }

        if version < 17 {
            // Rename view_nodes → bookmark_nodes.
            try db.execute(sql: "ALTER TABLE view_nodes RENAME TO bookmark_nodes;")
            try db.execute(sql: "DROP INDEX IF EXISTS view_nodes_parent;")
            try db.execute(sql: "CREATE INDEX bookmark_nodes_parent ON bookmark_nodes(parent_id, position);")
            try db.execute(sql: "PRAGMA user_version = 17;")
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
            try sanitizeStoredNames(in: db)
            try db.execute(sql: "PRAGMA user_version = 18;")
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
            let hasColumn = try Self.hasColumn("content_hash", on: "sources", in: db)
            if !hasColumn {
                try db.execute(sql: "ALTER TABLE sources ADD COLUMN content_hash TEXT;")
            }
            let hasIndex = try Self.hasIndex("sources_content_hash", in: db)
            if !hasIndex {
                try db.execute(sql: "CREATE INDEX sources_content_hash ON sources(content_hash);")
            }
            try Self.backfillContentHashes(in: db)
            try db.execute(sql: "PRAGMA user_version = 19;")
            version = 19
        }

        // ---- v19 → v37: graph-model phases + chat + workspaces (data
        // migrations that must run for a genuine upgrade). Each helper below
        // is a faithful translation of the SQLiteWikiStore counterpart. ----

        if version < 20 {
            try Self.migrateV19ToV20(in: db)
            try db.execute(sql: "PRAGMA user_version = 20;")
            version = 20
        }

        if version < 21 {
            try Self.migrateV20ToV21(in: db)
            try db.execute(sql: "PRAGMA user_version = 21;")
            version = 21
        }

        if version < 22 {
            try Self.migrateV21ToV22(in: db)
            try db.execute(sql: "PRAGMA user_version = 22;")
            version = 22
        }

        if version < 23 {
            try migrateV22ToV23(in: db)
            try db.execute(sql: "PRAGMA user_version = 23;")
            version = 23
        }

        // Step 23 → 25 (issue #119 phase 1): persisted chat history — `chats` +
        // `chat_messages`. Purely additive. `IF NOT EXISTS` — a no-op on a DB
        // that already has them. (v24 is a reserved slot, never stamped; the
        // smv.content drop is appended as v26 below so DBs already at v25 run
        // it.)
        if version < 25 {
            try Self.createChatTablesV23(in: db)
            try db.execute(sql: "PRAGMA user_version = 25;")
            version = 25
        }

        // Step 25 → 26 (graph-model Phase 2 close-out): drop the now-dead
        // `source_markdown_versions.content` column. Post-v21 every derived-
        // markdown row is content-addressed in `blobs` (the inline column was
        // `''` and unread), so finishing the CAS-only model removes it
        // entirely. Appended at the TOP — not inserted at the reserved v24
        // slot — because a DB already at v25 would skip a
        // `version < 24` step; the drop must be the newest version to run on
        // every existing DB. Idempotent: a no-op where the column is already
        // gone (fresh DBs never create it). Without this, the store's
        // blob-only readers throw `no such column: smv.content` against a
        // column-less DB — the bug that left byteless podcast transcripts
        // projecting as empty `.md` files.
        if version < 26 {
            let hasSMVContent = try Self.hasColumn("content", on: "source_markdown_versions", in: db)
            if hasSMVContent {
                try db.execute(sql: "ALTER TABLE source_markdown_versions DROP COLUMN content;")
            }
            try db.execute(sql: "PRAGMA user_version = 26;")
            version = 26
        }

        // Step 26 → 27 (issue #242): add `created_at`/`updated_at` to
        // `bookmark_nodes` so the UI can show "date added"/"date updated"
        // (companion sort/filter in #241). Additive ALTER (NOT NULL DEFAULT 0),
        // then backfill every existing row to `now` — legacy nodes have no
        // recorded creation time, so migration time is the best available proxy
        // (and on a brand-new DB forced through the ladder there are no rows).
        // Column defs match the fresh-path CREATE TABLE byte-for-byte. 
        // Idempotent: pragma_table_info-guarded so a rewound-for-testing DB
        // stamps v27 without re-adding the columns.
        if version < 27 {
            // `bookmark_nodes` is created at v16, so any DB that reached here
            // through the real ladder already has it. But hand-crafted test
            // fixtures (e.g. a minimal v19 DB with only `sources`) may be
            // stamped at ≥16 without the table — skip the column work in that
            // case rather than crash mid-migration. There's nothing to backfill
            // when the table is absent.
            let tableExists = try Self.tableExists("bookmark_nodes", in: db)
            if tableExists {
                let hasCreatedAt = try Self.hasColumn("created_at", on: "bookmark_nodes", in: db)
                if !hasCreatedAt {
                    try db.execute(sql: "ALTER TABLE bookmark_nodes ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
                    try db.execute(sql: "ALTER TABLE bookmark_nodes ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
                    let now = Date().timeIntervalSince1970
                    try db.execute(sql: "UPDATE bookmark_nodes SET created_at = \(now), updated_at = \(now);")
                }
            }
            try db.execute(sql: "PRAGMA user_version = 27;")
            version = 27
        }

        // Step 27 → 28 (issue #245): semantic + FTS search over chats. Adds
        // `chat_chunks` (per-chunk cosine embeddings) + the `chat_search` FTS
        // sidecar + `chats_fts` external-content index, mirroring the existing
        // pages/sources search pipeline. Purely additive (`IF NOT EXISTS`); a
        // brand-new DB forced through the ladder has no chat rows to index.
        if version < 28 {
            try Self.createChatSearchTables(in: db)
            try db.execute(sql: "PRAGMA user_version = 28;")
            version = 28
        }

        // Step 28 → 29 (remove-readonly-chat-mode): data-only sweep — the
        // read-only Ask chat mode is deleted; every chat is now write-capable
        // (`.edit`). Rewrite any legacy `kind = 'ask'` rows to `'edit'` so the
        // single-case `ChatKind` enum decodes them. No schema change —
        // `user_version=29` is only a run-once guard (the v23 precedent). A
        // fresh DB has no chat rows, so the UPDATE is a no-op there.
        if version < 29 {
            try Self.migrateV28ToV29(in: db)
            try db.execute(sql: "PRAGMA user_version = 29;")
            version = 29
        }

        // Step 29 → 30 (W0 — page versioning, PR #312): adds the
        // `page_versions` table (append-only, blob-backed page body chain),
        // rebuilds `refs` to drop the `owner_id REFERENCES sources(id)` FK
        // (replaced by a CHECK on `kind` so `page-content` refs can use a page
        // id as `owner_id`), and seeds one root version per existing page
        // (blob of current body_markdown). No ref rows are written for the root
        // versions — the default-active rule (no ref → head is MAX(id)) means
        // main tracks latest, exactly like sources did at v20.
        if version < 30 {
            try migrateV29ToV30(in: db)
            try db.execute(sql: "PRAGMA user_version = 30;")
            version = 30
        }

        // Step 30 → 31 (W1 — workspaces, PR #312): creates the `workspaces` +
        // `workspace_refs` tables for multi-writer ingestion isolation. Purely
        // additive (`IF NOT EXISTS`); no existing data to backfill.
        if version < 31 {
            try Self.createWorkspacesV31(in: db)
            try db.execute(sql: "PRAGMA user_version = 31;")
            version = 31
        }

        // Step 31 → 32 (W3 — conflict resolution, PR #312): creates the
        // `workspace_conflicts` table for persisting per-page conflict
        // details when a workspace is parked as `conflicted`. Purely
        // additive.
        if version < 32 {
            try Self.createWorkspaceConflictsV32(in: db)
            try db.execute(sql: "PRAGMA user_version = 32;")
            version = 32
        }

        // Step 32 → 33 (#131 — provenance frontmatter): adds `created_by` and
        // `last_edited_by` nullable text columns to `pages` (agent/model
        // attribution), and a `technique` nullable text column to
        // `source_markdown_versions` (which extraction backend produced it).
        // All additive — existing rows get NULL, which the frontmatter layer
        // treats as "unknown" and omits.
        if version < 33 {
            try Self.migrateV32ToV33(in: db)
            try db.execute(sql: "PRAGMA user_version = 33;")
            version = 33
        }

        // Step 33 → 34 (#multi-writer-hardening Phase 3 — head-ref invariant):
        // backfills a `page-content` ref for every page that lacks one, and
        // seeds a root version for pages that have none (agent-created pages
        // via blind `wikictl page add` never created a version row). After
        // v34, every page has an explicit ref → the MAX(id) fallback in
        // `pageHeadVersionIDLocked` is dead code for migrated data.
        if version < 34 {
            try migrateV33ToV34(in: db)
            try db.execute(sql: "PRAGMA user_version = 34;")
            version = 34
        }

        // Step 34 → 35 (#multi-writer-hardening Phase 5 — created-page
        // staging): Rebuilds `workspace_refs` to make `version_id` nullable
        // and add `blob_hash` + `title` columns. SQLite cannot ALTER TABLE to
        // relax a NOT NULL constraint, so a table rebuild
        // (CREATE-INSERT-DROP-RENAME) is required. Existing rows are preserved
        // with their original `version_id` values; new `blob_hash`/`title`
        // columns are NULL.
        if version < 35 {
            try Self.migrateV34ToV35(in: db)
            try db.execute(sql: "PRAGMA user_version = 35;")
            version = 35
        }

        // Step 35 → 36 (issue #411 — chat summary): adds nullable `summary`
        // and `summary_at` columns to `chats` so the sidebar can show a
        // one-line summary of the model's first response. Simple ALTER — no
        // table rebuild needed for nullable columns.
        if version < 36 {
            try Self.migrateV35ToV36(in: db)
            try db.execute(sql: "PRAGMA user_version = 36;")
            version = 36
        }

        // Step 36 → 37 (issue #477 — wiki metadata): creates a
        // `wiki_metadata` key-value table for persisting one-time work flags
        // (e.g. the link-reconcile version) so they survive model recreation
        // between launches. Purely additive — `CREATE TABLE IF NOT EXISTS`.
        if version < 37 {
            try Self.createWikiMetadataTable(in: db)
            try db.execute(sql: "PRAGMA user_version = 37;")
            version = 37
        }

        // Step 37 → 38 (issue #634 — drop FTS5): Tantivy is now the sole BM25
        // search path (PR #649 routed all the FTS5-only call sites through the
        // Tantivy `bm25Leg` seam; the FTS5 leg is no longer queried at all).
        // The external-content virtual tables + their AFTER INSERT/UPDATE/DELETE
        // sync triggers are derived data — dropping them loses nothing, the
        // Tantivy sidecar rebuilds independently, and the `source_search` /
        // `chat_search` content sidecars are kept as ordinary tables (still
        // written by `upsertSourceSearch`/`upsertChatSearch` — harmless orphans
        // now that no FTS5 reader remains). `DROP TABLE IF EXISTS` /
        // `DROP TRIGGER IF EXISTS` so a fresh-DB forced through the ladder (which
        // never created them at v13/v28) is a no-op. Mirrors the SQLiteWikiStore
        // ladder's v37→v38 step.
        if version < 38 {
            try Self.dropFTS5TablesAndTriggers(in: db)
            try db.execute(sql: "PRAGMA user_version = 38;")
            version = 38
        }

        // Step 38 → 39 (page provenance — #page-provenance): forward-only
        // bump. The write-path change (route `updatePage` CAS-off through
        // `appendPageVersionLocked`, swap `legacyImportAgentID → ensureAgent`)
        // is what guarantees correctness for NEW saves; this step is the
        // explicit `user_version` bump so existing v38 DBs re-open as v39 and
        // a fresh DB lands at v39. NO backfill — pre-v39 page activities stay
        // on the shared `legacy-import` agent (degraded, same as today); the
        // `pageOrigin(pageID:)` read accessor degrades `agentName` to
        // `"unknown"` and `agentKind` to `"software"` for those rows. A
        // future, guarded, irreversible backfill can repoint historical
        // `activity.agent_id` from `last_edited_by` behind a `wiki_metadata`
        // flag (#page-provenance §5.2 — Phase C, deferred).
        //
        // ⚠ LOAD-BEARING ordering: this step MUST precede the catch-all
        // fallback immediately below. The fallback's guard is keyed on
        // `currentSchemaVersion` (40 now), so once this constant is bumped it
        // short-circuits: it re-runs `dropFTS5TablesAndTriggers` (harmless —
        // `DROP … IF EXISTS`) and stamps `user_version = 40`, executing NONE
        // of any new step above it. Any new v40 migration work belongs INSIDE
        // this block (before the fallback), not as a sibling after it.
        if version < 39 {
            try db.execute(sql: "PRAGMA user_version = 39;")
            version = 39
        }

        // Step 39 → 40 (chat-message summary, plans/chat-summary.md): adds
        // nullable summary columns to `chat_messages` so each assistant message
        // can carry a cached one-line summary. Mirrors `migrateV35ToV36`
        // (issue #411): guarded `tableColumnInfo` column-presence check +
        // `db.inTransaction(.immediate)` + `ALTER TABLE ADD COLUMN`. The columns
        // are nullable so the migration is a pure schema change with no backfill
        // — pre-feature rows surface as `summary = NULL` and are lazily
        // summarized on first view (chat-summary plan §6.2).
        //
        // LOAD-BEARING: MUST precede the catch-all fallback immediately below
        // (same reason as the v38→39 step above — the fallback re-runs
        // `dropFTS5TablesAndTriggers` and stamps
        // `user_version = currentSchemaVersion`, executing none of any new step
        // after it).
        if version < 40 {
            let columns = try Self.tableColumnInfo("chat_messages", in: db)
            if !columns.contains("summary") {
                try db.inTransaction(.immediate) {
                    try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN summary TEXT;")
                    try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN summary_kind TEXT;")
                    try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN summary_at REAL;")
                    return .commit
                }
            }
            try db.execute(sql: "PRAGMA user_version = 40;")
            version = 40
        }

        // v40→v41: migrate stored system prompts from `$WIKICTL` → bare
        // `wikictl` (which is on PATH), and `wikictl page upsert` →
        // `wikictl page add`. The default prompt was already updated, but
        // existing wikis keep their seeded copy forever (`INSERT OR IGNORE`),
        // and `$WIKICTL` doesn't always expand correctly in the agent's
        // subprocess shell. Idempotent: a no-op on already-migrated prompts.
        // Step 41 → 42: remove the user-editable system_prompt table. The system
        // prompt is now always the compiled `SystemPrompt.defaultBody`
        // (`GeneratedPrompts.systemPromptDefault`). The user-editable copy could drift
        // from the compiled default; removing the table eliminates the drift. The
        // changeToken's systemPrompt fold now derives from a stable hash of the
        // compiled body (see SystemPromptTokenContributor).
        if version < 42 {
            try db.execute(sql: "DROP TABLE IF EXISTS system_prompt;")
            try db.execute(sql: "PRAGMA user_version = 42;")
            version = 42
        }

        // Step 41 → 42 (was 40 → 41): migrate $WIKICTL → wikictl in the system
        // prompt body. This migration is no longer active (the table is dropped in
        // the step above), but is left in place for historical reference.
        if version < 41 {
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT body_markdown FROM system_prompt WHERE id = 1;"
            ),
               let body = row["body_markdown"] as String?,
               body.contains("$WIKICTL") {
                let migrated = body
                    .replacingOccurrences(of: "$WIKICTL", with: "wikictl")
                    .replacingOccurrences(
                        of: "wikictl page upsert", with: "wikictl page add"
                    )
                try db.execute(
                    sql: "UPDATE system_prompt SET body_markdown = ?, updated_at = ? WHERE id = 1;",
                    arguments: [migrated, Date.timeIntervalSinceReferenceDate]
                )
            }
            try db.execute(sql: "PRAGMA user_version = 41;")
            version = 41
        }

        // v42→v43: add acp_session_id to the chats table (#830). Stores the ACP
        // session ID so a continued chat can attempt resumeSession/loadSession
        // instead of re-seeding a preamble. Nullable: NULL for all existing
        // chats (they predate resume) and for chats whose resume permanently
        // failed. Idempotent via the column-existence guard.
        if version < 43 {
            if !(try Self.hasColumn("acp_session_id", on: "chats", in: db)) {
                try db.execute(sql: "ALTER TABLE chats ADD COLUMN acp_session_id TEXT;")
            }
            try db.execute(sql: "PRAGMA user_version = 43;")
            version = 43
        }

        // v43->v44: incremental in-flight turn persistence (#826). Adds
        // `is_draft` (0 = finalized, 1 = a mid-generation checkpoint not yet
        // finalized) and `draft_handle` (a launcher-generated ULID used as the
        // upsert key for streaming rows) to `chat_messages`. Both nullable /
        // default-0 so every pre-existing row is finalized with no backfill.
        // The partial unique index allows many NULL handles (standard SQLite
        // behavior) while enforcing one row per live handle. #830/#849 own
        // v43; this plan owns v43->v44.
        if version < 44 {
            let columns = try Self.tableColumnInfo("chat_messages", in: db)
            if !columns.contains("is_draft") {
                try db.inTransaction(.immediate) {
                    try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN is_draft INTEGER NOT NULL DEFAULT 0;")
                    try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN draft_handle TEXT;")
                    return .commit
                }
            }
            if !(try Self.hasIndex("chat_messages_draft_handle", in: db)) {
                try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_draft_handle
                    ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL;
                """)
            }
            try db.execute(sql: "PRAGMA user_version = 44;")
            version = 44
        }

        // Catch-all fallback: any DB older than `currentSchemaVersion` whose
        // per-step work has not been added above (the steady-state guard for a
        // genuine currentSchemaVersion bump). Drops FTS5 + stamps
        // `user_version` so the read-only File Provider handle never sees a
        // half-migrated schema. Idempotent (`DROP … IF EXISTS`). Mirrors the
        // historical SQLiteWikiStore ladder terminator. The version-specific
        // step above is the one that runs on a real upgrade; this only fires
        // if a future contributor bumps `currentSchemaVersion` without adding
        // an explicit step (defensive — emits a loud reminder in the form of
        // a redundant `PRAGMA user_version = N`).
        if version < Self.currentSchemaVersion {
            try Self.dropFTS5TablesAndTriggers(in: db)
            try db.execute(sql: "PRAGMA user_version = \(Self.currentSchemaVersion);")
            version = Self.currentSchemaVersion
        }
    }

    // MARK: - Schema introspection helpers (idempotency guards)

    /// True when `table.column` exists. Mirrors the
    /// `pragma_table_info` COUNT column-existence check used throughout the
    /// `SQLiteWikiStore` ladder.
    private static func hasColumn(
        _ column: String, on table: String, in db: Database
    ) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name='\(column)';"
        ) ?? 0
        return count != 0
    }

    /// True when a named index exists in `sqlite_master`.
    private static func hasIndex(_ name: String, in db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='\(name)';"
        ) ?? 0
        return count != 0
    }

    /// True when a table named `name` exists.
    private static func tableExists(_ name: String, in db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(name)';"
        ) ?? 0
        return count != 0
    }

    /// Returns the column-name set of `table` via `pragma_table_info`. Mirrors
    /// `SQLiteWikiStore.tableColumnInfo`.
    private static func tableColumnInfo(_ table: String, in db: Database) throws -> Set<String> {
        let rows = try String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_info('\(table)');"
        )
        return Set(rows)
    }

    /// Run a one-row PRAGMA/SELECT and return column 0 as `String`. Mirrors
    /// `SQLiteWikiStore.queryScalarText` for the few ladder sites that need a
    /// scalar text value (e.g. `SELECT sql FROM sqlite_master …`).
    private static func queryScalarText(_ sql: String, in db: Database) throws -> String {
        try String.fetchOne(db, sql: sql) ?? ""
    }

    // MARK: - Shared table builders (fresh-path + migration step parity)

    /// Create the five graph-model objects tables (§4.1–4.3): `blobs`,
    /// `agents`, `activities`, `source_versions`, `refs`. Idempotent
    /// (`IF NOT EXISTS`) — called by both the fresh path (via
    /// `createFreshSchema`) and the v19→20 migration step so the two stay
    /// schema-identical.
    private static func createObjectsTablesV20(in db: Database) throws {
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
        // UNIQUE partial index for byteless-source dedup: keeps the
        // external_identity lookup O(log n) AND provides a DB-level backstop
        // against the SELECT-then-INSERT TOCTOU (a concurrent wikictl writer
        // could pass the dedup check and both insert). NULL external_identity
        // values are not equal in SQLite, so multiple NULLs coexist fine.
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
    }

    /// Create the `page_versions` table (v30, W0 — PR #312). Mirrors the
    /// `source_versions` pattern: append-only, ULID-ordered chain, blob-backed
    /// body, PROV activity linkage. `IF NOT EXISTS`: idempotent so a DB rewound
    /// for testing already has it.
    private static func createPageVersionsV30(in db: Database) throws {
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
    }

    /// Create the workspace tables (v31, W1 — PR #312). Called by both the
    /// fresh path and the v30→31 migration step so the two stay
    /// schema-identical.
    private static func createWorkspacesV31(in db: Database) throws {
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
    }

    /// Create the `workspace_conflicts` table (v32, W3 — PR #312). 
    /// `IF NOT EXISTS`: idempotent.
    private static func createWorkspaceConflictsV32(in db: Database) throws {
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
    }

    /// Create the two persisted-chat-history tables (issue #119 phase 1):
    /// `chats` (one row per chat) and `chat_messages` (one row per
    /// persistable `AgentEvent`, `event_json` verbatim). Called by both the
    /// fresh path and the v23→25 migration step so the two stay
    /// schema-identical.
    private static func createChatTablesV23(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chats (
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            title           TEXT NOT NULL,
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL,
            summary         TEXT,
            summary_at      REAL,
            acp_session_id  TEXT
        );
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS chats_updated ON chats(updated_at);")
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id          TEXT PRIMARY KEY,
            chat_id     TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            seq         INTEGER NOT NULL,
            role        TEXT NOT NULL,
            event_json  TEXT NOT NULL,
            text        TEXT NOT NULL DEFAULT '',
            created_at  REAL NOT NULL,
            summary     TEXT,
            summary_kind TEXT,
            summary_at  REAL,
            is_draft    INTEGER NOT NULL DEFAULT 0,
            draft_handle TEXT
        );
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_seq ON chat_messages(chat_id, seq);")
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_draft_handle
            ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL;
        """)
    }

    /// Create the chat-search tables (issue #245): `chat_chunks` (per-chunk
    /// cosine embeddings, mirroring `page_chunks`/`source_chunks`) and the
    /// `chat_search` content sidecar (kept as an ordinary table post-#634 —
    /// no FTS5 virtual table on top; Tantivy is the sole BM25 leg).
    private static func createChatSearchTables(in db: Database) throws {
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
    }

    /// Create the `wiki_metadata` key-value table (v37, issue #477). Stores
    /// one-time work flags like the link-reconcile version so they survive
    /// model recreation between launches. `IF NOT EXISTS` — idempotent for DBs
    /// rewound in testing.
    private static func createWikiMetadataTable(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS wiki_metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - FTS5 drop (issue #634, v37 → v38)

    /// Drop the FTS5 external-content virtual tables + their sync triggers.
    /// Tantivy is now the sole BM25 leg (PR #649); the FTS5 leg has no readers.
    /// The `source_search` / `chat_search` content sidecars are kept as ordinary
    /// tables (still written by `upsertSourceSearch`/`upsertChatSearch` — they
    /// become harmless orphan writes). All `DROP` statements are `IF EXISTS` so
    /// a fresh DB forced through the ladder (which never created them at v13/v28)
    /// is a no-op. Mirrors the SQLiteWikiStore ladder's v37→v38 step.
    private static func dropFTS5TablesAndTriggers(in db: Database) throws {
        // Triggers first: a trigger on a content table references its FTS5
        // target, so dropping triggers before tables is the safe order. Each
        // trigger was created `IF NOT EXISTS`-guarded in `createFreshSchema` /
        // the v12→v13 / v27→v28 migration steps.
        let triggers = [
            "pages_fts_ai", "pages_fts_ad", "pages_fts_au",
            "sources_fts_ai", "sources_fts_ad", "sources_fts_au",
            "chats_fts_ai", "chats_fts_ad", "chats_fts_au",
        ]
        for trigger in triggers {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger);")
        }
        // The virtual tables themselves (with their shadow b-trees).
        for table in ["pages_fts", "sources_fts", "chats_fts"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table);")
        }
    }

    // MARK: - Data-migration helpers (v19 → v38)

    /// The v19→20 migration step (graph-model Phase 1): move source content
    /// out of the mutable `sources.content` column into immutable,
    /// content-addressed `blobs`, an append-only `source_versions` chain, a
    /// PROV-DM `agents`/`activities` substrate, and a single mutable `refs`
    /// pointer. Each existing source gets one v1 version + one ref + a blob
    /// whose hash reuses the v19 `content_hash` (same SHA-256). Then
    /// `sources.content` is DROPPED.
    ///
    /// Faithful translation of `SQLiteWikiStore.migrateV19ToV20`. All DML is
    /// inside one `db.inTransaction(.immediate)` (the GRDB equivalent of
    /// `withTransaction`): if the pre-migration assertion fails, the whole step
    /// rolls back harmlessly.
    private static func migrateV19ToV20(in db: Database) throws {
        try db.inTransaction(.immediate) {
            // 1. Create the five objects tables (idempotent — IF NOT EXISTS).
            try createObjectsTablesV20(in: db)

            let hasContentColumn = try Self.hasColumn("content", on: "sources", in: db)
            guard hasContentColumn else { return .commit }

            // 0. Pre-migration assertion (silent-data-loss guard).
            let unhashed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sources WHERE content_hash IS NULL OR content_hash = '';"
            ) ?? 0
            if unhashed != 0 {
                try Self.backfillContentHashes(in: db)
                let recheck = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sources WHERE content_hash IS NULL OR content_hash = '';"
                ) ?? 0
                guard recheck == 0 else {
                    throw WikiStoreError.unexpected(
                        "v20 migration: \(recheck) source(s) still lack a content_hash after backfill — refusing to drop content")
                }
            }

            // 2. Seed one legacy agent.
            let legacyAgentID = ULID.generate()
            try db.execute(
                sql: "INSERT INTO agents (id, kind, name) VALUES (?, 'software', 'legacy-import');",
                arguments: [legacyAgentID])

            // 3. For each existing source: blob + activity + v1 version + ref.
            let now = Date().timeIntervalSince1970
            struct SourceRow {
                let id: String; let content: Data; let hash: String
                let mime: String?; let byteSize: Int; let createdAt: Double
            }
            let sourceRows = try Row.fetchAll(db, sql: """
            SELECT id, content, content_hash, mime_type, byte_size, created_at
            FROM sources;
            """).map { row -> SourceRow in
                // GRDB's optional binding: `String?` is nil for SQL NULL.
                let mime: String? = row["mime_type"]
                return SourceRow(
                    id: row["id"],
                    content: row["content"],
                    hash: row["content_hash"],
                    mime: mime,
                    byteSize: row["byte_size"],
                    createdAt: row["created_at"]
                )
            }

            for source in sourceRows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);",
                    arguments: [source.hash, source.byteSize, source.content])

                let activityID = ULID.generate()
                try db.execute(sql: """
                INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                VALUES (?, 'import', ?, ?, ?);
                """, arguments: [activityID, legacyAgentID, source.createdAt, source.createdAt])

                let versionID = ULID.generate()
                try db.execute(sql: """
                INSERT INTO source_versions (id, source_id, parent_id, blob_hash,
                                             mime_type, activity_id, fetched_at)
                VALUES (?, ?, NULL, ?, ?, ?, ?);
                """, arguments: [versionID, source.id, source.hash, source.mime, activityID, source.createdAt])

                try db.execute(sql: """
                INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
                VALUES ('source-content', ?, ?, 1, ?);
                """, arguments: [source.id, versionID, now])
            }

            // 4. Drop the content column.
            try db.execute(sql: "ALTER TABLE sources DROP COLUMN content;")
        return .commit
        }
    }

    /// The v20→21 migration step (graph-model Phase 2). CAS-moves each legacy
    /// row's inline `content` into a blob. Faithful translation of
    /// `SQLiteWikiStore.migrateV20ToV21`.
    private static func migrateV20ToV21(in db: Database) throws {
        try db.inTransaction(.immediate) {
            let hasSMV = try Self.tableExists("source_markdown_versions", in: db)
            guard hasSMV else { return .commit }

            for (col, decl) in [
                ("activity_id", "TEXT REFERENCES activities(id)"),
                ("source_version_id", "TEXT"),
                ("blob_hash", "TEXT REFERENCES blobs(hash)"),
                ("mime_type", "TEXT NOT NULL DEFAULT 'text/markdown'"),
            ] {
                let present = try Self.hasColumn(col, on: "source_markdown_versions", in: db)
                guard !present else { continue }
                try db.execute(sql: "ALTER TABLE source_markdown_versions ADD COLUMN \(col) \(decl);")
            }

            let unmigrated = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_markdown_versions WHERE blob_hash IS NULL;"
            ) ?? 0
            guard unmigrated != 0 else { return .commit }

            let legacyAgentID: String
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT id FROM agents WHERE name = ? LIMIT 1;",
                arguments: [ExtractionBackend.legacyAgentName]
            ) {
                legacyAgentID = existing
            } else {
                legacyAgentID = ULID.generate()
                try db.execute(
                    sql: "INSERT INTO agents (id, kind, name) VALUES (?, 'software', ?);",
                    arguments: [legacyAgentID, ExtractionBackend.legacyAgentName])
            }

            struct LegacyRow {
                let id: String; let fileID: String
                let content: String; let origin: String; let createdAt: Double
            }
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, file_id, content, origin, created_at
            FROM source_markdown_versions WHERE blob_hash IS NULL;
            """).map { row -> LegacyRow in
                LegacyRow(
                    id: row["id"], fileID: row["file_id"],
                    content: row["content"], origin: row["origin"],
                    createdAt: row["created_at"])
            }
            for row in rows {
                guard !row.content.isEmpty else {
                    throw WikiStoreError.unexpected(
                        "v21 migration: source_markdown_versions row \(row.id) has empty content — refusing to backfill")
                }
            }

            for row in rows {
                let data = Data(row.content.utf8)
                let hash = portableSHA256( data)
                    .map { String(format: "%02x", $0) }.joined()

                try db.execute(
                    sql: "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);",
                    arguments: [hash, Int64(data.count), data])

                var activityID: String? = nil
                if SourceMarkdownOrigin(rawValue: row.origin) == .extraction {
                    let id = ULID.generate()
                    try db.execute(sql: """
                    INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                    VALUES (?, 'extract', ?, ?, ?);
                    """, arguments: [id, legacyAgentID, row.createdAt, row.createdAt])
                    activityID = id
                }

                var sourceVersionID: String?
                if let svID = try String.fetchOne(
                    db,
                    sql: """
                    SELECT sv.id
                    FROM refs r
                    JOIN source_versions sv ON sv.id = r.version_id
                    WHERE r.kind = 'source-content' AND r.owner_id = ?;
                    """,
                    arguments: [row.fileID]
                ) {
                    sourceVersionID = svID
                } else if let svID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM source_versions WHERE source_id = ? ORDER BY id DESC LIMIT 1;",
                    arguments: [row.fileID]
                ) {
                    sourceVersionID = svID
                }

                try db.execute(sql: """
                UPDATE source_markdown_versions
                   SET blob_hash = ?, activity_id = ?, source_version_id = ?,
                       mime_type = 'text/markdown', content = ''
                 WHERE id = ?;
                """, arguments: [hash, activityID, sourceVersionID, row.id])
            }
        return .commit
        }
    }

    /// The v21→v22 migration step (graph-model Phase 4 foundation):
    /// `sources.role` + `source_links` rebuild. Faithful translation of
    /// `SQLiteWikiStore.migrateV21ToV22`.
    private static func migrateV21ToV22(in db: Database) throws {
        try db.inTransaction(.immediate) {
            let hasRole = try Self.hasColumn("role", on: "sources", in: db)
            guard !hasRole else { return .commit }

            try db.execute(sql: "ALTER TABLE sources ADD COLUMN role TEXT NOT NULL DEFAULT 'primary';")

            let hasSourceLinks = try Self.tableExists("source_links", in: db)
            guard hasSourceLinks else { return .commit }
            let hasRoleCol = try Self.hasColumn("role", on: "source_links", in: db)
            guard !hasRoleCol else { return .commit }
            try db.execute(sql: "ALTER TABLE source_links RENAME TO source_links_v21;")
            try db.execute(sql: """
            CREATE TABLE source_links (
                from_page_id TEXT NOT NULL REFERENCES pages(id),
                to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                link_text    TEXT NOT NULL,
                role         TEXT NOT NULL DEFAULT 'cite',
                pinned_version_id TEXT
            );
            """)
            try db.execute(sql: """
            INSERT INTO source_links (from_page_id, to_source_id, link_text, role, pinned_version_id)
            SELECT from_page_id, to_source_id, link_text, 'cite', NULL FROM source_links_v21;
            """)
            try db.execute(sql: "DROP TABLE source_links_v21;")
            try db.execute(sql: """
            CREATE UNIQUE INDEX source_links_edge
                ON source_links(from_page_id, to_source_id, role,
                                COALESCE(pinned_version_id, ''));
            """)
        return .commit
        }
    }

    /// The v22→23 step: canonicalize `[[…]]` links to ULID-stable form.
    /// Faithful translation of `SQLiteWikiStore.migrateV22ToV23`.
    ///
    /// Uses `_Locked` resolver variants that take a `Database` directly — the
    /// public resolvers re-enter `dbWriter.read` and would deadlock inside a
    /// `writeWithoutTransaction` migration.
    private func migrateV22ToV23(in db: Database) throws {
        try db.inTransaction(.immediate) {
            let hasPages = try Self.tableExists("pages", in: db)
            guard hasPages else { return .commit }

            let hasSources = try Self.tableExists("sources", in: db)
            let resolveSource: (String) throws -> PageID? = hasSources
                ? { [self] in try self.resolveSourceByNameLocked($0, in: db) }
                : { _ in nil }

            let hasChats = try Self.tableExists("chats", in: db)
            let resolveChat: (String) throws -> PageID? = hasChats
                ? { [self] in try self.resolveChatByTitleLocked($0, in: db) }
                : { _ in nil }

            let rows = try Row.fetchAll(db, sql: "SELECT id, body_markdown FROM pages;")
            let now = Date().timeIntervalSince1970
            for row in rows {
                let id: String = row["id"]
                let body: String = row["body_markdown"]
                guard let canonical = try WikiLinkRewriter.canonicalize(
                    in: body,
                    resolvePage: { [self] in try self.resolveTitleToIDLocked($0, in: db) },
                    resolveSource: resolveSource,
                    resolveChat: resolveChat) else { continue }
                try db.execute(sql: """
                UPDATE pages SET body_markdown = ?, updated_at = ?, version = version + 1 WHERE id = ?;
                """, arguments: [canonical, now, id])
            }
        return .commit
        }
    }

    /// The v28→29 step: rewrite `kind = 'ask'` → `'edit'`.
    private static func migrateV28ToV29(in db: Database) throws {
        let hasChats = try Self.tableExists("chats", in: db)
        guard hasChats else { return }
        try db.execute(sql: "UPDATE chats SET kind = 'edit' WHERE kind = 'ask';")
    }

    /// The v29→30 migration step (W0 — page versioning).
    /// Faithful translation of `SQLiteWikiStore.migrateV29ToV30`.
    private func migrateV29ToV30(in db: Database) throws {
        try db.inTransaction(.immediate) {
            try Self.createPageVersionsV30(in: db)

            let refsExists = try Self.tableExists("refs", in: db)
            if refsExists {
                let refsSQL = try Self.queryScalarText(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='refs';", in: db)
                if !refsSQL.contains("CHECK") {
                    try db.execute(sql: """
                    CREATE TABLE _refs_new (
                        kind       TEXT NOT NULL CHECK (kind IN ('source-content','source-derived','page-content')),
                        owner_id   TEXT NOT NULL,
                        version_id TEXT NOT NULL,
                        generation INTEGER NOT NULL DEFAULT 1,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (kind, owner_id)
                    );
                    """)
                    try db.execute(sql: "INSERT INTO _refs_new (kind, owner_id, version_id, generation, updated_at) SELECT kind, owner_id, version_id, generation, updated_at FROM refs;")
                    try db.execute(sql: "DROP TABLE refs;")
                    try db.execute(sql: "ALTER TABLE _refs_new RENAME TO refs;")
                }
            } else {
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
            }

            let pageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_versions;") ?? 0
            guard pageCount == 0 else { return .commit }

            let hasPages = try Self.tableExists("pages", in: db)
            guard hasPages else { return .commit }

            let legacyAgentID = try legacyImportAgentID(on: db)

            struct PageRow {
                let id: String; let title: String; let body: Data; let createdAt: Double
            }
            let pages = try Row.fetchAll(db, sql: """
            SELECT id, title, body_markdown, created_at FROM pages;
            """).map { row -> PageRow in
                PageRow(
                    id: row["id"], title: row["title"],
                    body: Data((row["body_markdown"] as String).utf8), createdAt: row["created_at"])
            }

            for page in pages {
                let hash = portableSHA256( page.body)
                    .map { String(format: "%02x", $0) }.joined()

                try db.execute(
                    sql: "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);",
                    arguments: [hash, Int64(page.body.count), page.body])

                let activityID = ULID.generate()
                try db.execute(sql: """
                INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                VALUES (?, 'import', ?, ?, ?);
                """, arguments: [activityID, legacyAgentID, page.createdAt, page.createdAt])

                let versionID = ULID.generate()
                try db.execute(sql: """
                INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
                VALUES (?, ?, NULL, ?, ?, ?, ?);
                """, arguments: [versionID, page.id, hash, page.title, activityID, page.createdAt])
            }
        return .commit
        }
    }

    /// v32 → v33 (#131): provenance columns.
    private static func migrateV32ToV33(in db: Database) throws {
        try db.inTransaction(.immediate) {
            let hasPages = try Self.tableExists("pages", in: db)
            if hasPages {
                let pagesCols = try tableColumnInfo("pages", in: db)
                if !pagesCols.contains("created_by") {
                    try db.execute(sql: "ALTER TABLE pages ADD COLUMN created_by TEXT;")
                }
                if !pagesCols.contains("last_edited_by") {
                    try db.execute(sql: "ALTER TABLE pages ADD COLUMN last_edited_by TEXT;")
                }
            }
            let hasSMV = try Self.tableExists("source_markdown_versions", in: db)
            if hasSMV {
                let smvCols = try tableColumnInfo("source_markdown_versions", in: db)
                if !smvCols.contains("technique") {
                    try db.execute(sql: "ALTER TABLE source_markdown_versions ADD COLUMN technique TEXT;")
                }
            }
        return .commit
        }
    }

    /// v33 → v34 (#multi-writer-hardening Phase 3 — head-ref invariant).
    /// Faithful translation of `SQLiteWikiStore.migrateV33ToV34`.
    private func migrateV33ToV34(in db: Database) throws {
        try db.inTransaction(.immediate) {
            let hasPages = try Self.tableExists("pages", in: db)
            guard hasPages else { return .commit }
            let hasRefs = try Self.tableExists("refs", in: db)
            guard hasRefs else { return .commit }

            let legacyAgentID = try legacyImportAgentID(on: db)
            let now = Date().timeIntervalSince1970

            struct PageRow {
                let id: String; let title: String; let body: Data; let createdAt: Double
            }
            let pages = try Row.fetchAll(db, sql: """
            SELECT p.id, p.title, p.body_markdown, p.created_at
            FROM pages p
            WHERE NOT EXISTS (
                SELECT 1 FROM refs r
                WHERE r.kind = 'page-content' AND r.owner_id = p.id
            );
            """).map { row -> PageRow in
                PageRow(
                    id: row["id"], title: row["title"],
                    body: Data((row["body_markdown"] as String).utf8), createdAt: row["created_at"])
            }

            guard !pages.isEmpty else { return .commit }

            for page in pages {
                var headVersionID: String
                if let maxID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM page_versions WHERE page_id = ? ORDER BY id DESC LIMIT 1;",
                    arguments: [page.id]
                ) {
                    headVersionID = maxID
                } else {
                    let hash = portableSHA256( page.body)
                        .map { String(format: "%02x", $0) }.joined()

                    try db.execute(
                        sql: "INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);",
                        arguments: [hash, Int64(page.body.count), page.body])

                    let activityID = ULID.generate()
                    try db.execute(sql: """
                    INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
                    VALUES (?, 'import', ?, ?, ?);
                    """, arguments: [activityID, legacyAgentID, page.createdAt, page.createdAt])

                    headVersionID = ULID.generate()
                    try db.execute(sql: """
                    INSERT INTO page_versions (id, page_id, parent_id, blob_hash, title, activity_id, saved_at)
                    VALUES (?, ?, NULL, ?, ?, ?, ?);
                    """, arguments: [headVersionID, page.id, hash, page.title, activityID, page.createdAt])
                }

                try db.execute(sql: """
                INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
                VALUES ('page-content', ?, ?, 1, ?);
                """, arguments: [page.id, headVersionID, now])
            }
        return .commit
        }
    }

    /// v34 → v35 (#multi-writer-hardening Phase 5 — created-page staging).
    private static func migrateV34ToV35(in db: Database) throws {
        let columns = try tableColumnInfo("workspace_refs", in: db)
        guard !columns.contains("blob_hash") else { return }

        try db.inTransaction(.immediate) {
            try db.execute(sql: """
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
            try db.execute(sql: """
            INSERT INTO _workspace_refs_new
                (workspace_id, kind, owner_id, base_version_id, version_id, blob_hash, title, updated_at)
            SELECT workspace_id, kind, owner_id, base_version_id, version_id, NULL, NULL, updated_at
            FROM workspace_refs;
            """)
            try db.execute(sql: "DROP TABLE workspace_refs;")
            try db.execute(sql: "ALTER TABLE _workspace_refs_new RENAME TO workspace_refs;")
        return .commit
        }
    }

    /// The v35→36 migration step (issue #411 — chat summary).
    private static func migrateV35ToV36(in db: Database) throws {
        let columns = try tableColumnInfo("chats", in: db)
        guard !columns.contains("summary") else { return }

        try db.inTransaction(.immediate) {
            try db.execute(sql: "ALTER TABLE chats ADD COLUMN summary TEXT;")
            try db.execute(sql: "ALTER TABLE chats ADD COLUMN summary_at REAL;")
        return .commit
        }
    }

    /// One-time backfill for the v18→19 step: hash every existing source's
    /// `content` (SHA-256, hex) into the new `content_hash` column.
    private static func backfillContentHashes(in db: Database) throws {
        let hasContentColumn = try Self.hasColumn("content", on: "sources", in: db)
        guard hasContentColumn else { return }

        struct SourceRow { let id: String; let data: Data }
        let rows = try Row.fetchAll(db, sql: "SELECT id, content FROM sources;")
            .map { row -> SourceRow in
                SourceRow(id: row["id"], data: row["content"])
            }
        for row in rows {
            let hash = portableSHA256( row.data)
                .map { String(format: "%02x", $0) }.joined()
            try db.execute(
                sql: "UPDATE sources SET content_hash = ? WHERE id = ?;",
                arguments: [hash, row.id])
        }
    }

    /// The v17→18 sweep: rewrite unlinkable page titles and source display names.
    private func sanitizeStoredNames(in db: Database) throws {
        let now = Date().timeIntervalSince1970

        let pages = try Row.fetchAll(db, sql: "SELECT id, title FROM pages;")
            .map { row -> (id: String, title: String) in
                (id: row["id"], title: row["title"])
            }
        for page in pages where !WikiNameRules.isLinkable(page.title) {
            let clean = WikiNameRules.sanitized(page.title)
            let slug = try uniqueSlug(from: clean, id: PageID(rawValue: page.id), on: db)
            try db.execute(sql: """
            UPDATE pages SET title = ?, slug = ?, updated_at = ?,
                             version = version + 1 WHERE id = ?;
            """, arguments: [clean, slug, now, page.id])
        }

        let sources = try Row.fetchAll(
            db, sql: "SELECT id, COALESCE(display_name, filename) FROM sources;"
        ).map { row -> (id: String, effectiveName: String) in
            (id: row["id"], effectiveName: row[1])
        }
        for source in sources where !WikiNameRules.isLinkable(source.effectiveName) {
            try db.execute(sql: """
            UPDATE sources SET display_name = ?, updated_at = ?,
                               version = version + 1 WHERE id = ?;
            """, arguments: [WikiNameRules.sanitized(source.effectiveName), now, source.id])
        }
    }

    // MARK: - Locked resolvers (Database-taking, no dbWriter re-entry)

    /// `resolveTitleToID` taking a `Database` directly — safe to call from
    /// inside a migration. The public `resolveTitleToID(_:)` re-enters
    /// `dbWriter.read` and would deadlock.
    private func resolveTitleToIDLocked(_ title: String, in db: Database) throws -> PageID? {
        if let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM pages WHERE title = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1;",
            arguments: [title]
        ) {
            return PageID(rawValue: id)
        }
        return nil
    }

    /// `resolveSourceByName` taking a `Database` directly. Faithful port of
    /// `SQLiteWikiStore.resolveSourceByName` (3-pass: exact → extension-stripped
    /// → loose-key unique). Safe to call from inside a `mutate`/transaction
    /// closure — never re-enters `dbWriter`.
    private func resolveSourceByNameLocked(_ displayName: String, in db: Database) throws -> PageID? {
        // Pass 1: exact (display_name or filename) match, newest first.
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
        // Pass 2 + 3: scan all sources — extension-stripped match (immediate)
        // and loose-key collection (unique-only at the end).
        let queryLooseKey = WikiNameRules.looseMatchKey(displayName)
        var looseMatches: [PageID] = []
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, COALESCE(display_name, filename) AS name FROM sources ORDER BY updated_at DESC;"
        )
        for row in rows {
            let id: String = row["id"]
            let name: String = row["name"]
            if (name as NSString).deletingPathExtension.caseInsensitiveCompare(displayName) == .orderedSame {
                return PageID(rawValue: id)
            }
            if !queryLooseKey.isEmpty, WikiNameRules.looseMatchKey(name) == queryLooseKey {
                looseMatches.append(PageID(rawValue: id))
            }
        }
        // Pass 3: lenient, unique-only.
        return looseMatches.count == 1 ? looseMatches[0] : nil
    }

    /// Resolve a parsed link's target to an id, trying every candidate
    /// (name, fragment) reading of the raw target — longest name first — via
    /// `WikiLinkResolver`, so names containing `#` resolve whole. Ported from
    /// `SQLiteWikiStore.resolveLinkTarget`, but takes a `Database` and a
    /// resolver closure `(String, Database) throws -> PageID?` (the `*Locked`
    /// variants) so it can run inside the write transaction without re-entering
    /// `dbWriter`.
    private func resolveLinkTarget(
        _ link: ParsedLink,
        using resolve: (String, Database) throws -> PageID?,
        in db: Database
    ) throws -> PageID? {
        let raw = link.fragment.map { "\(link.target)#\($0)" } ?? link.target
        for split in WikiLinkResolver.candidateSplits(of: raw) {
            if let id = try resolve(split.base, db) { return id }
        }
        return nil
    }

    /// If `link.target` is a canonical ULID naming an existing row, return that
    /// id directly (Phase 5). Ported from `SQLiteWikiStore.canonicalLinkID` but
    /// does the existence check via `String.fetchOne` rather than the public
    /// `getPage`/`getSource` (those open their own `dbWriter.read` and would
    /// re-enter). Returns `nil` for non-canonical targets or ids naming no row
    /// so the caller can fall back to name resolution.
    private func canonicalLinkID(_ link: ParsedLink, in db: Database) throws -> PageID? {
        guard WikiLinkParser.isCanonicalULID(link.target) else { return nil }
        let id = PageID(rawValue: link.target)
        switch link.linkType {
        case .page:
            return try String.fetchOne(
                db, sql: "SELECT id FROM pages WHERE id = ?;", arguments: [id.rawValue]
            ) != nil ? id : nil
        case .source:
            return try String.fetchOne(
                db, sql: "SELECT id FROM sources WHERE id = ?;", arguments: [id.rawValue]
            ) != nil ? id : nil
        case .chat:
            return try String.fetchOne(
                db, sql: "SELECT id FROM chats WHERE id = ?;", arguments: [id.rawValue]
            ) != nil ? id : nil
        }
    }

    /// The derived-markdown chain (`[smvID]`) for `sourceID`, ULID-asc =
    /// chronological (index 0 = v1). Locked variant of
    /// `SQLiteWikiStore.derivedVersionIDs` — runs against the given `db`.
    private func derivedVersionIDsLocked(sourceID: PageID, in db: Database) throws -> [PageID] {
        let rows = try String.fetchAll(
            db,
            sql: "SELECT id FROM source_markdown_versions WHERE file_id = ? ORDER BY id ASC;",
            arguments: [sourceID.rawValue]
        )
        return rows.map { PageID(rawValue: $0) }
    }

    /// Resolve an `@vN` ordinal (1-based) to the concrete smv id for
    /// `sourceID`, or `nil` when out of range. Locked variant of
    /// `SQLiteWikiStore.resolveVersionPin` — runs against the given `db`.
    private func resolveVersionPin(
        _ pin: String, sourceID: PageID, in db: Database
    ) throws -> PageID? {
        guard let ordinal = Int(pin), ordinal >= 1 else { return nil }
        let ids = try derivedVersionIDsLocked(sourceID: sourceID, in: db)
        let idx = ordinal - 1
        return idx < ids.count ? ids[idx] : nil
    }

    /// `resolveChatByTitle` taking a `Database` directly.
    private func resolveChatByTitleLocked(_ title: String, in db: Database) throws -> PageID? {
        if let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM chats WHERE title = ? COLLATE NOCASE ORDER BY id ASC LIMIT 1;",
            arguments: [title]
        ) {
            return PageID(rawValue: id)
        }
        return nil
    }

    /// Build the complete current schema (v39 end-state) on a fresh `Database`.
    /// Mirrors `SQLiteWikiStore.createFreshSchemaV20()` + the additive tables
    /// from v23–v39. All DDL is `IF NOT EXISTS`-guarded so re-running on an
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
        // Note: system_prompt table removed in v42 → always use compiled default.
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
        // Note: system_prompt table removed in v42 → always use compiled default.
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

        // v13 search sidecar (kept as an ordinary table post-#634; Tantivy
        // is the sole BM25 leg, no FTS5 virtual table on top).
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS source_search (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            title     TEXT NOT NULL,
            body      TEXT NOT NULL
        );
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
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            title           TEXT NOT NULL,
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL,
            summary         TEXT,
            summary_at      REAL,
            acp_session_id  TEXT
        );
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS chats_updated ON chats(updated_at);")
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id          TEXT PRIMARY KEY,
            chat_id     TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            seq         INTEGER NOT NULL,
            role        TEXT NOT NULL,
            event_json  TEXT NOT NULL,
            text        TEXT NOT NULL DEFAULT '',
            created_at  REAL NOT NULL,
            summary     TEXT,
            summary_kind TEXT,
            summary_at  REAL,
            is_draft    INTEGER NOT NULL DEFAULT 0,
            draft_handle TEXT
        );
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_seq ON chat_messages(chat_id, seq);")
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_draft_handle
            ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL;
        """)

        // v28: chat semantic search (chat_chunks) + the `chat_search` sidecar
        // (kept as an ordinary table post-#634 — written by `upsertChatSearch`,
        // no FTS5 reader).
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
    /// Mirrors `SQLiteWikiStore.legacyImportAgentID`. Used as the fallback
    /// when a page mutation has no author identity (nil/empty `created_by` /
    /// `last_edited_by` — pre-v39 rows, legacy callers). Page-PROV (#page-
    /// provenance) routes authored saves through `ensureAgent(name:kind:)`
    /// so the activity carries the REAL `chat:<id>` / `agent:<kind>` /
    /// `user` / model-id identity; this stays as the degraded path.
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

    /// Map a provenance author string (#131 / #397) to an `agents.kind`
    /// value, mirroring the writer shapes documented in
    /// `plans/wikictl-author-provenance.md`. The write seam threads the SAME
    /// `chat:<id>` / `agent:<kind>` / `user` / model-id string that
    /// `created_by`/`last_edited_by` carry into `ensureAgent(name:kind:)`,
    /// so page activities point at REAL named agents (not the shared
    /// `legacy-import`). `nil`/empty falls back to `"software"` (the
    /// `legacyImportAgentID` path degrades the same as today — no data loss).
    ///
    /// `chat:<id>` and `agent:<kind>` are ULID-suffixed by construction
    /// (`AgentLauncher.startInteractiveQuery` / `WIKI_AUTHOR` env), so they
    /// cannot collide with a stray page titled `chat:…` on `ensureAgent`'s
    /// `(name, kind)` dedup.
    ///
    /// Implementation note (#797): this is a thin shim over the single source
    /// of truth — `PageAuthor(rawValue: author).agentKind.rawValue`. The
    /// mapping is defined ONCE in `WikiFSTypes` and shared by every
    /// construction/parse site (`AgentLauncher.authorForRun`, `ProvenancePanel`,
    /// the tests). Signature kept (`String? -> String`) so
    /// `appendPageVersionLocked` and other callers are untouched.
    private func authorKind(_ author: String?) -> String {
        PageAuthor(rawValue: author).agentKind.rawValue
    }

    /// Resolve the agent for a page mutation's activity: if `author` carries a
    /// `chat:`/`agent:`/`user`/model-id identity, dedup a REAL named agent on
    /// `(name, kind)` via `ensureAgent`; otherwise degrade to the shared
    /// `legacy-import` (pre-v39 behaviour). `db:`-taking so it composes inside
    /// `mutate(event:_:)` bodies (the page-provenance write seam — see
    /// `appendPageVersionLocked` + `createPage`).
    private func ensurePageAuthorAgent(
        _ author: String?, on db: Database
    ) throws -> String {
        guard let author, !author.isEmpty else {
            return try legacyImportAgentID(on: db)
        }
        return try ensureAgent(
            name: author, kind: authorKind(author), on: db)
    }

    // MARK: - changeToken (File Provider sync anchor)

    /// The whole-database change token — the File Provider sync anchor and
    /// durable per-wiki ground truth. Folds `COUNT`/`SUM` over every table
    /// into one ``ChangeToken``, assembled from per-kind
    /// ``ChangeTokenContributor``s in registration order.
    ///
    /// The registry order is load-bearing: it reproduces the historical
    /// 14-field ``ChangeToken/rawString`` byte-for-byte. The
    /// `ChangeTokenContributorTests` contributor-order test + the rawString
    /// round-trip test enforce that.
    public func changeToken() throws -> ChangeToken {
        try dbWriter.read { db in
            var token = ChangeToken()
            for contributor in Self.tokenContributors {
                token.apply(try contributor.fold(in: self, on: db))
            }
            return token
        }
    }

    /// Resilient single-value read: returns `0` if the table doesn't exist
    /// (a read connection opened against a pre-migration DB), so
    /// `changeToken()` always answers. Mirrors the `try?` resilience of the
    /// historical SQLiteWikiStore helpers.
    internal func resilientScalar(_ sql: String, on db: Database) -> Int64 {
        (try? Int64.fetchOne(db, sql: sql)) ?? 0
    }

    /// `COUNT`/`SUM(version)` over `pages`. Unlike the resilient helpers
    /// below, this `try`s and throws if the `pages` table is absent — matching
    /// the pre-2b behavior (the pages fold was the only one that could throw).
    internal func pageCountSum(on db: Database) throws -> (Int64, Int64) {
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*), COALESCE(SUM(version), 0) FROM pages;")
        return (row?[0] ?? 0, row?[1] ?? 0)
    }

    /// COUNT/SUM(version) over `sources`, resilient to a missing table.
    internal func sourceCountSum(on db: Database) -> (Int64, Int64) {
        guard let row = try? Row.fetchOne(db, sql: "SELECT COUNT(*), COALESCE(SUM(version), 0) FROM sources;") else {
            return (0, 0)
        }
        return (row[0] ?? 0, row[1] ?? 0)
    }

    internal func systemPromptVersion(on db: Database) -> Int64 {
        // The system_prompt table was removed in v42. Return a stable hash of
        // the compiled default so the changeToken advances when the prompt changes.
        Int64(SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF)
    }
    internal func logRowCount(on db: Database) -> Int64 { resilientScalar("SELECT COUNT(*) FROM log;", on: db) }
    internal func wikiIndexVersion(on db: Database) -> Int64 {
        resilientScalar("SELECT COALESCE(version, 0) FROM wiki_index WHERE id = 1;", on: db)
    }
    internal func sourceMarkdownVersionCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM source_markdown_versions;", on: db)
    }
    internal func sourceVersionCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM source_versions;", on: db)
    }
    internal func refsGenerationSum(on db: Database) -> Int64 {
        resilientScalar("SELECT COALESCE(SUM(generation), 0) FROM refs;", on: db)
    }
    internal func activitiesCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM activities;", on: db)
    }
    internal func bookmarkNodesCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM bookmark_nodes;", on: db)
    }
    internal func chatCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM chats;", on: db)
    }
    internal func chatMessageCount(on db: Database) -> Int64 {
        resilientScalar("SELECT COUNT(*) FROM chat_messages;", on: db)
    }

    // MARK: - changeToken contributors (slice 2b)

    /// The per-kind contributors whose folds assemble into ``changeToken()``.
    /// Order is load-bearing: it reproduces the historical 14-field
    /// ``ChangeToken/rawString`` byte-for-byte. A kind may appear more than
    /// once (the historical layout interleaves the system-prompt/log/index
    /// folds between the `sources` table fold and the graph-model source
    /// folds). `internal` so the contributor-exhaustiveness test can read it
    /// (`@testable import`).
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

    internal struct PagesTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .page
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            let (count, sum) = try store.pageCountSum(on: db)
            return .pages(count: count, versionSum: sum)
        }
    }

    internal struct SourceTableTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            let (count, sum) = store.sourceCountSum(on: db)
            return .sourceTable(count: count, versionSum: sum)
        }
    }

    internal struct SystemPromptTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .systemPrompt
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .systemPrompt(version: store.systemPromptVersion(on: db))
        }
    }

    internal struct LogTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .log
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .log(rowCount: store.logRowCount(on: db))
        }
    }

    internal struct WikiIndexTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .wikiIndex
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .wikiIndex(version: store.wikiIndexVersion(on: db))
        }
    }

    /// The derived-alternative fold: the `source_markdown_versions` row count.
    /// Logically a source concern; appears after the index fold in the
    /// historical layout, so it is its own contributor in registry order.
    internal struct SourceDerivedTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .sourceMarkdownVersions(count: store.sourceMarkdownVersionCount(on: db))
        }
    }

    /// The graph-model source folds: `source_versions` count, `refs` generation
    /// sum, `activities` count. Appended at the token tail by Phase 1 (v20);
    /// logically source provenance/version state.
    internal struct SourceGraphTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .source
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .sourceGraph(versionCount: store.sourceVersionCount(on: db),
                         refsGenerationSum: store.refsGenerationSum(on: db),
                         activitiesCount: store.activitiesCount(on: db))
        }
    }

    /// Phase D fold: the `bookmark_nodes` row count. A bookmark create/delete
    /// bumps the token so the File Provider re-enumerates the `bookmarks/` tree.
    internal struct BookmarkTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .bookmark
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .bookmarks(count: store.bookmarkNodesCount(on: db))
        }
    }

    /// Chat fold (#119 follow-on): the `chats` row count + `chat_messages` row
    /// count. A chat create/delete bumps the count; a message append bumps the
    /// message count. Both advance the token so the FP re-enumerates `chats/`.
    internal struct ChatTokenContributor: ChangeTokenContributor {
        let kind: ResourceKind = .chat
        func fold(in store: GRDBWikiStore, on db: Database) throws -> ChangeTokenFold {
            .chat(count: store.chatCount(on: db), messageCount: store.chatMessageCount(on: db))
        }
    }

    // MARK: - WikiStore protocol: Pages

    public func listPages(sortBy: PageSortOrder) throws -> [WikiPageSummary] {
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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

    public func createPage(title: String, createdBy: String? = nil) throws -> WikiPage {
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
            let hash = portableSHA256( bodyData)
                .map { String(format: "%02x", $0) }.joined()

            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(0), bodyData])

            // Page provenance (#page-provenance): route the root activity's
            // agent through `ensureAgent(name:kind:)` so a chat / agent / user
            // author identity lands as a REAL named agent row (not the shared
            // `legacy-import`). Degrades to the shared legacy agent when
            // `createdBy` is nil/empty (pre-v39 behaviour, no data loss).
            let agentID = try self.ensurePageAuthorAgent(createdBy, on: db)
            let activityID = ULID.generate()
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'import', ?, ?, ?);
            """, arguments: [activityID, agentID, nowTS, nowTS])

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

    /// 1-arg convenience requirement: forward to the full-signature impl with
    /// `createdBy: nil`. Mirrors `SQLiteWikiStore`'s defaulted-parameter convenience.
    @discardableResult
    public func createPage(title: String) throws -> WikiPage {
        try createPage(title: title, createdBy: nil)
    }

    public func updatePage(id: PageID, title: String, body: String, lastEditedBy: String? = nil) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: id.rawValue, change: .updated)
        }) { db in
            // Existence check — match the pre-refactor contract that threw
            // `.notFound` when the id is gone (the legacy `guard
            // db.changesCount > 0` ran AFTER the UPDATE; this runs FIRST
            // because the refactored body INSERTs into `page_versions` —
            // whose FK on pages(id) would otherwise throw a raw SQLite
            // `FOREIGN KEY constraint failed` instead of the user-friendly
            // `.notFound`). The savepoint rolls back; `mutate` discards the
            // buffered event (no emit on failure) — see
            // `StoreEmissionReentrancyTests.throwingMutationEmitsNothing`.
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM pages WHERE id = ?;",
                arguments: [id.rawValue]
            ) ?? 0
            guard exists == 1 else { throw WikiStoreError.notFound(id) }

            let title = WikiNameRules.sanitized(title)
            let slug = try self.uniqueSlug(from: title, id: id, on: db)
            let bodyData = Data(body.utf8)
            let hash = portableSHA256( bodyData)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // Page provenance (#page-provenance): the CAS-off path (no
            // `expectedHeadVersionID`, the `wikictl` default — see
            // `PageUpsert.writePage`) now appends a `page_versions` +
            // `activities` row just like the CAS path, closing the "records
            // nothing" hole (pre-v39, only the flat `last_edited_by` string
            // survived). Routes through `appendPageVersionLocked` — NOT public
            // `appendPageVersion` — because (a) `mutate`'s doc warns
            // `dbWriter.write` is NOT reentrant (a public mutator that
            // re-calls `mutate` deadlocks), and (b) `appendPageVersion` is
            // itself a `mutate` wrapper that emits `.page .updated`, so a
            // naive delegation would double-emit (the HIGH hazard in §5.3).
            // This method's own `mutate` wrapper is the single emit site; the
            // shared helper emits nothing.
            //
            // The amend-coalescing check (`tryAmendPageVersion`) at line ~6461
            // IS run on this path too — a rapid same-author save within the
            // 5s window amend-coalesces into the head instead of appending a
            // new row (autosave semantics). The plan's AC.3 row-count test
            // accounts for this by using a DISTINCT author from the create so
            // the amend short-circuit does not suppress the new version row.
            let head = try Self.pageHeadVersionIDLocked(pageID: id, on: db)
            if let amendVersionID = try self.tryAmendPageVersion(
                db: db, pageID: id, head: head, title: title, slug: slug,
                body: body, bodyData: bodyData, hash: hash,
                lastEditedBy: lastEditedBy, now: now, nowTS: nowTS)
            {
                _ = amendVersionID   // amend already touched the mirror.
                return
            }
            _ = try self.appendPageVersionLocked(
                db: db, pageID: id, head: head, title: title, slug: slug,
                body: body, bodyData: bodyData, hash: hash,
                lastEditedBy: lastEditedBy, now: now, nowTS: nowTS)
        }
    }

    public func deletePage(id: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: id.rawValue, change: .deleted)
        }) { db in
            // FK safety: page_links, attachments, source_links all have FKs
            // onto pages(id) WITHOUT ON DELETE CASCADE (unlike page_chunks).
            // Clear every dependent row first, then delete the page — all in
            // ONE transaction (dbWriter.write provides this).
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
            try self.resolveSourceByNameLocked(displayName, in: db)
        }
    }

    public func replaceLinks(from pageID: PageID, parsedLinks: [ParsedLink]) throws {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            // Delete all existing outgoing page + source links, then insert the
            // resolved subset. Faithful port of `SQLiteWikiStore.replaceLinks`:
            // canonical-ULID targets validate by id (direct row fetch); legacy
            // and forward links resolve by name via `resolveLinkTarget`. All
            // resolvers used here are the `*Locked` variants that take the
            // in-transaction `db` — the public `resolveTitleToID` /
            // `resolveSourceByName` open their own `dbWriter.read`, which would
            // re-enter the DatabasePool's serial queue and hit GRDB's fatal
            // "Database methods are not reentrant".
            try db.execute(sql: "DELETE FROM page_links WHERE from_page_id = ?;",
                           arguments: [pageID.rawValue])
            try db.execute(sql: "DELETE FROM source_links WHERE from_page_id = ?;",
                           arguments: [pageID.rawValue])
            for link in parsedLinks {
                switch link.linkType {
                case .page:
                    let resolved: PageID?
                    if let id = try self.canonicalLinkID(link, in: db) {
                        resolved = id
                    } else {
                        resolved = try self.resolveLinkTarget(
                            link, using: self.resolveTitleToIDLocked, in: db)
                    }
                    guard let resolved else { continue }
                    try db.execute(sql: """
                    INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text)
                    VALUES (?, ?, ?);
                    """, arguments: [pageID.rawValue, resolved.rawValue, link.linkText])
                case .source:
                    let resolved: PageID?
                    if let id = try self.canonicalLinkID(link, in: db) {
                        resolved = id
                    } else {
                        resolved = try self.resolveLinkTarget(
                            link, using: self.resolveSourceByNameLocked, in: db)
                    }
                    guard let resolved else { continue }
                    // Resolve the `@vN` ordinal (1-based) to a concrete smv id;
                    // NULL when unpinned or out-of-range (follows the active ref).
                    let pinID = try link.versionPin.flatMap {
                        try self.resolveVersionPin($0, sourceID: resolved, in: db)
                    }
                    // Embed source links (`![[source:…]]`) write a DISTINCT edge
                    // with role='embed' — the `source_links_edge` unique index
                    // treats (from, to, role, pin) as distinct, so a cite + embed
                    // to the same source coexist as separate rows (Phase 4a, AC.3).
                    let role = link.isEmbed ? "embed" : "cite"
                    try db.execute(sql: """
                    INSERT OR IGNORE INTO source_links
                        (from_page_id, to_source_id, link_text, role, pinned_version_id)
                    VALUES (?, ?, ?, ?, ?);
                    """, arguments: [pageID.rawValue, resolved.rawValue, link.linkText,
                                     role, pinID?.rawValue])
                case .chat:
                    // Chat links resolve at render time (no persisted graph edge).
                    continue
                }
            }
        }
    }

    // MARK: - WikiStore protocol: Sources

    public func addSource(
        filename: String, data: Data,
        zoteroItemKey: String? = nil, zoteroItemTitle: String? = nil,
        mimeType: String? = nil, provenance: SourceProvenance? = nil,
        role: SourceRole = .primary, originalPath: String? = nil,
        activityID: String? = nil, resolvedDisplayName: String?? = nil
    ) throws -> SourceSummary {
        // Resolve the display name BEFORE entering the locked mutate path
        // (a CSV-ish PDFKit parse would extend the write transaction past the
        // 5 s busy_timeout — issue #229).
        let ext = (filename as NSString).pathExtension.lowercased()
        let utiMime: String? = {
            #if canImport(UniformTypeIdentifiers)
            return ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType
            #else
            return nil
            #endif
        }()
        let mime = mimeType
            ?? ContentSniff.mimeType(of: data)
            ?? utiMime
            ?? MimeType.mime(forExtension: ext)  // #620: .mmd → text/mermaid (UTType can't resolve it)
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
            let contentHash = portableSHA256( data)
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

    /// 2-arg convenience requirement: forward to the full-signature impl with
    /// all trailing args at their defaults (`nil` / `.primary`). Mirrors
    /// `SQLiteWikiStore`'s defaulted-parameter convenience.
    @discardableResult
    public func addSource(filename: String, data: Data) throws -> SourceSummary {
        try addSource(
            filename: filename, data: data,
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil,
            provenance: nil, role: .primary, originalPath: nil,
            activityID: nil, resolvedDisplayName: nil)
    }


    public func addBytelessSource(
        filename: String, mimeType: String? = nil,
        provenance: SourceProvenance, role: SourceRole = .primary
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
            let utiMime: String? = {
                #if canImport(UniformTypeIdentifiers)
                return ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType
                #else
                return nil
                #endif
            }()
            let mime = mimeType ?? utiMime
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
            // 1. Resolve the active content version (ref → version, else
            //    default-active MAX(id)). Mirrors `SQLiteWikiStore.sourceContent`.
            let cols = "sv.id, sv.source_id, sv.parent_id, sv.blob_hash"
            var row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(cols)
                FROM refs r
                JOIN source_versions sv ON sv.id = r.version_id
                WHERE r.kind = 'source-content' AND r.owner_id = ?;
                """,
                arguments: [id.rawValue]
            )
            if row == nil {
                // No ref → default-active rule: MAX(id) version.
                row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT \(cols)
                    FROM source_versions
                    WHERE source_id = ? ORDER BY id DESC LIMIT 1;
                    """,
                    arguments: [id.rawValue]
                )
            }
            guard let row else {
                // No version rows at all → unknown source.
                throw WikiStoreError.notFound(id)
            }

            // 2. Byteless source (blob_hash IS NULL) → empty Data (never throws).
            //    Mirrors `SQLiteWikiStore.sourceContent`'s explicit byteless path.
            let blobHash: String? = row["blob_hash"]
            guard let blobHash else { return Data() }

            // 3. Read the blob bytes.
            guard let blobRow = try Row.fetchOne(
                db,
                sql: "SELECT content FROM blobs WHERE hash = ?;",
                arguments: [blobHash]
            ) else {
                // A version points at a blob that is missing — an integrity
                // break (blob writes always precede version writes). Treat as
                // byteless (empty Data) rather than crashing, matching
                // `SQLiteWikiStore.sourceContent`'s resilient fallback.
                return Data()
            }
            return blobRow["content"]
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
        try dbWriter.read { db in
            // Same `runTitle` subquery as `pageOrigin` (#745) — resolves the
            // chat title for `chat:<id>` agents; NULL for other agent kinds.
            //
            // Raw 'chat:' prefix stripping — format owned by
            // `PageAuthor.chat(_:).rawValue`. Do not change the SQL prefix
            // without updating PageAuthor too (#797).
            let cols = """
            sv.id,
            a.name, a.kind,
            act.kind, act.plan, act.external_ref,
            sv.external_identity, sv.fetched_at,
            (SELECT c.title FROM chats c WHERE c.id = substr(a.name, 6) AND a.name LIKE 'chat:%')
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

    /// The full edit history for a source — every `source_versions` row joined
    /// to its `activities` → `agents` (the source-side mirror of
    /// `pageEditHistory`). Ordered NEWEST-FIRST (the provenance panel renders
    /// newest at top). Read-only: routes through `dbWriter.read` so this is
    /// safe off-main. READ-ONLY → emits no `ResourceChangeEvent`.
    public func sourceEditHistory(sourceID: PageID) throws -> [SourceOrigin] {
        try dbWriter.read { db in
            // Same `runTitle` subquery as `sourceOrigin` (#745).
            //
            // Raw 'chat:' prefix stripping — format owned by
            // `PageAuthor.chat(_:).rawValue`. Do not change the SQL prefix
            // without updating PageAuthor too (#797).
            let cols = """
            sv.id,
            a.name, a.kind,
            act.kind, act.plan, act.external_ref,
            sv.external_identity, sv.fetched_at,
            (SELECT c.title FROM chats c WHERE c.id = substr(a.name, 6) AND a.name LIKE 'chat:%')
            """
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(cols)
                FROM source_versions sv
                LEFT JOIN activities act ON act.id = sv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE sv.source_id = ?
                ORDER BY sv.id DESC;
                """,
                arguments: [sourceID.rawValue]
            )
            return rows.map { Self.originFrom(row: $0) }
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
            try dbWriter.write { db in
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
        try dbWriter.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT id FROM sources WHERE ingested_at IS NOT NULL;"
            )
            return Set(rows)
        }
    }

    // MARK: - WikiStore protocol: Processed markdown versions

    public func appendContentVersion(
        sourceID: PageID, data: Data, mimeType: String? = nil,
        provenance: SourceProvenance? = nil
    ) throws -> SourceVersion {
        try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            guard data.count <= Self.ingestByteCap else {
                throw WikiStoreError.unexpected(
                    "source \(data.count) bytes exceeds cap \(Self.ingestByteCap)")
            }
            let contentHash = portableSHA256( data)
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_markdown_versions WHERE file_id = ?;",
                arguments: [sourceID.rawValue]
            ) ?? 0
            return count > 0
        }
    }

    public func processedMarkdownHistory(sourceID: PageID) throws -> [SourceMarkdownVersion] {
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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
            return try dbWriter.read { db in
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
            return try dbWriter.read { db in
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
            let contentHash = portableSHA256( data)
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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
        technique: String? = nil
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
    /// `processedMarkdownHead` — it re-enters `dbWriter.read` and deadlocks).


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
        sourceVersionID: String? = nil, note: String? = nil, modelVersion: String? = nil
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
        lastEditedBy: String? = nil
    ) throws -> String {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            let title = WikiNameRules.sanitized(title)
            let slug = try self.uniqueSlug(from: title, id: pageID, on: db)
            let bodyData = Data(body.utf8)
            let hash = portableSHA256( bodyData)
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

            // 2–6. Append the new version row (blob + activity + version +
            //      mirror + ref). Extracted to `appendPageVersionLocked` so
            //      `updatePage` (CAS-off) can share the same write seam
            //      WITHOUT re-entering `mutate(event:)` (the HIGH hazard
            //      called out in `plans/page-provenance.md` §5.3 — public
            //      mutators that compose must pass the `Database` to internal
            //      helpers, not re-call `mutate`). This helper does NOT emit;
            //      this method's `mutate` wrapper is the single emit site.
            return try self.appendPageVersionLocked(
                db: db, pageID: pageID, head: head, title: title, slug: slug,
                body: body, bodyData: bodyData, hash: hash,
                lastEditedBy: lastEditedBy, now: now, nowTS: nowTS)
        }
    }

    /// Shared version-append logic for `appendPageVersion` (CAS path) and
    /// `updatePage` (CAS-off path). Performs the six-step write:
    /// (1) skip the no-op case when the new body's hash matches the head blob
    ///     (avoids bloat from `wikictl` re-writes that touched nothing), but
    ///     ONLY when both titles also match — a pure title rename still
    ///     appends (the mirror needs the new slug);
    /// (2) `INSERT OR IGNORE` the new blob (CAS — identical bodies dedup);
    /// (3) get-or-create the activity's `agents` row via `ensurePageAuthorAgent`
    ///     so the author chain points at the REAL `chat:<id>` / `agent:<kind>`
    ///     / `user` / model-id (the structured #page-provenance upgrade —
    ///     previously the shared `legacy-import` agent for every page edit);
    /// (4) insert an `activities` row of kind `'edit'`;
    /// (5) insert a `page_versions` row (parent = `head`);
    /// (6) update the `pages` denormalized mirror + UPSERT the `page-content`
    ///     ref's `version_id` (bumping `generation`).
    ///
    /// NOT a `mutate(event:)` wrapper — does NOT emit. Each public caller
    /// (`appendPageVersion`, `updatePage`) wraps its own `mutate` body around
    /// this and emits `.page .updated` ONCE there (the Approach-A composition
    /// pattern — `mutate`'s doc at the top of this file warns `dbWriter.write`
    /// is NOT reentrant; a public mutator that re-calls `mutate` deadlocks).
    /// `updatePage` MUST NOT call public `appendPageVersion` (would double-emit
    /// AND re-enter); both call THIS instead.
    private func appendPageVersionLocked(
        db: Database, pageID: PageID, head: String?,
        title: String, slug: String,
        body: String, bodyData: Data, hash: String,
        lastEditedBy: String?, now: Date, nowTS: Double
    ) throws -> String {
        // No-op guard: identical body AND title = no real change. Skip the
        // version-append and the `pages` UPDATE (the ref's generation is
        // unchanged too). The mirror already reflects the head. `wikictl`'s
        // idempotent re-writes are the common case here — saves a row + a
        // `pages` UPDATE per no-op save. Returns the existing head's id so the
        // public caller's return value stays consistent with "the active
        // version after this save".
        if let head,
           let headRow = try Row.fetchOne(db, sql: """
                SELECT pv.blob_hash, pv.title, p.last_edited_by
                FROM page_versions pv
                JOIN pages p ON p.id = pv.page_id
                WHERE pv.id = ?;
                """, arguments: [head])
        {
            let headHash: String? = headRow["blob_hash"]
            let headTitle: String? = headRow["title"]
            let existingActor: String? = headRow["last_edited_by"]
            if headHash == hash && headTitle == title {
                // #763: If the author changed (e.g. a pre-v39 page with
                // `legacy-import` being re-ingested by `agent:ingest`), DON'T
                // short-circuit — fall through to create a new version +
                // activity so the provenance reflects the new author. Same
                // author → the no-op path is genuinely a no-op (bump
                // `updated_at` only, no version chain pollution).
                if existingActor == lastEditedBy || (existingActor == nil && lastEditedBy == nil) {
                    try db.execute(sql: """
                    UPDATE pages SET updated_at = ?, last_edited_by = ? WHERE id = ?;
                    """, arguments: [nowTS, lastEditedBy, pageID.rawValue])
                    return head
                }
                // Author changed — fall through to append a new version with
                // the new author's activity. This is the fix for #763: a re-
                // ingestion of identical content by a different agent no
                // longer preserves the old `legacy-import` activity on the
                // page-content ref.
            }
        }

        // 2. Blob (identical body = one row, ever).
        try db.execute(sql: """
        INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
        """, arguments: [hash, Int64(bodyData.count), bodyData])

        // 3. Real named agent (page provenance #page-provenance) + an
        //    'edit' activity. Degrades to legacy-import for nil/empty authors.
        let agentID = try self.ensurePageAuthorAgent(lastEditedBy, on: db)
        let activityID = ULID.generate()
        try db.execute(sql: """
        INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
        VALUES (?, 'edit', ?, ?, ?);
        """, arguments: [activityID, agentID, nowTS, nowTS])

        // 4. New version (parent = current head, or NULL for a brand-new page
        //    with no prior versions — `head == nil` should not happen after v34
        //    migration but is defensive).
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


    public func pageHeadVersionID(pageID: PageID) throws -> String? {
        try dbWriter.read { db in
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
        try dbWriter.read { db in
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

    /// The origin provenance of a page's active (HEAD) version: joins
    /// `refs → page_versions → activities → agents` (the read mirror of the
    /// page-PROV graph substrate sources already use). Falls back to the
    /// default-active rule (`MAX(id)` version) when no `page-content` ref
    /// exists (should not happen after v34 migration, but defensive). Returns
    /// `nil` when the page has no version rows (unknown id).
    ///
    /// NULL activity/agent columns degrade gracefully:
    /// - no activity → `activityKind` falls back to `"import"`, `plan`/`externalRef` to `nil`;
    /// - no agent → `agentName` falls back to `"unknown"`, `agentKind` to `"software"`
    ///   (the kind of the shared `legacy-import` agent that pre-v39 rows point at).
    ///
    /// Read-only: routes through `dbWriter.read` so this is safe off-main via
    /// `WikiReadPool` (a pooled store is `GRDBWikiStore(readOnlyURL:)`, no
    /// migrations). READ-ONLY → emits no `ResourceChangeEvent`.
    public func pageOrigin(pageID: PageID) throws -> PageOrigin? {
        try dbWriter.read { db in
            // The `runTitle` column (#745): for `chat:<id>` agents, LEFT JOIN the
            // `chats` table on the stripped chat ID to resolve the chat's display
            // title. `substr(a.name, 6)` strips the `chat:` prefix (5 chars + 1).
            // Non-chat agents (agent:*, user, legacy-import) produce NULL →
            // `runTitle` degrades to nil.
            //
            // Raw 'chat:' prefix stripping — format owned by
            // `PageAuthor.chat(_:).rawValue`. The prefix is sourced from
            // `ResourceKind.chat.linkPrefix`. Do not change the SQL prefix
            // without updating PageAuthor too (#797).
            let cols = """
            pv.id, pv.title, pv.blob_hash,
            a.name, a.kind,
            act.kind, act.plan, act.external_ref,
            (SELECT c.title FROM chats c WHERE c.id = substr(a.name, 6) AND a.name LIKE 'chat:%'),
            pv.saved_at
            """
            // 1. Prefer the active ref (matches pageHeadVersionIDLocked).
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(cols)
                FROM refs r
                JOIN page_versions pv ON pv.id = r.version_id
                LEFT JOIN activities act ON act.id = pv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE r.kind = 'page-content' AND r.owner_id = ?;
                """,
                arguments: [pageID.rawValue]
            ) {
                return Self.pageOriginFrom(row: row)
            }
            // 2. Fall back to the default-active rule: MAX(id) version.
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(cols)
                FROM page_versions pv
                LEFT JOIN activities act ON act.id = pv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE pv.page_id = ? ORDER BY pv.id DESC LIMIT 1;
                """,
                arguments: [pageID.rawValue]
            ) else { return nil }
            return Self.pageOriginFrom(row: row)
        }
    }

    /// The full edit history for a page — every `page_versions` row joined to
    /// its `activities` → `agents` (extends `pageVersionHistory` with the
    /// PROV join). Ordered OLDEST-FIRST (matches `pageVersionHistory` so
    /// `entry.last` is the HEAD). An empty page (`createPage`'s empty root)
    /// is included as one entry (kind 'import'); a fresh-then-edited page
    /// therefore returns exactly 2 entries (the empty root + the first real
    /// edit) — unless the same author edited within the 5s amend-coalescing
    /// window, in which case the second save amends the root in place and no
    /// new version row is appended (autosave semantics — see
    /// `tryAmendPageVersion`). Read-only: emits nothing.
    public func pageEditHistory(pageID: PageID) throws -> [PageOrigin] {
        try dbWriter.read { db in
            // Same `runTitle` subquery as `pageOrigin` (#745) — resolves the chat
            // title for `chat:<id>` agents; NULL for other agent kinds.
            //
            // Raw 'chat:' prefix stripping — format owned by
            // `PageAuthor.chat(_:).rawValue`. Do not change the SQL prefix
            // without updating PageAuthor too (#797).
            let cols = """
            pv.id, pv.title, pv.blob_hash,
            a.name, a.kind,
            act.kind, act.plan, act.external_ref,
            (SELECT c.title FROM chats c WHERE c.id = substr(a.name, 6) AND a.name LIKE 'chat:%'),
            pv.saved_at
            """
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(cols)
                FROM page_versions pv
                LEFT JOIN activities act ON act.id = pv.activity_id
                LEFT JOIN agents a ON a.id = act.agent_id
                WHERE pv.page_id = ?
                ORDER BY pv.id DESC;
                """,
                arguments: [pageID.rawValue]
            )
            return rows.map { Self.pageOriginFrom(row: $0) }
        }
    }

    /// Decode a `PageOrigin` from a joined row. NULL activity/agent columns
    /// degrade gracefully (matches `originFrom(row:)` for sources).
    private static func pageOriginFrom(row: Row) -> PageOrigin {
        // Position 0..9 mirrors the SELECT column order in `pageOrigin`/
        // `pageEditHistory`. `pv.id`/`pv.title`/`pv.blob_hash`/`pv.saved_at`
        // are NOT NULL per the `page_versions` schema; the LEFT-joined
        // `agents` + `activities` columns can be NULL (a pre-v39 page whose
        // activity's agent was deleted, or a root version whose activity_id is
        // somehow null). `String?` decodes both cases; `?? default` degrades.
        // Position 8 is the `runTitle` subquery (#745) — NULL for non-chat
        // agents or when the chat has been deleted.
        let versionID: String = (row[0] as String?) ?? ""
        let title: String = (row[1] as String?) ?? ""
        let blobHash: String? = row[2]
        let agentName: String? = row[3]
        let agentKind: String? = row[4]
        let activityKind: String? = row[5]
        let plan: String? = row[6]
        let externalRef: String? = row[7]
        let runTitle: String? = row[8]
        let savedAt: Double = (row[9] as Double?) ?? 0
        return PageOrigin(
            versionID: versionID,
            title: title,
            blobHash: blobHash,
            agentName: agentName ?? "unknown",
            agentKind: agentKind ?? "software",
            activityKind: activityKind ?? "import",
            plan: plan,
            externalRef: externalRef,
            runTitle: runTitle,
            savedAt: Date(timeIntervalSince1970: savedAt)
        )
    }


    /// Read the full blob-decoded body of an arbitrary page version by its id.
    /// The read-side counterpart of `revertPage`'s internal join: the same
    /// `page_versions → blobs` query, but as a pure read with no mutation.
    /// Returns `nil` when no `page_versions` row matches `versionID`. The body
    /// is decoded as UTF-8 (page bodies are always written as UTF-8 by
    /// `appendPageVersion`); a decode failure degrades to an empty string
    /// rather than throwing (mirrors `revertPage`'s `?? ""` fallback).
    ///
    /// READ-ONLY: routes through `dbWriter.read`, so this is safe off-main via
    /// `WikiReadPool` and emits no `ResourceChangeEvent`. Used by the Versions
    /// window to view/diff a historical version without restoring it.
    public func pageVersionBody(versionID: String) throws -> String? {
        try dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT b.content
                FROM page_versions pv
                JOIN blobs b ON b.hash = pv.blob_hash
                WHERE pv.id = ?;
                """,
                arguments: [versionID]
            ) else { return nil }
            let bodyData: Data = row["content"]
            return String(data: bodyData, encoding: .utf8) ?? ""
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


    /// Restore a page to a previous version by appending a NEW version node
    /// (the append-only counterpart of `revertPage`; mirrors
    /// `revertProcessedMarkdown` for sources). The new row reuses the target's
    /// `blob_hash` (CAS dedup — identical bytes already dedup to one blob), so a
    /// restore adds zero blob bytes; what's new is the auditable `page_versions`
    /// node + its `'restore'` PROV activity. The new node becomes HEAD (the
    /// `page-content` ref is repointed to it); history is never mutated. Emits a
    /// `.page .updated` `ResourceChangeEvent` via `mutate()`.
    @discardableResult
    public func restorePage(pageID: PageID, to versionID: String) throws -> String {
        try mutate(event: { _ in
            self.localEvent(.page, id: pageID.rawValue, change: .updated)
        }) { db in
            // 1. Read the target version's blob_hash + title + content.
            guard let row = try Row.fetchOne(db, sql: """
            SELECT pv.blob_hash, pv.title, b.content
            FROM page_versions pv
            JOIN blobs b ON b.hash = pv.blob_hash
            WHERE pv.id = ? AND pv.page_id = ?;
            """, arguments: [versionID, pageID.rawValue]) else {
                throw WikiStoreError.unexpected("restore target \(versionID) not found for page \(pageID.rawValue)")
            }
            let targetBlobHash: String = row["blob_hash"]
            let targetTitle: String = row["title"]
            let bodyData: Data = row["content"]
            let body = String(data: bodyData, encoding: .utf8) ?? ""

            // 2. Current HEAD is the parent of the new restore node.
            let head = try Self.pageHeadVersionIDLocked(pageID: pageID, on: db)

            // 3. Create a 'restore' PROV activity (distinct from 'edit'/'import'
            //    so the history badges it as a restore). Author = the user
            //    (a manual restore is an explicit user action).
            let agentID = try self.ensurePageAuthorAgent(PageAuthor.user.rawValue, on: db)
            let activityID = ULID.generate()
            let now = Date()
            let nowTS = now.timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO activities (id, kind, agent_id, started_at, ended_at)
            VALUES (?, 'restore', ?, ?, ?);
            """, arguments: [activityID, agentID, nowTS, nowTS])

            // 4. Append the new version node (parent = current head; reuses the
            //    target's blob_hash — no blob INSERT needed, it already exists).
            let newVersionID = ULID.generate()
            let sanitizedTitle = WikiNameRules.sanitized(targetTitle)
            let slug = try self.uniqueSlug(from: sanitizedTitle, id: pageID, on: db)
            try db.execute(sql: """
            INSERT INTO page_versions (id, page_id, parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?);
            """, arguments: [newVersionID, pageID.rawValue, head, targetBlobHash,
                            sanitizedTitle, activityID, nowTS])

            // 5. Update the denormalized pages mirror (fires the FTS5 trigger —
            //    pages use external-content FTS over `pages`, so no manual
            //    search refresh is needed).
            try db.execute(sql: """
            UPDATE pages
            SET title = ?, slug = ?, body_markdown = ?,
                updated_at = ?, version = version + 1, last_edited_by = ?
            WHERE id = ?;
            """, arguments: [sanitizedTitle, slug, body, nowTS,
                            PageAuthor.user.rawValue, pageID.rawValue])
            guard db.changesCount > 0 else { throw WikiStoreError.notFound(pageID) }

            // 6. Repoint HEAD to the NEW restore node.
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('page-content', ?, ?, 1, ?)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = generation + 1,
                updated_at = excluded.updated_at;
            """, arguments: [pageID.rawValue, newVersionID, nowTS])

            return newVersionID
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

    /// Validate and execute a `workspaces.status` transition on `db`.
    ///
    /// This is the **single write seam** for the `status` column: every UPDATE
    /// to it routes through here (the initial `INSERT … 'open'` in
    /// `createWorkspace` is the lone exception — it sets the starting state,
    /// not a transition). Reads the current status inside the caller's
    /// savepoint, asserts it is in `allowedFrom`, and writes the new status —
    /// read-validate-write in one transaction, so there is no TOCTOU window
    /// between the guard and the write. Mirrors `QueueStore.validateTransition`
    /// but operates inline on the caller's `Database` (it does NOT open its own
    /// write, so it preserves the `mutate(event:_:)` emission invariant — every
    /// public mutator still owns its `mutate` call and event emission).
    ///
    /// The per-call `allowedFrom` reflects the status that is **actually
    /// reachable at that call site** (e.g. the merge catch block runs from
    /// `.open`, because `mutate()` rolls the step-1 `'merging'` write back when
    /// the closure throws on conflict). See `plans/workspace-status-fsm.md`.
    private func transitionWorkspace(
        on db: Database, id: String,
        to: WorkspaceStatus, allowedFrom: Set<WorkspaceStatus>
    ) throws {
        let currentRaw = try String.fetchOne(
            db, sql: "SELECT status FROM workspaces WHERE id = ?;",
            arguments: [id]
        )
        guard let currentRaw else { throw WorkspaceError.notFound(id) }
        guard let current = WorkspaceStatus(rawValue: currentRaw) else {
            throw WorkspaceError.invalidStateTransition(from: nil, to: to)
        }
        guard allowedFrom.contains(current) else {
            throw WorkspaceError.invalidStateTransition(from: current, to: to)
        }
        try db.execute(
            sql: "UPDATE workspaces SET status = ?, updated_at = ? WHERE id = ?;",
            arguments: [to.rawValue, Date().timeIntervalSince1970, id]
        )
    }

    public func workspaceSummary(id: String) throws -> WorkspaceSummary? {
        try dbWriter.read { db in
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
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT workspace_id, owner_id, base_version_id, version_id, blob_hash, title, updated_at
            FROM workspace_refs WHERE workspace_id = ?;
            """, arguments: [workspaceID])
            return rows.map { row in
                // blob_hash and title are nullable (INSERTs use NULL for refs
                // without a blob/title). Decode as String? explicitly so GRDB
                // doesn't try to force-decode NULL → String.
                let blobHash: String? = row["blob_hash"]
                let title: String? = row["title"]
                return WorkspaceRef(
                    workspaceID: row["workspace_id"],
                    ownerID: PageID(rawValue: row["owner_id"]),
                    baseVersionID: row["base_version_id"],
                    versionID: row["version_id"],
                    blobHash: blobHash,
                    title: title,
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
        }
    }


    public func workspaceWritePage(
        workspaceID: String, pageID: PageID, title: String, body: String,
        author: String? = nil
    ) throws -> String {
        try mutate(event: { _ in nil }) { db in
            let title = WikiNameRules.sanitized(title)
            let bodyData = Data(body.utf8)
            let hash = portableSHA256( bodyData)
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

            // #763: thread the author identity through ensurePageAuthorAgent
            // so workspace version activities carry the real agent (e.g.
            // `agent:ingest`), not the shared `legacy-import`.
            let agentID = try self.ensurePageAuthorAgent(author, on: db)
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
        try dbWriter.read { db in
            try Self.workspacePageVersionLocked(workspaceID: workspaceID, pageID: pageID, on: db)
        }
    }


    public func workspacePageBody(workspaceID: String, pageID: PageID) throws -> String? {
        try dbWriter.read { db in
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
                // 1. Mark workspace as 'merging' (.open → .merging, validated).
                try self.transitionWorkspace(
                    on: db, id: workspaceID, to: .merging, allowedFrom: [.open]
                )

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
                    // title is nullable (staging INSERTs use NULL).
                    let title: String? = ref["title"]
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
                        try self.mintCreatedPage(db: db, pageID: pageID, blobHash: stagedHash, title: title ?? "")
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

                // 4. All fast-forwarded → mark 'merged' (.merging → .merged).
                try self.transitionWorkspace(
                    on: db, id: workspaceID, to: .merged, allowedFrom: [.merging]
                )
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
                    // The merge savepoint rolled back on the conflict throw, so
                    // status reverted to .open (the step-1 'merging' write was
                    // undone) — transition from .open, not .merging.
                    try self.transitionWorkspace(
                        on: db, id: workspaceID, to: .conflicted, allowedFrom: [.open]
                    )

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
            try self.transitionWorkspace(
                on: db, id: id, to: .abandoned,
                allowedFrom: [.open, .merging, .conflicted]
            )
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
                    let hash = portableSHA256( mergedData)
                        .map { String(format: "%02x", $0) }.joined()
                    let nowTS = Date().timeIntervalSince1970

                    try db.execute(sql: """
                    INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
                    """, arguments: [hash, Int64(mergedData.count), mergedData])

                    // #763: use the workspace version's agent.
                    let agentID = try self.workspaceVersionAgentID(db: db, pageID: pageID)
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
                    // Refresh never wrote status in its savepoint (it only
                    // read-validated ==.open); that savepoint rolled back on the
                    // conflict throw, so status is still .open here.
                    try self.transitionWorkspace(
                        on: db, id: workspaceID, to: .conflicted, allowedFrom: [.open]
                    )

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
        try dbWriter.read { db in
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
            let hash = portableSHA256( bodyData)
                .map { String(format: "%02x", $0) }.joined()
            let now = Date()
            let nowTS = now.timeIntervalSince1970

            // 1. Blob.
            try db.execute(sql: """
            INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
            """, arguments: [hash, Int64(bodyData.count), bodyData])

            // 2. Activity.
            // #763: use the workspace version's agent.
            let agentID = try self.workspaceVersionAgentID(db: db, pageID: pageID)
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
            try self.transitionWorkspace(
                on: db, id: workspaceID, to: .open, allowedFrom: [.conflicted]
            )
        }
        // Now attempt the merge again.
        _ = try workspaceMerge(workspaceID: workspaceID)
    }


    public func reapStaleWorkspaces(ttl: TimeInterval) throws -> Int {
        try mutate(event: { count in
            count > 0 ? self.localEvent(.page, id: "workspace-reap", change: .updated) : nil
        }) { db in
            let cutoff = Date().timeIntervalSince1970 - ttl
            // Select stale open workspace IDs.
            let staleIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM workspaces WHERE status = 'open' AND updated_at < ?;",
                arguments: [cutoff]
            )
            // Delete refs + conflicts, then mark abandoned (mirrors
            // SQLiteWikiStore.reapStaleWorkspaces — the refs are the staging
            // rows, which must not survive a reap).
            for id in staleIDs {
                try db.execute(sql: "DELETE FROM workspace_refs WHERE workspace_id = ?;",
                               arguments: [id])
                try db.execute(sql: "DELETE FROM workspace_conflicts WHERE workspace_id = ?;",
                               arguments: [id])
                // staleIDs are all '.open' (the SELECT filters on status='open'),
                // so the transition is .open → .abandoned.
                try self.transitionWorkspace(
                    on: db, id: id, to: .abandoned, allowedFrom: [.open]
                )
            }
            return staleIDs.count
        }
    }

    // MARK: - WikiStore protocol: System prompt + log + wiki index

    public func getSystemPrompt() throws -> SystemPrompt {
        // The system_prompt table was removed in v42. Always return the compiled
        // default. The version is a stable hash of the body so the changeToken
        // advances when the compiled prompt changes.
        let version = Int64(SystemPrompt.defaultBody.hashValue & 0x7FFFFFFF)
        return SystemPrompt(body: SystemPrompt.defaultBody,
                            updatedAt: Date(timeIntervalSince1970: 0), version: Int(version))
    }

    public func updateSystemPrompt(body: String) throws {
        // The system_prompt table was removed in v42. This method is a no-op.
        // The system prompt is now read-only, always sourced from the compiled
        // SystemPrompt.defaultBody.
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
        return try dbWriter.read { db in
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
        try dbWriter.read { db in
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
            return try dbWriter.read { db in
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

    public func searchSimilar(query: String, limit: Int, bm25Leg: [WikiPageSummary]?) throws -> [WikiPageSummary] {
        try dbWriter.read { db in
            let pool = max(limit * 2, limit)
            // --- BM25 leg (Tantivy) ---
            // `bm25Leg` is the sole lexical path after #634 (FTS5 dropped). A
            // nil/empty leg means the caller has no Tantivy index → no BM25
            // results (only the semantic cosine leg below contributes). The
            // rank-fusion contract is unchanged: two legs (BM25 + cosine),
            // one of which may be empty.
            let ftsRows = bm25Leg ?? []

            // --- Semantic (cosine) pass + RRF ---
            // Replaced the prior `MIN(<cosine distance>(embedding, ?)) GROUP BY
            // page_id` SQL scalar with Swift-side dot-product ranking over
            // L2-normalized vectors (issue #628 — vendored C scalar retired).
            // Stored vectors are unit-norm (`Embedder` contract), so dot == cosine.
            // Gated on the embedder being loaded (else there's no query vector).
            if EmbeddingService.isAvailable,
               let queryBlob = EmbeddingService.embeddingBlob(for: query),
               let queryVec = VectorCosine.decode(queryBlob) {
                DebugLog.store("search[pages]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=true")
                // Single query: carry the summary columns + chunk embedding per row.
                // Group by page keeping the best (max-sim) row in Swift — one
                // round-trip, no `IN (...)` re-fetch. `page_chunks` is WITHOUT
                // ROWID; a sequential clustered-index scan is fine at current
                // scale (see `VectorCosine` scale-scope note).
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, p.title, p.updated_at, p.created_at, pc.embedding
                    FROM page_chunks pc
                    JOIN pages p ON p.id = pc.page_id;
                    """)
                var best: [String: (sim: Float, row: Row)] = [:]
                best.reserveCapacity(rows.count)
                for row in rows {
                    let id: String = row["id"]
                    let embedding: Data = row["embedding"]
                    guard let v = VectorCosine.decode(embedding), v.count == queryVec.count else {
                        DebugLog.store("search[pages]: skipped undecodable chunk for \(id)")
                        continue
                    }
                    let sim = VectorCosine.dot(queryVec, v)
                    if sim > (best[id]?.sim ?? -.infinity) { best[id] = (sim, row) }
                }
                let semRows = best
                    .sorted { $0.value.sim > $1.value.sim }
                    .prefix(pool)
                    .map { _, entry in
                        WikiPageSummary(
                            id: PageID(rawValue: entry.row["id"]),
                            title: entry.row["title"],
                            updatedAt: Date(timeIntervalSince1970: entry.row["updated_at"]),
                            createdAt: Date(timeIntervalSince1970: entry.row["created_at"])
                        )
                    }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[pages]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=false")
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
            return try dbWriter.read { db in
                // Mirrors SQLiteWikiStore: text is the source's title + its
                // processed-markdown HEAD body (title-only when un-extracted).
                // The body is the CAS-resolved HEAD version (`smvHeadBodySQL`),
                // NOT the filename — guards the regression where the embed text
                // silently emptied to just the filename (AC.9a).
                let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, COALESCE(s.display_name, s.filename) AS title,
                       \(Self.smvHeadBodySQL) AS body
                FROM sources s
                LEFT JOIN source_chunks sc ON sc.source_id = s.id
                WHERE sc.source_id IS NULL
                ORDER BY s.id;
                """)
                return rows.map { row in
                    let id = PageID(rawValue: row["id"])
                    let title: String = row["title"]
                    let body: String = row["body"]
                    return (id, body.isEmpty ? title : "\(title)\n\n\(body)")
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore.missingSourceEmbeddingWork failed: \(error)")
            return []
        }
    }

    public func searchSimilarSources(query: String, limit: Int, bm25Leg: [SourceSummary]?) throws -> [SourceSummary] {
        try dbWriter.read { db in
            let pool = max(limit * 2, limit)
            // --- BM25 leg (Tantivy) ---
            // Sole lexical leg post-#634. nil/empty → no BM25 results, only the
            // cosine semantic leg contributes. See `searchSimilar(query:limit:bm25Leg:)`
            // for the full rationale.
            let ftsRows = bm25Leg ?? []

            // --- Semantic (cosine) pass + RRF ---
            // Swift-side dot product (issue #628) over L2-normalized chunk
            // embeddings. Same shape as `searchSimilar` (pages).
            if EmbeddingService.isAvailable,
               let queryBlob = EmbeddingService.embeddingBlob(for: query),
               let queryVec = VectorCosine.decode(queryBlob) {
                DebugLog.store("search[sources]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=true")
                // Single query: carry the 12 summary columns + chunk embedding per
                // row. The explicit column list (NEVER `SELECT s.*`) is the
                // `readSourceSummary(from:)` contract — a regression guard kept
                // from `searchSimilarSourcesNeverSelectsStar`.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size, s.created_at, s.updated_at,
                           s.version, s.zotero_item_key, s.zotero_item_title, s.display_name, s.role,
                           sc.embedding
                    FROM source_chunks sc
                    JOIN sources s ON s.id = sc.source_id;
                    """)
                var best: [String: (sim: Float, row: Row)] = [:]
                best.reserveCapacity(rows.count)
                for row in rows {
                    let id: String = row["id"]
                    let embedding: Data = row["embedding"]
                    guard let v = VectorCosine.decode(embedding), v.count == queryVec.count else {
                        DebugLog.store("search[sources]: skipped undecodable chunk for \(id)")
                        continue
                    }
                    let sim = VectorCosine.dot(queryVec, v)
                    if sim > (best[id]?.sim ?? -.infinity) { best[id] = (sim, row) }
                }
                let semRows: [SourceSummary] = try best
                    .sorted { $0.value.sim > $1.value.sim }
                    .prefix(pool)
                    .map { _, entry in try Self.readSourceSummary(from: entry.row) }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[sources]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=false")
            return Array(ftsRows.prefix(limit))
        }
    }


    // MARK: - WikiStore protocol: Bookmark nodes

    public func listBookmarkNodes() throws -> [BookmarkNode] {
        try dbWriter.read { db in
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


    /// Upsert a streaming assistant row under a stable draft handle (#826).
    /// First call INSERTs (assigns the next seq, is_draft=1); subsequent calls
    /// UPDATE the same row's `event_json`/`text` in place (is_draft unchanged).
    /// `isDraft=false` finalizes (turn complete): sets `is_draft=0` AND bumps
    /// `chats.updated_at` + refreshes the chat_search FTS sidecar. Per C6,
    /// draft checkpoints (isDraft=true) do NOT bump `updated_at` so the chat
    /// list doesn't re-sort every ~2s during generation.
    ///
    /// Manual SELECT/INSERT/UPDATE inside `mutate()` (C5 — matches existing
    /// `appendChatMessages` style). Idempotent: re-checkpointing the same
    /// content is a no-op UPDATE. Throws `.notFound` if `chatID` has no row.
    public func checkpointStreamingMessage(
        chatID: PageID, handle: String, event: AgentEvent, isDraft: Bool
    ) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            // Existence check (mirrors appendChatMessages).
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM chats WHERE id = ?;",
                arguments: [chatID.rawValue]
            ) ?? 0
            guard exists != 0 else {
                throw WikiStoreError.notFound(chatID)
            }

            let now = Date()
            let json = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? "{}"

            // Does a row with this draft_handle already exist?
            let existingSeq = try Int.fetchOne(
                db,
                sql: "SELECT seq FROM chat_messages WHERE chat_id = ? AND draft_handle = ?;",
                arguments: [chatID.rawValue, handle]
            )

            if let _ = existingSeq {
                // UPDATE in place — keep the original created_at + id + seq.
                try db.execute(sql: """
                UPDATE chat_messages
                SET event_json = ?, text = ?, is_draft = ?
                WHERE chat_id = ? AND draft_handle = ?;
                """, arguments: [
                    json, event.plainText, isDraft ? 1 : 0,
                    chatID.rawValue, handle
                ])
            } else {
                // INSERT — assign the next dense seq (continuing from max).
                let maxSeq = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(seq), -1) FROM chat_messages WHERE chat_id = ?;",
                    arguments: [chatID.rawValue]
                ) ?? -1
                let nextSeq = maxSeq + 1
                let messageID = PageID(rawValue: ULID.generate())
                try db.execute(sql: """
                INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at, is_draft, draft_handle)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, arguments: [
                    messageID.rawValue, chatID.rawValue, nextSeq,
                    event.chatRole, json, event.plainText,
                    now.timeIntervalSince1970, isDraft ? 1 : 0, handle
                ])
            }

            // C6: only bump updated_at + refresh chat_search on finalize (not
            // on draft checkpoints) so the chat list doesn't re-sort every ~2s
            // during generation and the FTS sidecar only refreshes on the
            // authoritative final text.
            if !isDraft {
                try db.execute(sql: """
                UPDATE chats SET updated_at = ? WHERE id = ?;
                """, arguments: [now.timeIntervalSince1970, chatID.rawValue])

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
                    DebugLog.store("checkpointStreamingMessage chat_search refresh failed — \(error)")
                }
            }
        }
    }

    /// Finalize any stale draft rows for a chat (C8). Called when a chat is
    /// opened: a draft row left over from an interrupted turn (hard kill)
    /// should no longer be marked as in-progress. Sets `is_draft=0` for all
    /// draft rows belonging to `chatID`. Cheap single UPDATE. Bumps
    /// `chats.updated_at` so the chat list reflects the finalized state.
    public func finalizeStaleDrafts(forChat chatID: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE chat_messages SET is_draft = 0
            WHERE chat_id = ? AND is_draft = 1;
            """, arguments: [chatID.rawValue])
            try db.execute(sql: """
            UPDATE chats SET updated_at = ? WHERE id = ?;
            """, arguments: [Date().timeIntervalSince1970, chatID.rawValue])
        }
    }


    public func listChats() throws -> [ChatSummary] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                   (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                   c.summary, c.summary_at, c.acp_session_id
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
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, seq, event_json, created_at, summary, summary_kind, summary_at, is_draft
            FROM chat_messages
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
                // Decode-if-present for the nullable summary columns
                // (chat-summary plan §3.4). Pre-v40 rows and unsummarized
                // messages surface as nil.
                let summary: String? = row["summary"]
                let summaryKindRaw: String? = row["summary_kind"]
                let summaryAtDouble: Double? = row["summary_at"]
                out.append(ChatMessage(
                    id: PageID(rawValue: row["id"]),
                    chatID: chatID,
                    seq: row["seq"],
                    event: event,
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    summary: summary,
                    summaryKind: summaryKindRaw.flatMap(ChatMessageSummaryKind.init(rawValue:)),
                    summaryAt: summaryAtDouble.map { Date(timeIntervalSince1970: $0) },
                    isDraft: (row["is_draft"] as Int?) == 1
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
            // A 0-row UPDATE means the chat id is gone — throw .notFound inside
            // `mutate`'s body so the savepoint rolls back and no event is emitted
            // (mirrors updatePage / SQLiteWikiStore.renameChat).
            guard db.changesCount > 0 else { throw WikiStoreError.notFound(id) }

            // Refresh the FTS sidecar title so keyword search reflects the new
            // name (the body is unchanged). A no-op if no chat_search row exists
            // yet (a chat with no messages has nothing to index). Mirrors
            // `SQLiteWikiStore.renameChat`'s `upsertChatSearch(chatID:)`.
            do {
                let body: String = (try String.fetchOne(
                    db,
                    sql: "SELECT COALESCE(GROUP_CONCAT(text, '\n'), '') FROM chat_messages WHERE chat_id = ?;",
                    arguments: [id.rawValue]
                )) ?? ""
                try db.execute(sql: """
                INSERT OR REPLACE INTO chat_search (chat_id, title, body) VALUES (?, ?, ?);
                """, arguments: [id.rawValue, title, body])
            } catch {
                DebugLog.store("GRDBWikiStore.renameChat: upsertChatSearch[\(id.rawValue)] failed — \(error)")
            }
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

    /// Write (or clear) the ACP session ID for resume (#830). Bumps
    /// `updated_at`. Routes through `mutate(event:_:)` so it emits a
    /// `.chat .updated` event. Pass `nil` to clear (terminal teardown /
    /// permanent resume failure).
    public func updateChatAcpSessionId(chatID: PageID, acpSessionId: String?) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE chats SET acp_session_id = ?, updated_at = ?
            WHERE id = ?;
            """, arguments: [acpSessionId, Date().timeIntervalSince1970,
                            chatID.rawValue])
            guard db.changesCount > 0 else { throw WikiStoreError.notFound(chatID) }
        }
    }

    /// Write the cached one-line summary for a single assistant message
    /// (chat-summary plan §3.5). Routes through `mutate(event:_:)` and emits a
    /// `.chat .updated` event on the chat the message belongs to — the
    /// projection + model subscribe to `.chat` changes, and there is no
    /// standalone `.message` resource kind (`chat_messages` cascade-delete with
    /// `chats`). The write is idempotent (re-running on an already-summarized
    /// row overwrites the cached values), but the caller is expected to
    /// short-circuit when `summary` is non-nil (compute-once, AC.6).
    public func updateMessageSummary(
        chatID: PageID, messageID: PageID, summary: String, kind: ChatMessageSummaryKind
    ) throws {
        try mutate(event: { _ in
            self.localEvent(.chat, id: chatID.rawValue, change: .updated)
        }) { db in
            try db.execute(sql: """
            UPDATE chat_messages
            SET summary = ?, summary_kind = ?, summary_at = ?
            WHERE id = ?;
            """, arguments: [summary, kind.rawValue,
                            Date().timeIntervalSince1970, messageID.rawValue])
        }
    }

    public func listAllChatsOrderedByID() throws -> [ChatSummary] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                   (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                   c.summary, c.summary_at, c.acp_session_id
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
        try dbWriter.read { db in
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
            return try dbWriter.read { db in
                // Build the embeddable text from the chat title + concatenated
                // user/assistant message text — exactly like
                // `SQLiteWikiStore.missingChatEmbeddingWork`. The FTS sidecar
                // (`chat_search`) is NOT used here because it may lag the chat's
                // actual messages (it's updated at append time, but the embeddable
                // text must reflect the raw message text, not the FTS body).
                let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.title,
                       COALESCE((
                           SELECT GROUP_CONCAT(m.text, '\n')
                           FROM chat_messages m
                           WHERE m.chat_id = c.id AND m.role IN ('user', 'assistant')
                       ), '') AS body
                FROM chats c
                WHERE NOT EXISTS (
                    SELECT 1 FROM chat_chunks WHERE chat_id = c.id
                )
                ORDER BY c.id;
                """)
                return rows.map { row -> (id: PageID, text: String) in
                    let id = PageID(rawValue: row["id"])
                    let title: String = row["title"]
                    let body: String = row["body"]
                    return (id, body.isEmpty ? title : "\(title)\n\n\(body)")
                }
            }
        } catch {
            DebugLog.store("GRDBWikiStore.missingChatEmbeddingWork failed: \(error)")
            return []
        }
    }

    public func searchSimilarChats(query: String, limit: Int, bm25Leg: [ChatSummary]?) throws -> [ChatSummary] {
        try dbWriter.read { db in
            let pool = max(limit * 2, limit)
            // --- BM25 leg (Tantivy) ---
            // Sole lexical leg post-#634. nil/empty → no BM25 results, only the
            // cosine semantic leg contributes.
            let ftsRows = bm25Leg ?? []

            // --- Semantic (cosine) pass + RRF ---
            // Swift-side dot product (issue #628) over L2-normalized chunk
            // embeddings. Same shape as `searchSimilar` (pages).
            if EmbeddingService.isAvailable,
               let queryBlob = EmbeddingService.embeddingBlob(for: query),
               let queryVec = VectorCosine.decode(queryBlob) {
                DebugLog.store("search[chats]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=true")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                           (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                           cc.embedding, c.acp_session_id
                    FROM chat_chunks cc
                    JOIN chats c ON c.id = cc.chat_id;
                    """)
                var best: [String: (sim: Float, row: Row)] = [:]
                best.reserveCapacity(rows.count)
                for row in rows {
                    let id: String = row["id"]
                    let embedding: Data = row["embedding"]
                    guard let v = VectorCosine.decode(embedding), v.count == queryVec.count else {
                        DebugLog.store("search[chats]: skipped undecodable chunk for \(id)")
                        continue
                    }
                    let sim = VectorCosine.dot(queryVec, v)
                    if sim > (best[id]?.sim ?? -.infinity) { best[id] = (sim, row) }
                }
                let semRows = best
                    .sorted { $0.value.sim > $1.value.sim }
                    .prefix(pool)
                    .map { _, entry in
                        Self.readChatSummary(from: entry.row, summary: nil, summaryAt: nil)
                    }
                return Array(RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit))
            }
            DebugLog.store("search[chats]: query=\(query) \(ftsRows.isEmpty ? "no-BM25" : "Tantivy-BM25"), cosine=false")
            return Array(ftsRows.prefix(limit))
        }
    }


    // MARK: - WikiStore protocol: Blob GC

    public func vacuumBlobs(dryRun: Bool) throws -> BlobVacuumReport {
        try dbWriter.write { db in
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
        try dbWriter.write { db in
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
        try dbWriter.write { db in
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
        try dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM wiki_metadata WHERE key = ?;",
                arguments: [key]
            )
        }
    }

    public func setMetadata(_ key: String, value: String) throws {
        // NO-EMIT: metadata flags don't change projected content.
        try dbWriter.write { db in
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

    /// Read a ChatSummary from a GRDB Row. The `summary` and `summaryAt` columns
    /// are passed in so this works for both the 6-column search variants (nil) and
    /// the 8-column list variants. Mirrors SQLiteWikiStore.chatSummary(from:).
    /// Columns (named): id, kind, title, created_at, updated_at, + an unnamed
    /// message-count subquery at index 5.
    private static func readChatSummary(
        from row: Row, summary: String?, summaryAt: Date?
    ) -> ChatSummary {
        let acpSessionId: String? = row["acp_session_id"]
        return ChatSummary(
            id: PageID(rawValue: row["id"]),
            kind: ChatKind(rawValue: row["kind"]) ?? .edit,
            title: row["title"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            messageCount: row["msg_count"],
            summary: summary,
            summaryAt: summaryAt,
            acpSessionId: acpSessionId
        )
    }


    /// The ingest byte cap (100 MiB). Mirrors `SQLiteWikiStore.ingestByteCap`
    /// — defined locally so GRDBWikiStore is self-contained (no cross-store
    /// reference). Public so tests can assert the cap (e.g. `SourcesTests`).
    public static let ingestByteCap = 100 * 1024 * 1024

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
        let hash = portableSHA256( data)
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

    /// Public protocol impl: the active content version for `sourceID`.
    /// Routes the read through `dbWriter.read` (the serial reader queue), which
    /// is reentrant-safe from within the private `db:`-taking helper. Mirrors
    /// `SQLiteWikiStore.activeContentVersion(sourceID:)` exactly.
    public func activeContentVersion(sourceID: PageID) throws -> SourceVersion? {
        try dbWriter.read { db in
            try self.activeContentVersion(sourceID: sourceID, on: db)
        }
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

    /// Whether the embedder is loaded — the semantic-cosine gate now that
    /// the C scalar target is retired (issue #628). Best-effort re-embed still
    /// routes through `EmbeddingService.isAvailable` directly (no separate
    /// probe).


    /// Best-effort re-embed of `sourceID` from `body`. Runs POST-commit (never
    /// inside `mutate`): reads the source name on its own, runs MLX chunked
    /// embeddings out-of-transaction, then writes via the existing public
    /// `storeSourceChunks` (its own transaction). Gated on the embedder being
    /// loaded (the model must be available to embed). Mirrors
    /// `SQLiteWikiStore.reembedSource` minus the lock-holding.
    private func reembedSource(sourceID: PageID, body: String) {
        guard let title = try? dbWriter.read({ db in
            try String.fetchOne(
                db,
                sql: "SELECT COALESCE(display_name, filename) FROM sources WHERE id = ?;",
                arguments: [sourceID.rawValue]
            )
        }) else { return }
        // Embedder-gated (issue #628): no C scalar to probe anymore; the
        // embedder must be loaded to produce chunk vectors.
        guard EmbeddingService.isAvailable else { return }
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


    /// Decode an origin row. NULL activity/agent columns degrade gracefully
    /// (matches `pageOriginFrom(row:)` for pages). Position 0..7 mirrors the
    /// SELECT column order in `sourceOrigin`/`sourceEditHistory`. `sv.id` and
    /// `sv.fetched_at` are NOT NULL per the `source_versions` schema; the
    /// LEFT-joined columns can be NULL. Position 7 is the `runTitle` subquery
    /// (#745) — NULL for non-chat agents or when the chat has been deleted.
    private static func originFrom(row: Row) -> SourceOrigin {
        let versionID: String = (row[0] as String?) ?? ""
        let agentName: String? = row[1]
        let agentKind: String? = row[2]
        let activityKind: String? = row[3]
        let plan: String? = row[4]
        let externalRef: String? = row[5]
        let externalIdentity: String? = row[6]
        let fetchedAt: Double = (row[7] as Double?) ?? 0
        let runTitle: String? = row[8]
        return SourceOrigin(
            versionID: versionID,
            agentName: agentName ?? "unknown",
            agentKind: agentKind ?? "software",
            activityKind: activityKind ?? "import",
            plan: plan,
            externalRef: externalRef,
            externalIdentity: externalIdentity,
            runTitle: runTitle,
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
    /// `processedMarkdownHead` — it re-enters `dbWriter.read` and deadlocks).
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

    /// #763: resolve the agent identity from a workspace-staged page version's
    /// activity (created by `workspaceWritePage` with the real author). Falls
    /// back to `legacyImportAgentID` when no workspace version or agent is
    /// found (genuinely degraded path — same as pre-#763).
    private func workspaceVersionAgentID(
        db: Database, pageID: PageID
    ) throws -> String {
        if let row = try Row.fetchOne(
            db, sql: """
            SELECT a.id, a.name, a.kind FROM workspace_refs wr
            LEFT JOIN page_versions pv ON pv.id = wr.version_id
            LEFT JOIN activities act ON act.id = pv.activity_id
            LEFT JOIN agents a ON a.id = act.agent_id
            WHERE wr.kind = 'page-content' AND wr.owner_id = ?
            ORDER BY wr.updated_at DESC LIMIT 1;
            """, arguments: [pageID.rawValue]
        ), let name = row["name"] as String?,
           let kind = row["kind"] as String? {
            return try ensureAgent(name: name, kind: kind, on: db)
        }
        return try legacyImportAgentID(on: db)
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
        // #763: resolve the author from the workspace version's activity.
        let agentID = try self.workspaceVersionAgentID(db: db, pageID: pageID)
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
        let hash = portableSHA256( mergedData)
            .map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let nowTS = now.timeIntervalSince1970

        // Blob.
        try db.execute(sql: """
        INSERT OR IGNORE INTO blobs (hash, byte_size, content) VALUES (?, ?, ?);
        """, arguments: [hash, Int64(mergedData.count), mergedData])

        // Merge PROV activity.
        // #763: use the workspace version's agent.
        let agentID = try self.workspaceVersionAgentID(db: db, pageID: pageID)
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
        // NOTE: Cannot call self.replaceLinks here — it re-enters mutate/dbWriter.write
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

    // MARK: - File Provider read-projection helpers

    /// Roll the source-content ref back to `versionID`, refreshing the
    /// denormalized `sources` mirror (byte_size, mime_type, content_hash).
    /// Ported from the former `SQLiteWikiStore.rollbackSourceContent`.
    public func rollbackSourceContent(sourceID: PageID, to versionID: PageID) throws {
        try mutate(event: { _ in
            self.localEvent(.source, id: sourceID.rawValue, change: .updated)
        }) { db in
            try self.rollbackSourceContentBody(db: db, sourceID: sourceID, versionID: versionID)
        }
    }

    private func rollbackSourceContentBody(db: Database, sourceID: PageID, versionID: PageID) throws {
        // Use inSavepoint (not inTransaction) — this method is called from inside
        // mutate()'s inSavepoint, so inSavepoint nests as a SAVEPOINT instead
        // of failing with "cannot start a transaction within a transaction".
        try db.inSavepoint {
            guard let target = try Row.fetchOne(
                db,
                sql: """
                SELECT blob_hash, mime_type FROM source_versions
                WHERE id = ? AND source_id = ?;
                """,
                arguments: [versionID.rawValue, sourceID.rawValue]
            ) else {
                throw WikiStoreError.notFound(versionID)
            }
            let blobHash: String? = target["blob_hash"]
            let mime: String? = target["mime_type"]

            var byteSize: Int64 = 0
            if let blobHash {
                byteSize = (try Int64.fetchOne(
                    db, sql: "SELECT byte_size FROM blobs WHERE hash = ?;",
                    arguments: [blobHash]
                )) ?? 0
            }

            let prevGeneration: Int = try self.refGeneration(sourceID: sourceID, on: db) ?? 0
            let nextGeneration: Int64 = Int64(prevGeneration + 1)
            let nowTS: Double = Date().timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at)
            VALUES ('source-content', ?, ?, ?, ?)
            ON CONFLICT(kind, owner_id) DO UPDATE SET
                version_id = excluded.version_id,
                generation = excluded.generation,
                updated_at = excluded.updated_at;
            """, arguments: [sourceID.rawValue, versionID.rawValue, nextGeneration, nowTS])

            try db.execute(sql: """
            UPDATE sources SET byte_size = ?, content_hash = ?, updated_at = ?,
                                version = version + 1
            WHERE id = ?;
            """, arguments: [byteSize, blobHash, nowTS, sourceID.rawValue])
            if let mime {
                try db.execute(sql: "UPDATE sources SET mime_type = ? WHERE id = ?;",
                               arguments: [mime, sourceID.rawValue])
            }
            return .commit
        }
    }

    /// All pages ordered by id (for the File Provider index projection).
    /// Ported from the former SQLiteWikiStore.listAllPagesOrderedByID.
    public func listAllPagesOrderedByID() throws -> [WikiPage] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, title, slug, body_markdown, created_at, updated_at, version
            FROM pages ORDER BY id ASC;
            """)
            return rows.map { row in
                WikiPage(
                    id: PageID(rawValue: row["id"]),
                    title: row["title"],
                    slug: row["slug"],
                    bodyMarkdown: row["body_markdown"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    version: row["version"]
                )
            }
        }
    }

    /// The source summary for `id`. Ported from the former
    /// SQLiteWikiStore.getSource(id:).
    public func getSource(id: PageID) throws -> SourceSummary {
        try dbWriter.read { db in try Self.getSourceSummary(id: id, on: db) }
    }

    /// One chat summary by id. Ported from the former
    /// SQLiteWikiStore.getChat(id:).
    public func getChat(id: PageID) throws -> ChatSummary {
        try dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT c.id, c.kind, c.title, c.created_at, c.updated_at,
                       (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS msg_count,
                       c.summary, c.summary_at, c.acp_session_id
                FROM chats c WHERE c.id = ?;
                """,
                arguments: [id.rawValue]
            ) else { throw WikiStoreError.notFound(id) }
            let summary: String? = row["summary"]
            let summaryAt: Double? = row["summary_at"]
            return Self.readChatSummary(
                from: row,
                summary: summary,
                summaryAt: summaryAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// All page-to-page links ordered (for the File Provider link index).
    /// Ported from the former SQLiteWikiStore.listAllLinks().
    public func listAllLinks() throws -> [IndexGenerators.LinkRow] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT from_page_id, to_page_id, link_text
            FROM page_links ORDER BY from_page_id, to_page_id;
            """)
            return rows.map { row in
                IndexGenerators.LinkRow(
                    from: row["from_page_id"],
                    to: row["to_page_id"],
                    linkText: row["link_text"],
                    type: "page"
                )
            }
        }
    }

    /// All page-to-source links ordered (for the File Provider link index).
    /// Ported from the former SQLiteWikiStore.listAllSourceLinks().
    public func listAllSourceLinks() throws -> [IndexGenerators.LinkRow] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT from_page_id, to_source_id, link_text
            FROM source_links ORDER BY from_page_id, to_source_id;
            """)
            return rows.map { row in
                IndexGenerators.LinkRow(
                    from: row["from_page_id"],
                    to: row["to_source_id"],
                    linkText: row["link_text"],
                    type: "source"
                )
            }
        }
    }

    /// All log entries ordered (for the File Provider log projection).
    /// Ported from the former SQLiteWikiStore.listAllLogEntriesOrderedByID().
    public func listAllLogEntriesOrderedByID() throws -> [LogEntry] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, ts, kind, title, note FROM log ORDER BY ts ASC, rowid ASC;
            """)
            return rows.map { row in
                let note: String? = row["note"]
                return LogEntry(
                    id: PageID(rawValue: row["id"]),
                    timestamp: Date(timeIntervalSince1970: row["ts"]),
                    kind: LogEntry.Kind(rawValue: row["kind"]) ?? .ingest,
                    title: row["title"],
                    note: note
                )
            }
        }
    }
    /// All sources ordered by id with a has_markdown flag (for the File
    /// Provider index projection). Ported from the former
    /// SQLiteWikiStore.listAllSourcesOrderedByID.
    public func listAllSourcesOrderedByID() throws -> [IndexGenerators.SourceIndexRow] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT s.id, s.filename, s.ext, s.mime_type, s.byte_size,
                   s.created_at, s.updated_at, s.version, s.display_name,
                   (SELECT 1 FROM source_markdown_versions WHERE file_id = s.id LIMIT 1) IS NOT NULL AS has_markdown
            FROM sources s ORDER BY s.id ASC;
            """)
            return rows.map { row in
                let mime: String? = row["mime_type"]
                let displayName: String? = row["display_name"]
                return IndexGenerators.SourceIndexRow(
                    id: row["id"],
                    filename: row["filename"],
                    ext: row["ext"],
                    mime: mime,
                    byteSize: row["byte_size"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                    version: row["version"],
                    displayName: displayName,
                    hasMarkdown: (row["has_markdown"] as Int?) == 1
                )
            }
        }
    }

    /// Head `source_markdown_versions` row per source (ref-resolved or
    /// default-active MAX), for the File Provider's `.md`-sibling projection.
    /// Resilient: returns `[:]` if the tables don't exist (pre-migration read
    /// connection). Ported from the former
    /// SQLiteWikiStore.processedMarkdownHeadsBySource.
    public func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion] {
        do {
            return try dbWriter.read { db in
                let rows = try Row.fetchAll(db, sql: """
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
                """)
                var result: [String: SourceMarkdownVersion] = [:]
                for row in rows {
                    let version = Self.readMarkdownVersion(from: row)
                    result[version.sourceID.rawValue] = version
                }
                return result
            }
        } catch {
            return [:]
        }
    }

    // MARK: - Ported from SQLiteWikiStore (test/protocol parity)

    /// The SQL fragment that selects the HEAD processed-markdown body text for a
    /// source `s`. Resolves the active ref first (if any), else falls back to
    /// `MAX(id)` on the version chain — the same default-active rule used
    /// throughout the store. Mirrors `SQLiteWikiStore.smvHeadBodySQL`.
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

    // MARK: - withTransaction (reentrant savepoint wrapper)

    /// Wraps a closure in a transaction (BEGIN IMMEDIATE at the outermost level,
    /// SAVEPOINT when nested). Public methods called inside (e.g. `createPage`,
    /// `storePageChunks`) re-enter `mutate` → `dbWriter.writeWithoutTransaction`
    /// → `db.inSavepoint`, which nests as a SAVEPOINT — no deadlock, no
    /// "cannot start a transaction within a transaction". Mirrors
    /// `SQLiteWikiStore.withTransaction`.
    ///
    /// Internal (not private) so tests can exercise nesting directly.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        var result: T!
        // `unsafeReentrantWrite` (not `writeWithoutTransaction`) so a `mutate`
        // call inside `body` re-enters inline (GRDB Case 2) instead of tripping
        // DatabasePool's "not reentrant" fatal error. `inSavepoint` nests as a
        // SAVEPOINT inside the outer write.
        try dbWriter.unsafeReentrantWrite { db in
            try db.inSavepoint {
                result = try body()
                return .commit
            }
        }
        return result
    }

    // MARK: - Source version history

    /// The full content-version chain for a source, newest-first (parallel to
    /// `processedMarkdownHistory`). Empty when the source has no versions.
    /// Mirrors `SQLiteWikiStore.contentVersionHistory(sourceID:)`.
    public func contentVersionHistory(sourceID: PageID) throws -> [SourceVersion] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_id, parent_id, blob_hash, mime_type,
                       activity_id, external_identity, fetched_at
                FROM source_versions WHERE source_id = ? ORDER BY id DESC;
                """,
                arguments: [sourceID.rawValue]
            )
            return rows.map { row in
                SourceVersion(
                    id: row["id"],
                    sourceID: PageID(rawValue: row["source_id"]),
                    parentID: row["parent_id"],
                    blobHash: row["blob_hash"],
                    mimeType: row["mime_type"],
                    activityID: row["activity_id"],
                    externalIdentity: row["external_identity"],
                    fetchedAt: Date(timeIntervalSince1970: row["fetched_at"])
                )
            }
        }
    }

    // MARK: - Embedder consistency

    /// Check the stored embedder identifier in `embedding_meta` against the
    /// currently selected embedder. On mismatch, wipes `page_chunks` and
    /// `source_chunks` so the async backfill re-embeds everything with the new
    /// embedder. Mirrors `SQLiteWikiStore.ensureEmbedderConsistency`.
    ///
    /// `activeIdentifierOverride` is injected by tests; production passes `nil`
    /// and the live `EmbeddingService.selectedEmbedderIdentifier()` is used.
    func ensureEmbedderConsistency(activeIdentifierOverride: String? = nil) {
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
            try dbWriter.writeWithoutTransaction { db in
                let stored = (try? String.fetchOne(
                    db,
                    sql: "SELECT embedder FROM embedding_meta WHERE id = 1;"
                )) ?? ""
                guard stored != activeIdentifier else { return }
                try db.execute(sql: "DELETE FROM page_chunks;")
                try db.execute(sql: "DELETE FROM source_chunks;")
                try db.execute(sql: "DELETE FROM chat_chunks;")
                try db.execute(
                    sql: "INSERT OR REPLACE INTO embedding_meta(id, embedder) VALUES (1, ?);",
                    arguments: [activeIdentifier]
                )
                DebugLog.store("ensureEmbedderConsistency: \(stored.isEmpty ? "(empty)" : stored) -> \(activeIdentifier), chunks wiped")
            }
        } catch {
            DebugLog.store("ensureEmbedderConsistency: failed — \(error)")
        }
    }

    // MARK: - Launch search-index self-heal

    /// Self-heal search indexes on every writable open. Idempotent + near-zero
    /// cost when nothing is missing, so search "just works" without a manual
    /// reindex. NOT run by the read-only File Provider connection. Mirrors
    /// `SQLiteWikiStore.ensureSearchIndexesPopulated`.
    ///
    /// Steps:
    /// 0. Reconcile the stored embedder identifier against the active one.
    /// 0a. Ensure the byteless-source dedup UNIQUE partial index exists (for
    ///     pre-v20 DBs that predate Phase 3b).
    /// 1. Seed a v1 processed-markdown version for markdown-native sources
    ///    that have none, so their body is searchable.
    /// 2. Backfill the `source_search` / `chat_search` sidecars for rows
    ///    lacking one. (Post-#634 these tables have no FTS5 reader, but the
    ///    writes are kept as harmless orphans — `upsertSourceSearch` /
    ///    `upsertChatSearch` continue to populate them, the Tantivy sidecar
    ///    is the BM25 index now.)
    private func ensureSearchIndexesPopulated() {
        // 0. Reconcile embedder (app-gated internally).
        ensureEmbedderConsistency()

        // Steps 0a, 2, 2b are pure SQL → one write block. Each operation
        // catches its own errors (best-effort, idempotent) so the write block
        // itself does not throw.
        dbWriter.writeWithoutTransaction { db in
            // 0a. Byteless-source dedup index (idempotent; no-op once it exists).
            do {
                try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS source_versions_byteless_eid
                    ON source_versions(external_identity) WHERE blob_hash IS NULL;
                """)
            } catch {
                DebugLog.store("ensureSearchIndexes: byteless index create failed — \(error)")
            }

            // 2. Backfill source_search for sources lacking a row (PDFs/binaries
            //    → name-only). Post-#634 there's no FTS5 reader, but the sidecar
            //    is kept (Tantivy can read it if extended; harmless orphan writes
            //    otherwise).
            do {
                try db.execute(sql: """
                INSERT OR IGNORE INTO source_search (source_id, title, body)
                SELECT s.id, COALESCE(s.display_name, s.filename),
                       \(Self.smvHeadBodySQL)
                FROM sources s;
                """)
            } catch {
                DebugLog.store("ensureSearchIndexes: source_search backfill failed — \(error)")
            }

            // 2b. Backfill chat_search for chats lacking a row (created before v28,
            //     or whose append predates the sidecar). One row per chat:
            //     title + concatenated message text.
            do {
                try db.execute(sql: """
                INSERT OR IGNORE INTO chat_search (chat_id, title, body)
                SELECT c.id, c.title,
                       COALESCE((SELECT GROUP_CONCAT(m.text, '\n')
                                 FROM chat_messages m WHERE m.chat_id = c.id), '')
                FROM chats c
                WHERE c.id NOT IN (SELECT chat_id FROM chat_search);
                """)
            } catch {
                DebugLog.store("ensureSearchIndexes: chat_search backfill failed — \(error)")
            }
        }

        // 1. Seed markdown-native sources lacking a version. Done outside the
        //    write block because `appendProcessedMarkdown` opens its own
        //    transaction (via `mutate`) and fires post-commit re-embed/event work.
        _ = seedNativeMarkdownSources()
    }

    /// Seed the first processed-markdown version for markdown-native sources that
    /// lack one, by decoding their raw bytes as UTF-8 — the same lazy seeding the
    /// UI used to do on first view. Returns the count seeded. Best-effort.
    /// Mirrors `SQLiteWikiStore.seedNativeMarkdownSources`.
    private func seedNativeMarkdownSources() -> Int {
        // Collect IDs first (read), then seed each outside any write block so
        // `appendProcessedMarkdown`'s own `mutate` transaction + post-commit work
        // (re-embed, event emit) run cleanly.
        let ids: [PageID]
        do {
            ids = try dbWriter.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT s.id FROM sources s
                    WHERE s.mime_type LIKE 'text/%'
                      AND NOT EXISTS (SELECT 1 FROM source_markdown_versions smv
                                      WHERE smv.file_id = s.id);
                    """
                ).map { PageID(rawValue: $0) }
            }
        } catch {
            DebugLog.store("seedNativeMarkdownSources: id query failed — \(error)")
            return 0
        }
        var seeded = 0
        for id in ids {
            guard let bytes = try? sourceContent(id: id),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            do {
                _ = try appendProcessedMarkdown(
                    sourceID: id, content: text, origin: .source, note: nil)
            } catch {
                DebugLog.store("seedNativeMarkdownSources: append failed for \(id.rawValue) — \(error)")
                continue
            }
            seeded += 1
        }
        if seeded > 0 {
            DebugLog.store("seedNativeMarkdownSources: seeded \(seeded) source(s)")
        }
        return seeded
    }

    // MARK: - Source link queries

    /// Read the `pinned_version_id` for a source-link edge `(from, to, role)`.
    /// Returns the resolved version id, or nil when the edge has no pin (NULL)
    /// or doesn't exist. Mirrors `SQLiteWikiStore.sourceLinkPin`.
    public func sourceLinkPin(from pageID: PageID, to sourceID: PageID,
                              role: WikiLinkParser.LinkRole = .cite) throws -> PageID? {
        try dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT pinned_version_id FROM source_links
                WHERE from_page_id = ? AND to_source_id = ? AND role = ?;
                """,
                arguments: [pageID.rawValue, sourceID.rawValue, role.rawValue]
            )
            guard let row else { return nil }
            // Distinguish NULL (no pin) from a TEXT value.
            let value: String? = row["pinned_version_id"]
            return value.map { PageID(rawValue: $0) }
        }
    }

    /// Pages whose bodies link to `sourceID` via `[[source:…]]` (by source ID —
    /// stable across renames). Used by `renameSource` to find candidate pages
    /// for link rewriting. One query, zero false positives. Mirrors
    /// `SQLiteWikiStore.sourceLinkingPages`.
    public func sourceLinkingPages(to sourceID: PageID) throws -> [PageID] {
        try dbWriter.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT from_page_id FROM source_links WHERE to_source_id = ?;",
                arguments: [sourceID.rawValue]
            )
            return rows.map { PageID(rawValue: $0) }
        }
    }

    // MARK: - Test hooks (#if DEBUG)

    // No C-scalar registration test hook anymore — the vendored scalar target
    // is retired (issue #628). Semantic-cosine ranking is now pure Swift
    // (`VectorCosine`); tests assert the ranker directly (`VectorCosineTests`)
    // rather than probing a C-extension scalar on the connection.
}
