#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Search plugin boot", .serialized, .timeLimit(.minutes(1)))
struct SearchPluginBootTests {
    @Test("fixture-safe providers register and unload")
    func providersRegisterAndUnload() async throws {
        let entries = [
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                SearchPlugin.definition,
                TantivySearchPlugin.definition(),
                EmbeddingsSearchPlugin.definition(
                    configure: {},
                    selectedIdentifier: { "fixture-embedding" },
                    isAvailable: { false }),
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(try await booted.context.find(SearchServiceKeys.providers))
        #expect(await registry.keys() == [
            EmbeddingsSearchPlugin.key,
            TantivySearchPlugin.key,
        ].sorted { $0.description < $1.description })

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("tantivy") })
        #expect(await registry.resolve(TantivySearchPlugin.key) == nil)
        #expect(await registry.resolve(EmbeddingsSearchPlugin.key) != nil)

        try await booted.shutdown()
    }
}
#endif
