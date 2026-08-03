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
