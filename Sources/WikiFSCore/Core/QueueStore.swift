import Foundation

// `internal import` (SE-0409, Swift 6.0+) keeps GRDB types from leaking into
// downstream modules. Without this, GRDB's `SQL` type (which is
// `ExpressibleByStringInterpolation`) competes with `String` in string
// interpolation contexts in WikiCtlCore/WikiFS, causing type mismatches.
internal import GRDB

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
/// Backed by GRDB.swift (`DatabaseQueue`) — a lightweight, well-tested Swift
/// SQLite toolkit. The store owns one serial connection to `queue.sqlite`,
/// configured with WAL mode, foreign keys, busy timeout, and the same set of
/// performance PRAGMAs as `SQLiteWikiStore` (#523).
///
/// **Concurrency model:** GRDB's `DatabaseQueue` serializes all reads and
/// writes through a single dispatch queue — every `dbQueue.read { }` /
/// `dbQueue.write { }` call runs without overlap. This replaces the prior
/// `NSRecursiveLock` + `withTransaction` + prepared-statement cache with
/// GRDB's built-in statement caching and automatic transaction management.
///
/// **Migrations:** `DatabaseMigrator` provides named, idempotent, auto-tracked
/// migrations (via the `grdb_migrations` table). Existing databases that were
/// created by the hand-rolled `user_version` ladder are detected automatically
/// — the migrator sees there is no `grdb_migrations` table and runs all
/// registered migrations, which are all `IF NOT EXISTS` / idempotent so
/// re-running them on an already-current schema is a no-op.
///
/// The store has **no scheduling opinions** — it owns CRUD and state
/// transitions only. The `QueueEngine` actor calls these methods to drive the
/// processing lifecycle. The store emits **no** `ResourceChangeEvent` (it is
/// not a `WikiStore` and has no event bus).
public final class QueueStore: @unchecked Sendable {

    // MARK: - Stored properties

    /// The serial GRDB connection. Reads and writes are serialized through
    /// GRDB's internal dispatch queue — no external lock needed.
    private var dbQueue: DatabaseQueue?

    /// Guards against double-close (`close()` then `deinit`).
    private let closeLock = NSLock()
    private var closed = false

    // MARK: - Init

    /// Open (creating if needed) the queue database at `databaseURL`.
    /// Phase 1 tests inject a temp-directory URL; the app injects
    /// `DatabaseLocation.queueDatabaseURL()` in Phase 2.
    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)

        // Performance PRAGMAs matching SQLiteWikiStore (#523).
        // `prepareDatabase` runs on the connection before any app code —
        // journal_mode is set to WAL by GRDB when requested, but we also
        // set it explicitly here for clarity.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-65536")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
        }

        do {
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
        } catch {
            throw QueueStoreError.open("\(error)")
        }
    }

    deinit {
        checkpoint()
        dbQueue = nil
    }

    /// Explicitly close the database connection. After calling this, the store
    /// must not be used further. `deinit` normally handles this, but callers
    /// that need to quiesce the WAL before opening a new connection on the same
    /// file (e.g. tests verifying persistence across reopen) must call this.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        checkpoint()
        dbQueue = nil
    }

    /// Force-checkpoint the WAL to zero length, then let GRDB close the
    /// connection on deinit. Mirrors `SQLiteWikiStore.checkpointAndClose` —
    /// the explicit TRUNCATE checkpoint flushes committed frames into the
    /// main file first so reopening the same file has nothing pending
    /// (avoids intermittent `SQLITE_ERROR` under CI load — #223, #234).
    private func checkpoint() {
        guard let dbQueue else { return }
        do {
            try dbQueue.writeWithoutTransaction { db in
                // TRUNCATE checkpoint — flush WAL frames, then truncate WAL to zero.
                if let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") {
                    let busy: Int = row["busy"]
                    if busy != 0 {
                        let log: Int = row["log"]
                        let checkpointed: Int = row["checkpointed"]
                        DebugLog.store("QueueStore WAL checkpoint busy: busy=\(busy) log=\(log) checkpointed=\(checkpointed)")
                    }
                }
            }
        } catch {
            DebugLog.store("QueueStore WAL checkpoint failed: \(error)")
        }
    }

    // MARK: - GRDB connection helper

    /// Returns the live `DatabaseQueue`, or throws if the store has been closed.
    private func queue() throws -> DatabaseQueue {
        guard let dbQueue else {
            throw QueueStoreError.sqlite(code: -1, message: "Database is closed")
        }
        return dbQueue
    }

    // MARK: - Migrations

    /// Named, auto-tracked migrations replacing the `PRAGMA user_version` ladder.
    ///
    /// All migrations are idempotent (`IF NOT EXISTS`, `INSERT OR IGNORE`, etc.)
    /// because GRDB's `DatabaseMigrator` detects databases created by the
    /// old hand-rolled code (no `grdb_migrations` table) and runs all
    /// registered migrations from scratch. The `IF NOT EXISTS` guards make
    /// this a no-op for existing databases that already have the schema.
    ///
    /// Migration history:
    /// - v1: `queue_items`, `queue_state`, `queue_item_events` (+ indexes + seed).
    /// - v2: `queue_item_events` table (originally added to fresh-schema only
    ///   without a migration step; existing v1 DBs silently lacked it — #450).
    /// - v3: Namespace `QueueRunState.running` rawValue from `"running"` to
    ///   `"queue-running"` to disambiguate from `QueueItemState.running` (#508).
    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        m.registerMigration("v1_create_queue_schema") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_items (
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

            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_queue_items_active
                ON queue_items(queue, state, ordering_key);
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_state (
                queue  TEXT PRIMARY KEY,
                state  TEXT NOT NULL
            );
            """)

            // Seed default run states: both queues start queue-running.
            try db.execute(sql: "INSERT OR IGNORE INTO queue_state(queue, state) VALUES ('extraction', 'queue-running');")
            try db.execute(sql: "INSERT OR IGNORE INTO queue_state(queue, state) VALUES ('ingestion', 'queue-running');")

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_item_events (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id       TEXT NOT NULL,
                seq           INTEGER NOT NULL,
                event_json    TEXT NOT NULL,
                created_at    INTEGER NOT NULL,
                FOREIGN KEY (item_id) REFERENCES queue_items(id) ON DELETE CASCADE
            );
            """)

            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_queue_item_events
                ON queue_item_events(item_id, seq);
            """)

            // Defensive cleanup: remove any rows persisted with the now-removed
            // `queue = 'lint'` kind from a partial earlier execution. The enum
            // case was reverted — lint is a payload variant of `.ingestion`.
            // Safe + idempotent (no-op if no such rows exist).
            try db.execute(sql: "DELETE FROM queue_items WHERE queue = 'lint';")
        }

        m.registerMigration("v2_add_item_events") { db in
            // v2 is subsumed by v1's `IF NOT EXISTS` migration (which builds
            // queue_item_events). This migration is kept for explicit
            // provenance and to advance the grdb_migrations tracking.
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_item_events (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id       TEXT NOT NULL,
                seq           INTEGER NOT NULL,
                event_json    TEXT NOT NULL,
                created_at    INTEGER NOT NULL,
                FOREIGN KEY (item_id) REFERENCES queue_items(id) ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_queue_item_events
                ON queue_item_events(item_id, seq);
            """)
        }

        m.registerMigration("v3_namespace_run_state") { db in
            try db.execute(sql: "UPDATE queue_state SET state = 'queue-running' WHERE state = 'running';")
        }

        return m
    }()

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

    // MARK: - GRDB error wrapping

    /// Wrap `DatabaseError` into `QueueStoreError.sqlite` so callers catching
    /// `QueueStoreError` never see a raw `DatabaseError`. All other errors
    /// (including `QueueStoreError`) pass through unchanged.
    private static func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as DatabaseError {
            throw QueueStoreError.sqlite(
                code: error.extendedResultCode.rawValue,
                message: error.message ?? "\(error)")
        }
    }

    // MARK: - Row decoding

    /// Shared SELECT column list for `queue_items`.
    private static let selectColumns = """
        id, queue, wiki_id, payload, state, ordering_key,
        provider_id, attempt, error, created_at, started_at, finished_at
    """

    /// Read a `QueueItem` from a GRDB `Row`. Named column access (not positional)
    /// so column order changes are harmless — a key safety improvement over
    /// the old `stmt.text(at: 0)` positional access.
    private static func readItem(from row: Row) throws -> QueueItem {
        let id: String = row["id"]
        let queueRaw: String = row["queue"]
        let wikiID: String = row["wiki_id"]
        let payloadText: String = row["payload"]
        let stateRaw: String = row["state"]
        let orderingKey: Int64 = row["ordering_key"]
        let providerID: String? = row["provider_id"]
        let attempt: Int = row["attempt"]
        let errorText: String? = row["error"]
        let createdAt: Int64 = row["created_at"]
        let startedAt: Int64? = row["started_at"]
        let finishedAt: Int64? = row["finished_at"]

        guard let queue = QueueKind(rawValue: queueRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown queue kind: \(queueRaw)")
        }
        guard let state = QueueItemState(rawValue: stateRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown item state: \(stateRaw)")
        }
        let payload = try decodePayload(payloadText)

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
    /// queue is empty). Called inside `enqueue` and `retryItem` within a
    /// write transaction.
    private static func nextOrderingKey(_ db: Database, for queue: QueueKind) throws -> Int64 {
        let maxKey = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(ordering_key), 0) + 1000 FROM queue_items WHERE queue = ?;",
            arguments: [queue.rawValue]) ?? 0
        return maxKey
    }

    // MARK: - Public API: Enqueue

    /// Enqueue a new item: generates a ULID ID, assigns the next ordering key
    /// (max + 1000 for this queue kind), sets `state = .queued`, `attempt = 0`,
    /// and records `createdAt`. Returns the fully-populated item.
    @discardableResult
    public func enqueue(_ request: QueueItemRequest) throws -> QueueItem {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.write { db in
                let id = ULID.generate()
                let orderingKey = try Self.nextOrderingKey(db, for: request.queue)
                let now = Self.nowMillis()
                let payloadJSON = try Self.encodePayload(request.payload)

                try db.execute(
                    sql: """
                    INSERT INTO queue_items
                        (id, queue, wiki_id, payload, state, ordering_key,
                         provider_id, attempt, error, created_at, started_at, finished_at)
                    VALUES
                        (?, ?, ?, ?, ?, ?, NULL, 0, NULL, ?, NULL, NULL);
                    """,
                    arguments: [
                        id, request.queue.rawValue, request.wikiID, payloadJSON,
                        QueueItemState.queued.rawValue, orderingKey, now,
                    ])

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
    }

    // MARK: - Public API: Read

    /// Fetch a single item by ID, or `nil` if no row matches.
    public func getItem(_ id: QueueItem.ID) throws -> QueueItem? {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT \(Self.selectColumns)
                    FROM queue_items
                    WHERE id = ?;
                    """,
                    arguments: [id])
                guard let row else { return nil }
                return try Self.readItem(from: row)
            }
        }
    }

    /// Load all non-terminal items (`.queued` and `.running`), ordered by
    /// `ordering_key` ascending. If `queue` is `nil`, returns items from both
    /// queues; otherwise restricted to the specified queue.
    public func loadActive(for queue: QueueKind? = nil) throws -> [QueueItem] {
        try Self.wrap {
            let dbQueue = try self.queue()
            return try dbQueue.read { db in
                let rows: [Row]
                if let queue {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT \(Self.selectColumns)
                        FROM queue_items
                        WHERE state IN ('queued', 'running') AND queue = ?
                        ORDER BY ordering_key ASC;
                        """,
                        arguments: [queue.rawValue])
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT \(Self.selectColumns)
                        FROM queue_items
                        WHERE state IN ('queued', 'running')
                        ORDER BY ordering_key ASC;
                        """)
                }
                return try rows.map { try Self.readItem(from: $0) }
            }
        }
    }

    /// Load terminal items (`.completed`, `.failed`, `.cancelled`), newest
    /// first (by `finished_at` descending), bounded by `limit`.
    public func loadRecent(limit: Int = 200) throws -> [QueueItem] {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.selectColumns)
                    FROM queue_items
                    WHERE state IN ('completed', 'failed', 'cancelled')
                    ORDER BY finished_at DESC
                    LIMIT ?;
                    """,
                    arguments: [Int64(limit)])
                return try rows.map { try Self.readItem(from: $0) }
            }
        }
    }

    // MARK: - Public API: State transitions

    /// Transition an item from `.queued` → `.running`, recording the provider
    /// that claimed it and the start time. Throws if the item is not in
    /// `.queued` state.
    public func markRunning(id: QueueItem.ID, providerID: String) throws {
        try validateTransition(id: id, allowedFrom: [.queued], to: .running)
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'running', provider_id = ?, started_at = ?,
                        finished_at = NULL, error = NULL
                    WHERE id = ?;
                    """,
                    arguments: [providerID, now, id])
            }
        }
    }

    /// Transition an item from `.running` → `.completed`, recording the finish
    /// time. Throws if the item is not in `.running` state.
    public func markCompleted(id: QueueItem.ID) throws {
        try validateTransition(id: id, allowedFrom: [.running], to: .completed)
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'completed', finished_at = ?
                    WHERE id = ?;
                    """,
                    arguments: [now, id])
            }
        }
    }

    /// Transition an item from `.running` → `.failed`, recording the finish
    /// time and the error message. Throws if the item is not in `.running` state.
    public func markFailed(id: QueueItem.ID, error: String) throws {
        try validateTransition(id: id, allowedFrom: [.running], to: .failed)
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'failed', finished_at = ?, error = ?
                    WHERE id = ?;
                    """,
                    arguments: [now, error, id])
            }
        }
    }

    /// Transition an item from `.queued` or `.running` → `.cancelled`,
    /// recording the finish time. Preserves the `orderingKey`. Throws if the
    /// item is in a terminal state.
    public func markCancelled(id: QueueItem.ID) throws {
        try validateTransition(id: id, allowedFrom: [.queued, .running], to: .cancelled)
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'cancelled', finished_at = ?
                    WHERE id = ?;
                    """,
                    arguments: [now, id])
            }
        }
    }

    /// Transition an item from `.running` → `.queued` (the halt / cancel path).
    /// Clears `providerID` and `startedAt`. Preserves the `orderingKey` so the
    /// item retains its position. Throws if the item is not in `.running` state.
    public func requeue(id: QueueItem.ID) throws {
        try validateTransition(id: id, allowedFrom: [.running], to: .queued)

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'queued', provider_id = NULL, started_at = NULL
                    WHERE id = ?;
                    """,
                    arguments: [id])
            }
        }
    }

    /// Retry a `.failed` item: transition to `.queued`, increment `attempt`,
    /// and assign a NEW `orderingKey` (back of the queue). Clears the error
    /// message. Throws if the item is not in `.failed` state.
    public func retryItem(id: QueueItem.ID) throws {
        try validateTransition(id: id, allowedFrom: [.failed], to: .queued)

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                let kind = try Self.fetchQueueKind(db, id: id)
                let newOrderingKey = try Self.nextOrderingKey(db, for: kind)

                try db.execute(
                    sql: """
                    UPDATE queue_items
                    SET state = 'queued', ordering_key = ?, attempt = attempt + 1,
                        error = NULL, finished_at = NULL
                    WHERE id = ?;
                    """,
                    arguments: [newOrderingKey, id])
            }
        }
    }

    // MARK: - Public API: Reorder

    /// Update the `ordering_key` for an item. Used by the engine's
    /// `reorderItem` to move a queued item to a new position in its queue.
    /// Does not change state — the item must already be `.queued`.
    /// Returns the updated item, or `nil` if the item was not found.
    @discardableResult
    public func updateOrderingKey(id: QueueItem.ID, key: Int64) throws -> QueueItem? {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE queue_items SET ordering_key = ? WHERE id = ?;",
                    arguments: [key, id])
            }
        }
        return try getItem(id)
    }

    /// The current maximum ordering key for a queue. Used by the engine
    /// when moving an item to the end of a queue.
    public func maxOrderingKey(for queue: QueueKind) throws -> Int64 {
        try Self.wrap {
            let dbQueue = try self.queue()
            return try dbQueue.read { db in
                let value = try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(ordering_key), 0) FROM queue_items WHERE queue = ?;",
                    arguments: [queue.rawValue])
                return value ?? 0
            }
        }
    }

    // MARK: - Public API: Crash recovery

    /// Reset all items found in `.running` state back to `.queued` (their
    /// `attempt` count is preserved). Called by the engine at launch to
    /// recover from crashes. Returns the count of reset rows.
    @discardableResult
    public func resetRunningToQueued() throws -> Int {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.write { db in
                try db.execute(sql: """
                UPDATE queue_items
                SET state = 'queued', provider_id = NULL, started_at = NULL
                WHERE state = 'running';
                """)
                return db.changesCount
            }
        }
    }

    // MARK: - Public API: Queue run state

    /// The run state for a queue (`.running` or `.paused`). Defaults to
    /// `.running` if the row is somehow missing (shouldn't happen — seeded at
    /// schema creation).
    public func queueRunState(for queue: QueueKind) throws -> QueueRunState {
        try Self.wrap {
            let dbQueue = try self.queue()
            return try dbQueue.read { db in
                let raw = try String.fetchOne(
                    db,
                    sql: "SELECT state FROM queue_state WHERE queue = ?;",
                    arguments: [queue.rawValue])
                return QueueRunState(rawValue: raw ?? "") ?? .running
            }
        }
    }

    /// Set the run state for a queue (persisted across app restarts).
    public func setQueueRunState(_ queue: QueueKind, _ state: QueueRunState) throws {
        try Self.wrap {
            let dbQueue = try self.queue()
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO queue_state (queue, state) VALUES (?, ?)
                    ON CONFLICT(queue) DO UPDATE SET state = ?;
                    """,
                    arguments: [queue.rawValue, state.rawValue, state.rawValue])
            }
        }
    }

    // MARK: - Public API: Maintenance

    /// Prune terminal items (`.completed`, `.failed`, `.cancelled`) beyond
    /// `maxPerQueue` per queue kind, keeping the most recent (by
    /// `finished_at`). Non-terminal items are never pruned.
    public func pruneHistory(maxPerQueue: Int = 200) throws {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                for kind in [QueueKind.extraction, QueueKind.ingestion] {
                    try db.execute(
                        sql: """
                        DELETE FROM queue_items
                        WHERE id IN (
                            SELECT id FROM queue_items
                            WHERE queue = ?
                              AND state IN ('completed', 'failed', 'cancelled')
                            ORDER BY finished_at DESC
                            LIMIT -1 OFFSET ?
                        );
                        """,
                        arguments: [kind.rawValue, Int64(maxPerQueue)])
                }
            }
        }
    }

    // MARK: - Public API: Item events (transcripts)

    /// Append a typed agent event to the persisted transcript for a queue item.
    /// Events are stored in insertion order (seq is auto-incremented by SQLite).
    /// Safe to call from a background thread — the store serializes via GRDB.
    public func appendItemEvent(itemID: QueueItem.ID, event: AgentEvent) throws {
        let data = try JSONEncoder().encode(event)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO queue_item_events (item_id, seq, event_json, created_at)
                    VALUES (?, COALESCE((SELECT MAX(seq) FROM queue_item_events WHERE item_id = ?), -1) + 1, ?, ?);
                    """,
                    arguments: [itemID, itemID, json, now])
            }
        }
    }

    /// Load all persisted agent events for a queue item, ordered by seq.
    public func loadItemEvents(itemID: QueueItem.ID) throws -> [AgentEvent] {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT event_json FROM queue_item_events WHERE item_id = ? ORDER BY seq;",
                    arguments: [itemID])
                return rows.compactMap { row -> AgentEvent? in
                    let json: String = row["event_json"]
                    guard let data = json.data(using: .utf8) else { return nil }
                    do {
                        return try JSONDecoder().decode(AgentEvent.self, from: data)
                    } catch {
                        DebugLog.store("QueueStore.loadItemEvents: decode failed for event row — \(error.localizedDescription)")
                        return nil
                    }
                }
            }
        }
    }

    /// Delete all persisted events for an item (e.g. on retry — clears the old transcript).
    public func deleteItemEvents(itemID: QueueItem.ID) throws {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM queue_item_events WHERE item_id = ?;",
                    arguments: [itemID])
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
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let raw = try String.fetchOne(
                    db,
                    sql: "SELECT state FROM queue_items WHERE id = ?;",
                    arguments: [id])
                guard let raw else { throw QueueStoreError.notFound(id) }
                guard let state = QueueItemState(rawValue: raw) else {
                    throw QueueStoreError.sqlite(code: -1, message: "Unknown item state: \(raw)")
                }
                return state
            }
        }
    }

    /// Fetch the `QueueKind` of an item by ID. Throws `.notFound` if no row.
    private static func fetchQueueKind(_ db: Database, id: QueueItem.ID) throws -> QueueKind {
        let raw = try String.fetchOne(
            db,
            sql: "SELECT queue FROM queue_items WHERE id = ?;",
            arguments: [id])
        guard let raw else { throw QueueStoreError.notFound(id) }
        guard let kind = QueueKind(rawValue: raw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown queue kind: \(raw)")
        }
        return kind
    }
}
