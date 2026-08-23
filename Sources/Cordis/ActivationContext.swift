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

    // MARK: Events

    /// Best-effort notification dispatched from this activation's context.
    /// Listener errors are ignored by the emit-mode contract.
    public func emit<P: Sendable>(_ key: EventKey<P, EmitMode>, _ payload: P) async {
        // swiftlint:disable:next silent_try_optional
        _ = try? await runtime.dispatch(key.erased, payload: payload, contextID: contextID)
    }

    /// Registers a reversible listener staged with this activation attempt.
    /// It is committed when activation succeeds and removed when the component
    /// unloads (LIFO).
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
        try await runtime.stageListener(
            contextID: contextID,
            componentID: componentID,
            generation: generation,
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
        try await runtime.stageListener(
            contextID: contextID,
            componentID: componentID,
            generation: generation,
            key: key.erased,
            simple: { payload in
                guard let typed = payload as? P else {
                    throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
                }
                try await listener(typed)
            },
            waterfall: nil)
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
