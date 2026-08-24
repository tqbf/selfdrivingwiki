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
        let committedRows = try ProfileBootFixture.processEntries(includeAppServices: true)
        #expect(Set(committedRows.map(\.plugin)) == Set([
            ProcessRuntimePlugins.inputsID,
            ProcessRuntimePlugins.agentProviderID,
            ProcessRuntimePlugins.extractionID,
            ProcessRuntimePlugins.queueID,
            ProcessRuntimePlugins.transportID,
            ProcessRuntimePlugins.rendererID,
            ProcessRuntimePlugins.embeddingsID,
            ProcessRuntimePlugins.urlFetchProviderID,
            ProcessRuntimePlugins.zoteroClientProviderID,
        ]))
        let owner = AppProcessProfileOwner {
            await gate.wait()
            return try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: disposals),
                layers: [PatchFile(entries: committedRows)]))
        }

        #expect(owner.readiness == .idle)
        owner.start()
        #expect(owner.readiness == .loading)
        await gate.open()
        await owner.awaitSettled()
        #expect(owner.readiness == .ready)
        #expect(owner.services != nil)

        await owner.shutdown()
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

    @Test("process owner shuts down a booted profile when service resolution fails")
    @MainActor
    func processOwnerCleansUpResolutionFailure() async throws {
        let disposals = ProfileProcessDisposalRecorder()
        let owner = AppProcessProfileOwner {
            try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(
                    includeAppServices: false,
                    recorder: disposals),
                layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))]))
        }

        owner.start()
        await owner.awaitSettled()

        guard case .failed = owner.readiness else {
            Issue.record("expected missing app process services to fail resolution")
            return
        }
        #expect(owner.services == nil)
        #expect(await disposals.count == 0)
        await owner.shutdown()
        #expect(await disposals.count == 0)
    }

    @Test("per-wiki facade boots from child and process profile services")
    @MainActor
    func profileProfileWikiSessionCoversSessionSurface() async throws {
        let directory = try ProfileBootFixture.directory(named: "profile-wiki-session")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove profile wiki session fixture: \(error)")
            }
        }
        let disposals = ProfileProcessDisposalRecorder()
        let owner = AppProcessProfileOwner {
            try await CordisBoot.boot(.init(
                catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: disposals),
                layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: true))]))
        }
        owner.start()
        let wikiID = WikiID(rawValue: "profile-wiki-session")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let descriptor = WikiDescriptor(
            id: wikiID,
            displayName: "Profile Wiki",
            createdAt: timestamp,
            lastUsedAt: timestamp)
        let facade = try await owner.bootWikiSession(
            wikiID: wikiID,
            descriptor: descriptor,
            containerDirectory: directory,
            catalog: try ProfileBootFixture.appCatalog(),
            extractionProvider: ProfileBootFixture.extractionProvider())

        #expect(facade.wikiID == wikiID)
        #expect(facade.descriptor.displayName == "Profile Wiki")
        #expect(facade.store.readService != nil)
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
        await owner.shutdown()
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
        let processEntries = try ProfileBootFixture.processEntries(includeAppServices: true)
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(includeAppServices: true, recorder: processDisposals),
            layers: [PatchFile(entries: processEntries)]))
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.appCatalog(recorder: recorder),
            layers: [PatchFile(entries: entries)],
            parent: process.context))
        #expect(await booted.tree.mountedEntryIDs.count == entries.filter { !$0.disabled }.count)
        try await ProfileBootFixture.assertRequiredServices(in: booted.context)
        _ = try #require(try await booted.context.find(ProcessServiceKeys.agentProvider))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.extraction))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.queue))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.transport))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.renderer))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.urlFetchProvider))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.zoteroClientProvider))
        #expect(ProcessServiceKeys.urlFetchProvider.label == "process.integration.url-fetch-provider")
        #expect(ProcessServiceKeys.zoteroClientProvider.label == "process.integration.zotero-client-provider")
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

    @Test("editing copied app YAML changes the running renderer registry")
    func copiedYAMLIsAuthoritative() async throws {
        let bundles = try ProfileBootFixture.copiedProductionBundles(named: "yaml-authority")
        let root = bundles.deletingLastPathComponent()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("could not remove YAML authority fixture: \(error)") }
        }
        let selectedIDs = Set([EntryID("renderers"), EntryID("renderer-services")])
        let process = try await CordisBoot.boot(.init(
            catalog: try ProcessPluginCatalog.build(factories: ProcessPluginCatalogFactories(
                compositionInputs: ProfileBootFixture.fixtureProcessInputs(rendererAssembly: {
                    ProcessRuntimeLease<any RendererServices>(service: UnavailableRendererServices()) {}
                }),
                makeEmbeddings: {
                    ProcessRuntimeLease(service: .unavailable(identifier: "unavailable-fixture"), dispose: {})
                })),
            layers: [PatchFile(entries: [
                Entry(id: EntryID("inputs"), plugin: ProcessRuntimePlugins.inputsID),
                Entry(id: EntryID("renderer"), plugin: ProcessRuntimePlugins.rendererID),
            ])]))
        let catalog = try PluginCatalog([
            RenderersPlugin.definition,
            RendererServicesPlugin.definition,
        ])
        let baselineRows = try ProductionProfiles.resolve(
            kind: .app, scope: .wiki, bundlesDirectory: bundles).entries
            .filter { selectedIDs.contains($0.id) }
        let baseline = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: [PatchFile(entries: baselineRows)],
            parent: process.context))
        let baselineRegistry = try await baseline.context.require(RendererServiceKeys.renderers)
        #expect(await baselineRegistry.providerIDs() == [RendererServicesPlugin.providerID])
        try await baseline.shutdown()

        try ProfileBootFixture.setDisabled(
            true, entryID: EntryID("renderer-services"), profile: "wikifs-app", in: bundles)
        let changedRows = try ProductionProfiles.resolve(
            kind: .app, scope: .wiki, bundlesDirectory: bundles).entries
            .filter { selectedIDs.contains($0.id) }
        let changed = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: [PatchFile(entries: changedRows)],
            parent: process.context))
        let changedRegistry = try await changed.context.require(RendererServiceKeys.renderers)
        #expect(await changedRegistry.providerIDs().isEmpty)
        try await changed.shutdown()
        try await process.shutdown()
    }
}
#endif
