import Foundation
import Testing
@testable import WikiFSCore

/// `ZoteroConfig` load/save round-trip and defaulting — mirrors
/// `WikiRegistryTests`'s temp-directory pattern.
struct ZoteroConfigTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let dir = tempDirectory()
        var config = ZoteroConfig()
        config.libraryID = "7089244"
        config.zoteroDirOverride = "/Volumes/External/Zotero"
        try config.save(to: dir)

        let loaded = ZoteroConfig.load(from: dir)
        #expect(loaded == config)
    }

    @Test func missingFileLoadsEmptyAndUnconfigured() {
        let config = ZoteroConfig.load(from: tempDirectory())
        #expect(config.libraryID == nil)
        #expect(!config.isConfigured)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent(ZoteroConfig.fileName, isDirectory: false)
        try Data("not json".utf8).write(to: url)
        let config = ZoteroConfig.load(from: dir)
        #expect(!config.isConfigured)
    }

    @Test func isConfiguredRequiresNonEmptyLibraryID() {
        #expect(!ZoteroConfig(libraryID: nil).isConfigured)
        #expect(!ZoteroConfig(libraryID: "   ").isConfigured)
        #expect(ZoteroConfig(libraryID: "7089244").isConfigured)
    }

    @Test func zoteroDirectoryFallsBackToDefaultWhenNoOverride() {
        let config = ZoteroConfig(libraryID: "1")
        #expect(config.zoteroDirectory() == ZoteroLocalStorage.defaultDirectory())
    }

    @Test func zoteroDirectoryUsesOverrideWhenSet() {
        let config = ZoteroConfig(libraryID: "1", zoteroDirOverride: "/Volumes/External/Zotero")
        #expect(config.zoteroDirectory().path == "/Volumes/External/Zotero")
    }
}
