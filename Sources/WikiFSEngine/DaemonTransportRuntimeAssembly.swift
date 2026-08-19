#if os(macOS)
import Cordis
import Foundation

public enum DaemonTransportRuntimeAssemblyError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

public struct DaemonTransportRuntimeAssembly: Sendable {
    public enum ServiceLabels {
        public static let connectionFactory = "daemon-transport.connection-factory"
        public static let configuration = "daemon-transport.configuration"
        public static let runtime = "daemon-transport.runtime"
        public static let services = "daemon-transport.services"
    }

    internal enum Component: String, CaseIterable, Sendable {
        case connectionFactory
        case configuration
        case runtime
        case services
    }

    private enum Keys {
        static let connectionFactory = ServiceKey<DaemonTransportConnectionFactory>(
            label: ServiceLabels.connectionFactory)
        static let configuration = ServiceKey<DaemonTransportConfiguration>(
            label: ServiceLabels.configuration)
        static let runtime = ServiceKey<DaemonTransportRuntime>(
            label: ServiceLabels.runtime)
        static let services = ServiceKey<DaemonTransportServices>(
            label: ServiceLabels.services)
    }

    public let connectionFactory: DaemonTransportConnectionFactory
    public let configuration: DaemonTransportConfiguration

    public init(
        connectionFactory: DaemonTransportConnectionFactory,
        configuration: DaemonTransportConfiguration = .init()
    ) {
        self.connectionFactory = connectionFactory
        self.configuration = configuration
    }

    public func assemble() async throws -> DaemonTransportRuntimeHandle {
        try await assemble(registrationOrder: Component.allCases)
    }

    internal func assemble(
        registrationOrder: [Component]
    ) async throws -> DaemonTransportRuntimeHandle {
        let context = CordisContext()
        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await context.register(try definition(for: component))
            }
            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw DaemonTransportRuntimeAssemblyError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                if case .failed(_, let failure) = try await handle.awaitSettled() {
                    throw DaemonTransportRuntimeAssemblyError.activationFailed(
                        component: component.rawValue,
                        failure: failure)
                }
            }
            return DaemonTransportRuntimeHandle(
                services: try await require(Keys.services, from: context),
                rootContext: context)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do {
                try await context.dispose()
            } catch let cleanupError {
                throw DaemonTransportRuntimeAssemblyError.assemblyAndCleanupFailed(
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
            throw DaemonTransportRuntimeAssemblyError.missingService(
                ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .connectionFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.connectionFactory)]) { activation in
                    _ = try await activation.supply(Keys.connectionFactory, value: connectionFactory)
                }
        case .configuration:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.configuration)]) { activation in
                    _ = try await activation.supply(Keys.configuration, value: configuration)
                }
        case .runtime:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.connectionFactory),
                    ServiceDependency(Keys.configuration),
                ],
                provisions: [ServiceDependency(Keys.runtime)]) { activation in
                    let runtime = DaemonTransportRuntime(
                        factory: try await activation.require(Keys.connectionFactory),
                        configuration: try await activation.require(Keys.configuration))
                    _ = try await activation.supply(Keys.runtime, value: runtime)
                    _ = try await activation.effect { _ in await runtime.stop() }
                }
        case .services:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.runtime)],
                provisions: [ServiceDependency(Keys.services)]) { activation in
                    let runtime = try await activation.require(Keys.runtime)
                    _ = try await activation.supply(
                        Keys.services,
                        value: DaemonTransportServices(runtime: runtime))
                }
        }
    }
}

public actor DaemonTransportRuntimeHandle {
    public nonisolated let services: DaemonTransportServices
    private let rootContext: CordisContext
    private var didDispose = false

    internal init(services: DaemonTransportServices, rootContext: CordisContext) {
        self.services = services
        self.rootContext = rootContext
    }

    public func dispose() async throws {
        guard !didDispose else { return }
        await services.stop()
        try await rootContext.dispose()
        didDispose = true
    }
}
#endif
