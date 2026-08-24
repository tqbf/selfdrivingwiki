#if os(macOS)
import Cordis
import CordisLoader
import Foundation
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

/// Typed services resolved once from a booted profile. Consumers receive this
/// facade rather than a Cordis context or a legacy runtime assembly.
public struct AppServices: Sendable {
    public let profile: BootedProfile
    public let store: any WikiStore
    public let readPool: WikiReadPool
    public let extractionBackends: ExtractionBackendRegistry
    public let searchProviders: SearchProviderRegistry

    public static func resolve(from profile: BootedProfile) async throws -> AppServices {
        AppServices(
            profile: profile,
            store: try await profile.context.require(StoreServiceKeys.store),
            readPool: try await profile.context.require(StoreServiceKeys.readPool),
            extractionBackends: try await profile.context.require(ExtractionServiceKeys.backends),
            searchProviders: try await profile.context.require(SearchServiceKeys.providers))
    }

    public func shutdown() async throws {
        try await profile.shutdown()
    }
}

/// Concrete per-wiki profile rows. The store row is a complete replacement for
/// the machine-independent placeholder shipped in `wikifs-base`.
public enum ProductionProfileEntries {
    public static func app(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        base(databaseURL: databaseURL, wikiID: wikiID) + [
            Entry(id: EntryID("renderer-services"), plugin: RendererServicesPlugin.id),
            Entry(id: EntryID("daemon-transport"), plugin: DaemonTransportPlugin.id),
            Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
    }

    public static func daemon(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        base(databaseURL: databaseURL, wikiID: wikiID) + [
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
    }

    public static func cli() -> [Entry] {
        [
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
        ]
    }

    private static func base(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        [
            Entry(id: EntryID("store"), plugin: StorePlugin.id, config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string(wikiID.rawValue),
            ]),
            Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id),
            Entry(id: EntryID("chats-persistence"), plugin: ChatsPersistencePlugin.id),
            Entry(id: EntryID("llm-runtime"), plugin: LlmRuntimePlugin.id),
            Entry(id: EntryID("tools"), plugin: ToolsPlugin.id),
            Entry(id: EntryID("system-prompt"), plugin: SystemPromptPlugin.id),
            Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id),
            Entry(id: EntryID("extraction"), plugin: ExtractionPlugin.id),
            Entry(id: EntryID("pdf2md"), plugin: Pdf2mdExtractionPlugin.id),
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("renderers"), plugin: RenderersPlugin.id),
            Entry(id: EntryID("transport"), plugin: TransportPlugin.id),
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
        ]
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
