import Foundation

/// A `Sendable` handle for one actor-owned runtime context.
public struct CordisContext: Sendable {
    public let id: ContextID
    internal let runtime: CordisRuntime

    public init() {
        let runtime = CordisRuntime()
        self.id = runtime.rootContextID
        self.runtime = runtime
    }

    internal init(id: ContextID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public func child() async throws -> CordisContext {
        let childID = try await runtime.createChild(parentID: id)
        return CordisContext(id: childID, runtime: runtime)
    }

    public func find<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value? {
        try await runtime.find(key, contextID: id)
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
        try await runtime.supplyAmbient(key, value: value, contextID: id)
    }

    @discardableResult
    public func register(_ definition: ComponentDefinition) async throws -> ComponentHandle {
        try await runtime.register(definition, contextID: id)
    }

    public func diagnostics() async throws -> [ComponentDiagnostic] {
        try await runtime.diagnostics(contextID: id)
    }

    public func dispose() async throws {
        try await runtime.disposeContext(id)
    }
}
