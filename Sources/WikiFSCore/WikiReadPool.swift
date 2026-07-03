import Foundation

/// A pool of **read-only** snapshot connections over one wiki database, for
/// reads that should not run on the main-actor write store (debounced search,
/// bulk existence checks, future projection-style reads).
///
/// Why this is safe (graph-model Phase 0, `plans/graph-model-and-versioning.md` §8):
/// - Each pooled store is opened via `SQLiteWikiStore(readOnlyURL:)` —
///   `PRAGMA query_only=ON`, no migrations, no open-time self-heal — so a pool
///   member can never write or author schema. This mirrors exactly how the
///   File Provider extension already reads the same file from another process.
/// - Each pooled store owns its **own** prepared-statement cache and its own
///   internal lock, so pooled readers can never alias the writer's (or each
///   other's) `sqlite3_stmt` handles.
/// - WAL gives every read a consistent snapshot concurrent with any writer
///   (the app's write store or `wikictl`). Connections are reused across
///   reads; SQLite starts a fresh read transaction per query, so a reused
///   connection always sees the latest committed state.
///
/// Connections open lazily on first use — constructing a pool is free and
/// never throws. A read against a missing/unopenable database throws from
/// `read(_:)` itself.
public final class WikiReadPool: @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private var idle: [SQLiteWikiStore] = []
    private let maxIdle: Int

    public init(databaseURL: URL, maxIdle: Int = 3) {
        self.databaseURL = databaseURL
        self.maxIdle = max(1, maxIdle)
    }

    /// Run `body` against a read-only store on the CALLING thread. The store
    /// must not escape the closure (it is returned to the pool afterwards).
    public func read<T>(_ body: (SQLiteWikiStore) throws -> T) throws -> T {
        let store = try checkout()
        defer { checkin(store) }
        return try body(store)
    }

    /// Run `body` against a read-only store OFF the calling thread/actor —
    /// the off-main entry point for UI-triggered reads (search, lookups).
    public func asyncRead<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable (SQLiteWikiStore) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority) { [self] in
            try read(body)
        }.value
    }

    /// Number of idle pooled connections. Test hook.
    var idleCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return idle.count
    }

    private func checkout() throws -> SQLiteWikiStore {
        lock.lock()
        let cached = idle.popLast()
        lock.unlock()
        if let cached { return cached }
        return try SQLiteWikiStore(readOnlyURL: databaseURL)
    }

    private func checkin(_ store: SQLiteWikiStore) {
        lock.lock(); defer { lock.unlock() }
        if idle.count < maxIdle {
            idle.append(store)
        }
        // Overflow connections drop here; SQLiteWikiStore.deinit closes them.
    }
}
