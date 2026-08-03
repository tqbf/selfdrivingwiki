import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Integration coverage for the v49 GRDB-owned repository metadata boundary.
@MainActor
struct TrackedRepoStoreTests {
    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracked-repo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    @Test func repositoryMetadataPersistsAndTracksWatermarks() throws {
        let store = try TestStoreFactory.inMemory()
        let repository = try store.addRepo(
            name: "example/project",
            remoteURL: "https://github.com/example/project.git",
            branch: nil)

        let added = try #require(try store.listRepos().first)
        #expect(added.id == repository.id)
        #expect(added.remoteURL == "https://github.com/example/project.git")
        try store.setRepoBranch(id: repository.id, branch: "main")
        try store.updateRepoSync(id: repository.id, headCommit: "abc123", fetchedAt: Date(timeIntervalSince1970: 42))
        try store.markRepoIngested(id: repository.id, commit: "abc123")

        let persisted = try store.getRepo(id: repository.id)
        #expect(persisted.branch == "main")
        #expect(persisted.headCommit == "abc123")
        #expect(persisted.lastIngestedCommit == "abc123")
        #expect(persisted.lastFetchedAt == Date(timeIntervalSince1970: 42))
        #expect(!persisted.isDrifted)
    }

    @Test func v48UpgradeCreatesTrackedRepositoriesTable() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initial = try GRDBWikiStore(databaseURL: databaseURL)
        initial.close()

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "DROP TABLE tracked_repos;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 48;", nil, nil, nil) == SQLITE_OK)

        let migrated = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(migrated.pragmaValue("user_version") == "49")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'tracked_repos';") == "1")
        #expect(try migrated.listRepos().isEmpty)
    }

    @Test func modelProjectsNewRepositoryImmediately() throws {
        let model = WikiStoreModel(store: try TestStoreFactory.inMemory())

        let repository = try #require(model.addTrackedRepository(
            remoteInput: "https://github.com/example/project.git"))

        #expect(model.trackedRepositories.map(\.id) == [repository.id])
    }
}
