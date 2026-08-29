import Cordis
import Foundation
import WikiFSCore

public enum AgentProviderRuntimeFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

public struct AgentProviderRuntimeFactory: Sendable {
    internal enum Component: String, CaseIterable, Sendable {
        case configurationReader
        case commandResolver
        case credentialReader
        case spawnSecretReader
        case permissionPolicyResolver
        case backendFactory
        case catalogProbe
        case runtime
        case services
    }

    private enum Keys {
        static let configurationReader = ServiceKey<AgentProviderRuntime.ConfigurationReader>(label: "agent-provider.configuration-reader")
        static let commandResolver = ServiceKey<AgentProviderRuntime.CommandResolver>(label: "agent-provider.command-resolver")
        static let credentialReader = ServiceKey<AgentProviderRuntime.CredentialReader>(label: "agent-provider.credential-reader")
        static let spawnSecretReader = ServiceKey<AgentProviderRuntime.SpawnSecretReader>(label: "agent-provider.spawn-secret-reader")
        static let permissionPolicyResolver = ServiceKey<AgentProviderRuntime.PermissionPolicyResolver>(label: "agent-provider.permission-policy-resolver")
        static let backendFactory = ServiceKey<AgentProviderRuntime.BackendFactory>(label: "agent-provider.backend-factory")
        static let catalogProbe = ServiceKey<AgentProviderRuntime.CatalogProbe>(label: "agent-provider.catalog-probe")
        static let runtime = ServiceKey<AgentProviderRuntime>(label: "agent-provider.runtime")
        static let services = ServiceKey<any AgentProviderServices>(label: "agent-provider.services")
    }

    public let readConfiguration: AgentProviderRuntime.ConfigurationReader
    public let resolveCommand: AgentProviderRuntime.CommandResolver
    public let readCredential: AgentProviderRuntime.CredentialReader
    public let readSpawnSecrets: AgentProviderRuntime.SpawnSecretReader
    public let resolvePermissionPolicy: AgentProviderRuntime.PermissionPolicyResolver
    public let makeBackend: AgentProviderRuntime.BackendFactory
    public let probeCatalog: AgentProviderRuntime.CatalogProbe

    public init(
        readConfiguration: @escaping AgentProviderRuntime.ConfigurationReader,
        resolveCommand: @escaping AgentProviderRuntime.CommandResolver,
        readCredential: @escaping AgentProviderRuntime.CredentialReader,
        readSpawnSecrets: @escaping AgentProviderRuntime.SpawnSecretReader = { _ in [:] },
        resolvePermissionPolicy: @escaping AgentProviderRuntime.PermissionPolicyResolver,
        makeBackend: @escaping AgentProviderRuntime.BackendFactory = { policy, budget, ceiling in
            AgentBackendFactory.makeBackend(policy: policy, budget: budget, turnCeilingTimeout: ceiling)
        },
        probeCatalog: @escaping AgentProviderRuntime.CatalogProbe = { provider, resolvedCommand, apiKey in
            try await ACPProviderModelProbe(
                provider: provider,
                resolvedCommand: resolvedCommand,
                apiKey: apiKey)
                .discoverObservation()
        }
    ) {
        self.readConfiguration = readConfiguration
        self.resolveCommand = resolveCommand
        self.readCredential = readCredential
        self.readSpawnSecrets = readSpawnSecrets
        self.resolvePermissionPolicy = resolvePermissionPolicy
        self.makeBackend = makeBackend
        self.probeCatalog = probeCatalog
    }

    public func assemble() async throws -> AgentProviderRuntimeHandle {
        try await assemble(registrationOrder: Component.allCases)
    }

    internal func assemble(registrationOrder: [Component]) async throws -> AgentProviderRuntimeHandle {
        let context = CordisContext()
        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await context.register(try definition(for: component))
            }
            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw AgentProviderRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                if case .failed(_, let failure) = try await handle.awaitSettled() {
                    throw AgentProviderRuntimeFactoryError.activationFailed(component: component.rawValue, failure: failure)
                }
            }
            return AgentProviderRuntimeHandle(
                services: try await require(Keys.services, from: context),
                rootContext: context)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do {
                try await context.dispose()
            } catch let cleanupError {
                throw AgentProviderRuntimeFactoryError.assemblyAndCleanupFailed(
                    assembly: assemblyFailure,
                    cleanup: CordisFailure(cleanupError))
            }
            throw error
        }
    }

    private func require<Value: Sendable>(_ key: ServiceKey<Value>, from context: CordisContext) async throws -> Value {
        guard let value = try await context.find(key) else {
            throw AgentProviderRuntimeFactoryError.missingService(ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .configurationReader:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.configurationReader)]) { activation in
                _ = try await activation.supply(Keys.configurationReader, value: readConfiguration)
            }
        case .commandResolver:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.commandResolver)]) { activation in
                _ = try await activation.supply(Keys.commandResolver, value: resolveCommand)
            }
        case .credentialReader:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.credentialReader)]) { activation in
                _ = try await activation.supply(Keys.credentialReader, value: readCredential)
            }
        case .spawnSecretReader:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.spawnSecretReader)]) { activation in
                _ = try await activation.supply(Keys.spawnSecretReader, value: readSpawnSecrets)
            }
        case .permissionPolicyResolver:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.permissionPolicyResolver)]) { activation in
                _ = try await activation.supply(Keys.permissionPolicyResolver, value: resolvePermissionPolicy)
            }
        case .backendFactory:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.backendFactory)]) { activation in
                _ = try await activation.supply(Keys.backendFactory, value: makeBackend)
            }
        case .catalogProbe:
            return try ComponentDefinition(label: component.rawValue, provisions: [ServiceDependency(Keys.catalogProbe)]) { activation in
                _ = try await activation.supply(Keys.catalogProbe, value: probeCatalog)
            }
        case .runtime:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.configurationReader), ServiceDependency(Keys.commandResolver), ServiceDependency(Keys.credentialReader), ServiceDependency(Keys.spawnSecretReader), ServiceDependency(Keys.permissionPolicyResolver), ServiceDependency(Keys.backendFactory), ServiceDependency(Keys.catalogProbe)],
                provisions: [ServiceDependency(Keys.runtime)]) { activation in
                    let runtime = AgentProviderRuntime(
                        readConfiguration: try await activation.require(Keys.configurationReader),
                        resolveCommand: try await activation.require(Keys.commandResolver),
                        readCredential: try await activation.require(Keys.credentialReader),
                        readSpawnSecrets: try await activation.require(Keys.spawnSecretReader),
                        resolvePermissionPolicy: try await activation.require(Keys.permissionPolicyResolver),
                        makeBackend: try await activation.require(Keys.backendFactory),
                        probeCatalog: try await activation.require(Keys.catalogProbe))
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

public actor AgentProviderRuntimeHandle {
    public nonisolated let services: any AgentProviderServices
    private let rootContext: CordisContext
    private var didDispose = false

    internal init(services: any AgentProviderServices, rootContext: CordisContext) {
        self.services = services
        self.rootContext = rootContext
    }

    public func dispose() async throws {
        guard !didDispose else { return }
        try await rootContext.dispose()
        didDispose = true
    }
}
