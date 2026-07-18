import Foundation

/// A pool of **read-only** snapshot connections over one wiki database, for
/// reads that should not run on the main-actor write store (debounced search,
/// bulk existence checks, future projection-style reads).
///
/// GRDB's `DatabaseQueue` (used by `GRDBWikiStore`) serializes all reads/writes
/// through one dispatch queue. A single store instance therefore cannot run a
/// concurrent off-main read alongside a main-actor write — this pool holds
/// several read-only stores so debounced search never contends with the UI.
///
/// - Each pooled store is opened via `GRDBWikiStore(readOnlyURL:)` —
///   `PRAGMA query_only=ON`, no migrations — so a pool member can never write
///   or author schema.
/// - Each pooled store owns its own `DatabaseQueue`, so pooled readers can
///   never alias the writer's connection.
/// - WAL gives every read a consistent snapshot concurrent with any writer.
///
/// Connections open lazily on first use — constructing a pool is free and
/// never throws. A read against a missing/unopenable database throws from
/// `read(_:)` itself.
public final class WikiReadPool: @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private var idle: [GRDBWikiStore] = []
    private let maxIdle: Int

    public init(databaseURL: URL, maxIdle: Int = 3) {
        self.databaseURL = databaseURL
        self.maxIdle = max(1, maxIdle)
    }

    /// Run `body` against a read-only store on the CALLING thread. The store
    /// must not escape the closure (it is returned to the pool afterwards).
    public func read<T>(_ body: (GRDBWikiStore) throws -> T) throws -> T {
        let store = try checkout()
        defer { checkin(store) }
        return try body(store)
    }

    /// Run `body` against a read-only store OFF the calling thread/actor —
    /// the off-main entry point for UI-triggered reads (search, lookups).
    public func asyncRead<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable (GRDBWikiStore) throws -> T
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

    private func checkout() throws -> GRDBWikiStore {
        lock.lock()
        let cached = idle.popLast()
        lock.unlock()
        if let cached { return cached }
        return try GRDBWikiStore(readOnlyURL: databaseURL)
    }

    private func checkin(_ store: GRDBWikiStore) {
        lock.lock(); defer { lock.unlock() }
        if idle.count < maxIdle {
            idle.append(store)
        }
    }
}
