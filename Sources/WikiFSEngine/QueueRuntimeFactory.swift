import Cordis
import Foundation
import WikiFSCore

public enum QueueRuntimeFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(
        assembly: CordisFailure,
        cleanup: CordisFailure)
}

public struct QueueRuntimeFactory: Sendable {
    public typealias IngestionProviderFactory = @Sendable (QueueStore) async throws -> any QueueIngestionProvider

    internal enum Component: String, CaseIterable, Sendable {
        case store
        case extractionProvider
        case ingestionProvider
        case outputChannel
        case extractionFactory
        case ingestionFactory
        case compositeFactory
        case tools
        case engine
    }

    private enum Keys {
        static let store = ServiceKey<QueueStore>(label: "queue.store")
        static let extractionProvider = ServiceKey<any QueueExtractionProvider>(
            label: "queue.extraction-provider")
        static let ingestionProvider = ServiceKey<any QueueIngestionProvider>(
            label: "queue.ingestion-provider")
        static let outputChannel = ServiceKey<QueueWorkerOutputChannel>(
            label: "queue.output-channel")
        static let extractionFactory = ServiceKey<QueueExtractionWorkerFactory>(
            label: "queue.extraction-factory")
        static let ingestionFactory = ServiceKey<QueueIngestionWorkerFactory>(
            label: "queue.ingestion-factory")
        static let compositeFactory = ServiceKey<CompositeWorkerFactory>(
            label: "queue.composite-factory")
        static let engine = ServiceKey<QueueEngine>(label: "queue.engine")
    }

    public let databaseURL: URL
    public let extractionProvider: any QueueExtractionProvider
    public let makeIngestionProvider: IngestionProviderFactory

    public init(
        databaseURL: URL,
        extractionProvider: any QueueExtractionProvider,
        makeIngestionProvider: @escaping IngestionProviderFactory
    ) {
        self.databaseURL = databaseURL
        self.extractionProvider = extractionProvider
        self.makeIngestionProvider = makeIngestionProvider
    }

    public func assemble() async throws -> QueueRuntimeHandle {
        try await assemble(registrationOrder: Component.allCases)
    }

    internal func assemble(
        registrationOrder: [Component]
    ) async throws -> QueueRuntimeHandle {
        let context = CordisContext()

        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await context.register(
                    try definition(for: component))
            }

            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw QueueRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                let state = try await handle.awaitSettled()
                if case .failed(_, let failure) = state {
                    throw QueueRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: failure)
                }
            }

            let engine = try await require(Keys.engine, from: context)
            let store = try await require(Keys.store, from: context)
            await engine.start()
            return QueueRuntimeHandle(
                engine: engine,
                store: store,
                rootContext: context)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do {
                try await context.dispose()
            } catch let cleanupError {
                throw QueueRuntimeFactoryError.assemblyAndCleanupFailed(
                    assembly: assemblyFailure,
                    cleanup: CordisFailure(cleanupError))
            }
            throw error
        }
    }

    private func require<Value: Sendable>(
        _ key: ServiceKey<Value>,
        from context: CordisContext
    ) async throws -> Value {
        guard let value = try await context.find(key) else {
            throw QueueRuntimeFactoryError.missingService(
                ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .store:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.store)]) { activation in
                    let store = try QueueStore(databaseURL: databaseURL)
                    _ = try await activation.supply(Keys.store, value: store)
                    _ = try await activation.effect { _ in
                        store.close()
                    }
                }

        case .extractionProvider:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.extractionProvider)]) { activation in
                    _ = try await activation.supply(
                        Keys.extractionProvider,
                        value: extractionProvider)
                }

        case .ingestionProvider:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.store)],
                provisions: [ServiceDependency(Keys.ingestionProvider)]) { activation in
                    let store = try await activation.require(Keys.store)
                    let provider = try await makeIngestionProvider(store)
                    _ = try await activation.supply(Keys.ingestionProvider, value: provider)
                }

        case .outputChannel:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.store)],
                provisions: [ServiceDependency(Keys.outputChannel)]) { activation in
                    let store = try await activation.require(Keys.store)
                    let channel = QueueWorkerOutputChannel(store: store)
                    _ = try await activation.supply(Keys.outputChannel, value: channel)
                }

        case .extractionFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.extractionProvider),
                    ServiceDependency(Keys.outputChannel),
                ],
                provisions: [ServiceDependency(Keys.extractionFactory)]) { activation in
                    let provider = try await activation.require(Keys.extractionProvider)
                    let channel = try await activation.require(Keys.outputChannel)
                    let factory = QueueExtractionWorkerFactory(
                        provider: provider,
                        emitProgress: channel.emitProgress(itemID:line:))
                    _ = try await activation.supply(Keys.extractionFactory, value: factory)
                }

        case .ingestionFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.ingestionProvider),
                    ServiceDependency(Keys.outputChannel),
                ],
                provisions: [ServiceDependency(Keys.ingestionFactory)]) { activation in
                    let provider = try await activation.require(Keys.ingestionProvider)
                    let channel = try await activation.require(Keys.outputChannel)
                    let factory = QueueIngestionWorkerFactory(
                        provider: provider,
                        emitProgress: channel.emitProgress(itemID:line:),
                        emitTranscript: channel.emitTranscript(attemptID:event:),
                        emitUsage: channel.emitUsage(itemID:usage:),
                        emitLiveUsage: channel.emitLiveUsage(itemID:usage:),
                        emitLogPaths: channel.emitRunPaths(itemID:logURL:debugURL:),
                        emitPendingPermission: channel.emitPendingPermission(itemID:permission:))
                    _ = try await activation.supply(Keys.ingestionFactory, value: factory)
                }

        case .compositeFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.extractionFactory),
                    ServiceDependency(Keys.ingestionFactory),
                ],
                provisions: [ServiceDependency(Keys.compositeFactory)]) { activation in
                    let extractionFactory = try await activation.require(Keys.extractionFactory)
                    let ingestionFactory = try await activation.require(Keys.ingestionFactory)
                    let factory = CompositeWorkerFactory(factories: [
                        .extraction: extractionFactory,
                        .ingestion: ingestionFactory,
                    ])
                    _ = try await activation.supply(Keys.compositeFactory, value: factory)
                }

        case .tools:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(ToolServiceKeys.tools)]) { activation in
                    let registry = ToolRegistry()
                    _ = try await activation.on(ToolEventKeys.execute) { context, next in
                        var context = try await next()
                        guard context.result == nil else { return context }
                        guard let tool = await registry.resolve(context.name) else {
                            throw ToolRuntimeError.unknownTool(context.name)
                        }
                        context.result = try await tool.execute(payload: context.payload)
                        return context
                    }
                    let runtime = ToolRuntime(registry: registry) { key, context in
                        try await activation.waterfall(key, context)
                    }
                    _ = try await activation.supply(ToolServiceKeys.tools, value: runtime)
                }

        case .engine:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.store),
                    ServiceDependency(Keys.outputChannel),
                    ServiceDependency(Keys.compositeFactory),
                    ServiceDependency(ToolServiceKeys.tools),
                ],
                provisions: [ServiceDependency(Keys.engine)]) { activation in
                    let store = try await activation.require(Keys.store)
                    let channel = try await activation.require(Keys.outputChannel)
                    let factory = try await activation.require(Keys.compositeFactory)
                    let tools = try await activation.require(ToolServiceKeys.tools)
                    let engine = QueueEngine(
                        store: store,
                        workerFactory: factory,
                        workerExecutor: CordisQueueWorkerExecutor(runtime: tools),
                        outputChannel: channel)
                    _ = try await activation.supply(Keys.engine, value: engine)
                }
        }
    }
}

public actor QueueRuntimeHandle {
    public nonisolated let client: any QueueEngineClient
    public nonisolated let engine: QueueEngine
    public nonisolated let store: QueueStore

    private let rootContext: CordisContext
    private var terminalResult: QueueEngineShutdownResult?

    internal init(
        engine: QueueEngine,
        store: QueueStore,
        rootContext: CordisContext
    ) {
        self.client = engine
        self.engine = engine
        self.store = store
        self.rootContext = rootContext
    }

    public func dispose() async throws -> QueueEngineShutdownResult {
        if let terminalResult { return terminalResult }

        let shutdownResult = await engine.shutdownForHandoff()
        guard shutdownResult == .shutDown else {
            return shutdownResult
        }

        try await rootContext.dispose()
        terminalResult = shutdownResult
        return shutdownResult
    }
}
