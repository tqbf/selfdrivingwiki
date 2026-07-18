import Foundation
import Testing
@testable import WikiFSCore

/// `WikiRegistryClient` tests (the registry portion of the dissolved
/// `WikiManager`): per-wiki DB isolation at the registry layer, create/select/
/// delete, MRU launch pick, export/import, and the v0→registry migration. The
/// client opens DBs under an injected container directory, so these run
/// hermetically against a temp dir with no App Group access.
///
/// The per-wiki *session* lifecycle (store opening, launchers, vacuum) is
/// covered by `WikiSessionTests`. The registry client itself never opens a
/// store except for seeding/import validation.
@MainActor
struct WikiRegistryClientTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Fresh install seeds one wiki

    @Test func bootstrapOnEmptyContainerSeedsOneWiki() {
        let registry = WikiRegistryClient(containerDirectory: tempDirectory())
        registry.bootstrap()
        #expect(registry.wikis.count == 1)
        #expect(registry.activeWikiID != nil)
    }

    // MARK: - Deferred activation (launch reentrancy sequencing)

    /// Guards the macOS-26 launch sequencing: `App.init()` calls
    /// `bootstrap(activateNow: false)` so the first SwiftUI render populates
    /// `wikis` WITHOUT setting `activeWikiID` — keeping the initial NSTableView
    /// `reloadData` free of a concurrent selection change (a reentrant-delegate
    /// warning).
    @Test func deferredBootstrapPopulatesWikisButActivatesNothing() {
        let registry = WikiRegistryClient(containerDirectory: tempDirectory())
        registry.bootstrap(activateNow: false)
        #expect(registry.wikis.count == 1)
        #expect(registry.activeWikiID == nil)
    }

    /// `activateMostRecent()` (called from the root `.task`, after the first
    /// render) is what selects the wiki.
    @Test func activateMostRecentSelectsWikiAfterDeferredBootstrap() {
        let registry = WikiRegistryClient(containerDirectory: tempDirectory())
        registry.bootstrap(activateNow: false)
        #expect(registry.activeWikiID == nil)
        registry.activateMostRecent()
        #expect(registry.activeWikiID != nil)
    }

    // MARK: - Per-wiki DB isolation (the gate's core claim)

    @Test func pagesInOneWikiNeverAppearInAnother() async throws {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let first = registry.activeWikiID!

        // Write a uniquely-titled page into wiki A via the store directly.
        let storeA = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(first).sqlite"))
        let pageA = try storeA.createPage(title: "Only-In-A")
        try storeA.updatePage(id: pageA.id, title: "Only-In-A", body: "A")

        // Create wiki B.
        let b = await registry.createWiki(displayName: "Wiki B")
        #expect(registry.activeWikiID == b.id)
        #expect(b.id != first)

        // B has its own DB: it must NOT contain A's page.
        let storeB = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(b.id).sqlite"))
        let bTitles = (try storeB.listPages(sortBy: .lastUpdated)).map(\.title)
        #expect(!bTitles.contains("Only-In-A"))

        // Switch back to A: its page is still there, independent of B.
        registry.select(first)
        let aTitles = (try storeA.listPages(sortBy: .lastUpdated)).map(\.title)
        #expect(aTitles.contains("Only-In-A"))
    }

    @Test func eachWikiIsADistinctFileOnDisk() async {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let a = registry.activeWikiID!
        let b = await registry.createWiki(displayName: "B")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(a).sqlite").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(b.id).sqlite").path))
        #expect(a != b.id)
    }

    // MARK: - Delete removes the registry entry + the DB file

    @Test func deleteRemovesWikiAndItsDatabaseFile() async {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        _ = registry.activeWikiID!
        let b = await registry.createWiki(displayName: "B")
        let bPath = dir.appendingPathComponent("\(b.id).sqlite").path
        #expect(FileManager.default.fileExists(atPath: bPath))

        await registry.deleteWiki(id: b.id)
        #expect(!registry.wikis.contains { $0.id == b.id })
        #expect(!FileManager.default.fileExists(atPath: bPath))
        // Deleting the active wiki falls back to the remaining one.
        #expect(registry.activeWikiID != nil)
        #expect(registry.activeWikiID != b.id)
    }

    // MARK: - Select bumps MRU and persists across reload

    @Test func selectBumpsMostRecentlyUsedAndPicksItOnRelaunch() async {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let a = registry.activeWikiID!
        _ = await registry.createWiki(displayName: "B")   // B now active + MRU

        // Re-select A: it becomes most-recently-used.
        registry.select(a)
        #expect(registry.activeWikiID == a)

        // A fresh registry over the same dir picks the MRU wiki (A) on launch.
        let relaunched = WikiRegistryClient(containerDirectory: dir)
        relaunched.bootstrap()
        #expect(relaunched.activeWikiID == a)
        #expect(relaunched.wikis.count == 2)
    }

    // MARK: - Rename keeps the DB stable (identity = ULID)

    @Test func renameDoesNotMoveTheDatabaseFile() async {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let id = registry.activeWikiID!
        let path = dir.appendingPathComponent("\(id).sqlite").path
        #expect(FileManager.default.fileExists(atPath: path))

        await registry.renameWiki(id: id, to: "Renamed")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(registry.activeWikiID == id)
        #expect(registry.wikis.first { $0.id == id }?.displayName == "Renamed")
    }

    @Test func renameRefreshesTheFileProviderDomainName() async throws {
        let registry = WikiRegistryClient(containerDirectory: tempDirectory())
        registry.bootstrap()
        let id = try #require(registry.activeWikiID)
        var renamedDomain: (id: String, displayName: String)?
        registry.renameDomain = { id, displayName in
            renamedDomain = (id, displayName)
        }

        await registry.renameWiki(id: id, to: "Readable Name")

        #expect(renamedDomain?.id == id)
        #expect(renamedDomain?.displayName == "Readable Name")
    }

    // MARK: - Backup / restore

    @Test func exportWritesAPortableSQLiteFileWithCurrentContent() throws {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let id = try #require(registry.activeWikiID)

        // Write a page via the store directly.
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(id).sqlite"))
        let page = try store.createPage(title: "Exported Page")
        try store.updatePage(id: page.id, title: "Exported Page", body: "backup body")

        let backupURL = dir.appendingPathComponent("backup.sqlite")
        try registry.exportWiki(id: id, to: backupURL)

        let restoredStore = try GRDBWikiStore(databaseURL: backupURL)
        let resolvedPageID = try restoredStore.resolveTitleToID("Exported Page")
        let pageID = try #require(resolvedPageID)
        let restoredPage = try restoredStore.getPage(id: pageID)
        #expect(restoredPage.bodyMarkdown == "backup body")
    }

    @Test func exportRefusesToOverwriteTheSourceDatabase() throws {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let id = try #require(registry.activeWikiID)
        let sourceURL = dir.appendingPathComponent("\(id).sqlite")

        #expect(throws: WikiRegistryError.exportWouldOverwriteSource) {
            try registry.exportWiki(id: id, to: sourceURL)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func importCopiesSQLiteFileAsANewNamedWiki() async throws {
        let dir = tempDirectory()
        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()
        let originalID = try #require(registry.activeWikiID)

        // Write a page via the store directly.
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(originalID).sqlite"))
        let page = try store.createPage(title: "Restored Page")
        try store.updatePage(id: page.id, title: "Restored Page", body: "restored body")

        let backupURL = dir.appendingPathComponent("restore-source.sqlite")
        try registry.exportWiki(id: originalID, to: backupURL)

        let imported = try await registry.importWiki(from: backupURL, displayName: "Restored Wiki")

        #expect(imported.id != originalID)
        #expect(imported.displayName == "Restored Wiki")
        #expect(registry.activeWikiID == imported.id)
        #expect(registry.wikis.first?.id == imported.id)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(imported.id).sqlite").path))

        // Verify the imported page is present.
        let restoredStore = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(imported.id).sqlite"))
        let titles = (try? restoredStore.listPages(sortBy: .lastUpdated))?.map(\.title) ?? []
        #expect(titles.contains("Restored Page"))
        let pageID = try restoredStore.resolveTitleToID("Restored Page")
        let restoredPage = try restoredStore.getPage(id: pageID ?? PageID(rawValue: ""))
        #expect(restoredPage.bodyMarkdown == "restored body")
    }

    // MARK: - v0 migration: legacy WikiFS.sqlite becomes wiki #1, content intact

    @Test func migratesLegacyV0WikiAsWikiOnePreservingContent() throws {
        let dir = tempDirectory()

        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        do {
            let store = try GRDBWikiStore(databaseURL: legacy)
            let page = try store.createPage(title: "Legacy Home")
            try store.updatePage(id: page.id, title: "Legacy Home", body: "VERIFY-V0-CONTENT")
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        let registry = WikiRegistryClient(containerDirectory: dir)
        registry.bootstrap()

        #expect(registry.wikis.count == 1)
        let descriptor = registry.wikis[0]
        #expect(descriptor.displayName == "Self Driving Wiki")

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(descriptor.id).sqlite").path))

        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("\(descriptor.id).sqlite"))
        let titles = (try? store.listPages(sortBy: .lastUpdated))?.map(\.title) ?? []
        #expect(titles.contains("Legacy Home"))
        let pageID = try store.resolveTitleToID("Legacy Home")
        let legacyPage = try store.getPage(id: pageID ?? PageID(rawValue: ""))
        #expect(legacyPage.bodyMarkdown == "VERIFY-V0-CONTENT")
    }

    @Test func migrationDoesNotRerunOnSecondLaunch() throws {
        let dir = tempDirectory()
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        _ = try GRDBWikiStore(databaseURL: legacy)

        let first = WikiRegistryClient(containerDirectory: dir)
        first.bootstrap()
        #expect(first.wikis.count == 1)

        let second = WikiRegistryClient(containerDirectory: dir)
        second.bootstrap()
        #expect(second.wikis.count == 1)
    }

    @Test func legacyFileReappearingAfterFirstLaunchDoesNotDuplicate() throws {
        let dir = tempDirectory()
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)

        _ = try GRDBWikiStore(databaseURL: legacy)
        let first = WikiRegistryClient(containerDirectory: dir)
        first.bootstrap()
        #expect(first.wikis.count == 1)
        let migratedID = first.activeWikiID
        #expect(migratedID != nil)

        // Simulate the Application Support layer re-copying the legacy file back.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        _ = try GRDBWikiStore(databaseURL: legacy)
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        let second = WikiRegistryClient(containerDirectory: dir)
        second.bootstrap()
        #expect(second.wikis.count == 1)
        #expect(second.activeWikiID == migratedID)

        _ = try GRDBWikiStore(databaseURL: legacy)
        let third = WikiRegistryClient(containerDirectory: dir)
        third.bootstrap()
        #expect(third.wikis.count == 1)
        #expect(third.activeWikiID == migratedID)
    }

    @Test func strayLegacyFileWithNonEmptyRegistryCreatesNoWiki() throws {
        let dir = tempDirectory()

        let manager = WikiRegistryClient(containerDirectory: dir)
        manager.bootstrap()
        #expect(manager.wikis.count == 1)
        let existingID = manager.activeWikiID

        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        _ = try GRDBWikiStore(databaseURL: legacy)

        let relaunched = WikiRegistryClient(containerDirectory: dir)
        relaunched.bootstrap()
        #expect(relaunched.wikis.count == 1)
        #expect(relaunched.activeWikiID == existingID)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
