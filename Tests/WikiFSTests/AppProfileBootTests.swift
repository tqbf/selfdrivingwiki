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
        let processDisposals = ProfileProcessDisposalRecorder()
        let processEntries = ProfileBootFixture.processEntries(includeAppServices: true)
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: processDisposals),
            layers: [PatchFile(entries: processEntries)]))
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.appCatalog(recorder: recorder),
            layers: [PatchFile(entries: entries)],
            parent: process.context))
        #expect(await booted.tree.mountedEntryIDs.count == entries.count)
        try await ProfileBootFixture.assertRequiredServices(in: booted.context)
        _ = try #require(try await booted.context.find(ProcessServiceKeys.agentProvider))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.extraction))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.queue))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.transport))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.renderer))
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
        #expect(await processDisposals.count == 0)
        try await process.shutdown()
        #expect(await processDisposals.count == 3)
    }
}
#endif
