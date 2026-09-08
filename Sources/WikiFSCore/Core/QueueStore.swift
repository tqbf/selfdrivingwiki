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
    /// A typed transcript item did not provide a usable case-specific identity.
    case invalidTranscriptIdentity(String)
    /// A transcript batch was produced by a queue worker from an earlier retry.
    case staleAttempt(QueueAttemptID, currentAttempt: Int)

    public var description: String {
        switch self {
        case .open(let m): return "QueueStore open failed: \(m)"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .notFound(let id): return "Queue item not found: \(id.rawValue)"
        case .invalidStateTransition(let from, let to):
            return "Invalid queue state transition: \(from.rawValue) → \(to.rawValue)"
        case .invalidRequest(let m): return "Invalid request: \(m)"
        case .invalidTranscriptIdentity(let kind):
            return "Invalid transcript identity for \(kind)"
        case .staleAttempt(let rejected, let currentAttempt):
            return "Stale queue attempt \(rejected.attempt) for \(rejected.itemID.rawValue); current attempt is \(currentAttempt)"
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
/// performance PRAGMAs as `GRDBWikiStore` (#523).
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

        // Performance PRAGMAs matching GRDBWikiStore (#523).
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
    /// connection on deinit. Mirrors `GRDBWikiStore.checkpointAndClose` —
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
    /// - v4: `queue_item_activity` table — per-item usage JSON, log/debug URLs,
    ///   and progress-log text (persisted Activity-window metadata).
    /// - v5: `queue_item_transcript_items` table — additive typed transcript
    ///   storage.
    /// - v6: final typed transcript cutover. Drops only the approved legacy
    ///   `queue_item_events` table.
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

        // v4: per-item Activity-window metadata — cumulative token/cost usage
        // (JSON), the run's `run.jsonl` log URL + `debug/` folder URL, and the
        // accumulated progress-log text. Persisted so the Activity window can
        // show completed/failed/cancelled ingestion + lint runs (usage summary,
        // "Reveal Log" / "Reveal Debug Folder", progress) after an app restart.
        // Keyed by `item_id` with `ON DELETE CASCADE` so rows vanish when the
        // item is pruned by `pruneHistory` (mirrors `queue_item_events`).
        // `usage_json` is an opaque string here — `QueueStore` lives in
        // `WikiFSCore` and cannot reference `SessionUsage` (in `WikiFSEngine`);
        // the engine encodes/decodes it.
        m.registerMigration("v4_add_item_activity") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_item_activity (
                item_id       TEXT PRIMARY KEY,
                usage_json    TEXT,
                log_url       TEXT,
                debug_url     TEXT,
                progress_log  TEXT,
                updated_at    INTEGER NOT NULL,
                FOREIGN KEY (item_id) REFERENCES queue_items(id) ON DELETE CASCADE
            );
            """)
        }

        // v5: additive typed queue transcript storage. The v6 cutover below
        // drops the approved legacy table after all runtime callers use these
        // typed APIs.
        m.registerMigration("v5_add_typed_transcript_items") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_item_transcript_items (
                item_id        TEXT NOT NULL REFERENCES queue_items(id) ON DELETE CASCADE,
                attempt        INTEGER NOT NULL,
                seq            INTEGER NOT NULL,
                item_kind      TEXT NOT NULL,
                identity       TEXT NOT NULL,
                item_json      TEXT NOT NULL,
                projected_text TEXT NOT NULL DEFAULT '',
                created_at     INTEGER NOT NULL,
                updated_at     INTEGER NOT NULL,
                PRIMARY KEY (item_id, attempt, seq),
                UNIQUE (item_id, attempt, item_kind, identity)
            ) WITHOUT ROWID;
            """)
        }

        // v6 is intentionally only the approved legacy transcript reset. Do
        // not alter queue metadata, activity rows, or any wiki/chat database.
        m.registerMigration("v6_drop_legacy_item_events") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS queue_item_events;")
        }

        // v7: additive durable attempt reports (integrated-queue-workspace
        // plan §2). One header row per (item, attempt) with the producing
        // execution identity + monotonic revision, and one row per target
        // keyed by item + attempt + namespace + target id so target updates
        // upsert only affected rows. Both cascade with `queue_items`, so
        // `pruneHistory` and item deletion clean reports without a separate
        // sweep. `retryItem` deliberately does NOT touch these tables —
        // previous attempts' reports are preserved (attempt isolation).
        m.registerMigration("v7_add_attempt_reports") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_attempt_reports (
                item_id        TEXT NOT NULL REFERENCES queue_items(id) ON DELETE CASCADE,
                attempt        INTEGER NOT NULL,
                execution_id   TEXT NOT NULL,
                operation      TEXT NOT NULL,
                scope          TEXT NOT NULL,
                phase          TEXT NOT NULL,
                provider_id    TEXT,
                model          TEXT,
                availability   TEXT NOT NULL,
                result_summary TEXT,
                revision       INTEGER NOT NULL,
                updated_at     INTEGER NOT NULL,
                PRIMARY KEY (item_id, attempt)
            ) WITHOUT ROWID;
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS queue_attempt_report_targets (
                item_id       TEXT NOT NULL REFERENCES queue_items(id) ON DELETE CASCADE,
                attempt       INTEGER NOT NULL,
                namespace     TEXT NOT NULL,
                target_id     TEXT NOT NULL,
                seq           INTEGER NOT NULL,
                display_name  TEXT NOT NULL DEFAULT '',
                state         TEXT NOT NULL,
                result        TEXT,
                detail        TEXT,
                updated_at    INTEGER NOT NULL,
                PRIMARY KEY (item_id, attempt, namespace, target_id),
                UNIQUE (item_id, attempt, seq)
            ) WITHOUT ROWID;
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_queue_attempt_report_targets_order
                ON queue_attempt_report_targets(item_id, attempt, seq);
            """)
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

    // MARK: - Typed transcript storage helpers

    /// The case tag is part of the durable identity. A provider can reuse one
    /// raw ID in multiple transcript namespaces, so the raw value alone is not
    /// safe for lookups or uniqueness.
    private enum TypedTranscriptItemKind: String {
        case message
        case toolCall
        case systemNotice
        case turnFailure
    }

    private struct TypedTranscriptIdentity {
        let kind: TypedTranscriptItemKind
        let rawValue: String

        init(item: ChatTranscriptItem) throws {
            switch item {
            case .message(let message):
                self.kind = .message
                self.rawValue = message.messageID.rawValue
            case .toolCall(let toolCall):
                self.kind = .toolCall
                self.rawValue = toolCall.toolCallID.rawValue
            case .systemNotice(let notice):
                self.kind = .systemNotice
                self.rawValue = notice.noticeID.rawValue
            case .turnFailure(let failure):
                self.kind = .turnFailure
                self.rawValue = failure.failureID.rawValue
            }

            guard rawValue.isEmpty == false else {
                throw QueueStoreError.invalidTranscriptIdentity(kind.rawValue)
            }
        }
    }

    private struct EncodedTypedTranscriptItem {
        let identity: TypedTranscriptIdentity
        let itemJSON: String
        let projectedText: String
    }

    private static func encodeTypedTranscriptItem(_ item: ChatTranscriptItem) throws -> EncodedTypedTranscriptItem {
        let identity = try TypedTranscriptIdentity(item: item)
        let data = try JSONEncoder().encode(item)
        guard let itemJSON = String(data: data, encoding: .utf8) else {
            throw QueueStoreError.invalidRequest("Transcript item JSON is not UTF-8")
        }
        return EncodedTypedTranscriptItem(
            identity: identity,
            itemJSON: itemJSON,
            projectedText: LegacyChatTranscriptPersistenceProjection.project(item).plainText
        )
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

    /// Decode a stored `queue` raw value into a `QueueKind`.
    ///
    /// Tolerates the legacy `"lint"` raw value: an abandoned dev-only queue
    /// kind that was never shipped in `QueueKind` but can survive in databases
    /// migrated before the v1 cleanup `DELETE`. Lint is a payload variant of
    /// `.ingestion` (see `QueueKind`), so those rows decode as `.ingestion`.
    /// Also tolerates legacy `"transcription"` rows from before transcript
    /// work merged into `.extraction`.
    /// Genuinely unrecognized values still throw — so real corruption stays
    /// visible instead of being silently coerced.
    private static func decodeQueueKind(_ raw: String) throws -> QueueKind {
        if let kind = QueueKind(rawValue: raw) { return kind.canonical }
        if raw == "lint" { return .ingestion }
        throw QueueStoreError.sqlite(code: -1, message: "Unknown queue kind: \(raw)")
    }

    /// Decode rows one-by-one so a single unknown legacy/corrupt queue raw
    /// value does not hide every other item in the same snapshot section.
    private static func readItemsSkippingUnknownQueues(from rows: [Row]) throws -> [QueueItem] {
        var items: [QueueItem] = []
        items.reserveCapacity(rows.count)

        for row in rows {
            do {
                items.append(try readItem(from: row))
            } catch let QueueStoreError.sqlite(code, message)
                where code == -1 && message.hasPrefix("Unknown queue kind:") {
                let rowID = (row["id"] as String?) ?? "<missing-id>"
                DebugLog.store("QueueStore: skipping row id=\(rowID) with \(message)")
            }
        }

        return items
    }

    /// Read a `QueueItem` from a GRDB `Row`. Named column access (not positional)
    /// so column order changes are harmless — a key safety improvement over
    /// the old `stmt.text(at: 0)` positional access.
    private static func readItem(from row: Row) throws -> QueueItem {
        // SQL/Row boundary: the column is a raw TEXT String — wrap as QueueItemID.
        let id = QueueItemID(rawValue: (row["id"] as String? ?? ""))
        let queueRaw: String = row["queue"]
        // SQL/Row boundary: the column is a raw TEXT String — wrap as WikiID.
        let wikiID = WikiID(rawValue: (row["wiki_id"] as String? ?? ""))
        let payloadText: String = row["payload"]
        let stateRaw: String = row["state"]
        let orderingKey: Int64 = row["ordering_key"]
        // SQL/Row boundary: the column is a raw TEXT String — wrap as ProviderID.
        let providerID: ProviderID? = (row["provider_id"] as String?).map { ProviderID(rawValue: $0) }
        let attempt: Int = row["attempt"]
        let errorText: String? = row["error"]
        let createdAt: Int64 = row["created_at"]
        let startedAt: Int64? = row["started_at"]
        let finishedAt: Int64? = row["finished_at"]

        let queue = try decodeQueueKind(queueRaw)
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
                let id = QueueItemID(rawValue: ULID.generate())
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
                        id.rawValue, request.queue.rawValue, request.wikiID.rawValue, payloadJSON,
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
                    arguments: [id.rawValue])
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
                return try Self.readItemsSkippingUnknownQueues(from: rows)
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
                return try Self.readItemsSkippingUnknownQueues(from: rows)
            }
        }
    }

    // MARK: - Public API: State transitions

    /// Transition an item from `.queued` → `.running`, recording the provider
    /// that claimed it and the start time. Throws if the item is not in
    /// `.queued` state.
    public func markRunning(id: QueueItem.ID, providerID: ProviderID) throws {
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
                    // SQL argument boundary: bind the raw String.
                    arguments: [providerID.rawValue, now, id.rawValue])
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
                    arguments: [now, id.rawValue])
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
                    arguments: [now, error, id.rawValue])
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
                    arguments: [now, id.rawValue])
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
                    arguments: [id.rawValue])
            }
        }
    }

    /// Retry a `.failed` or `.cancelled` item: transition to `.queued`,
    /// increment `attempt`, and assign a NEW `orderingKey` (back of the
    /// queue). Clears the error message. Throws if the item is not in
    /// `.failed` or `.cancelled` state.
    ///
    /// `.cancelled → .queued` is permitted (#635): the Activity window offers
    /// a Retry button on cancelled/killed jobs, and silently rejecting the
    /// transition (the prior behavior) dead-ended the button — the UI's
    /// affordance must match the store's allowed transitions.
    public func retryItem(id: QueueItem.ID) throws {
        try validateTransition(id: id, allowedFrom: [.failed, .cancelled], to: .queued)

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
                    arguments: [newOrderingKey, id.rawValue])
                try db.execute(
                    sql: "DELETE FROM queue_item_transcript_items WHERE item_id = ?;",
                    arguments: [id.rawValue])
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
                    arguments: [key, id.rawValue])
            }
        }
        return try getItem(id)
    }

    /// Update the `payload` for an item. Used to persist ACP session IDs
    /// for crash recovery. Returns the updated item, or `nil` if the item
    /// was not found.
    @discardableResult
    public func updatePayload(id: QueueItem.ID, payload: QueueItemPayload) throws -> QueueItem? {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                let data = try JSONEncoder().encode(payload)
                try db.execute(
                    sql: "UPDATE queue_items SET payload = ? WHERE id = ?;",
                    arguments: [String(data: data, encoding: .utf8)!, id.rawValue])
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

    // MARK: - Public API: Typed transcript items

    /// Atomically persist changed typed transcript items for one immutable queue
    /// attempt. The store validates the attempt inside the same write
    /// transaction that allocates sequence numbers and upserts the batch.
    ///
    /// A matching tagged identity updates content in place. Its original
    /// sequence and creation time remain stable, so streamed replacements do
    /// not move a row in the transcript.
    public func upsertTranscriptItems(
        attemptID: QueueAttemptID,
        items: [ChatTranscriptItem]
    ) throws {
        let encodedItems = try items.map(Self.encodeTypedTranscriptItem)
        let now = Self.nowMillis()

        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                let currentAttempt = try Int.fetchOne(
                    db,
                    sql: "SELECT attempt FROM queue_items WHERE id = ?;",
                    arguments: [attemptID.itemID.rawValue]
                )
                guard let currentAttempt else {
                    throw QueueStoreError.notFound(attemptID.itemID)
                }
                guard currentAttempt == attemptID.attempt else {
                    throw QueueStoreError.staleAttempt(attemptID, currentAttempt: currentAttempt)
                }

                for item in encodedItems {
                    try db.execute(sql: """
                    INSERT INTO queue_item_transcript_items (
                        item_id, attempt, seq, item_kind, identity, item_json,
                        projected_text, created_at, updated_at
                    ) VALUES (
                        ?, ?,
                        COALESCE((
                            SELECT MAX(seq) + 1
                            FROM queue_item_transcript_items
                            WHERE item_id = ? AND attempt = ?
                        ), 0),
                        ?, ?, ?, ?, ?, ?
                    )
                    ON CONFLICT(item_id, attempt, item_kind, identity) DO UPDATE SET
                        item_json = excluded.item_json,
                        projected_text = excluded.projected_text,
                        updated_at = excluded.updated_at;
                    """, arguments: [
                        attemptID.itemID.rawValue,
                        attemptID.attempt,
                        attemptID.itemID.rawValue,
                        attemptID.attempt,
                        item.identity.kind.rawValue,
                        item.identity.rawValue,
                        item.itemJSON,
                        item.projectedText,
                        now,
                        now,
                    ])
                }
            }
        }
    }

    /// Load all typed transcript items for an item in durable sequence order.
    /// Invalid rows are logged and skipped so one corrupt row does not hide the
    /// rest of the item transcript.
    public func loadTranscriptItems(itemID: QueueItem.ID) throws -> [ChatTranscriptItem] {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT item_json
                    FROM queue_item_transcript_items
                    WHERE item_id = ?
                    ORDER BY seq ASC;
                    """,
                    arguments: [itemID.rawValue]
                )
                var items: [ChatTranscriptItem] = []
                items.reserveCapacity(rows.count)
                for row in rows {
                    let itemJSON: String = row["item_json"]
                    guard let data = itemJSON.data(using: .utf8) else {
                        DebugLog.store("QueueStore.loadTranscriptItems: item JSON is not UTF-8 for \(itemID.rawValue)")
                        continue
                    }
                    do {
                        items.append(try JSONDecoder().decode(ChatTranscriptItem.self, from: data))
                    } catch {
                        DebugLog.store("QueueStore.loadTranscriptItems: decode failed for \(itemID.rawValue): \(error)")
                    }
                }
                return items
            }
        }
    }

    /// Delete typed transcript rows for one selected queue item. Phase 2 keeps
    /// legacy event-store callers unchanged, so this method is intentionally not
    /// wired into the existing retry path until the typed cutover.
    public func deleteTranscriptItems(itemID: QueueItem.ID) throws {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM queue_item_transcript_items WHERE item_id = ?;",
                    arguments: [itemID.rawValue]
                )
            }
        }
    }

    // MARK: - Public API: Item activity (usage / paths / progress)

    /// Persisted per-item Activity-window metadata: cumulative token/cost usage
    /// (encoded JSON), the run's `run.jsonl` log URL + `debug/` folder URL, and
    /// the accumulated progress-log text.
    ///
    /// Stored as raw `String?`s so this type lives in `WikiFSCore` without
    /// depending on `SessionUsage` (which is in `WikiFSEngine`). The engine
    /// layer encodes/decodes `usageJSON` to/from `SessionUsage`. Persisted so
    /// the Activity window can show completed/failed/cancelled ingestion + lint
    /// runs (usage summary, "Reveal Log"/"Reveal Debug Folder", progress) after
    /// an app restart. Rows cascade-delete with their item (`pruneHistory`).
    public struct QueueItemActivity: Sendable, Equatable {
        public let usageJSON: String?
        public let logURL: String?
        public let debugURL: String?
        public let progressLog: String?

        public init(usageJSON: String?, logURL: String?, debugURL: String?, progressLog: String?) {
            self.usageJSON = usageJSON
            self.logURL = logURL
            self.debugURL = debugURL
            self.progressLog = progressLog
        }
    }

    /// Upsert per-item activity metadata. Each parameter is optional; a `nil`
    /// argument leaves the existing value untouched (COALESCE), so callers can
    /// update one field (e.g. just usage) without clobbering the others. Safe
    /// to call from a background thread — the store serializes via GRDB.
    public func upsertItemActivity(
        itemID: QueueItem.ID,
        usageJSON: String?,
        logURL: String?,
        debugURL: String?
    ) throws {
        let now = Self.nowMillis()
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO queue_item_activity
                        (item_id, usage_json, log_url, debug_url, progress_log, updated_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(item_id) DO UPDATE SET
                        usage_json = COALESCE(excluded.usage_json, queue_item_activity.usage_json),
                        log_url    = COALESCE(excluded.log_url, queue_item_activity.log_url),
                        debug_url  = COALESCE(excluded.debug_url, queue_item_activity.debug_url),
                        updated_at = excluded.updated_at;
                    """,
                    arguments: [itemID.rawValue, usageJSON, logURL, debugURL, now])
            }
        }
    }

    /// Append a progress line to an item's accumulated progress log. The first
    /// line sets the column; subsequent lines append with a newline separator
    /// (mirrors `QueueActivityTracker`'s in-memory accumulation). Safe to call
    /// from a background thread.
    public func appendItemProgress(itemID: QueueItem.ID, line: String) throws {
        let now = Self.nowMillis()
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO queue_item_activity
                        (item_id, usage_json, log_url, debug_url, progress_log, updated_at)
                    VALUES (?, NULL, NULL, NULL, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET
                        progress_log = CASE
                            WHEN queue_item_activity.progress_log IS NULL
                              OR queue_item_activity.progress_log = ''
                            THEN excluded.progress_log
                            ELSE queue_item_activity.progress_log || char(10) || excluded.progress_log
                        END,
                        updated_at = excluded.updated_at;
                    """,
                    arguments: [itemID.rawValue, line, now])
            }
        }
    }

    /// Load the persisted activity metadata for a single item, or `nil`.
    public func loadItemActivity(itemID: QueueItem.ID) throws -> QueueItemActivity? {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT usage_json, log_url, debug_url, progress_log
                    FROM queue_item_activity WHERE item_id = ?;
                    """,
                    arguments: [itemID.rawValue]) else { return nil }
                return QueueItemActivity(
                    usageJSON: row["usage_json"],
                    logURL: row["log_url"],
                    debugURL: row["debug_url"],
                    progressLog: row["progress_log"])
            }
        }
    }

    /// Load all persisted activity rows, keyed by item ID. Used by the Activity
    /// tracker to rehydrate after an app restart. Bounded by `pruneHistory`
    /// (rows cascade-delete with their item, so only existing terminal items
    /// have rows).
    public func loadAllActivity() throws -> [QueueItem.ID: QueueItemActivity] {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT item_id, usage_json, log_url, debug_url, progress_log
                    FROM queue_item_activity;
                    """)
                var result: [QueueItem.ID: QueueItemActivity] = [:]
                result.reserveCapacity(rows.count)
                for row in rows {
                    // SQL/Row boundary: TEXT → QueueItemID.
                    let id = QueueItemID(rawValue: (row["item_id"] as String? ?? ""))
                    result[id] = QueueItemActivity(
                        usageJSON: row["usage_json"],
                        logURL: row["log_url"],
                        debugURL: row["debug_url"],
                        progressLog: row["progress_log"])
                }
                return result
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
                    arguments: [id.rawValue])
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
            arguments: [id.rawValue])
        guard let raw else { throw QueueStoreError.notFound(id) }
        return try decodeQueueKind(raw)
    }
}

// MARK: - QueueReportStoreError

/// Errors specific to the attempt-report tables. Stale attempts reuse
/// `QueueStoreError.staleAttempt`; a report written by an execution that no
/// longer owns the item is rejected with `.staleExecution` so delayed
/// prior-dispatch updates can never replace newer data.
public enum QueueReportStoreError: Error, CustomStringConvertible, LocalizedError {
    /// The attempt has no report header — the producer never began one.
    case notInitialized(QueueItem.ID)
    /// The write came from an execution (lease dispatch) that is no longer
    /// the current owner of this (item, attempt) report.
    case staleExecution(
        attemptID: QueueAttemptID,
        expected: QueueExecutionID,
        current: QueueExecutionID)

    public var description: String {
        switch self {
        case .notInitialized(let id):
            return "Queue report not initialized for item \(id.rawValue)"
        case .staleExecution(let attemptID, let expected, let current):
            return "Stale queue report execution \(expected.rawValue.uuidString) for \(attemptID.itemID.rawValue) attempt \(attemptID.attempt); current execution is \(current.rawValue.uuidString)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - QueueStore: attempt reports

extension QueueStore {

    // MARK: Report row codecs

    private static let reportHeaderColumns = """
        item_id, attempt, execution_id, operation, scope, phase, provider_id,
        model, availability, result_summary, revision
        """

    private static let reportEncoder = JSONEncoder()
    private static let reportDecoder = JSONDecoder()

    private static func encodeReportValue<T: Encodable>(_ value: T) throws -> String {
        let data = try reportEncoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeReportValue<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw QueueStoreError.sqlite(code: -1, message: "report value is not valid UTF-8")
        }
        return try reportDecoder.decode(type, from: data)
    }

    /// Read one attempt's full report (header + rows) inside the caller's
    /// transaction or read block. Returns `nil` when no header exists.
    private static func readReport(
        _ db: Database,
        itemID: QueueItem.ID,
        attempt: Int
    ) throws -> QueueAttemptReport? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT \(reportHeaderColumns) FROM queue_attempt_reports WHERE item_id = ? AND attempt = ?;",
            arguments: [itemID.rawValue, attempt])
        else { return nil }

        let executionRaw: String = row["execution_id"]
        guard let executionUUID = UUID(uuidString: executionRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "corrupt report execution id for \(itemID.rawValue)")
        }
        let operationRaw: String = row["operation"]
        guard let operation = QueueReportOperation(rawValue: operationRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown report operation: \(operationRaw)")
        }
        let scopeRaw: String = row["scope"]
        let scope = try decodeReportValue(QueueReportScope.self, from: scopeRaw)
        let phaseRaw: String = row["phase"]
        guard let phase = QueueReportPhase(rawValue: phaseRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown report phase: \(phaseRaw)")
        }
        let availabilityRaw: String = row["availability"]
        guard let availability = QueueReportAvailability(rawValue: availabilityRaw) else {
            throw QueueStoreError.sqlite(code: -1, message: "Unknown report availability: \(availabilityRaw)")
        }
        let providerID: ProviderID? = (row["provider_id"] as String?).map { ProviderID(rawValue: $0) }
        let modelRaw: String? = row["model"]
        let revisionRaw: Int = row["revision"]

        let targetRows = try Row.fetchAll(
            db,
            sql: """
            SELECT namespace, target_id, display_name, state, result, detail
            FROM queue_attempt_report_targets
            WHERE item_id = ? AND attempt = ?
            ORDER BY seq ASC;
            """,
            arguments: [itemID.rawValue, attempt])

        var targets: [QueueReportTargetRecord] = []
        targets.reserveCapacity(targetRows.count)
        for targetRow in targetRows {
            let namespace: String = targetRow["namespace"]
            let targetID: String = targetRow["target_id"]
            let target: QueueReportTarget
            switch namespace {
            case QueueReportTarget.source(SourceID(rawValue: "")).namespace:
                target = .source(SourceID(rawValue: targetID))
            case QueueReportTarget.page(PageID(rawValue: "")).namespace:
                target = .page(PageID(rawValue: targetID))
            default:
                throw QueueStoreError.sqlite(code: -1, message: "Unknown report target namespace: \(namespace)")
            }
            let stateRaw: String = targetRow["state"]
            let state = try decodeReportValue(QueueReportTargetState.self, from: stateRaw)
            let result = try (targetRow["result"] as String?).map {
                try decodeReportValue(QueueTargetResult.self, from: $0)
            }
            targets.append(QueueReportTargetRecord(
                target: target,
                displayName: targetRow["display_name"] ?? "",
                state: state,
                result: result,
                detail: targetRow["detail"]))
        }

        return QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: itemID, attempt: attempt),
            executionID: QueueExecutionID(rawValue: executionUUID),
            revision: QueueReportRevision(rawValue: revisionRaw),
            operation: operation,
            scope: scope,
            phase: phase,
            provider: providerID,
            model: modelRaw.map(QueueReportModelName.init(rawValue:)),
            availability: availability,
            resultSummary: row["result_summary"],
            targets: targets)
    }

    /// The item's current attempt, validated against `attemptID`. Shared
    /// guard for every report write so a worker from an earlier retry can
    /// never touch the current report.
    @discardableResult
    private static func validateReportAttempt(
        _ db: Database,
        _ attemptID: QueueAttemptID
    ) throws -> Int {
        let currentAttempt = try Int.fetchOne(
            db,
            sql: "SELECT attempt FROM queue_items WHERE id = ?;",
            arguments: [attemptID.itemID.rawValue])
        guard let currentAttempt else {
            throw QueueStoreError.notFound(attemptID.itemID)
        }
        guard currentAttempt == attemptID.attempt else {
            throw QueueStoreError.staleAttempt(attemptID, currentAttempt: currentAttempt)
        }
        return currentAttempt
    }

    /// Reset an existing header to a fresh state under a new execution.
    /// Observed outcomes are discarded (they belong to the dead dispatch) but
    /// the revision keeps moving forward so delayed old-execution data can
    /// never win.
    private static func resetHeaderToExecution(
        _ db: Database,
        itemID: QueueItem.ID,
        attempt: Int,
        executionID: QueueExecutionID
    ) throws {
        try db.execute(
            sql: "DELETE FROM queue_attempt_report_targets WHERE item_id = ? AND attempt = ?;",
            arguments: [itemID.rawValue, attempt])
        try db.execute(
            sql: """
            UPDATE queue_attempt_reports
            SET execution_id = ?, phase = ?, availability = ?,
                result_summary = NULL, provider_id = NULL, model = NULL,
                revision = revision + 1, updated_at = ?
            WHERE item_id = ? AND attempt = ?;
            """,
            arguments: [
                executionID.rawValue.uuidString,
                QueueReportPhase.planned.rawValue,
                QueueReportAvailability.available.rawValue,
                nowMillis(),
                itemID.rawValue,
                attempt,
            ])
    }

    /// Insert the scope's planned target rows at their inventory positions.
    private static func insertScopeTargets(
        _ db: Database,
        attemptID: QueueAttemptID,
        scope: QueueReportScope,
        at date: Int64
    ) throws {
        guard case .targets(let records) = scope else { return }
        for (index, record) in records.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO queue_attempt_report_targets (
                    item_id, attempt, namespace, target_id, seq,
                    display_name, state, result, detail, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                arguments: [
                    attemptID.itemID.rawValue,
                    attemptID.attempt,
                    record.target.namespace,
                    record.target.id,
                    index,
                    record.displayName,
                    try encodeReportValue(record.state),
                    try record.result.map { try encodeReportValue($0) },
                    record.detail,
                    date,
                ])
        }
    }

    /// Upsert only the affected target rows. A new row allocates the next
    /// inventory sequence; an existing row keeps its original position. An
    /// empty `displayName` never clobbers a recorded name (history
    /// preservation).
    private static func upsertTargetRecords(
        _ db: Database,
        attemptID: QueueAttemptID,
        records: [QueueReportTargetRecord],
        at date: Int64
    ) throws {
        for record in records {
            try db.execute(
                sql: """
                INSERT INTO queue_attempt_report_targets (
                    item_id, attempt, namespace, target_id, seq,
                    display_name, state, result, detail, updated_at
                ) VALUES (
                    ?, ?, ?, ?,
                    COALESCE(
                        (SELECT seq FROM queue_attempt_report_targets
                         WHERE item_id = ? AND attempt = ? AND namespace = ? AND target_id = ?),
                        (SELECT COALESCE(MAX(seq) + 1, 0) FROM queue_attempt_report_targets
                         WHERE item_id = ? AND attempt = ?)),
                    ?, ?, ?, ?, ?
                )
                ON CONFLICT(item_id, attempt, namespace, target_id) DO UPDATE SET
                    display_name = CASE
                        WHEN excluded.display_name = ''
                        THEN queue_attempt_report_targets.display_name
                        ELSE excluded.display_name
                    END,
                    state = excluded.state,
                    result = excluded.result,
                    detail = excluded.detail,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    attemptID.itemID.rawValue,
                    attemptID.attempt,
                    record.target.namespace,
                    record.target.id,
                    attemptID.itemID.rawValue,
                    attemptID.attempt,
                    record.target.namespace,
                    record.target.id,
                    attemptID.itemID.rawValue,
                    attemptID.attempt,
                    record.displayName,
                    try encodeReportValue(record.state),
                    try record.result.map { try encodeReportValue($0) },
                    record.detail,
                    date,
                ])
        }
    }

    // MARK: Public API: Report lifecycle

    /// Initialize (or execution-check) the report for one attempt.
    ///
    /// - No header → insert at revision 1 with the scope's planned targets.
    /// - Header with the same execution → no-op, returns the current report.
    /// - Header with a different execution (same-attempt restart,
    ///   halt-resume dispatch) → resets progress and advances the revision;
    ///   the scope is re-inserted fresh.
    ///
    /// This is the only place a report's target inventory is (re)created.
    /// `requeue(id:)` never calls this — halt/cancellation keeps observed
    /// outcomes until a new lease actually activates.
    public func beginReport(
        attemptID: QueueAttemptID,
        executionID: QueueExecutionID,
        operation: QueueReportOperation,
        scope: QueueReportScope
    ) throws -> QueueAttemptReport {
        let now = Self.nowMillis()
        return try Self.wrap {
            let queue = try self.queue()
            return try queue.write { db in
                try Self.validateReportAttempt(db, attemptID)

                if let existing = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) {
                    if existing.executionID == executionID {
                        // Same execution. Normally a no-op — EXCEPT when the
                        // inventory is empty (a lease activation reset the
                        // rows before this begin arrived): recreate the
                        // planned scope so a halt-resumed dispatch reports
                        // its targets.
                        if case .targets(let records) = scope, existing.targets.isEmpty, records.isEmpty == false {
                            try Self.insertScopeTargets(db, attemptID: attemptID, scope: scope, at: now)
                            try db.execute(
                                sql: "UPDATE queue_attempt_reports SET revision = revision + 1, updated_at = ? WHERE item_id = ? AND attempt = ?;",
                                arguments: [now, attemptID.itemID.rawValue, attemptID.attempt])
                            guard let reloaded = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                                throw QueueReportStoreError.notInitialized(attemptID.itemID)
                            }
                            return reloaded
                        }
                        return existing
                    }
                    try Self.resetHeaderToExecution(
                        db,
                        itemID: attemptID.itemID,
                        attempt: attemptID.attempt,
                        executionID: executionID)
                    try Self.insertScopeTargets(db, attemptID: attemptID, scope: scope, at: now)
                    guard let reloaded = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                        throw QueueReportStoreError.notInitialized(attemptID.itemID)
                    }
                    return reloaded
                }

                try db.execute(
                    sql: """
                    INSERT INTO queue_attempt_reports (
                        item_id, attempt, execution_id, operation, scope, phase,
                        provider_id, model, availability, result_summary, revision, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, NULL, 1, ?);
                    """,
                    arguments: [
                        attemptID.itemID.rawValue,
                        attemptID.attempt,
                        executionID.rawValue.uuidString,
                        operation.rawValue,
                        try Self.encodeReportValue(scope),
                        QueueReportPhase.planned.rawValue,
                        QueueReportAvailability.available.rawValue,
                        now,
                    ])
                try Self.insertScopeTargets(db, attemptID: attemptID, scope: scope, at: now)
                guard let report = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                    throw QueueReportStoreError.notInitialized(attemptID.itemID)
                }
                return report
            }
        }
    }

    /// Compare the stored execution identity for an attempt and reset the
    /// report when it changed, WITHOUT initializing a missing report. Called
    /// at every lease activation (`QueueWorkerOutputChannel.makeScope`) so a
    /// same-attempt restart cannot let a previous dispatch's stale progress
    /// survive into the new dispatch — including items whose producers never
    /// emit reports.
    public func activateReportExecution(
        attemptID: QueueAttemptID,
        executionID: QueueExecutionID
    ) throws {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try Self.validateReportAttempt(db, attemptID)
                guard let existing = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                    return
                }
                guard existing.executionID != executionID else { return }
                try Self.resetHeaderToExecution(
                    db,
                    itemID: attemptID.itemID,
                    attempt: attemptID.attempt,
                    executionID: executionID)
            }
        }
    }

    /// Validate the attempt and producing execution, apply one mutation,
    /// advance the revision, and return the committed report — all in the
    /// same write transaction. Rejections:
    /// - `.staleAttempt` — the write came from an earlier retry.
    /// - `.staleExecution` — the write came from a dispatch that no longer
    ///   owns this attempt (delayed old-lease update).
    /// - `.notInitialized` — the producer never began a report.
    public func commitReportMutation(
        attemptID: QueueAttemptID,
        executionID: QueueExecutionID,
        mutation: QueueReportMutation
    ) throws -> QueueAttemptReport {
        let now = Self.nowMillis()
        return try Self.wrap {
            let queue = try self.queue()
            return try queue.write { db in
                try Self.validateReportAttempt(db, attemptID)
                guard let existing = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                    throw QueueReportStoreError.notInitialized(attemptID.itemID)
                }
                guard existing.executionID == executionID else {
                    throw QueueReportStoreError.staleExecution(
                        attemptID: attemptID,
                        expected: executionID,
                        current: existing.executionID)
                }

                try db.execute(
                    sql: """
                    UPDATE queue_attempt_reports SET
                        phase = COALESCE(?, phase),
                        provider_id = COALESCE(?, provider_id),
                        model = COALESCE(?, model),
                        availability = COALESCE(?, availability),
                        result_summary = COALESCE(?, result_summary),
                        revision = revision + 1,
                        updated_at = ?
                    WHERE item_id = ? AND attempt = ?;
                    """,
                    arguments: [
                        mutation.phase?.rawValue,
                        mutation.provider?.rawValue,
                        mutation.model?.rawValue,
                        mutation.availability?.rawValue,
                        mutation.resultSummary,
                        now,
                        attemptID.itemID.rawValue,
                        attemptID.attempt,
                    ])
                try Self.upsertTargetRecords(
                    db,
                    attemptID: attemptID,
                    records: mutation.targetUpserts,
                    at: now)

                guard let committed = try Self.readReport(db, itemID: attemptID.itemID, attempt: attemptID.attempt) else {
                    throw QueueReportStoreError.notInitialized(attemptID.itemID)
                }
                return committed
            }
        }
    }

    /// Project a report after cancellation/halt/crash-recovery: observed
    /// outcomes are retained exactly as recorded; every unfinished target
    /// becomes `.interrupted` (never failed or succeeded); the phase closes
    /// as `.finished` and the revision advances. Returns `nil` when the
    /// item's current attempt has no report.
    @discardableResult
    public func projectInterruptedReport(itemID: QueueItem.ID) throws -> QueueAttemptReport? {
        let now = Self.nowMillis()
        return try Self.wrap {
            let queue = try self.queue()
            return try queue.write { db in
                let currentAttempt = try Int.fetchOne(
                    db,
                    sql: "SELECT attempt FROM queue_items WHERE id = ?;",
                    arguments: [itemID.rawValue])
                guard let currentAttempt else { return nil }
                guard let report = try Self.readReport(db, itemID: itemID, attempt: currentAttempt) else {
                    return nil
                }

                let unfinished = report.targets.filter { record in
                    !record.state.isObservedOutcome
                        && record.state != .interrupted
                        && record.state != .notReported
                }
                let alreadyFinished = report.phase == .finished
                if unfinished.isEmpty && alreadyFinished {
                    return report
                }

                try Self.upsertTargetRecords(
                    db,
                    attemptID: QueueAttemptID(itemID: itemID, attempt: currentAttempt),
                    records: unfinished.map { record in
                        QueueReportTargetRecord(
                            target: record.target,
                            displayName: record.displayName,
                            state: .interrupted,
                            result: nil,
                            detail: record.detail)
                    },
                    at: now)
                try db.execute(
                    sql: """
                    UPDATE queue_attempt_reports
                    SET phase = ?, revision = revision + 1, updated_at = ?
                    WHERE item_id = ? AND attempt = ?;
                    """,
                    arguments: [
                        QueueReportPhase.finished.rawValue,
                        now,
                        itemID.rawValue,
                        currentAttempt,
                    ])

                guard let reloaded = try Self.readReport(db, itemID: itemID, attempt: currentAttempt) else {
                    return nil
                }
                return reloaded
            }
        }
    }

    /// Read the current attempt's committed report, or `nil` when the item
    /// has no report — including a pruned/deleted item, for which "no
    /// report" is the truthful answer. Header + rows are read in one store
    /// operation so the revision can never disagree with the rows it
    /// describes.
    public func loadReport(itemID: QueueItem.ID) throws -> QueueAttemptReport? {
        try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let currentAttempt = try Int.fetchOne(
                    db,
                    sql: "SELECT attempt FROM queue_items WHERE id = ?;",
                    arguments: [itemID.rawValue])
                guard let currentAttempt else { return nil }
                return try Self.readReport(db, itemID: itemID, attempt: currentAttempt)
            }
        }
    }

    /// Load bounded summaries for the given item IDs (their CURRENT attempts)
    /// in one read. Items without a report are absent from the dictionary —
    /// absent means "no report", never "zero targets".
    public func loadReportSummaries(
        itemIDs: [QueueItem.ID]
    ) throws -> [QueueItem.ID: QueueReportSummary] {
        guard itemIDs.isEmpty == false else { return [:] }
        let rawIDs = itemIDs.map(\.rawValue)
        return try Self.wrap {
            let queue = try self.queue()
            return try queue.read { db in
                let headerRows = try SQLRequest<Row>("""
                    SELECT r.item_id, r.attempt, r.revision, r.phase, r.availability, r.result_summary
                    FROM queue_attempt_reports r
                    JOIN queue_items i ON i.id = r.item_id AND i.attempt = r.attempt
                    WHERE r.item_id IN \(rawIDs);
                    """).fetchAll(db)

                var summaries: [QueueItem.ID: QueueReportSummary] = [:]
                summaries.reserveCapacity(headerRows.count)
                guard headerRows.isEmpty == false else { return summaries }

                var countsByItem: [String: [QueueReportTargetCountKey: Int]] = [:]
                let countRows = try SQLRequest<Row>("""
                    SELECT t.item_id, t.state, COUNT(*) AS n
                    FROM queue_attempt_report_targets t
                    JOIN queue_items i ON i.id = t.item_id AND i.attempt = t.attempt
                    WHERE t.item_id IN \(rawIDs)
                    GROUP BY t.item_id, t.state;
                    """).fetchAll(db)
                for row in countRows {
                    let itemRaw: String = row["item_id"]
                    let stateRaw: String = row["state"]
                    let count: Int = row["n"]
                    let state: QueueReportTargetState
                    do {
                        state = try Self.decodeReportValue(QueueReportTargetState.self, from: stateRaw)
                    } catch {
                        DebugLog.store(
                            "QueueStore.loadReportSummaries: undecodable target state for \(itemRaw): \(error)")
                        continue
                    }
                    var counts = countsByItem[itemRaw] ?? [:]
                    counts[state.countKey, default: 0] += count
                    countsByItem[itemRaw] = counts
                }

                // Per-item bound: each item contributes at most
                // `maxSearchTargets` rows (window-function row number), so a
                // single huge early item cannot starve the items after it the
                // way a shared global LIMIT did.
                let searchRows = try SQLRequest<Row>("""
                    SELECT item_id, display_name, state, detail FROM (
                        SELECT t.item_id AS item_id,
                               t.display_name AS display_name,
                               t.state AS state,
                               t.detail AS detail,
                               ROW_NUMBER() OVER (
                                   PARTITION BY t.item_id ORDER BY t.seq
                               ) AS search_rank
                        FROM queue_attempt_report_targets t
                        JOIN queue_items i ON i.id = t.item_id AND i.attempt = t.attempt
                        WHERE t.item_id IN \(rawIDs)
                    )
                    WHERE search_rank <= \(QueueReportSummaryLimits.maxSearchTargets)
                    ORDER BY item_id, search_rank;
                    """).fetchAll(db)

                var searchFieldsByItem: [String: [String]] = [:]
                var searchCounts: [String: Int] = [:]
                for row in searchRows {
                    let itemRaw: String = row["item_id"]
                    let used = searchCounts[itemRaw, default: 0]
                    guard used < QueueReportSummaryLimits.maxSearchTargets else { continue }
                    searchCounts[itemRaw] = used + 1
                    var fields = searchFieldsByItem[itemRaw] ?? []
                    func folded(_ raw: String?) {
                        guard let raw, raw.isEmpty == false else { return }
                        fields.append(String(raw.prefix(QueueReportSummaryLimits.maxFieldLength)))
                    }
                    folded(row["display_name"] as String?)
                    if let stateRaw: String = row["state"] {
                        do {
                            let state = try Self.decodeReportValue(QueueReportTargetState.self, from: stateRaw)
                            switch state {
                            case .skipped(let reason), .failed(let reason):
                                folded(reason)
                            default:
                                break
                            }
                        } catch {
                            DebugLog.store(
                                "QueueStore.loadReportSummaries: undecodable target state for \(itemRaw): \(error)")
                        }
                    }
                    folded(row["detail"] as String?)
                    searchFieldsByItem[itemRaw] = fields
                }

                for row in headerRows {
                    let itemRaw: String = row["item_id"]
                    let itemID = QueueItemID(rawValue: itemRaw)
                    let phaseRaw: String = row["phase"]
                    guard let phase = QueueReportPhase(rawValue: phaseRaw) else {
                        DebugLog.store("QueueStore.loadReportSummaries: unknown phase \(phaseRaw) for \(itemRaw)")
                        continue
                    }
                    let availabilityRaw: String = row["availability"]
                    guard let availability = QueueReportAvailability(rawValue: availabilityRaw) else {
                        DebugLog.store("QueueStore.loadReportSummaries: unknown availability \(availabilityRaw) for \(itemRaw)")
                        continue
                    }
                    var searchFields = searchFieldsByItem[itemRaw] ?? []
                    if let summary: String = row["result_summary"] {
                        searchFields.append(String(summary.prefix(QueueReportSummaryLimits.maxFieldLength)))
                    }
                    var searchText = searchFields.joined(separator: " ")
                    if searchText.count > QueueReportSummaryLimits.maxTotalLength {
                        searchText = String(searchText.prefix(QueueReportSummaryLimits.maxTotalLength))
                    }

                    summaries[itemID] = QueueReportSummary(
                        itemID: itemID,
                        attempt: row["attempt"],
                        revision: QueueReportRevision(rawValue: row["revision"]),
                        phase: phase,
                        availability: availability,
                        phaseCounts: countsByItem[itemRaw] ?? [:],
                        resultSummary: row["result_summary"],
                        searchText: searchText)
                }
                return summaries
            }
        }
    }

    /// Delete all report rows for one item (every attempt). Exists for
    /// explicit cleanup paths; ordinary pruning cascades via foreign keys.
    public func deleteReports(itemID: QueueItem.ID) throws {
        try Self.wrap {
            let queue = try self.queue()
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM queue_attempt_report_targets WHERE item_id = ?;",
                    arguments: [itemID.rawValue])
                try db.execute(
                    sql: "DELETE FROM queue_attempt_reports WHERE item_id = ?;",
                    arguments: [itemID.rawValue])
            }
        }
    }
}
