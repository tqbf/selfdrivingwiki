#if os(macOS)
import CordisLoader
import Foundation
import Testing
@testable import WikiFSEngine

@Suite("Cordis boot integration", .serialized, .timeLimit(.minutes(1)))
struct CordisBootIntegrationTests {
    @Test("changing only the store configuration row swaps active service identity")
    func storeConfigurationRowSwapsActiveServiceIdentity() async throws {
        let directory = try ProfileBootFixture.directory(named: "config-swap")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove config-swap fixture: \(error)")
            }
        }
        let firstEntries = ProfileBootFixture.entries(
            databaseURL: directory.appendingPathComponent("first.sqlite"),
            wikiID: "config-swap-test",
            includeAppProviders: false)
        var secondEntries = firstEntries
        secondEntries[0] = Entry(
            id: EntryID("store"),
            plugin: StorePlugin.id,
            config: [
                "databasePath": .string(directory.appendingPathComponent("second.sqlite").path),
                "wikiID": .string("config-swap-test"),
            ])

        let first = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: firstEntries)]))
        let second = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: secondEntries)]))
        let firstStore = try #require(try await first.context.find(StoreServiceKeys.store))
        let secondStore = try #require(try await second.context.find(StoreServiceKeys.store))

        #expect(ObjectIdentifier(firstStore as AnyObject) != ObjectIdentifier(secondStore as AnyObject))
        let page = try firstStore.createPage(title: "First profile only")
        #expect(try firstStore.listPages(sortBy: .lastUpdated).map(\.id).contains(page.id))
        #expect(!((try secondStore.listPages(sortBy: .lastUpdated)).map(\.id).contains(page.id)))

        try await second.shutdown()
        try await first.shutdown()
    }
}
#endif
