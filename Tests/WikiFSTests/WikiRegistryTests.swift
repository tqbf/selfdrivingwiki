import Foundation
import Testing
@testable import WikiFSCore

/// Registry tests (Phase 0): JSON round-trip, MRU ordering, and the
/// rename-doesn't-change-identity invariant — `dbFileName`/`domainIdentifier`
/// derive from the ULID, so a rename must NOT move the DB or the mount.
struct WikiRegistryTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round-trip

    @Test func savesAndLoadsRoundTrip() throws {
        let dir = tempDirectory()
        var registry = WikiRegistry()
        let a = WikiDescriptor.make(displayName: "Alpha")
        let b = WikiDescriptor.make(displayName: "Beta")
        registry.add(a)
        registry.add(b)
        try registry.save(to: dir)

        let loaded = WikiRegistry.load(from: dir)
        #expect(loaded.wikis.count == 2)
        // `add` inserts at the front, so Beta (added last) is first.
        #expect(loaded.wikis.first?.displayName == "Beta")
        #expect(loaded.descriptor(id: a.id)?.displayName == "Alpha")
    }

    @Test func missingFileLoadsEmpty() {
        let registry = WikiRegistry.load(from: tempDirectory())
        #expect(registry.isEmpty)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let dir = tempDirectory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent(WikiRegistry.fileName))
        let registry = WikiRegistry.load(from: dir)
        #expect(registry.isEmpty)
    }

    // MARK: - MRU ordering

    @Test func touchMovesToFrontAsMostRecentlyUsed() {
        var registry = WikiRegistry()
        let a = WikiDescriptor.make(displayName: "A")
        let b = WikiDescriptor.make(displayName: "B")
        registry.add(a)       // [A]
        registry.add(b)       // [B, A]
        #expect(registry.mostRecentlyUsed?.id == b.id)

        registry.touch(id: a.id)  // [A, B]
        #expect(registry.mostRecentlyUsed?.id == a.id)
    }

    // MARK: - Rename keeps identity stable (the doc's open-risk)

    @Test func renameChangesOnlyDisplayNameNotIdentity() {
        var registry = WikiRegistry()
        let wiki = WikiDescriptor.make(displayName: "Old Name")
        registry.add(wiki)
        let originalDBFile = wiki.dbFileName
        let originalDomain = wiki.domainIdentifier

        registry.rename(id: wiki.id, to: "New Name")
        let renamed = registry.descriptor(id: wiki.id)
        #expect(renamed?.displayName == "New Name")
        #expect(renamed?.id == wiki.id)                       // ULID unchanged
        #expect(renamed?.dbFileName == originalDBFile)        // DB file unchanged
        #expect(renamed?.domainIdentifier == originalDomain)  // domain unchanged
    }

    @Test func dbFileNameAndDomainDeriveFromULIDNeverDisplayName() {
        let wiki = WikiDescriptor.make(displayName: "Has Spaces & Symbols!")
        #expect(wiki.dbFileName == "\(wiki.id).sqlite")
        #expect(wiki.domainIdentifier == wiki.id)
        // Display name characters never leak into the on-disk identity.
        #expect(!wiki.dbFileName.contains(" "))
        #expect(!wiki.dbFileName.contains("!"))
    }

    @Test func removeDropsEntry() {
        var registry = WikiRegistry()
        let wiki = WikiDescriptor.make(displayName: "Doomed")
        registry.add(wiki)
        registry.remove(id: wiki.id)
        #expect(registry.isEmpty)
        #expect(registry.descriptor(id: wiki.id) == nil)
    }

    // MARK: - Home page (issue #280)

    @Test func setHomePageStoresAndClears() {
        var registry = WikiRegistry()
        let wiki = WikiDescriptor.make(displayName: "Home Test")
        registry.add(wiki)
        #expect(registry.descriptor(id: wiki.id)?.homePageID == nil)

        let pageID = PageID(rawValue: "page-1")
        registry.setHomePage(id: wiki.id, pageID: pageID)
        #expect(registry.descriptor(id: wiki.id)?.homePageID == pageID)

        registry.setHomePage(id: wiki.id, pageID: nil)
        #expect(registry.descriptor(id: wiki.id)?.homePageID == nil)
    }

    @Test func setHomePageNoOpForUnknownID() {
        var registry = WikiRegistry()
        registry.setHomePage(id: "unknown", pageID: PageID(rawValue: "page-1"))
        #expect(registry.isEmpty)
    }

    @Test func decodesLegacyRegistryMissingHomePageIDAsNil() throws {
        let dir = tempDirectory()
        let legacyJSON = """
        {"wikis":[{"id":"01ABC","displayName":"Legacy","createdAt":"2024-01-01T00:00:00Z","lastUsedAt":"2024-01-01T00:00:00Z"}]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent(WikiRegistry.fileName))
        let loaded = WikiRegistry.load(from: dir)
        #expect(loaded.descriptor(id: "01ABC")?.homePageID == nil)
    }

    @Test func homePageSurvivesRoundTrip() throws {
        let dir = tempDirectory()
        var registry = WikiRegistry()
        let wiki = WikiDescriptor.make(displayName: "Persisted")
        registry.add(wiki)
        registry.setHomePage(id: wiki.id, pageID: PageID(rawValue: "page-1"))
        try registry.save(to: dir)

        let loaded = WikiRegistry.load(from: dir)
        #expect(loaded.descriptor(id: wiki.id)?.homePageID == PageID(rawValue: "page-1"))
    }
}
