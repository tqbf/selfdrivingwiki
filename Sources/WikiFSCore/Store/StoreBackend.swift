import Foundation

/// Selects which concrete ``WikiStore`` implementation is constructed throughout
/// the app and the test suite.
///
/// Tests construct the store directly (`SomeStore(databaseURL:)`) and via the
/// `makeStore` closures injected at the `WikiSession` / `WikiDaemon` /
/// `WikiRegistryClient` seams. Routing all of those through
/// ``current`` lets the entire suite run against `GRDBWikiStore` instead of
/// `SQLiteWikiStore` by setting:
///
/// ```sh
/// export WIKIFS_STORE_BACKEND=grdb
/// ```
///
/// The default (unset / any other value) keeps the battle-tested
/// `SQLiteWikiStore`, so production behaviour is unchanged unless explicitly
/// opted in. This is the affordance used by the GRDB-parity test harness (#545,
/// #550, #557): it exercises the 2,400+ test suite against `GRDBWikiStore` to
/// verify identical behaviour before any rollout.
public enum StoreBackend: String, Sendable {
    case sqlite
    case grdb

    /// The backend selected for this process. Reads `WIKIFS_STORE_BACKEND` once;
    /// any value other than `"grdb"` resolves to `.sqlite`.
    public static var current: StoreBackend {
        ProcessInfo.processInfo.environment["WIKIFS_STORE_BACKEND"] == "grdb" ? .grdb : .sqlite
    }

    /// Construct a read/write store at `databaseURL`, mirroring
    /// `SQLiteWikiStore.init(databaseURL:)` / `GRDBWikiStore.init(databaseURL:)`.
    public func makeStore(databaseURL: URL) throws -> any WikiStore {
        switch self {
        case .sqlite:
            return try SQLiteWikiStore(databaseURL: databaseURL)
        case .grdb:
            return try GRDBWikiStore(databaseURL: databaseURL)
        }
    }

    /// Construct a read-only store at `readOnlyURL`, mirroring
    /// `SQLiteWikiStore.init(readOnlyURL:)` / `GRDBWikiStore.init(readOnlyURL:)`.
    public func makeReadOnlyStore(readOnlyURL: URL) throws -> any WikiStore {
        switch self {
        case .sqlite:
            return try SQLiteWikiStore(readOnlyURL: readOnlyURL)
        case .grdb:
            return try GRDBWikiStore(readOnlyURL: readOnlyURL)
        }
    }
}
