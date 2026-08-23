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
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProfileBootFixture.daemonCatalog(),
            layers: [PatchFile(entries: entries)]))

        #expect(await booted.tree.mountedEntryIDs.count == entries.count)
        try await ProfileBootFixture.assertRequiredServices(in: booted.context)
        let renderers = try #require(try await booted.context.find(RendererServiceKeys.renderers))
        let transport = try #require(try await booted.context.find(TransportServiceKeys.transport))
        #expect(await renderers.providerIDs().isEmpty)
        #expect(await transport.providerIDs().isEmpty)
        _ = try ProfileBootFixture.cliCatalog()

        try await booted.shutdown()
    }
}
#endif
