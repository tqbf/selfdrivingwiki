import Foundation

/// Constructs the concrete ``WikiStore`` implementation used throughout the
/// app and the test suite.
///
/// Tests construct the store directly and via the `makeStore` closures injected
/// at the `WikiSession` / `WikiDaemon` / `WikiRegistryClient` seams. Routing
/// all of those through ``current`` ensures the entire suite runs against the
/// same backend.
///
/// `GRDBWikiStore` is the sole production backend — the hand-rolled
/// `SQLiteWikiStore` / `SQLiteStatement` / `WikiReadPool` raw-SQLite plumbing
/// has been removed. The 88-method `WikiStore` protocol is unchanged; the
/// change-token contributors, `WikiEventBus`, and the `mutate()` emission seam
/// all live on `GRDBWikiStore` now.
public struct StoreBootstrapResult: Sendable, Equatable {
    public let homePageID: PageID?

    public init(homePageID: PageID?) {
        self.homePageID = homePageID
    }
}

public struct StoreBootstrap: Sendable {
    public typealias StoreFactory = @Sendable (URL) throws -> any WikiStore

    private let makeStore: StoreFactory

    public init(
        makeStore: @escaping StoreFactory = { try StoreBackend.current.makeStore(databaseURL: $0) }
    ) {
        self.makeStore = makeStore
    }

    public func createAndSeed(databaseURL: URL) throws -> StoreBootstrapResult {
        let store = try makeStore(databaseURL)
        let pages = try store.listPages(sortBy: .newestFirst)
        guard pages.isEmpty else {
            return StoreBootstrapResult(homePageID: nil)
        }
        let home = try store.createPage(
            title: "Home",
            createdBy: PageAuthor.user.rawValue)
        return StoreBootstrapResult(homePageID: home.id)
    }
}

public enum StoreBackend: Sendable {
    /// The backend selected for this process. Always `.grdb`.
    public static var current: StoreBackend { .grdb }

    case grdb

    /// Construct a read/write store at `databaseURL`.
    public func makeStore(databaseURL: URL) throws -> any WikiStore {
        try GRDBWikiStore(databaseURL: databaseURL)
    }

    /// Construct a read-only store at `readOnlyURL`.
    public func makeReadOnlyStore(readOnlyURL: URL) throws -> any WikiStore {
        try GRDBWikiStore(readOnlyURL: readOnlyURL)
    }
}
