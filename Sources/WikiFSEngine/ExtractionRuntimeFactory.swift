#if os(macOS)
import Cordis
import Foundation
import WikiFSCore

public enum ExtractionRuntimeFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

/// Test-only compatibility assembly for legacy callers. Production profiles use
/// `ProcessExtractionContext` and `ProcessExtractionServices` instead.
///
/// The source audit in `ExtractionBackendAuthorityAuditTests` prevents shipping
/// targets from constructing this compatibility assembly.
public struct ExtractionRuntimeFactory: Sendable {
    public typealias BackendResolver = ExtractionRuntime.BackendResolver

    internal enum Component: String, CaseIterable, Sendable {
        case configurationReader
        case credentialReader
        case acpResolver
        case httpFetcher
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
    public init(
        readConfiguration: @escaping ExtractionRuntime.ConfigurationReader,
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        resolveACP: @escaping ExtractionPluginFactory.ACPResolver,
        httpFetcher: any HTTPRequestFetcher
    ) {
        self.readConfiguration = readConfiguration
        self.readCredential = readCredential
        self.resolveACP = resolveACP
        self.httpFetcher = httpFetcher
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
        case .backendResolver:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.credentialReader),
                    ServiceDependency(Keys.acpResolver),
                    ServiceDependency(Keys.httpFetcher),
                ],
                provisions: [ServiceDependency(Keys.backendResolver)]) { activation in
                    let readCredential = try await activation.require(Keys.credentialReader)
                    let resolveACP = try await activation.require(Keys.acpResolver)
                    let fetcher = try await activation.require(Keys.httpFetcher)
                    let resolver: BackendResolver = { configuration, backend in
                        switch backend {
                        case .localPdf2md:
                            throw ExtractionServicesError.unavailable
                        case .acp:
                            guard let extractor = resolveACP(configuration) else {
                                DebugLog.config("ExtractionRuntime: .acp backend has no provider")
                                throw ExtractionServicesError.unavailable
                            }
                            return ExtractionPreparation(
                                extractor: extractor,
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
                            // #1159: no in-process Docling construction. The
                            // legacy selection resolves through the reviewed
                            // Docling Serve package (ProcessExtractionServices
                            // maps the legacy key to that lineage); this
                            // plugin-layer resolver fails closed instead.
                            throw ExtractionServicesError.unavailable
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
