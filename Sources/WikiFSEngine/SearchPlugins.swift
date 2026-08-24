import Cordis
import WikiFSSearch

public enum SearchPlugin {
    public static let id = PluginID("wiki.search")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki search providers",
        provisions: [ServiceDependency(SearchServiceKeys.providers)]
    ) {
        try ComponentDefinition(
            label: "wiki.search",
            provisions: [ServiceDependency(SearchServiceKeys.providers)]
        ) { activation in
            _ = try await activation.supply(
                SearchServiceKeys.providers,
                value: SearchProviderRegistry())
        }
    }
}

#if os(macOS)
public enum TantivySearchPlugin {
    public static let id = PluginID("wiki.search.tantivy")
    public static let key = SearchProviderKey(kind: .lexical, providerID: "tantivy")

    public static func definition(
        makeRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.runtimeFactory
    ) -> PluginDefinition {
        adapterDefinition(
            id: id,
            label: "Tantivy lexical search",
            provider: RegisteredSearchProvider(
                key: key,
                adapter: .tantivy(TantivySearchProvider(makeRuntime: makeRuntime))))
    }
}
#endif

public enum EmbeddingsSearchPlugin {
    public static let id = PluginID("wiki.search.embeddings")
    public static let key = SearchProviderKey(kind: .embeddings, providerID: "embedding-service")

    public static func definition(
        configure: @escaping EmbeddingsSearchProvider.Configure = { await EmbeddingService.configure() },
        selectedIdentifier: @escaping EmbeddingsSearchProvider.SelectedIdentifier = {
            EmbeddingService.selectedEmbedderIdentifier()
        },
        isAvailable: @escaping EmbeddingsSearchProvider.Availability = {
            EmbeddingService.isAvailable
        }
    ) -> PluginDefinition {
        adapterDefinition(
            id: id,
            label: "Embedding semantic search",
            provider: RegisteredSearchProvider(
                key: key,
                adapter: .embeddings(EmbeddingsSearchProvider(
                    configure: configure,
                    selectedIdentifier: selectedIdentifier,
                    isAvailable: isAvailable))))
    }
}

private func adapterDefinition(
    id: PluginID,
    label: String,
    provider: RegisteredSearchProvider
) -> PluginDefinition {
    PluginDefinition(
        id: id,
        label: label,
        dependencies: [ServiceDependency(SearchServiceKeys.providers)]
    ) {
        try ComponentDefinition(
            label: id.rawValue,
            dependencies: [ServiceDependency(SearchServiceKeys.providers)]
        ) { activation in
            let registry = try await activation.require(SearchServiceKeys.providers)
            let registration = try await registry.register(provider)
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
        }
    }
}
