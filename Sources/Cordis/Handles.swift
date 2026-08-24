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

    // MARK: Mid-flight listeners and effects

    /// Registers a reversible listener owned by this component. The listener
    /// is removed when the component unloads (LIFO) or the handle is disposed.
    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, EmitMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimple(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, SerialMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimple(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, ParallelMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimple(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, BailMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimple(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, WaterfallMode>,
        listener: @escaping @Sendable (P, _ next: @Sendable () async throws -> P) async throws -> P
    ) async throws -> ListenerHandle {
        let contextID = try await runtime.contextID(ofComponent: id)
        return try await runtime.attachListener(
            contextID: contextID,
            componentID: id,
            key: key.erased,
            simple: nil,
            waterfall: { payload, next in
                guard let typed = payload as? P else {
                    throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
                }
                return try await listener(typed) {
                    guard let nextTyped = try await next(typed) as? P else {
                        throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
                    }
                    return nextTyped
                }
            })
    }

    private func registerSimple<P: Sendable>(
        _ key: EventKey<P, some EventDispatchMode>,
        _ listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        let contextID = try await runtime.contextID(ofComponent: id)
        return try await runtime.attachListener(
            contextID: contextID,
            componentID: id,
            key: key.erased,
            simple: { payload in
                guard let typed = payload as? P else {
                    throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
                }
                try await listener(typed)
            },
            waterfall: nil)
    }

    /// Registers a cleanup effect for an already-active component; the effect
    /// runs (LIFO) when the component unloads.
    @discardableResult
    public func effect(
        _ dispose: @escaping @Sendable (CleanupContext) async throws -> Void
    ) async throws -> EffectHandle {
        let contextID = try await runtime.contextID(ofComponent: id)
        return try await runtime.attachEffect(
            contextID: contextID,
            componentID: id,
            dispose: dispose)
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

/// A handle for one reversible event listener.
public struct ListenerHandle: Sendable {
    public let id: ListenerID
    internal let runtime: CordisRuntime

    internal init(id: ListenerID, runtime: CordisRuntime) {
        self.id = id
        self.runtime = runtime
    }

    public func dispose() async throws {
        try await runtime.removeListener(id)
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
