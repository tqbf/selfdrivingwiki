#if os(macOS)
import CordisLoader
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("Daemon profile boot", .serialized, .timeLimit(.minutes(1)))
struct DaemonProfileBootTests {
    @Test("production-shaped headless profile activates registry services")
    func daemonProfileActivatesRegistryServices() async throws {
        let directory = try ProfileBootFixture.directory(named: "daemon-profile")
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove daemon profile fixture: \(error)")
            }
        }
        let entries = ProfileBootFixture.entries(
            databaseURL: directory.appendingPathComponent("wiki.sqlite"),
            wikiID: "daemon-profile-test",
            includeAppProviders: false)
        let processDisposals = ProfileProcessDisposalRecorder()
        let processEntries = try ProfileBootFixture.processEntries(includeAppServices: false)
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(includeAppServices: false, recorder: processDisposals),
            layers: [PatchFile(entries: processEntries)]))
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: entries)],
            parent: process.context))

        #expect(await booted.tree.mountedEntryIDs.count == entries.filter { !$0.disabled }.count)
        try await ProfileBootFixture.assertRequiredServices(in: booted.context)
        _ = try #require(try await booted.context.find(ProcessServiceKeys.agentProvider))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.extraction))
        let renderers = try #require(try await booted.context.find(RendererServiceKeys.renderers))
        let transport = try #require(try await booted.context.find(TransportServiceKeys.transport))
        #expect(await renderers.providerIDs().isEmpty)
        #expect(await transport.providerIDs().isEmpty)
        _ = try ProfileBootFixture.cliCatalog()

        try await booted.shutdown()
        #expect(await processDisposals.count == 0)
        try await process.shutdown()
        #expect(await processDisposals.count == 2)
    }

    @Test("daemon owner retains process and one child per wiki, then shuts down once")
    func daemonOwnerCachesProfilesAndDisposesIdempotently() async throws {
        let directory = try ProfileBootFixture.directory(named: "daemon-owner")
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("could not remove daemon owner fixture: \(error)") }
        }
        let wikiID = WikiID(rawValue: "daemon-owner-wiki")
        let processDisposals = ProfileProcessDisposalRecorder()
        let processCatalog = try ProfileBootFixture.processCatalog(
            includeAppServices: false,
            recorder: processDisposals)
        let daemonCatalog = try ProfileBootFixture.daemonCatalog()
        let owner = DaemonProcessProfileOwner(
            boot: {
                try await CordisBoot.boot(.init(
                    catalog: processCatalog,
                    layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))]))
            },
            bootWiki: { requestedWikiID, process in
                let entries = ProfileBootFixture.entries(
                    databaseURL: directory.appendingPathComponent("\(requestedWikiID.rawValue).sqlite"),
                    wikiID: requestedWikiID.rawValue,
                    includeAppProviders: false)
                return try await CordisBoot.boot(.init(
                    catalog: daemonCatalog,
                    layers: [PatchFile(entries: entries)],
                    parent: process.context))
            })

        _ = try await owner.start()
        _ = try await owner.services()
        let firstWiki = try await owner.wiki(wikiID: wikiID)
        let secondWiki = try await owner.wiki(wikiID: wikiID)
        #expect(ObjectIdentifier(firstWiki.store as AnyObject) == ObjectIdentifier(secondWiki.store as AnyObject))

        await owner.shutdown()
        await owner.shutdown()
        #expect(await processDisposals.count == 2)
    }

    @Test("removing then reopening a wiki creates a fresh live store and bus")
    func daemonOwnerRemoveThenReopenCreatesFreshStore() async throws {
        let directory = try ProfileBootFixture.directory(named: "daemon-reopen")
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("could not remove daemon reopen fixture: \(error)") }
        }
        let wikiID = WikiID(rawValue: "daemon-reopen-wiki")
        let processDisposals = ProfileProcessDisposalRecorder()
        let processCatalog = try ProfileBootFixture.processCatalog(
            includeAppServices: false,
            recorder: processDisposals)
        let daemonCatalog = try ProfileBootFixture.daemonCatalog()
        let owner = DaemonProcessProfileOwner(
            boot: {
                try await CordisBoot.boot(.init(
                    catalog: processCatalog,
                    layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))]))
            },
            bootWiki: { requestedWikiID, process in
                try await CordisBoot.boot(.init(
                    catalog: daemonCatalog,
                    layers: [PatchFile(entries: ProfileBootFixture.entries(
                        databaseURL: directory.appendingPathComponent("\(requestedWikiID.rawValue).sqlite"),
                        wikiID: requestedWikiID.rawValue,
                        includeAppProviders: false))],
                    parent: process.context))
            })

        let first = try await owner.wiki(wikiID: wikiID)
        let firstStore = ObjectIdentifier(first.store as AnyObject)
        let firstBus = ObjectIdentifier(try #require(first.store.eventBus))
        await owner.removeWiki(wikiID)
        let second = try await owner.wiki(wikiID: wikiID)

        #expect(ObjectIdentifier(second.store as AnyObject) != firstStore)
        #expect(ObjectIdentifier(try #require(second.store.eventBus)) != firstBus)
        _ = try second.store.listPages(sortBy: PageSortOrder.newestFirst)
        await owner.shutdown()
    }
}
#endif
