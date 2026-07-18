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
/// The default is `GRDBWikiStore` — the GRDB migration is complete (all 88
/// methods implemented #545/#550, 37-version migration ladder #557, 2,480
/// parity tests pass #561). Set `WIKIFS_STORE_BACKEND=sqlite` to opt back in
/// to the legacy `SQLiteWikiStore` (deprecated, will be removed in a future
/// version). This escape hatch preserves the old behaviour for anyone who
/// needs it during the deprecation period.
public enum StoreBackend: String, Sendable {
    case sqlite
    case grdb

    /// The backend selected for this process. Reads `WIKIFS_STORE_BACKEND` once;
    /// `"sqlite"` resolves to `.sqlite`, any other value (including unset)
    /// resolves to `.grdb`.
    public static var current: StoreBackend {
        ProcessInfo.processInfo.environment["WIKIFS_STORE_BACKEND"] == "sqlite" ? .sqlite : .grdb
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
