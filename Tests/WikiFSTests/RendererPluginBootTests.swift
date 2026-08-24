#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Renderer plugin boot", .serialized, .timeLimit(.minutes(1)))
struct RendererPluginBootTests {
    @Test("fixture-safe renderer provider registers and unloads")
    func providerRegistersAndUnloads() async throws {
        let services = UnavailableRendererServices()
        let process = try await CordisBoot.boot(.init(
            catalog: try ProcessPluginCatalog.build(factories: ProcessPluginCatalogFactories(
                compositionInputs: ProfileBootFixture.fixtureProcessInputs(rendererAssembly: {
                    ProcessRuntimeLease<any RendererServices>(service: services) {}
                }),
                makeEmbeddings: {
                    ProcessRuntimeLease(service: .unavailable(identifier: "unavailable-fixture"), dispose: {})
                })),
            layers: [PatchFile(entries: [
                Entry(id: EntryID("inputs"), plugin: ProcessRuntimePlugins.inputsID),
                Entry(id: EntryID("renderer"), plugin: ProcessRuntimePlugins.rendererID),
            ])]))
        let entries = [
            Entry(id: EntryID("renderers"), plugin: RenderersPlugin.id),
            Entry(id: EntryID("renderer-services"), plugin: RendererServicesPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                RenderersPlugin.definition,
                RendererServicesPlugin.definition,
            ]),
            layers: [PatchFile(entries: entries)],
            parent: process.context))

        let registry = try #require(try await booted.context.find(RendererServiceKeys.renderers))
        #expect(await registry.providerIDs() == [RendererServicesPlugin.providerID])

        let provider = try #require(await registry.resolve(RendererServicesPlugin.providerID))
        #expect(provider.services is UnavailableRendererServices)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("renderer-services") })
        #expect(await registry.resolve(RendererServicesPlugin.providerID) == nil)

        try await booted.shutdown()
        try await process.shutdown()
    }
}
#endif
