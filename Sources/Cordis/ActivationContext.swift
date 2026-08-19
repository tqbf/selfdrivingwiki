import Foundation

/// The attempt-scoped API available during component activation.
public struct ActivationContext: Sendable {
    internal let runtime: CordisRuntime
    internal let contextID: ContextID
    internal let componentID: ComponentID
    internal let generation: UInt64

    internal init(
        runtime: CordisRuntime,
        contextID: ContextID,
        componentID: ComponentID,
        generation: UInt64
    ) {
        self.runtime = runtime
        self.contextID = contextID
        self.componentID = componentID
        self.generation = generation
    }

    public func find<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value? {
        try await runtime.findForActivation(
            key,
            contextID: contextID,
            componentID: componentID,
            generation: generation)
    }

    public func require<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value {
        guard let value = try await find(key) else {
            throw CordisError.missingService(ServiceDescriptor(key.erased))
        }
        return value
    }

    @discardableResult
    public func supply<Value: Sendable>(
        _ key: ServiceKey<Value>,
        value: Value
    ) async throws -> ProviderHandle {
        try await runtime.stageSupply(
            key,
            value: value,
            contextID: contextID,
            componentID: componentID,
            generation: generation)
    }

    @discardableResult
    public func effect(
        _ dispose: @escaping @Sendable (CleanupContext) async throws -> Void
    ) async throws -> EffectHandle {
        try await runtime.stageEffect(
            contextID: contextID,
            componentID: componentID,
            generation: generation,
            dispose: dispose)
    }
}

/// The lookup API available while one component's effects dispose.
public struct CleanupContext: Sendable {
    internal let runtime: CordisRuntime
    internal let contextID: ContextID
    internal let componentID: ComponentID

    internal init(runtime: CordisRuntime, contextID: ContextID, componentID: ComponentID) {
        self.runtime = runtime
        self.contextID = contextID
        self.componentID = componentID
    }

    public func find<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value? {
        try await runtime.findForCleanup(
            key,
            contextID: contextID,
            componentID: componentID)
    }

    public func require<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value {
        guard let value = try await find(key) else {
            throw CordisError.missingService(ServiceDescriptor(key.erased))
        }
        return value
    }
}
