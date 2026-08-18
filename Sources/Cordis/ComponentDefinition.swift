import Foundation

/// A type-erased dependency declaration.
public struct ServiceDependency: Hashable, Sendable {
    internal let key: AnyServiceKey

    public init<Value: Sendable>(_ key: ServiceKey<Value>) {
        self.key = key.erased
    }

    public var descriptor: ServiceDescriptor {
        ServiceDescriptor(key)
    }
}

/// A dormant component declaration.
public struct ComponentDefinition: Sendable {
    public typealias Activation = @Sendable (ActivationContext) async throws -> Void

    public let id: ComponentID
    public let label: String
    public let dependencies: [ServiceDependency]
    public let provisions: [ServiceDependency]
    internal let activation: Activation

    public init(
        id: ComponentID = ComponentID(),
        label: String,
        dependencies: [ServiceDependency] = [],
        provisions: [ServiceDependency] = [],
        activation: @escaping Activation
    ) throws {
        let dependencyKeys = dependencies.map(\.key)
        guard Set(dependencyKeys).count == dependencyKeys.count else {
            let duplicate = dependencyKeys.first { key in
                dependencyKeys.filter { $0 == key }.count > 1
            }
            let duplicateLabel = duplicate?.label ?? "unknown"
            throw CordisError.invalidDefinition(
                componentID: id,
                reason: "duplicate dependency: \(duplicateLabel)")
        }
        let provisionKeys = provisions.map(\.key)
        guard Set(provisionKeys).count == provisionKeys.count else {
            let duplicate = provisionKeys.first { key in
                provisionKeys.filter { $0 == key }.count > 1
            }
            let duplicateLabel = duplicate?.label ?? "unknown"
            throw CordisError.invalidDefinition(
                componentID: id,
                reason: "duplicate provision: \(duplicateLabel)")
        }
        if let selfCycle = Set(dependencyKeys).intersection(provisionKeys).first {
            throw CordisError.cycle(
                componentID: id,
                service: ServiceDescriptor(selfCycle))
        }
        self.id = id
        self.label = label
        self.dependencies = dependencies
        self.provisions = provisions
        self.activation = activation
    }
}
