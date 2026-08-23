#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Store plugin boot", .serialized, .timeLimit(.minutes(1)))
struct StorePluginBootTests {
    private actor EventRecorder {
        private(set) var events: [ResourceChangeEvent] = []

        func append(_ event: ResourceChangeEvent) {
            events.append(event)
        }
    }

    @Test("boot supplies the store and bridges changes until listener disposal")
    func bootSuppliesStoreAndBridgesChangesUntilDisposal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove store plugin fixture: \(error)")
            }
        }
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let wikiID = WikiID(rawValue: "store-plugin-test")
        let layer = PatchFile(entries: [
            Entry(
                id: EntryID("store"),
                plugin: StorePlugin.id,
                config: [
                    "databasePath": .string(databaseURL.path),
                    "wikiID": .string(wikiID.rawValue),
                ])
        ])
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([StorePlugin.definition]),
            layers: [layer]))

        let service = try #require(try await booted.context.find(StoreServiceKeys.store))
        let recorder = EventRecorder()
        let listener = try await booted.context.on(StoreEventKeys.resourceChange) { event in
            await recorder.append(event)
        }

        let page = try service.createPage(title: "Cordis store bridge")
        for _ in 0..<100 where await recorder.events.isEmpty {
            await MainActor.run { }
            await Task.yield()
        }
        let event = try #require(await recorder.events.first)
        #expect(event.wikiID == wikiID)
        #expect(event.kind == .page)
        #expect(event.id == page.id.rawValue)
        #expect(event.change == .created)

        try await listener.dispose()
        let countAfterDisposal = await recorder.events.count
        try service.updatePage(id: page.id, title: page.title, body: "after disposal")
        for _ in 0..<10 {
            await MainActor.run { }
            await Task.yield()
        }
        #expect(await recorder.events.count == countAfterDisposal)

        try await booted.shutdown()
    }
}
#endif
