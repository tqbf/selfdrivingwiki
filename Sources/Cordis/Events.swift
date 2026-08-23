import Foundation

/// Typed event dispatch on a context. The mode is part of each key's type:
/// these overloads only accept keys whose mode matches the call.
extension CordisContext {
    // MARK: Registration

    /// Registers a reversible listener owned by this context (ambient). The
    /// listener is removed when the handle is disposed or the context is
    /// disposed.
    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, EmitMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimpleAmbient(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, SerialMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimpleAmbient(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, ParallelMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimpleAmbient(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, BailMode>,
        listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await registerSimpleAmbient(key, listener)
    }

    @discardableResult
    public func on<P: Sendable>(
        _ key: EventKey<P, WaterfallMode>,
        listener: @escaping @Sendable (P, _ next: @Sendable () async throws -> P) async throws -> P
    ) async throws -> ListenerHandle {
        try await runtime.attachAmbientListener(
            contextID: id,
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

    private func registerSimpleAmbient<P: Sendable>(
        _ key: EventKey<P, some EventDispatchMode>,
        _ listener: @escaping @Sendable (P) async throws -> Void
    ) async throws -> ListenerHandle {
        try await runtime.attachAmbientListener(
            contextID: id,
            key: key.erased,
            simple: { payload in
                guard let typed = payload as? P else {
                    throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
                }
                try await listener(typed)
            },
            waterfall: nil)
    }

    // MARK: Dispatch

    /// Best-effort notification: listeners run sequentially and their errors
    /// are ignored by contract.
    public func emit<P: Sendable>(_ key: EventKey<P, EmitMode>, _ payload: P) async {
        // Emit mode ignores listener errors by contract; payload/context
        // failures have no listener to report to.
        // swiftlint:disable:next silent_try_optional
        _ = try? await runtime.dispatch(key.erased, payload: payload, contextID: id)
    }

    /// Sequential dispatch; the first listener error propagates.
    public func emit<P: Sendable>(_ key: EventKey<P, SerialMode>, _ payload: P) async throws {
        _ = try await runtime.dispatch(key.erased, payload: payload, contextID: id)
    }

    /// Concurrent dispatch; all listeners must finish; the first error
    /// propagates after the group settles.
    public func emit<P: Sendable>(_ key: EventKey<P, ParallelMode>, _ payload: P) async throws {
        _ = try await runtime.dispatch(key.erased, payload: payload, contextID: id)
    }

    /// Concurrent dispatch; the first listener to settle decides the outcome
    /// and the rest are cancelled.
    public func emit<P: Sendable>(_ key: EventKey<P, BailMode>, _ payload: P) async throws {
        _ = try await runtime.dispatch(key.erased, payload: payload, contextID: id)
    }

    /// Pass-through dispatch: each listener receives `next` to continue the
    /// chain; omitting `next` short-circuits everything downstream.
    @discardableResult
    public func waterfall<P: Sendable>(_ key: EventKey<P, WaterfallMode>, _ payload: P) async throws -> P {
        let result = try await runtime.dispatch(key.erased, payload: payload, contextID: id)
        guard let typed = result as? P else {
            throw CordisError.eventPayloadMismatch(EventDescriptor(key.erased))
        }
        return typed
    }
}
