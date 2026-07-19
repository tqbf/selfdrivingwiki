import Foundation
@testable import WikiFSCore

/// Shared factory for test `GRDBWikiStore` instances. All DB-backed test
/// suites should use this instead of copy-pasting temp-dir helpers.
///
/// **Default: in-memory** (`:memory:` via `DatabaseQueue`) — eliminates disk
/// I/O for the ~15 mutating suites that don't need file persistence (issue
/// #651). Tests that reopen a DB file (persistence-across-restart, File
/// Provider `Projection`) call `.fileBacked()` instead.
///
/// Tests that only need a single store instance for their lifetime (no
/// reopen) should call `.inMemory()` — each call returns a fresh, fully
/// migrated empty DB backed by a single serialized `DatabaseQueue`
/// connection (production uses `DatabasePool` against a file, but the
/// `DatabaseWriter` API is identical and the store does not call any
/// `DatabasePool`-only method). Suites tagged `.integration` stay tagged
/// even after switching to in-memory — the full schema + migration ladder
/// still runs (just in RAM instead of on disk), so they remain real
/// integration tests, not pure unit tests.
enum TestStoreFactory {

    /// A fresh in-memory store. Each call returns an independent empty DB
    /// (no inter-test bleed). Fast (no disk I/O — issue #651 target).
    /// Use for all mutating suites that don't reopen the DB file.
    static func inMemory() throws -> GRDBWikiStore {
        try GRDBWikiStore()
    }

    /// A fresh file-backed store at a temp path. Use for tests that
    /// reopen the same DB file (persistence-across-restart, File Provider
    /// `Projection`). Returns the store AND the URL (for reopening /
    /// `Projection` injection). Each call creates a new uniquely-named
    /// directory under `temporaryDirectory` so concurrent tests never
    /// collide on the same file.
    static func fileBacked(
        prefix: String = "sdw-test"
    ) throws -> (store: GRDBWikiStore, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("WikiFS.sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
    }
}
