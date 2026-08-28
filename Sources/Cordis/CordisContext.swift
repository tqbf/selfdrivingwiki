import Foundation
import WikiFSTypes

public enum ProcessScopeRole: String, Sendable, Equatable, CaseIterable {
    case app
    case daemon
    case commandLine
    case standalone
}

/// Immutable diagnostic metadata for a Cordis context.
/// `ContextID`, not this value, remains the runtime identity.
public enum ScopeDescriptor: Sendable, Equatable {
    case process(ProcessScopeRole)
    case wiki(WikiID)
}

public enum ScopeLifecycleState: Sendable, Equatable {
    case live
    case disposing
    case disposed
}

/// An immutable view of actor-owned context metadata.
public struct ScopeDiagnosticsSnapshot: Sendable, Equatable {
    public let contextID: ContextID
    public let parentContextID: ContextID?
    public let descriptor: ScopeDescriptor?
    public let parentDescriptor: ScopeDescriptor?
    public let lifecycle: ScopeLifecycleState
    public let activeChildCount: Int
    public let activeRegistrationCount: Int
    public let retainedComponentRecordCount: Int

    internal init(
        contextID: ContextID,
        parentContextID: ContextID?,
        descriptor: ScopeDescriptor?,
        parentDescriptor: ScopeDescriptor?,
        lifecycle: ScopeLifecycleState,
        activeChildCount: Int,
        activeRegistrationCount: Int,
        retainedComponentRecordCount: Int
    ) {
        self.contextID = contextID
        self.parentContextID = parentContextID
        self.descriptor = descriptor
        self.parentDescriptor = parentDescriptor
        self.lifecycle = lifecycle
        self.activeChildCount = activeChildCount
        self.activeRegistrationCount = activeRegistrationCount
        self.retainedComponentRecordCount = retainedComponentRecordCount
    }
}

public enum ScopeDescriptorError: Error, Sendable, Equatable {
    case processRequiresRoot
    case wikiRequiresProcessParent
}

/// A `Sendable` handle for one actor-owned runtime context.
public struct CordisContext: Sendable {
    public let id: ContextID
    internal let runtime: CordisRuntime

    public init() {
        let runtime = CordisRuntime(descriptor: nil)
        self.id = runtime.rootContextID
        self.runtime = runtime
    }

    public init(descriptor: ScopeDescriptor) throws {
        guard case .process = descriptor else {
            throw ScopeDescriptorError.wikiRequiresProcessParent
        }
        let runtime = CordisRuntime(descriptor: descriptor)
        self.id = runtime.rootContextID
        self.runtime = runtime
    }

    internal init(id: ContextID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public func child() async throws -> CordisContext {
        try await child(descriptor: nil)
    }

    public func child(descriptor: ScopeDescriptor?) async throws -> CordisContext {
        let childID = try await runtime.createChild(parentID: id, descriptor: descriptor)
        return CordisContext(id: childID, runtime: runtime)
    }

    public func scopeDiagnostics() async throws -> ScopeDiagnosticsSnapshot {
        try await runtime.scopeDiagnostics(contextID: id)
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
