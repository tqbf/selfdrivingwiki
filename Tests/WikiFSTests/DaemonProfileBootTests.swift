#if os(macOS)
import CordisLoader
import Foundation
import Testing
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
        let processEntries = ProfileBootFixture.processEntries(includeAppServices: false)
        let process = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.processCatalog(includeAppServices: false, recorder: processDisposals),
            layers: [PatchFile(entries: processEntries)]))
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: entries)],
            parent: process.context))

        #expect(await booted.tree.mountedEntryIDs.count == entries.count)
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
}
#endif
