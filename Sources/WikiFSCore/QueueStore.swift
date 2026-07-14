import Foundation
import SQLite3

// MARK: - QueueStoreError

/// Errors thrown by `QueueStore`. Dedicated (does not reuse `WikiStoreError`)
/// because `.notFound` carries a `QueueItem.ID`, not a `PageID` — the
/// semantic mismatch would mislead callers.
public enum QueueStoreError: Error, CustomStringConvertible, LocalizedError {
    /// Failed to open (or create) the database file.
    case open(String)
    /// A SQLite C-API call returned an error.
    case sqlite(code: Int32, message: String)
    /// No queue item exists with the given ID.
    case notFound(QueueItem.ID)
    /// A state transition was attempted that is not valid from the item's
    /// current state (e.g. `completed` → `running`).
    case invalidStateTransition(from: QueueItemState, to: QueueItemState)
    /// The request was malformed (e.g. empty wikiID — AC4.2).
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .open(let m): return "QueueStore open failed: \(m)"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .notFound(let id): return "Queue item not found: \(id)"
        case .invalidStateTransition(let from, let to):
            return "Invalid queue state transition: \(from.rawValue) → \(to.rawValue)"
        case .invalidRequest(let m): return "Invalid request: \(m)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - QueueStore

/// Persistent, durable store for the extraction / ingestion work queue.
///
/// Owns one serial SQLite connection (`queue.sqlite`) with a prepared-statement
/// cache, replicating `SQLiteWikiStore`'s proven concurrency discipline:
///
/// - **Method-atomic:** every public method acquires `lock` (an
///   `NSRecursiveLock`) for its entire body, so no two callers share a cached
///   `sqlite3_stmt*` or mutate the `statements` dictionary concurrently.
/// - **Savepoint nesting:** multi-step writes compose via `withTransaction`,
///   which uses `BEGIN IMMEDIATE` at depth 0 and `SAVEPOINT spN` for nesting —
///   never raw `BEGIN`.
/// - **No leaked read snapshots:** every stepped `SQLiteStatement` is covered
///   by `defer { stmt.reset() }`, so no statement is left at `SQLITE_ROW`
///   (which would pin the WAL read snapshot, causing stale reads and
///   `BEGIN IMMEDIATE` failures — issue #332).
/// - **No connection state crosses a method boundary:** statement handles and
///   column pointers are never returned or shared.
/// - **WAL + busy_timeout:** `PRAGMA journal_mode=WAL`,
///   `PRAGMA foreign_keys=ON`, `PRAGMA busy_timeout=5000`.
/// - **Versioned idempotent migrations:** `PRAGMA user_version` drives the
///   schema ladder; re-opening a store is a no-op.
///
/// The store has **no scheduling opinions** — it owns CRUD and state
/// transitions only. The `QueueEngine` actor (Phase 2) will call these methods
/// to drive the processing lifecycle. The store emits **no**
/// `ResourceChangeEvent` (it is not a `WikiStore` and has no event bus).
public final class QueueStore: @unchecked Sendable {

    // MARK: - Stored properties

    /// The single serial SQLite connection. `FULLMUTEX` (serialized) at the C
    /// level; the recursive lock adds method-level atomicity on top.
    private let db: OpaquePointer

    /// Prepared-statement cache keyed by SQL text; reused via `reset()`.
    private var statements: [String: SQLiteStatement] = [:]

    /// Serializes whole method bodies (bind → step → column reads) against the
    /// single connection. Recursive so public methods may compose without
    /// self-deadlock.
    private let lock = NSRecursiveLock()

    /// Current `withTransaction` nesting depth (0 = no open transaction).
    /// Only ever touched while holding `lock`.
    private var transactionDepth = 0

    /// Guards against double-close (`close()` then `deinit`).
    private var closed = false

    // MARK: - Init

    /// Open (creating if needed) the queue database at `databaseURL`.
    /// Phase 1 tests inject a temp-directory URL; the app will inject
    /// `DatabaseLocation.queueDatabaseURL()` in Phase 2.
    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            if let handle { sqlite3_close(handle) }
            throw QueueStoreError.open(msg)
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

    deinit {
        guard !closed else { return }
        closed = true
        statements.removeAll()
        Self.checkpointAndClose(db)
    }

    /// Explicitly close the database connection. After calling this, the store
    /// must not be used further. `deinit` normally handles this, but callers
    /// that need to quiesce the WAL before opening a new connection on the same
    /// file (e.g. tests verifying persistence across reopen) must call this.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        statements.removeAll()
        Self.checkpointAndClose(db)
    }

    /// Force-checkpoint the WAL to zero length, then close. Mirrors
    /// `SQLiteWikiStore.checkpointAndClose` — the explicit TRUNCATE checkpoint
    /// flushes committed frames into the main file first so `sqlite3_close`
    /// has nothing left to do (avoids intermittent `SQLITE_ERROR` on a
    /// reopening connection under CI load — #223, #234).
    nonisolated private static func checkpointAndClose(_ db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(db)
    }

    // MARK: - Open-time configuration

    private func configurePragmas() throws {
        let mode = try queryScalarText("PRAGMA journal_mode=WAL;")
        guard mode.lowercased() == "wal" else {
            throw QueueStoreError.sqlite(code: -1, message: "journal_mode is '\(mode)', expected 'wal'")
        }
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")
    }

    // MARK: - Schema + migrations

    /// Current schema version for `queue.sqlite`.
    private static let currentSchemaVersion = 1

    /// Stepwise, idempotent schema migration keyed on `PRAGMA user_version`.
    /// A fresh DB (version 0) runs `createFreshSchemaV1()`; an existing DB at
    /// version >= 1 is a no-op (no migration steps beyond v1 yet, but the
    /// ladder structure is ready for future phases).
    private func bootstrapSchema() throws {
        var version = Int(try queryScalarText("PRAGMA user_version;")) ?? 0
        if version == 0 {
            try createFreshSchemaV1()
            return
        }
        try migrate(from: &version)
        // Defensive cleanup: remove any rows persisted with the now-removed
        // `queue = 'lint'` kind from a partial earlier execution. The enum
        // case was reverted — lint is a payload variant of `.ingestion`.
        // Safe + idempotent (no-op if no such rows exist).
        try exec("DELETE FROM queue_items WHERE queue = 'lint';")
    }

    /// Stepwise migration ladder. No steps beyond v1 yet, but the structure is
    /// ready for future phases. Each `if version < N` block runs one step and
    /// stamps `user_version = N`.
    ///
    /// Mirrors `SQLiteWikiStore.migrate(from:)` — versioned, idempotent,
    /// each step runs only when the DB is below that step's target version.
    private func migrate(from version: inout Int) throws {
        // Future migrations:
        // if version < 2 { try migrateV1ToV2(); version = 2; try exec("PRAGMA user_version=2;") }
    }

    /// Build the complete v1 schema for a fresh database and stamp
    /// `user_version = 1`.
    private func createFreshSchemaV1() throws {
        try exec("""
        CREATE TABLE queue_items (
            id            TEXT PRIMARY KEY,
            queue         TEXT NOT NULL,
            wiki_id       TEXT NOT NULL,
            payload       TEXT NOT NULL,
            state         TEXT NOT NULL,
            ordering_key  INTEGER NOT NULL,
            provider_id   TEXT,
            attempt       INTEGER NOT NULL DEFAULT 0,
            error         TEXT,
            created_at    INTEGER NOT NULL,
            started_at    INTEGER,
            finished_at   INTEGER
        );
        """)

        try exec("""
        CREATE INDEX idx_queue_items_active
            ON queue_items(queue, state, ordering_key);
        """)

        try exec("""
        CREATE TABLE queue_state (
            queue  TEXT PRIMARY KEY,
            state  TEXT NOT NULL
        );
        """)

        // Seed default run states: both queues start running.
        try exec("INSERT INTO queue_state(queue, state) VALUES ('extraction', 'running');")
        try exec("INSERT INTO queue_state(queue, state) VALUES ('ingestion', 'running');")

        try exec("PRAGMA user_version=\(Self.currentSchemaVersion);")
    }

    // MARK: - Statement helpers

    /// Get (or prepare-and-cache) a `SQLiteStatement` for `sql`. Keyed by the
    /// raw SQL text so the same string always returns the same cached
    /// `sqlite3_stmt*`.
    private func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = statements[sql] { return cached }
        let stmt = try SQLiteStatement(db: db, sql: sql)
        statements[sql] = stmt
        return stmt
    }

    /// Execute a statement that returns no rows (DDL / PRAGMA assignment).
    /// Not cached — these run once at open time or are simple UPSERTs.
    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        defer { sqlite3_free(errmsg) }
        guard rc == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? SQLiteStatement.message(db)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                DebugLog.store("QueueStore exec BUSY/LOCKED rc=\(rc) sql=\(sql) msg=\(msg)")
            }
            throw QueueStoreError.sqlite(code: rc, message: msg)
        }
    }

    /// Run a one-row PRAGMA/SELECT and return column 0 as text. Uses a
    /// throwaway prepared statement (not cached) so pragmas like
    /// `journal_mode=WAL` (which return a row) can be observed.
    private func queryScalarText(_ sql: String) throws -> String {
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else {
            throw QueueStoreError.sqlite(code: rc, message: SQLiteStatement.message(db))
        }
        defer { sqlite3_finalize(handle) }
        let step = sqlite3_step(handle)
        guard step == SQLITE_ROW else { return "" }
        guard let c = sqlite3_column_text(handle, 0) else { return "" }
        return String(cString: c)
    }

    #if DEBUG
    /// Assert no cached statement is left busy. A busy statement pins the
    /// connection's WAL read snapshot, causing stale reads and write-lock
    /// failures after external commits (#332). Called before `BEGIN IMMEDIATE`
    /// in `withTransaction` as a DEBUG guardrail.
    private func assertNoBusyStatements() throws {
        for (sql, stmt) in statements {
            if stmt.isBusy {
                throw QueueStoreError.sqlite(
                    code: -1,
                    message: "Busy cached statement detected: \(sql.prefix(80))")
            }
        }
    }
    #endif

    /// Nested transaction wrapper. Depth 0 uses `BEGIN IMMEDIATE`;
    /// deeper calls use `SAVEPOINT spN` so public methods may compose. Never
    /// raw `BEGIN`. Includes the DEBUG `assertNoBusyStatements()` guard before
    /// `BEGIN IMMEDIATE` — the #332 guardrail.
    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let depth = transactionDepth
        let savepoint = "queue_txn_\(depth)"
        if depth == 0 {
            #if DEBUG
            try assertNoBusyStatements()
            #endif
            let start = DispatchTime.now()
            do {
                try exec("BEGIN IMMEDIATE;")
            } catch {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                DebugLog.store("QueueStore BEGIN IMMEDIATE failed after \(elapsedMs)ms — \(error)")
                throw error
            }
        } else {
            try exec("SAVEPOINT \(savepoint);")
        }
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try rewrap(body)
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

    // MARK: - Error rewrapping

    /// Rewrap `WikiStoreError.sqlite` (thrown by `SQLiteStatement`'s `init` /
    /// `bind` / `step`) into `QueueStoreError.sqlite`. All other errors
    /// (including `QueueStoreError`) pass through unchanged. This is the
    /// boundary that keeps `QueueStore`'s public surface clean — callers
    /// catching `QueueStoreError` never miss a `WikiStoreError` from a
    /// SQLite-level failure.
    private func rewrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let WikiStoreError.sqlite(code, message) {
            throw QueueStoreError.sqlite(code: code, message: message)
        }
    }

    // MARK: - Timestamp helper

    /// Current epoch time in milliseconds, matching the `created_at` /
    /// `started_at` / `finished_at` column type.
    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - JSON encoding helpers

    /// Encode a `QueueItemPayload` to JSON `Data`, then to a UTF-8 `String` for
    /// the `payload` TEXT column.
    private static func encodePayload(_ payload: QueueItemPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decode a JSON `String` back to a `QueueItemPayload`.
    private static func decodePayload(_ text: String) throws -> QueueItemPayload {
        guard let data = text.data(using: .utf8) else {
            throw QueueStoreError.sqlite(code: -1, message: "payload is not valid UTF-8")
        }
        return try JSONDecoder().decode(QueueItemPayload.self, from: data)
    }

    // MARK: - Row decoding

    /// The SELECT column list for `queue_items`, shared by all read queries so
    /// `readItem` can use fixed column indexes.
    private static let selectColumns = """
        id, queue, wiki_id, payload, state, ordering_key,
        provider_id, attempt, error, created_at, started_at, finished_at
    """

    /// Read a `QueueItem` from the current row of `stmt`. Column order matches
    /// `selectColumns`. Must be called while the statement is at `SQLITE_ROW`
    /// and before `reset()` — no column pointer crosses the method boundary
    /// (all values are copied out into value types).
    private func readItem(from stmt: SQLiteStatement) throws -> QueueItem {
        let id = stmt.text(at: 0)
        let queueRaw = stmt.text(at: 1)
        let wikiID = stmt.text(at: 2)
        let payloadText = stmt.text(at: 3)
        let stateRaw = stmt.text(at: 4)
        let orderingKey = stmt.int(at: 5)

        // Nullable TEXT columns: check SQLITE_NULL explicitly.
        let providerIDNil = sqlite3_column_type(stmt.handle, 6) == SQLITE_NULL
        let providerID = providerIDNil ? nil : stmt.text(at: 6)

        let attempt = Int(stmt.int(at: 7))

        let errorNil = sqlite3_column_type(stmt.handle, 8) == SQLITE_NULL
        let errorText = errorNil ? nil : stmt.text(at: 8)

        let createdAt = stmt.int(at: 9)

        let startedAtNil = sqlite3_column_type(stmt.handle, 10) == SQLITE_NULL
        let startedAt = startedAtNil ? nil : stmt.int(at: 10)

        let finishedAtNil = sqlite3_column_type(stmt.handle, 11) == SQLITE_NULL
        let finishedAt = finishedAtNil ? nil : stmt.int(at: 11)

        guard let queue = QueueKind(rawValue: queueRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown queue kind: \(queueRaw)")
        }
        guard let state = QueueItemState(rawValue: stateRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown item state: \(stateRaw)")
        }
        let payload = try Self.decodePayload(payloadText)

        return QueueItem(
            id: id,
            queue: queue,
            wikiID: wikiID,
            payload: payload,
            state: state,
            orderingKey: orderingKey,
            providerID: providerID,
            attempt: attempt,
            error: errorText,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    // MARK: - Ordering key helper

    /// The next ordering key for `queue` (current max + 1000, or 1000 if the
    /// queue is empty). Called inside `enqueue` and `retryItem` while holding
    /// the lock.
    private func nextOrderingKey(for queue: QueueKind) throws -> Int64 {
        let sql = "SELECT COALESCE(MAX(ordering_key), 0) + 1000 FROM queue_items WHERE queue = ?1;"
        let stmt = try statement(sql)
        defer { stmt.reset() }
        try stmt.bind(queue.rawValue, at: 1)
        _ = try stmt.step()
        return stmt.int(at: 0)
    }

    // MARK: - Public API: Enqueue

    /// Enqueue a new item: generates a ULID ID, assigns the next ordering key
    /// (max + 1000 for this queue kind), sets `state = .queued`, `attempt = 0`,
    /// and records `createdAt`. Returns the fully-populated item.
    @discardableResult
    public func enqueue(_ request: QueueItemRequest) throws -> QueueItem {
        lock.lock(); defer { lock.unlock() }

        return try withTransaction {
            let id = ULID.generate()
            let orderingKey = try nextOrderingKey(for: request.queue)
            let now = Self.nowMillis()
            let payloadJSON = try Self.encodePayload(request.payload)

            let sql = """
            INSERT INTO queue_items
                (id, queue, wiki_id, payload, state, ordering_key,
                 provider_id, attempt, error, created_at, started_at, finished_at)
            VALUES
                (?1, ?2, ?3, ?4, ?5, ?6,
                 NULL, 0, NULL, ?7, NULL, NULL);
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(id, at: 1)
            try stmt.bind(request.queue.rawValue, at: 2)
            try stmt.bind(request.wikiID, at: 3)
            try stmt.bind(payloadJSON, at: 4)
            try stmt.bind(QueueItemState.queued.rawValue, at: 5)
            try stmt.bind(orderingKey, at: 6)
            try stmt.bind(now, at: 7)
            _ = try stmt.step()

            return QueueItem(
                id: id,
                queue: request.queue,
                wikiID: request.wikiID,
                payload: request.payload,
                state: .queued,
                orderingKey: orderingKey,
                providerID: nil,
                attempt: 0,
                error: nil,
                createdAt: now,
                startedAt: nil,
                finishedAt: nil
            )
        }
    }

    // MARK: - Public API: Read

    /// Fetch a single item by ID, or `nil` if no row matches.
    public func getItem(_ id: QueueItem.ID) throws -> QueueItem? {
        lock.lock(); defer { lock.unlock() }

        do {
            let sql = """
            SELECT \(Self.selectColumns)
            FROM queue_items
            WHERE id = ?1;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { return nil }
            return try readItem(from: stmt)
        } catch let WikiStoreError.sqlite(code, message) {
            throw QueueStoreError.sqlite(code: code, message: message)
        }
    }

    /// Load all non-terminal items (`.queued` and `.running`), ordered by
    /// `ordering_key` ascending. If `queue` is `nil`, returns items from both
    /// queues; otherwise restricted to the specified queue.
    public func loadActive(for queue: QueueKind? = nil) throws -> [QueueItem] {
        lock.lock(); defer { lock.unlock() }

        return try rewrap {
            let sql: String
            if let queue {
                sql = """
                SELECT \(Self.selectColumns)
                FROM queue_items
                WHERE state IN ('queued', 'running') AND queue = ?1
                ORDER BY ordering_key ASC;
                """
            } else {
                sql = """
                SELECT \(Self.selectColumns)
                FROM queue_items
                WHERE state IN ('queued', 'running')
                ORDER BY ordering_key ASC;
                """
            }
            let stmt = try statement(sql)
            defer { stmt.reset() }
            if let queue { try stmt.bind(queue.rawValue, at: 1) }

            var items: [QueueItem] = []
            while try stmt.step() {
                items.append(try readItem(from: stmt))
            }
            return items
        }
    }

    /// Load terminal items (`.completed`, `.failed`, `.cancelled`), newest
    /// first (by `finished_at` descending), bounded by `limit`.
    public func loadRecent(limit: Int = 200) throws -> [QueueItem] {
        lock.lock(); defer { lock.unlock() }

        return try rewrap {
            let sql = """
            SELECT \(Self.selectColumns)
            FROM queue_items
            WHERE state IN ('completed', 'failed', 'cancelled')
            ORDER BY finished_at DESC
            LIMIT ?1;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(Int64(limit), at: 1)

            var items: [QueueItem] = []
            while try stmt.step() {
                items.append(try readItem(from: stmt))
            }
            return items
        }
    }

    // MARK: - Public API: State transitions

    /// Transition an item from `.queued` → `.running`, recording the provider
    /// that claimed it and the start time. Throws if the item is not in
    /// `.queued` state.
    public func markRunning(id: QueueItem.ID, providerID: String) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.queued], to: .running)

        let now = Self.nowMillis()
        try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'running', provider_id = ?1, started_at = ?2,
                finished_at = NULL, error = NULL
            WHERE id = ?3;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(providerID, at: 1)
            try stmt.bind(now, at: 2)
            try stmt.bind(id, at: 3)
            _ = try stmt.step()
        }
    }

    /// Transition an item from `.running` → `.completed`, recording the finish
    /// time. Throws if the item is not in `.running` state.
    public func markCompleted(id: QueueItem.ID) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.running], to: .completed)

        let now = Self.nowMillis()
        try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'completed', finished_at = ?1
            WHERE id = ?2;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(now, at: 1)
            try stmt.bind(id, at: 2)
            _ = try stmt.step()
        }
    }

    /// Transition an item from `.running` → `.failed`, recording the finish
    /// time and the error message. Throws if the item is not in `.running` state.
    public func markFailed(id: QueueItem.ID, error: String) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.running], to: .failed)

        let now = Self.nowMillis()
        try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'failed', finished_at = ?1, error = ?2
            WHERE id = ?3;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(now, at: 1)
            try stmt.bind(error, at: 2)
            try stmt.bind(id, at: 3)
            _ = try stmt.step()
        }
    }

    /// Transition an item from `.queued` or `.running` → `.cancelled`,
    /// recording the finish time. Preserves the `orderingKey`. Throws if the
    /// item is in a terminal state.
    public func markCancelled(id: QueueItem.ID) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.queued, .running], to: .cancelled)

        let now = Self.nowMillis()
        try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'cancelled', finished_at = ?1
            WHERE id = ?2;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(now, at: 1)
            try stmt.bind(id, at: 2)
            _ = try stmt.step()
        }
    }

    /// Transition an item from `.running` → `.queued` (the halt / cancel path).
    /// Clears `providerID` and `startedAt`. Preserves the `orderingKey` so the
    /// item retains its position. Throws if the item is not in `.running` state.
    public func requeue(id: QueueItem.ID) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.running], to: .queued)

        try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'queued', provider_id = NULL, started_at = NULL
            WHERE id = ?1;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(id, at: 1)
            _ = try stmt.step()
        }
    }

    /// Retry a `.failed` item: transition to `.queued`, increment `attempt`,
    /// and assign a NEW `orderingKey` (back of the queue). Clears the error
    /// message. Throws if the item is not in `.failed` state.
    public func retryItem(id: QueueItem.ID) throws {
        lock.lock(); defer { lock.unlock() }

        try validateTransition(id: id, allowedFrom: [.failed], to: .queued)

        try withTransaction {
            let kind = try fetchQueueKind(id: id)
            let newOrderingKey = try nextOrderingKey(for: kind)

            let sql = """
            UPDATE queue_items
            SET state = 'queued', ordering_key = ?1, attempt = attempt + 1,
                error = NULL, finished_at = NULL
            WHERE id = ?2;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(newOrderingKey, at: 1)
            try stmt.bind(id, at: 2)
            _ = try stmt.step()
        }
    }

    // MARK: - Public API: Crash recovery

    /// Reset all items found in `.running` state back to `.queued` (their
    /// `attempt` count is preserved). Called by the engine at launch to
    /// recover from crashes. Returns the count of reset rows.
    @discardableResult
    public func resetRunningToQueued() throws -> Int {
        lock.lock(); defer { lock.unlock() }

        return try withTransaction {
            let sql = """
            UPDATE queue_items
            SET state = 'queued', provider_id = NULL, started_at = NULL
            WHERE state = 'running';
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            _ = try stmt.step()
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Public API: Queue run state

    /// The run state for a queue (`.running` or `.paused`). Defaults to
    /// `.running` if the row is somehow missing (shouldn't happen — seeded at
    /// schema creation).
    public func queueRunState(for queue: QueueKind) throws -> QueueRunState {
        lock.lock(); defer { lock.unlock() }

        return try rewrap {
            let sql = "SELECT state FROM queue_state WHERE queue = ?1;"
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(queue.rawValue, at: 1)
            guard try stmt.step() else { return QueueRunState.running }
            let raw = stmt.text(at: 0)
            return QueueRunState(rawValue: raw) ?? .running
        }
    }

    /// Set the run state for a queue (persisted across app restarts).
    public func setQueueRunState(_ queue: QueueKind, _ state: QueueRunState) throws {
        lock.lock(); defer { lock.unlock() }

        try withTransaction {
            let sql = """
            INSERT INTO queue_state (queue, state) VALUES (?1, ?2)
            ON CONFLICT(queue) DO UPDATE SET state = ?2;
            """
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(queue.rawValue, at: 1)
            try stmt.bind(state.rawValue, at: 2)
            _ = try stmt.step()
        }
    }

    // MARK: - Public API: Maintenance

    /// Prune terminal items (`.completed`, `.failed`, `.cancelled`) beyond
    /// `maxPerQueue` per queue kind, keeping the most recent (by
    /// `finished_at`). Non-terminal items are never pruned.
    public func pruneHistory(maxPerQueue: Int = 200) throws {
        lock.lock(); defer { lock.unlock() }

        try withTransaction {
            for queue in [QueueKind.extraction, QueueKind.ingestion] {
                // Delete terminal items whose finished_at falls below the
                // Nth newest (i.e. outside the top `maxPerQueue` most recent
                // terminal items for this queue). `LIMIT -1 OFFSET N` selects
                // all rows after skipping the first N.
                let sql = """
                DELETE FROM queue_items
                WHERE id IN (
                    SELECT id FROM queue_items
                    WHERE queue = ?1
                      AND state IN ('completed', 'failed', 'cancelled')
                    ORDER BY finished_at DESC
                    LIMIT -1 OFFSET ?2
                );
                """
                let stmt = try statement(sql)
                defer { stmt.reset() }
                try stmt.bind(queue.rawValue, at: 1)
                try stmt.bind(Int64(maxPerQueue), at: 2)
                _ = try stmt.step()
            }
        }
    }

    // MARK: - Internal transition helpers

    /// Validate that the item exists and is in one of `allowedFrom` states.
    /// Throws `.notFound` if the item doesn't exist, or
    /// `.invalidStateTransition` if its current state is not in `allowedFrom`.
    private func validateTransition(
        id: QueueItem.ID,
        allowedFrom: Set<QueueItemState>,
        to: QueueItemState
    ) throws {
        let currentState = try currentState(id: id)
        guard allowedFrom.contains(currentState) else {
            throw QueueStoreError.invalidStateTransition(from: currentState, to: to)
        }
    }

    /// Get the current state of an item by ID. Throws `.notFound` if no row.
    private func currentState(id: QueueItem.ID) throws -> QueueItemState {
        try rewrap {
            let sql = "SELECT state FROM queue_items WHERE id = ?1;"
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { throw QueueStoreError.notFound(id) }
            let raw = stmt.text(at: 0)
            guard let state = QueueItemState(rawValue: raw) else {
                throw QueueStoreError.sqlite(code: -1, message: "Unknown item state: \(raw)")
            }
            return state
        }
    }

    /// Fetch the `QueueKind` of an item by ID. Throws `.notFound` if no row.
    private func fetchQueueKind(id: QueueItem.ID) throws -> QueueKind {
        try rewrap {
            let sql = "SELECT queue FROM queue_items WHERE id = ?1;"
            let stmt = try statement(sql)
            defer { stmt.reset() }
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { throw QueueStoreError.notFound(id) }
            let raw = stmt.text(at: 0)
            guard let kind = QueueKind(rawValue: raw) else {
                throw QueueStoreError.sqlite(code: -1, message: "Unknown queue kind: \(raw)")
            }
            return kind
        }
    }
}
