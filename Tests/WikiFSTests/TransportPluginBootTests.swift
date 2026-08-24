#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Transport plugin boot", .serialized, .timeLimit(.minutes(1)))
struct TransportPluginBootTests {
    @Test("fixture-safe daemon transport provider registers and unloads")
    func providerRegistersAndUnloads() async throws {
        let calls = TransportFactoryCallCounter()
        let entries = [
            Entry(id: EntryID("transport"), plugin: TransportPlugin.id),
            Entry(id: EntryID("daemon-transport"), plugin: DaemonTransportPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                TransportPlugin.definition,
                DaemonTransportPlugin.definition {
                    await calls.record()
                    return fixtureServices()
                },
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(try await booted.context.find(TransportServiceKeys.transport))
        #expect(await registry.providerIDs() == [DaemonTransportPlugin.providerID])
        #expect(await calls.value == 0)

        let provider = try #require(await registry.resolve(DaemonTransportPlugin.providerID))
        _ = try await provider.services()
        #expect(await calls.value == 1)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("daemon-transport") })
        #expect(await registry.resolve(DaemonTransportPlugin.providerID) == nil)

        try await booted.shutdown()
    }
}

private actor TransportFactoryCallCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}

private func fixtureServices() -> DaemonTransportServices {
    DaemonTransportServices(
        startAdmission: {},
        acknowledge: { _ in },
        requestManualReconnect: {},
        events: { AsyncStream { $0.finish() } },
        availability: { .idle },
        stop: {})
}
#endif
