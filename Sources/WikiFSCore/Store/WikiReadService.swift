import Foundation

public enum WikiReadServiceError: Error, Equatable, Sendable {
    case unavailable
}

/// A borrowed view of one read-only wiki connection.
///
/// The facade is noncopyable and deliberately non-Sendable. It is valid only
/// during one `WikiReadService.asyncRead` operation. It exposes value reads and
/// never exposes the store, a database connection, a statement, or transaction
/// state.
public struct WikiReadAccess: ~Copyable {
    private let store: GRDBWikiStore

    fileprivate init(store: GRDBWikiStore) {
        self.store = store
    }

    public func searchSimilar(
        query: String,
        limit: Int,
        bm25Leg: [WikiPageSummary]?
    ) throws -> [WikiPageSummary] {
        try store.searchSimilar(query: query, limit: limit, bm25Leg: bm25Leg)
    }

    public func searchSimilarSources(
        query: String,
        limit: Int,
        bm25Leg: [SourceSummary]?
    ) throws -> [SourceSummary] {
        try store.searchSimilarSources(query: query, limit: limit, bm25Leg: bm25Leg)
    }

    public func getPage(id: PageID) throws -> WikiPage {
        try store.getPage(id: id)
    }

    public func listSources() throws -> [SourceSummary] {
        try store.listSources()
    }

    public func pageHeadSources(pageID: PageID) throws -> [PageVersionSource] {
        try store.pageHeadSources(pageID: pageID)
    }

    public func pageVersionHistory(pageID: PageID) throws -> [PageVersionSummary] {
        try store.pageVersionHistory(pageID: pageID)
    }

    public func pageHeadVersionID(pageID: PageID) throws -> PageVersionID? {
        try store.pageHeadVersionID(pageID: pageID)
    }

    public func pageOrigin(pageID: PageID) throws -> PageOrigin? {
        try store.pageOrigin(pageID: pageID)
    }

    public func getChat(id: ChatID) throws -> ChatSummary {
        try store.getChat(id: id)
    }

    public func chatUsageSummary(chatID: ChatID) throws -> ChatUsageSummary {
        try store.chatUsageSummary(chatID: chatID)
    }

    public func processedMarkdownHistory(sourceID: SourceID) throws -> [SourceMarkdownVersion] {
        try store.processedMarkdownHistory(sourceID: sourceID)
    }

    public func processedMarkdownHead(sourceID: SourceID) throws -> SourceMarkdownVersion? {
        try store.processedMarkdownHead(sourceID: sourceID)
    }

    public func activeExtractionProvenance(sourceID: SourceID) throws -> ExtractionProvenance? {
        try store.activeExtractionProvenance(sourceID: sourceID)
    }

    public func getSource(id: SourceID) throws -> SourceSummary {
        try store.getSource(id: id)
    }

    public func sourceContent(id: SourceID) throws -> Data {
        try store.sourceContent(id: id)
    }
}

/// A lifecycle-aware read capability for one wiki database.
///
/// The service owns its private pool of read-only stores. Shutdown rejects new
/// reads, waits for admitted reads, closes idle stores, and is idempotent.
public actor WikiReadService {
    public enum State: Equatable, Sendable {
        case active
        case shuttingDown
        case stopped
    }

    private let pool: WikiReadPool
    private var state: State = .active
    private var activeReadCount = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(databaseURL: URL, maxIdle: Int = 3) {
        pool = WikiReadPool(databaseURL: databaseURL, maxIdle: maxIdle)
    }

    public func asyncRead<Result: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable (borrowing WikiReadAccess) throws -> Result
    ) async throws -> Result {
        guard state == .active else { throw WikiReadServiceError.unavailable }
        activeReadCount += 1
        do {
            let result = try await pool.asyncRead(priority: priority, operation)
            readFinished()
            return result
        } catch {
            readFinished()
            throw error
        }
    }

    public func shutdown() async {
        switch state {
        case .stopped:
            return
        case .shuttingDown:
            await withCheckedContinuation { shutdownWaiters.append($0) }
        case .active:
            state = .shuttingDown
            if activeReadCount == 0 {
                finishShutdown()
            } else {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
        }
    }

    public func lifecycleStateForTesting() -> State {
        state
    }

    func idleConnectionCountForTesting() -> Int {
        pool.idleCountForTesting
    }

    private func readFinished() {
        precondition(activeReadCount > 0)
        activeReadCount -= 1
        if state == .shuttingDown, activeReadCount == 0 {
            finishShutdown()
        }
    }

    private func finishShutdown() {
        pool.shutdown()
        state = .stopped
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Private read-only connection pool owned by `WikiReadService`.
///
/// Each store opens with `GRDBWikiStore(readOnlyURL:)`, which enables
/// `query_only`, performs no migrations, and owns separate GRDB connections.
/// The lock protects `idle` and `stopped`. The URL and idle limit are immutable.
// swiftlint:disable:next unchecked_sendable
private final class WikiReadPool: @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private var idle: [GRDBWikiStore] = []
    private let maxIdle: Int
    private var stopped = false

    init(databaseURL: URL, maxIdle: Int) {
        self.databaseURL = databaseURL
        self.maxIdle = max(1, maxIdle)
    }

    func asyncRead<Result: Sendable>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable (borrowing WikiReadAccess) throws -> Result
    ) async throws -> Result {
        try await Task.detached(priority: priority) { [self] in
            let store = try checkout()
            defer { checkin(store) }
            let access = WikiReadAccess(store: store)
            return try operation(access)
        }.value
    }

    var idleCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return idle.count
    }

    func shutdown() {
        lock.lock()
        stopped = true
        let stores = idle
        idle.removeAll()
        lock.unlock()
        for store in stores { store.close() }
    }

    private func checkout() throws -> GRDBWikiStore {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            throw WikiReadServiceError.unavailable
        }
        let cached = idle.popLast()
        lock.unlock()
        if let cached { return cached }
        return try GRDBWikiStore(readOnlyURL: databaseURL)
    }

    private func checkin(_ store: GRDBWikiStore) {
        lock.lock()
        if !stopped, idle.count < maxIdle {
            idle.append(store)
            lock.unlock()
        } else {
            lock.unlock()
            store.close()
        }
    }
}
