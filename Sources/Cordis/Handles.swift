import Foundation

/// A handle for one component declaration.
public struct ComponentHandle: Sendable {
    public let id: ComponentID
    internal let runtime: CordisRuntime

    internal init(id: ComponentID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public var state: ComponentState {
        get async throws {
            try await runtime.componentState(id)
        }
    }

    public var stateHistory: [ComponentState.Kind] {
        get async throws {
            try await runtime.componentStateHistory(id)
        }
    }

    public var cleanupFailures: [CleanupFailure] {
        get async throws {
            try await runtime.componentCleanupFailures(id)
        }
    }

    @discardableResult
    public func awaitSettled() async throws -> ComponentState {
        try await runtime.awaitComponentSettled(id)
    }

    @discardableResult
    public func restart() async throws -> ComponentState {
        try await runtime.restartComponent(id)
        return try await awaitSettled()
    }

    public func dispose() async throws {
        try await runtime.disposeComponent(id)
    }
}

/// A handle for one ambient or component-owned provider.
public struct ProviderHandle: Sendable {
    public let id: ProviderID
    internal let runtime: CordisRuntime

    internal init(id: ProviderID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public func dispose() async throws {
        try await runtime.disposeProvider(id)
    }
}

/// A handle for one component-owned cleanup effect.
public struct EffectHandle: Sendable {
    public let id: EffectID
    internal let runtime: CordisRuntime

    internal init(id: EffectID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public func dispose() async throws {
        try await runtime.disposeEffect(id)
    }
}
