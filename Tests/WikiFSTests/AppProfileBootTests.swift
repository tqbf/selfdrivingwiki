#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("App profile boot", .serialized, .timeLimit(.minutes(1)))
struct AppProfileBootTests {
    @Test("process owner exposes readiness, services, and shutdown")
    @MainActor
    func processOwnerReadinessAndShutdown() async throws {
        let disposals = ProfileProcessDisposalRecorder()
        let gate = ProfileBootGate()
        let owner = AppProcessProfileOwner {
            await gate.wait()
            return try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: disposals),
                layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        }

        #expect(owner.readiness == .idle)
        owner.start()
        #expect(owner.readiness == .loading)
        await gate.open()
        await owner.awaitSettled()
        #expect(owner.readiness == .ready)
        #expect(owner.profile != nil)
        #expect(owner.services != nil)

        await owner.shutdown()
        #expect(owner.profile == nil)
        #expect(owner.services == nil)
        #expect(await disposals.count == 3)
        await owner.shutdown()
        #expect(await disposals.count == 3)
    }

    @Test("process owner reports boot failure")
    @MainActor
    func processOwnerReportsFailure() async {
        let owner = AppProcessProfileOwner {
            throw ProfileBootFailure.expected
        }
        owner.start()
        await owner.awaitSettled()
        guard case .failed(let message) = owner.readiness else {
            Issue.record("expected failed readiness")
            return
        }
        #expect(message.contains("expected"))
    }

    @Test("per-wiki facade boots from child and process profile services")
    @MainActor
    func profileWikiSessionCoversSessionSurface() async throws {
        let directory = try ProfileBootFixture.directory(named: "profile-wiki-session")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove profile wiki session fixture: \(error)")
            }
        }
        let disposals = ProfileProcessDisposalRecorder()
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: disposals),
            layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        let processServices = try await AppProcessServices.resolve(from: process)
        let wikiID = WikiID(rawValue: "profile-wiki-session")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let descriptor = WikiDescriptor(
            id: wikiID,
            displayName: "Profile Wiki",
            createdAt: timestamp,
            lastUsedAt: timestamp)
        let facade = try await ProfileWikiSession.boot(
            wikiID: wikiID,
            descriptor: descriptor,
            containerDirectory: directory,
            catalog: try ProfileBootFixture.appCatalog(),
            processProfile: process,
            processServices: processServices,
            extractionProvider: ProfileBootFixture.extractionProvider())

        #expect(facade.wikiID == wikiID)
        #expect(facade.descriptor.displayName == "Profile Wiki")
        #expect(facade.store.readPool != nil)
        #expect(facade.descriptor.homePageID != nil)
        let renamed = WikiDescriptor(
            id: wikiID,
            displayName: "Renamed Profile Wiki",
            createdAt: timestamp,
            lastUsedAt: timestamp)
        facade.updateDescriptor(renamed)
        #expect(facade.descriptor.displayName == "Renamed Profile Wiki")
        let link = try #require(URL(string: "wiki://profile-wiki-session/Home"))
        facade.pendingWikiLink = (link, true)
        #expect(facade.pendingWikiLink?.url == link)
        #expect(facade.pendingWikiLink?.openInNewTab == true)
        facade.previewBlobVacuum()
        #expect(facade.pendingBlobVacuum != nil)
        facade.applyBlobVacuum()
        #expect(facade.pendingBlobVacuum == nil)

        await facade.shutdown()
        #expect(await disposals.count == 0)
        try await process.shutdown()
        #expect(await disposals.count == 3)
    }

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
