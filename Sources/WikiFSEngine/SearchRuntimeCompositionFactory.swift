#if os(macOS)
import Cordis
import Foundation
import WikiFSCore
import WikiFSSearch

public enum SearchRuntimeCompositionFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

public struct SearchRuntimeCompositionFactory: Sendable {
    public enum ServiceLabels {
        public static let identity = "search.identity"
        public static let contentSource = "search.content-source"
        public static let changeStreamFactory = "search.change-stream-factory"
        public static let indexer = "search.indexer"
        public static let runtime = "search.runtime"
        public static let services = "search.services"
    }

    internal enum Component: String, CaseIterable, Sendable {
        case identity, contentSource, changeStreamFactory, indexer, runtime, services
    }

    private enum Keys {
        static let identity = ServiceKey<SearchRuntimeIdentity>(label: ServiceLabels.identity)
        static let contentSource = ServiceKey<any TantivyContentSource>(label: ServiceLabels.contentSource)
        static let changeStreamFactory = ServiceKey<any SearchChangeStreamFactory>(label: ServiceLabels.changeStreamFactory)
        static let indexer = ServiceKey<TantivyIndexer>(label: ServiceLabels.indexer)
        static let runtime = ServiceKey<SearchRuntime>(label: ServiceLabels.runtime)
        static let services = ServiceKey<any SearchServices>(label: ServiceLabels.services)
    }

    public let identity: SearchRuntimeIdentity
    public let contentSource: any TantivyContentSource
    public let changeStreamFactory: any SearchChangeStreamFactory

    public init(
        identity: SearchRuntimeIdentity,
        contentSource: any TantivyContentSource,
        changeStreamFactory: any SearchChangeStreamFactory
    ) {
        self.identity = identity
        self.contentSource = contentSource
        self.changeStreamFactory = changeStreamFactory
    }

    public static func runtimeFactory(
        identity: SearchRuntimeIdentity,
        contentSource: any TantivyContentSource,
        changeStreamFactory: any SearchChangeStreamFactory
    ) -> SearchRuntimeFactory {
        let assembly = Self(
            identity: identity,
            contentSource: contentSource,
            changeStreamFactory: changeStreamFactory)
        return SearchRuntimeFactory(
            identity: identity,
            changeStreamFactory: changeStreamFactory,
            assemble: { context in try await assembly.assemble(in: context) })
    }

    public func assemble(in childContext: CordisContext) async throws -> SearchRuntimeHandle {
        try await assemble(in: childContext, registrationOrder: Component.allCases)
    }

    internal func assemble(
        in childContext: CordisContext,
        registrationOrder: [Component]
    ) async throws -> SearchRuntimeHandle {
        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await childContext.register(try definition(for: component))
            }
            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw SearchRuntimeCompositionFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                if case .failed(_, let failure) = try await handle.awaitSettled() {
                    throw SearchRuntimeCompositionFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: failure)
                }
            }
            return SearchRuntimeHandle(
                wikiID: identity.wikiID,
                services: try await require(Keys.services, from: childContext),
                childContext: childContext)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do {
                try await childContext.dispose()
            } catch let cleanupError {
                throw SearchRuntimeCompositionFactoryError.assemblyAndCleanupFailed(
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
            throw SearchRuntimeCompositionFactoryError.missingService(ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .identity:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.identity)]) { activation in
                    try identity.validate()
                    _ = try await activation.supply(Keys.identity, value: identity)
                }
        case .contentSource:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.contentSource)]) { activation in
                    _ = try await activation.supply(Keys.contentSource, value: contentSource)
                }
        case .changeStreamFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.changeStreamFactory)]) { activation in
                    _ = try await activation.supply(Keys.changeStreamFactory, value: changeStreamFactory)
                    _ = try await activation.effect { _ in changeStreamFactory.finish() }
                }
        case .indexer:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.identity),
                    ServiceDependency(Keys.contentSource),
                ],
                provisions: [ServiceDependency(Keys.indexer)]) { activation in
                    let resolvedIdentity = try await activation.require(Keys.identity)
                    let resolvedSource = try await activation.require(Keys.contentSource)
                    let indexer: TantivyIndexer
                    do {
                        indexer = try TantivyIndexer(
                            indexDirectory: resolvedIdentity.indexDirectory,
                            contentSource: resolvedSource)
                    } catch {
                        throw SearchServicesError.indexConstructionFailed(String(describing: error))
                    }
                    _ = try await activation.supply(Keys.indexer, value: indexer)
                }
        case .runtime:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.identity),
                    ServiceDependency(Keys.contentSource),
                    ServiceDependency(Keys.changeStreamFactory),
                    ServiceDependency(Keys.indexer),
                ],
                provisions: [ServiceDependency(Keys.runtime)]) { activation in
                    let runtime = SearchRuntime(
                        identity: try await activation.require(Keys.identity),
                        indexer: try await activation.require(Keys.indexer),
                        contentSource: try await activation.require(Keys.contentSource),
                        streamFactory: try await activation.require(Keys.changeStreamFactory))
                    try await runtime.start()
                    _ = try await activation.supply(Keys.runtime, value: runtime)
                    _ = try await activation.effect { _ in await runtime.dispose() }
                }
        case .services:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.runtime)],
                provisions: [ServiceDependency(Keys.services)]) { activation in
                    let runtime = try await activation.require(Keys.runtime)
                    _ = try await activation.supply(Keys.services, value: runtime)
                }
        }
    }
}

public actor SearchRuntimeHandle {
    public nonisolated let wikiID: WikiID
    public nonisolated let services: any SearchServices
    private let childContext: CordisContext
    private var didDispose = false

    internal init(
        wikiID: WikiID,
        services: any SearchServices,
        childContext: CordisContext
    ) {
        self.wikiID = wikiID
        self.services = services
        self.childContext = childContext
    }

    public func dispose() async throws {
        guard !didDispose else { return }
        didDispose = true
        do {
            try await childContext.dispose()
        } catch {
            didDispose = false
            throw error
        }
    }
}
#endif
