#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSEngine

@Suite("App profile boot", .serialized, .timeLimit(.minutes(1)))
struct AppProfileBootTests {
    @Test("production-shaped app profile activates services and owns store listener")
    func appProfileActivatesServicesAndOwnsStoreListener() async throws {
        let directory = try ProfileBootFixture.directory(named: "app-profile")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove app profile fixture: \(error)")
            }
        }
        let recorder = ProfileStoreEventRecorder()
        var entries = ProfileBootFixture.entries(
            databaseURL: directory.appendingPathComponent("wiki.sqlite"),
            wikiID: "app-profile-test",
            includeAppProviders: true)
        entries.append(Entry(
            id: ProfileBootFixture.listenerEntryID,
            plugin: ProfileBootFixture.listenerPluginID))
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.catalog(recorder: recorder),
            layers: [PatchFile(entries: entries)]))
        #expect(await booted.tree.mountedEntryIDs.count == entries.count)
        try await ProfileBootFixture.assertRequiredServices(in: booted.context)
        let store = try #require(try await booted.context.find(StoreServiceKeys.store))
        let page = try store.createPage(title: "Committed app profile page")

        for _ in 0..<100 where await recorder.events.isEmpty {
            await MainActor.run { }
            await Task.yield()
        }
        let event = try #require(await recorder.events.first)
        #expect(event.id == page.id.rawValue)
        #expect(await recorder.observedCommittedState)

        entries.removeAll { $0.id == ProfileBootFixture.listenerEntryID }
        try await booted.tree.update(to: entries)
        let countAfterDisposal = await recorder.events.count
        try store.updatePage(
            id: page.id,
            title: page.title,
            body: "after listener disposal",
            lastEditedBy: nil,
            provenance: [])
        for _ in 0..<10 {
            await MainActor.run { }
            await Task.yield()
        }
        #expect(await recorder.events.count == countAfterDisposal)

        try await booted.shutdown()
    }
}
#endif
