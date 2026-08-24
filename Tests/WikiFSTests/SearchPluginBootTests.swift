#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Search plugin boot", .serialized, .timeLimit(.minutes(1)))
struct SearchPluginBootTests {
    @Test("fixture-safe providers register and unload")
    func providersRegisterAndUnload() async throws {
        let embeddings = EmbeddingsSearchProvider(
            configure: {},
            selectedIdentifier: { "fixture-embedding" },
            isAvailable: { false })
        let process = try await CordisBoot.boot(.init(
            catalog: try ProcessPluginCatalog.build(factories: ProcessPluginCatalogFactories(
                compositionInputs: ProfileBootFixture.fixtureProcessInputs(),
                makeEmbeddings: { ProcessRuntimeLease(service: embeddings) {} })),
            layers: [PatchFile(entries: [
                Entry(id: EntryID("embeddings"), plugin: ProcessRuntimePlugins.embeddingsID),
            ])]))
        let entries = [
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                SearchPlugin.definition,
                TantivySearchPlugin.definition(),
                EmbeddingsSearchPlugin.definition,
            ]),
            layers: [PatchFile(entries: entries)],
            parent: process.context))

        let registry = try #require(try await booted.context.find(SearchServiceKeys.providers))
        #expect(await registry.keys() == [
            EmbeddingsSearchPlugin.key,
            TantivySearchPlugin.key,
        ].sorted { $0.description < $1.description })

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("tantivy") })
        #expect(await registry.resolve(TantivySearchPlugin.key) == nil)
        let registered = try #require(await registry.resolve(EmbeddingsSearchPlugin.key))
        guard case .embeddings(let resolved) = registered.adapter else {
            Issue.record("expected embedding search adapter")
            try await booted.shutdown()
            try await process.shutdown()
            return
        }
        #expect(resolved.selectedIdentifier() == "fixture-embedding")

        try await booted.shutdown()
        try await process.shutdown()
    }
}
#endif
