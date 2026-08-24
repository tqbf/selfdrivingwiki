#if os(macOS)
import Cordis
import Foundation
import WikiFSCore

public enum ExtractionRuntimeFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

public struct ExtractionRuntimeFactory: Sendable {
    public typealias BackendResolver = ExtractionRuntime.BackendResolver

    internal enum Component: String, CaseIterable, Sendable {
        case configurationReader
        case credentialReader
        case acpResolver
        case httpFetcher
        case localExtractorFactory
        case backendResolver
        case runtime
        case services
    }

    private enum Keys {
        static let configurationReader = ServiceKey<ExtractionRuntime.ConfigurationReader>(
            label: "extraction.configuration-reader")
        static let credentialReader = ServiceKey<ExtractionPluginFactory.CredentialReader>(
            label: "extraction.credential-reader")
        static let acpResolver = ServiceKey<ExtractionPluginFactory.ACPResolver>(
            label: "extraction.acp-resolver")
        static let httpFetcher = ServiceKey<any HTTPRequestFetcher>(
            label: "extraction.http-fetcher")
        static let localExtractorFactory = ServiceKey<ExtractionPluginFactory.LocalExtractor>(
            label: "extraction.local-extractor-factory")
        static let backendResolver = ServiceKey<BackendResolver>(
            label: "extraction.backend-resolver")
        static let runtime = ServiceKey<ExtractionRuntime>(
            label: "extraction.runtime")
        static let services = ServiceKey<any ExtractionServices>(
            label: "extraction.services")
    }

    public let readConfiguration: ExtractionRuntime.ConfigurationReader
    public let readCredential: ExtractionPluginFactory.CredentialReader
    public let resolveACP: ExtractionPluginFactory.ACPResolver
    public let httpFetcher: any HTTPRequestFetcher
    public let makeLocalExtractor: ExtractionPluginFactory.LocalExtractor

    public init(
        readConfiguration: @escaping ExtractionRuntime.ConfigurationReader,
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        resolveACP: @escaping ExtractionPluginFactory.ACPResolver,
        httpFetcher: any HTTPRequestFetcher,
        makeLocalExtractor: @escaping ExtractionPluginFactory.LocalExtractor
    ) {
        self.readConfiguration = readConfiguration
        self.readCredential = readCredential
        self.resolveACP = resolveACP
        self.httpFetcher = httpFetcher
        self.makeLocalExtractor = makeLocalExtractor
    }

    public func assemble() async throws -> ExtractionRuntimeHandle {
        try await assemble(registrationOrder: Component.allCases)
    }

    internal func assemble(
        registrationOrder: [Component]
    ) async throws -> ExtractionRuntimeHandle {
        let context = CordisContext()
        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await context.register(try definition(for: component))
            }
            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw ExtractionRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                if case .failed(_, let failure) = try await handle.awaitSettled() {
                    throw ExtractionRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: failure)
                }
            }
            return ExtractionRuntimeHandle(
                services: try await require(Keys.services, from: context),
                rootContext: context)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do {
                try await context.dispose()
            } catch let cleanupError {
                throw ExtractionRuntimeFactoryError.assemblyAndCleanupFailed(
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
            throw ExtractionRuntimeFactoryError.missingService(
                ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .configurationReader:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.configurationReader)]) { activation in
                    _ = try await activation.supply(
                        Keys.configurationReader,
                        value: readConfiguration)
                }
        case .credentialReader:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.credentialReader)]) { activation in
                    _ = try await activation.supply(Keys.credentialReader, value: readCredential)
                }
        case .acpResolver:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.acpResolver)]) { activation in
                    _ = try await activation.supply(Keys.acpResolver, value: resolveACP)
                }
        case .httpFetcher:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.httpFetcher)]) { activation in
                    _ = try await activation.supply(Keys.httpFetcher, value: httpFetcher)
                }
        case .localExtractorFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.localExtractorFactory)]) { activation in
                    _ = try await activation.supply(
                        Keys.localExtractorFactory,
                        value: makeLocalExtractor)
                }
        case .backendResolver:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.credentialReader),
                    ServiceDependency(Keys.acpResolver),
                    ServiceDependency(Keys.httpFetcher),
                    ServiceDependency(Keys.localExtractorFactory),
                ],
                provisions: [ServiceDependency(Keys.backendResolver)]) { activation in
                    let readCredential = try await activation.require(Keys.credentialReader)
                    let resolveACP = try await activation.require(Keys.acpResolver)
                    let fetcher = try await activation.require(Keys.httpFetcher)
                    let makeLocalExtractor = try await activation.require(Keys.localExtractorFactory)
                    let resolver: BackendResolver = { configuration, backend in
                        switch backend {
                        case .localPdf2md:
                            return ExtractionPreparation(
                                extractor: await makeLocalExtractor(),
                                backend: backend,
                                modelVersion: nil)
                        case .acp:
                            if let extractor = resolveACP(configuration) {
                                return ExtractionPreparation(
                                    extractor: extractor,
                                    backend: backend,
                                    modelVersion: nil)
                            }
                            DebugLog.config("ExtractionRuntime: .acp backend but no provider resolvable — falling back to local pdf2md")
                            return ExtractionPreparation(
                                extractor: await makeLocalExtractor(),
                                backend: backend,
                                modelVersion: nil)
                        case .anthropic:
                            let baseURL = configuration.anthropicBaseURLOverride
                                .flatMap(URL.init(string:))
                                ?? ExtractionDefaultURL.anthropic
                            return ExtractionPreparation(
                                extractor: AnthropicExtractionClient(
                                    model: configuration.anthropicModel,
                                    apiKey: readCredential(.anthropicAPIKey) ?? "",
                                    baseURL: baseURL,
                                    fetcher: fetcher),
                                backend: backend,
                                modelVersion: configuration.anthropicModel)
                        case .gemini:
                            let baseURL = configuration.geminiBaseURLOverride
                                .flatMap(URL.init(string:))
                                ?? ExtractionDefaultURL.gemini
                            return ExtractionPreparation(
                                extractor: GeminiExtractionClient(
                                    model: configuration.geminiModel,
                                    apiKey: readCredential(.geminiAPIKey) ?? "",
                                    baseURL: baseURL,
                                    fetcher: fetcher),
                                backend: backend,
                                modelVersion: configuration.geminiModel)
                        case .doclingServe:
                            return ExtractionPreparation(
                                extractor: DoclingServeClient(
                                    endpoint: configuration.doclingServeEndpoint ?? "",
                                    apiToken: readCredential(.doclingServeToken),
                                    fetcher: fetcher),
                                backend: backend,
                                modelVersion: nil)
                        }
                    }
                    _ = try await activation.supply(Keys.backendResolver, value: resolver)
                }
        case .runtime:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.configurationReader),
                    ServiceDependency(Keys.backendResolver),
                ],
                provisions: [ServiceDependency(Keys.runtime)]) { activation in
                    let runtime = ExtractionRuntime(
                        readConfiguration: try await activation.require(Keys.configurationReader),
                        resolveBackend: try await activation.require(Keys.backendResolver))
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

public actor ExtractionRuntimeHandle {
    public nonisolated let services: any ExtractionServices
    private let rootContext: CordisContext
    private var didDispose = false

    internal init(services: any ExtractionServices, rootContext: CordisContext) {
        self.services = services
        self.rootContext = rootContext
    }

    public func dispose() async throws {
        guard !didDispose else { return }
        try await rootContext.dispose()
        didDispose = true
    }
}
#endif
