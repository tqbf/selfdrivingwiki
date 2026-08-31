#if os(macOS)
import Cordis
import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

enum RendererRuntimeFactoryError: Error, Equatable, Sendable {
    case missingService(ServiceDescriptor)
    case activationFailed(component: String, failure: CordisFailure)
    case assemblyAndCleanupFailed(assembly: CordisFailure, cleanup: CordisFailure)
}

struct RendererRuntimeFactory: Sendable {
    enum Component: String, CaseIterable, Sendable {
        case packageStoreLayout
        case machineIndexStore
        case packageValidatorFactory
        case resourceProviderFactory
        case bundledPackageSource
        case runtime
        case services
    }

    enum ServiceLabels {
        static let packageStoreLayout = "renderer.package-store-layout"
        static let machineIndexStore = "renderer.machine-index-store"
        static let packageValidatorFactory = "renderer.package-validator-factory"
        static let resourceProviderFactory = "renderer.resource-provider-factory"
        static let bundledPackageSource = "renderer.bundled-package-source"
        static let runtime = "renderer.runtime"
        static let services = "renderer.services"

        static let all = [
            packageStoreLayout,
            machineIndexStore,
            packageValidatorFactory,
            resourceProviderFactory,
            bundledPackageSource,
            runtime,
            services,
        ]
    }

    private enum Keys {
        static let packageStoreLayout = ServiceKey<RendererPackageStoreLayout>(
            label: ServiceLabels.packageStoreLayout)
        static let machineIndexStore = ServiceKey<RendererMachineIndexStore>(
            label: ServiceLabels.machineIndexStore)
        static let packageValidatorFactory = ServiceKey<RendererRuntime.ValidatorFactory>(
            label: ServiceLabels.packageValidatorFactory)
        static let resourceProviderFactory = ServiceKey<RendererRuntime.ProviderFactory>(
            label: ServiceLabels.resourceProviderFactory)
        static let bundledPackageSource = ServiceKey<RendererRuntime.BundledPackageSource>(
            label: ServiceLabels.bundledPackageSource)
        static let runtime = ServiceKey<RendererRuntime>(label: ServiceLabels.runtime)
        static let services = ServiceKey<any RendererServices>(label: ServiceLabels.services)
    }

    let layout: RendererPackageStoreLayout
    let bundledPackageSource: RendererRuntime.BundledPackageSource
    let reviewedBundledIdentity: RendererRuntime.ReviewedBundledIdentity

    func assemble() async throws -> RendererRuntimeHandle {
        try await assemble(registrationOrder: Component.allCases)
    }

    func assemble(registrationOrder: [Component]) async throws -> RendererRuntimeHandle {
        let context = CordisContext()
        do {
            var handles: [Component: ComponentHandle] = [:]
            for component in registrationOrder {
                handles[component] = try await context.register(try definition(for: component))
            }
            for component in Component.allCases {
                guard let handle = handles[component] else {
                    throw RendererRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: CordisFailure("component was not registered"))
                }
                if case .failed(_, let failure) = try await handle.awaitSettled() {
                    throw RendererRuntimeFactoryError.activationFailed(
                        component: component.rawValue,
                        failure: failure)
                }
            }
            return RendererRuntimeHandle(
                services: try await require(Keys.services, from: context),
                rootContext: context)
        } catch {
            let assemblyFailure = CordisFailure(error)
            do { try await context.dispose() }
            catch {
                throw RendererRuntimeFactoryError.assemblyAndCleanupFailed(
                    assembly: assemblyFailure,
                    cleanup: CordisFailure(error))
            }
            throw error
        }
    }

    private func require<Value: Sendable>(
        _ key: ServiceKey<Value>,
        from context: CordisContext
    ) async throws -> Value {
        guard let value = try await context.find(key) else {
            throw RendererRuntimeFactoryError.missingService(
                ServiceDependency(key).descriptor)
        }
        return value
    }

    private func definition(for component: Component) throws -> ComponentDefinition {
        switch component {
        case .packageStoreLayout:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.packageStoreLayout)]) { activation in
                    _ = try await activation.supply(Keys.packageStoreLayout, value: layout)
                }
        case .machineIndexStore:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.packageStoreLayout)],
                provisions: [ServiceDependency(Keys.machineIndexStore)]) { activation in
                    let resolvedLayout = try await activation.require(Keys.packageStoreLayout)
                    _ = try await activation.supply(
                        Keys.machineIndexStore,
                        value: RendererMachineIndexStore(
                            layout: resolvedLayout,
                            reservedFenceAliases: BuiltInRendererDescriptors.reservedFenceAliases))
                }
        case .packageValidatorFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [ServiceDependency(Keys.packageStoreLayout)],
                provisions: [ServiceDependency(Keys.packageValidatorFactory)]) { activation in
                    let resolvedLayout = try await activation.require(Keys.packageStoreLayout)
                    let reservedFenceAliases = BuiltInRendererDescriptors.reservedFenceAliases
                    let factory: RendererRuntime.ValidatorFactory = {
                        RendererPackageValidator(
                            packageRoot: resolvedLayout.root,
                            stagingRoot: resolvedLayout.stagingRoot,
                            reservedFenceAliases: reservedFenceAliases)
                    }
                    _ = try await activation.supply(Keys.packageValidatorFactory, value: factory)
                }
        case .resourceProviderFactory:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.packageStoreLayout),
                    ServiceDependency(Keys.packageValidatorFactory),
                ],
                provisions: [ServiceDependency(Keys.resourceProviderFactory)]) { activation in
                    let resolvedLayout = try await activation.require(Keys.packageStoreLayout)
                    let makeValidator = try await activation.require(Keys.packageValidatorFactory)
                    let factory: RendererRuntime.ProviderFactory = { record in
                        try ValidatedRendererPackageResourceProvider(
                            packageID: record.packageID,
                            version: record.version,
                            expectedPackageHash: record.expectedPackageHash,
                            installedRoot: resolvedLayout.packageURL(
                                packageID: record.packageID,
                                version: record.version),
                            validator: makeValidator())
                    }
                    _ = try await activation.supply(Keys.resourceProviderFactory, value: factory)
                }
        case .bundledPackageSource:
            return try ComponentDefinition(
                label: component.rawValue,
                provisions: [ServiceDependency(Keys.bundledPackageSource)]) { activation in
                    _ = try await activation.supply(
                        Keys.bundledPackageSource,
                        value: bundledPackageSource)
                }
        case .runtime:
            return try ComponentDefinition(
                label: component.rawValue,
                dependencies: [
                    ServiceDependency(Keys.machineIndexStore),
                    ServiceDependency(Keys.packageValidatorFactory),
                    ServiceDependency(Keys.resourceProviderFactory),
                    ServiceDependency(Keys.bundledPackageSource),
                ],
                provisions: [ServiceDependency(Keys.runtime)]) { activation in
                    let runtime = RendererRuntime(
                        machineStore: try await activation.require(Keys.machineIndexStore),
                        makeValidator: try await activation.require(Keys.packageValidatorFactory),
                        makeProvider: try await activation.require(Keys.resourceProviderFactory),
                        bundledPackageSource: try await activation.require(Keys.bundledPackageSource),
                        reviewedBundledIdentity: reviewedBundledIdentity)
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

protocol RendererRuntimeOwning: Sendable {
    var services: any RendererServices { get }
    func dispose() async throws
}

actor RendererRuntimeHandle: RendererRuntimeOwning {
    nonisolated let services: any RendererServices
    private let rootContext: CordisContext
    private var didDispose = false

    init(services: any RendererServices, rootContext: CordisContext) {
        self.services = services
        self.rootContext = rootContext
    }

    func dispose() async throws {
        guard !didDispose else { return }
        try await rootContext.dispose()
        didDispose = true
    }
}
#endif
