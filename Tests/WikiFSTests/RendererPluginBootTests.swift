#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Renderer plugin boot", .serialized, .timeLimit(.minutes(1)))
struct RendererPluginBootTests {
    @Test("fixture-safe renderer provider registers and unloads")
    func providerRegistersAndUnloads() async throws {
        let calls = FactoryCallCounter()
        let entries = [
            Entry(id: EntryID("renderers"), plugin: RenderersPlugin.id),
            Entry(id: EntryID("renderer-services"), plugin: RendererServicesPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                RenderersPlugin.definition,
                RendererServicesPlugin.definition {
                    await calls.record()
                    return FixtureRendererServices()
                },
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(try await booted.context.find(RendererServiceKeys.renderers))
        #expect(await registry.providerIDs() == [RendererServicesPlugin.providerID])
        #expect(await calls.value == 0)

        let provider = try #require(await registry.resolve(RendererServicesPlugin.providerID))
        let value = try await provider.value()
        #expect(value is FixtureRendererServices)
        #expect(await calls.value == 1)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("renderer-services") })
        #expect(await registry.resolve(RendererServicesPlugin.providerID) == nil)

        try await booted.shutdown()
    }
}

private struct FixtureRendererServices: Sendable {}

private actor FactoryCallCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}
#endif
