#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
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

        let processDisposals = ProfileProcessDisposalRecorder()
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(
                includeAppServices: false,
                recorder: processDisposals),
            layers: [PatchFile(entries: ProfileBootFixture.processEntries(includeAppServices: false))],
            descriptor: .process(.daemon)))
        let first = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: firstEntries)],
            parent: process.context,
            descriptor: .wiki(WikiID(rawValue: "config-swap-test"))))
        let second = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: secondEntries)],
            parent: process.context,
            descriptor: .wiki(WikiID(rawValue: "config-swap-test"))))
        let firstStore: any WikiStore = try #require(
            try await first.context.find(StoreServiceKeys.store))
        let secondStore: any WikiStore = try #require(
            try await second.context.find(StoreServiceKeys.store))

        let processScope = try await process.context.scopeDiagnostics()
        let firstScope = try await first.context.scopeDiagnostics()
        let secondScope = try await second.context.scopeDiagnostics()
        #expect(processScope.descriptor == .process(.daemon))
        #expect(firstScope.parentContextID == process.context.id)
        #expect(firstScope.parentDescriptor == .process(.daemon))
        #expect(firstScope.descriptor == .wiki(WikiID(rawValue: "config-swap-test")))
        #expect(firstScope.contextID != secondScope.contextID)

        #expect(ObjectIdentifier(firstStore as AnyObject) != ObjectIdentifier(secondStore as AnyObject))
        let page = try firstStore.createPage(title: "First profile only")
        #expect(try firstStore.listPages(sortBy: .lastUpdated).map { $0.id }.contains(page.id))
        #expect(!(try secondStore.listPages(sortBy: .lastUpdated).map { $0.id }.contains(page.id)))

        try await second.shutdown()
        try await first.shutdown()
        let disposedFirst = try await first.context.scopeDiagnostics()
        #expect(disposedFirst.lifecycle == ScopeLifecycleState.disposed)
        #expect(disposedFirst.activeRegistrationCount == 0)
        #expect((try await process.context.scopeDiagnostics()).activeChildCount == 0)
        try await process.shutdown()
    }
}
#endif
