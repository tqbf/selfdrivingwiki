#if os(macOS)
import Cordis
import WikiFSCore

/// Assembly-independent factory signatures shared by extraction plugins and
/// the legacy extraction assembly while it remains during the migration.
public enum ExtractionPluginFactory {
    public typealias CredentialReader = @Sendable (ExtractionSecret) -> String?
    public typealias ACPResolver = @Sendable (ExtractionConfig) -> (any MarkdownExtractor)?
    public typealias LocalExtractor = @Sendable () async -> any MarkdownExtractor
}

public struct BasePluginCatalogFactories: Sendable {
    public let agentProviderServices: any AgentProviderServices
    public let makePDFExtractor: ExtractionPluginFactory.LocalExtractor
    public let configureEmbeddings: EmbeddingsSearchProvider.Configure
    public let selectedEmbeddingIdentifier: EmbeddingsSearchProvider.SelectedIdentifier
    public let embeddingsAvailable: EmbeddingsSearchProvider.Availability

    public init(
        agentProviderServices: any AgentProviderServices,
        makePDFExtractor: @escaping ExtractionPluginFactory.LocalExtractor,
        configureEmbeddings: @escaping EmbeddingsSearchProvider.Configure = { await EmbeddingService.configure() },
        selectedEmbeddingIdentifier: @escaping EmbeddingsSearchProvider.SelectedIdentifier = { EmbeddingService.selectedEmbedderIdentifier() },
        embeddingsAvailable: @escaping EmbeddingsSearchProvider.Availability = { EmbeddingService.isAvailable }
    ) {
        self.agentProviderServices = agentProviderServices
        self.makePDFExtractor = makePDFExtractor
        self.configureEmbeddings = configureEmbeddings
        self.selectedEmbeddingIdentifier = selectedEmbeddingIdentifier
        self.embeddingsAvailable = embeddingsAvailable
    }
}

public struct AppPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories
    public let makeRendererServices: RegisteredRendererProvider.Factory
    public let makeDefuddleExtractor: @Sendable () async -> any HtmlMarkdownExtractor
    public let makeDaemonTransport: RegisteredTransportProvider.Factory
    public let makeURLFetcher: RegisteredIntegrationCapability.Factory
    public let makeTantivyRuntime: SearchRuntimeFactory.Factory

    public init(
        base: BasePluginCatalogFactories,
        makeRendererServices: @escaping RegisteredRendererProvider.Factory,
        makeDefuddleExtractor: @escaping @Sendable () async -> any HtmlMarkdownExtractor,
        makeDaemonTransport: @escaping RegisteredTransportProvider.Factory,
        makeURLFetcher: @escaping RegisteredIntegrationCapability.Factory,
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeAssembly.runtimeFactory
    ) {
        self.base = base
        self.makeRendererServices = makeRendererServices
        self.makeDefuddleExtractor = makeDefuddleExtractor
        self.makeDaemonTransport = makeDaemonTransport
        self.makeURLFetcher = makeURLFetcher
        self.makeTantivyRuntime = makeTantivyRuntime
    }
}

public struct DaemonPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories

    public init(base: BasePluginCatalogFactories) {
        self.base = base
    }
}

public enum AppPluginCatalog {
    public static func build(
        factories: AppPluginCatalogFactories,
        additionalDefinitions: [PluginDefinition] = []
    ) throws -> PluginCatalog {
        var definitions = baseDefinitions(factories.base)
        definitions.append(contentsOf: [
            DefuddleExtractionPlugin.definition(makeExtractor: factories.makeDefuddleExtractor),
            RendererServicesPlugin.definition(makeServices: factories.makeRendererServices),
            DaemonTransportPlugin.definition(makeServices: factories.makeDaemonTransport),
            URLFetchIntegrationPlugin.definition(makeFetcher: factories.makeURLFetcher),
        ])
        definitions.append(TantivySearchPlugin.definition(makeRuntime: factories.makeTantivyRuntime))
        definitions.append(contentsOf: additionalDefinitions)
        return try PluginCatalog(definitions)
    }
}

public enum DaemonPluginCatalog {
    public static func build(
        factories: DaemonPluginCatalogFactories,
        additionalDefinitions: [PluginDefinition] = []
    ) throws -> PluginCatalog {
        try PluginCatalog(baseDefinitions(factories.base) + additionalDefinitions)
    }
}

public enum CLIPluginCatalog {
    public static func build(
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeAssembly.runtimeFactory
    ) throws -> PluginCatalog {
        try PluginCatalog([
            SearchPlugin.definition,
            TantivySearchPlugin.definition(makeRuntime: makeTantivyRuntime),
        ])
    }
}

private func baseDefinitions(_ factories: BasePluginCatalogFactories) -> [PluginDefinition] {
    [
        StorePlugin.definition,
        SessionsPlugin.definition,
        ChatsPersistencePlugin.definition,
        LlmRuntimePlugin.definition,
        ACPModelAdapterPlugin.definition(services: factories.agentProviderServices),
        ToolsPlugin.definition,
        NoOpToolPlugin.definition,
        SystemPromptPlugin.definition,
        AgentLoopPlugin.definition,
        ExtractionPlugin.definition,
        Pdf2mdExtractionPlugin.definition(makeExtractor: factories.makePDFExtractor),
        SearchPlugin.definition,
        EmbeddingsSearchPlugin.definition(
            configure: factories.configureEmbeddings,
            selectedIdentifier: factories.selectedEmbeddingIdentifier,
            isAvailable: factories.embeddingsAvailable),
        RenderersPlugin.definition,
        TransportPlugin.definition,
        IntegrationsPlugin.definition,
    ]
}
#endif
