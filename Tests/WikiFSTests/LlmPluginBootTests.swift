#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("LLM plugin boot", .serialized, .timeLimit(.minutes(1)))
struct LlmPluginBootTests {
    @Test("adapter entry replacement swaps the active route")
    func adapterEntryReplacementSwapsActiveRoute() async throws {
        let route = LlmRoute("agent-provider")
        let runtimeEntry = Entry(
            id: EntryID("llm-runtime"),
            plugin: LlmRuntimePlugin.id)
        let firstAdapter = Entry(
            id: EntryID("acp-adapter"),
            plugin: ACPModelAdapterPlugin.id,
            config: [
                "route": .string(route.rawValue),
                "adapterID": .string("fixture-a"),
            ])
        let services = UnavailableAgentProviderServices()
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                LlmRuntimePlugin.definition,
                ACPModelAdapterPlugin.definition(services: services),
            ]),
            layers: [PatchFile(entries: [runtimeEntry, firstAdapter])]))

        let runtime = try #require(try await booted.context.find(LlmServiceKeys.llm))
        #expect(await runtime.resolve(route)?.id == LlmAdapterID("fixture-a"))

        let replacementAdapter = Entry(
            id: firstAdapter.id,
            plugin: ACPModelAdapterPlugin.id,
            config: [
                "route": .string(route.rawValue),
                "adapterID": .string("fixture-b"),
            ])
        try await booted.tree.update(to: [runtimeEntry, replacementAdapter])
        #expect(await runtime.resolve(route)?.id == LlmAdapterID("fixture-b"))

        try await booted.tree.update(to: [runtimeEntry])
        #expect(await runtime.resolve(route) == nil)

        try await booted.shutdown()
    }
}
#endif
