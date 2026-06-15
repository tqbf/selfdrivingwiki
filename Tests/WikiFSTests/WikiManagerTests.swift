import Foundation
import Testing
@testable import WikiFSCore

/// `WikiManager` tests (Phase 0): per-wiki DB isolation at the store layer,
/// create/select/delete, MRU launch pick, and the v0→registry migration. The
/// manager opens DBs under an injected container directory, so these run
/// hermetically against a temp dir with no App Group access.
@MainActor
struct WikiManagerTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Fresh install seeds one wiki

    @Test func bootstrapOnEmptyContainerSeedsOneWiki() {
        let manager = WikiManager(containerDirectory: tempDirectory())
        manager.bootstrap()
        #expect(manager.wikis.count == 1)
        #expect(manager.activeWikiID != nil)
        #expect(manager.activeStore != nil)
        // Seeded with a Home page so the mount is non-empty.
        #expect(manager.activeStore?.summaries.contains { $0.title == "Home" } == true)
    }

    // MARK: - Per-wiki DB isolation (the gate's core claim)

    @Test func pagesInOneWikiNeverAppearInAnother() async {
        let manager = WikiManager(containerDirectory: tempDirectory())
        manager.bootstrap()
        let first = manager.activeWikiID!

        // Write a uniquely-titled page into wiki A.
        manager.activeStore?.newPage(title: "Only-In-A")
        manager.activeStore?.flushPendingSaves()

        // Create wiki B and switch to it.
        let b = await manager.createWiki(displayName: "Wiki B")
        #expect(manager.activeWikiID == b.id)
        #expect(b.id != first)

        // B has its own DB: it must NOT contain A's page.
        let bTitles = manager.activeStore?.summaries.map(\.title) ?? []
        #expect(!bTitles.contains("Only-In-A"))

        // Switch back to A: its page is still there, independent of B.
        manager.select(first)
        let aTitles = manager.activeStore?.summaries.map(\.title) ?? []
        #expect(aTitles.contains("Only-In-A"))
    }

    @Test func eachWikiIsADistinctFileOnDisk() async {
        let dir = tempDirectory()
        let manager = WikiManager(containerDirectory: dir)
        manager.bootstrap()
        let a = manager.activeWikiID!
        let b = await manager.createWiki(displayName: "B")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(a).sqlite").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(b.id).sqlite").path))
        #expect(a != b.id)
    }

    // MARK: - Delete removes the registry entry + the DB file

    @Test func deleteRemovesWikiAndItsDatabaseFile() async {
        let dir = tempDirectory()
        let manager = WikiManager(containerDirectory: dir)
        manager.bootstrap()
        _ = manager.activeWikiID!
        let b = await manager.createWiki(displayName: "B")
        let bPath = dir.appendingPathComponent("\(b.id).sqlite").path
        #expect(FileManager.default.fileExists(atPath: bPath))

        await manager.deleteWiki(id: b.id)
        #expect(!manager.wikis.contains { $0.id == b.id })
        #expect(!FileManager.default.fileExists(atPath: bPath))
        // Deleting the active wiki falls back to the remaining one.
        #expect(manager.activeWikiID != nil)
        #expect(manager.activeWikiID != b.id)
    }

    // MARK: - Select bumps MRU and persists across reload

    @Test func selectBumpsMostRecentlyUsedAndPicksItOnRelaunch() async {
        let dir = tempDirectory()
        let manager = WikiManager(containerDirectory: dir)
        manager.bootstrap()
        let a = manager.activeWikiID!
        let b = await manager.createWiki(displayName: "B")   // B now active + MRU

        // Re-select A: it becomes most-recently-used.
        manager.select(a)
        #expect(manager.activeWikiID == a)

        // A fresh manager over the same dir picks the MRU wiki (A) on launch.
        let relaunched = WikiManager(containerDirectory: dir)
        relaunched.bootstrap()
        #expect(relaunched.activeWikiID == a)
        #expect(relaunched.wikis.count == 2)
        _ = b
    }

    // MARK: - Rename keeps the DB stable (identity = ULID)

    @Test func renameDoesNotMoveTheDatabaseFile() async {
        let dir = tempDirectory()
        let manager = WikiManager(containerDirectory: dir)
        manager.bootstrap()
        let id = manager.activeWikiID!
        let path = dir.appendingPathComponent("\(id).sqlite").path
        #expect(FileManager.default.fileExists(atPath: path))

        manager.renameWiki(id: id, to: "Renamed")
        // Same file, same id — only the label changed.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(manager.activeWikiID == id)
        #expect(manager.wikis.first { $0.id == id }?.displayName == "Renamed")
    }

    // MARK: - v0 migration: legacy WikiFS.sqlite becomes wiki #1, content intact

    @Test func migratesLegacyV0WikiAsWikiOnePreservingContent() throws {
        let dir = tempDirectory()

        // Stand up a legacy single-wiki DB with a sentinel page, exactly where v0
        // left it (the literal `WikiFS.sqlite` in the container directory).
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        do {
            let store = try SQLiteWikiStore(databaseURL: legacy)
            let page = try store.createPage(title: "Legacy Home")
            try store.updatePage(id: page.id, title: "Legacy Home", body: "VERIFY-V0-CONTENT")
        }
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        // Bootstrapping the manager migrates it into the registry as wiki #1.
        let manager = WikiManager(containerDirectory: dir)
        manager.bootstrap()

        #expect(manager.wikis.count == 1)
        let descriptor = manager.wikis[0]
        #expect(descriptor.displayName == "WikiFS")

        // The legacy file was renamed to <ulid>.sqlite; the old name is gone.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(descriptor.id).sqlite").path))

        // Content preserved: the sentinel page rode along into the migrated wiki.
        let titles = manager.activeStore?.summaries.map(\.title) ?? []
        #expect(titles.contains("Legacy Home"))
        if let id = manager.activeStore?.summaries.first(where: { $0.title == "Legacy Home" })?.id {
            manager.activeStore?.select(.page(id))
            #expect(manager.activeStore?.draftBody == "VERIFY-V0-CONTENT")
        }
    }

    @Test func migrationDoesNotRerunOnSecondLaunch() throws {
        let dir = tempDirectory()
        let legacy = dir.appendingPathComponent(DatabaseLocation.legacyDatabaseFileName)
        _ = try SQLiteWikiStore(databaseURL: legacy)

        let first = WikiManager(containerDirectory: dir)
        first.bootstrap()
        #expect(first.wikis.count == 1)

        // A second launch (legacy file already migrated away) must not duplicate.
        let second = WikiManager(containerDirectory: dir)
        second.bootstrap()
        #expect(second.wikis.count == 1)
    }
}
