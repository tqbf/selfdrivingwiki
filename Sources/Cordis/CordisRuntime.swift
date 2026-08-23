import Foundation

internal enum ContextLifecycle: Sendable {
    case live
    case disposing
    case disposed
}

internal struct ContextRecord: Sendable {
    let id: ContextID
    let parentID: ContextID?
    var childIDs: [ContextID] = []
    var componentIDs: [ComponentID] = []
    var listenerIDs: [ListenerID] = []
    var providers: [AnyServiceKey: ProviderID] = [:]
    var lifecycle: ContextLifecycle = .live
    var disposalWaiters: [CheckedContinuation<[CleanupFailure], Never>] = []
    var cleanupFailures: [CleanupFailure] = []
}

internal enum ProviderOwner: Sendable {
    case ambient
    case component(ComponentID)
}

internal enum ProviderLifecycle: Sendable {
    case active
    case withdrawing
}

internal struct ProviderRecord: Sendable {
    let id: ProviderID
    let key: AnyServiceKey
    let contextID: ContextID
    let owner: ProviderOwner
    let value: any Sendable
    var lifecycle: ProviderLifecycle
}

internal struct StagedSupply: Sendable {
    let id: ProviderID
    let key: AnyServiceKey
    let value: any Sendable
}

internal struct StagedEffect: Sendable {
    let id: EffectID
    let dispose: @Sendable (CleanupContext) async throws -> Void
}

internal struct StagedListener: Sendable {
    let id: ListenerID
    let key: AnyEventKey
    let simple: AnySimpleListener?
    let waterfall: AnyWaterfallListener?
}

internal enum ListenerOwner: Sendable {
    case ambient
    case component(ComponentID)
}

internal struct ListenerRecord: Sendable {
    let id: ListenerID
    let key: AnyEventKey
    let contextID: ContextID
    let owner: ListenerOwner
    let simple: AnySimpleListener?
    let waterfall: AnyWaterfallListener?
}

internal struct ActivationAttempt: Sendable {
    let generation: UInt64
    let dependencyProviders: [AnyServiceKey: ProviderID]
    var supplies: [StagedSupply] = []
    var effects: [StagedEffect] = []
    var listeners: [StagedListener] = []
}

internal struct EffectRecord: Sendable {
    let id: EffectID
    let contextID: ContextID
    let componentID: ComponentID
    let dispose: @Sendable (CleanupContext) async throws -> Void
}

internal struct ComponentRecord: Sendable {
    let definition: ComponentDefinition
    let contextID: ContextID
    var state: ComponentState = .pending(generation: 0)
    var stateHistory: [ComponentState.Kind] = [.pending]
    var dependencyProviders: [AnyServiceKey: ProviderID] = [:]
    var committedProviderIDs: [ProviderID] = []
    var listenerIDs: [ListenerID] = []
    var effectIDs: [EffectID] = []
    var attempt: ActivationAttempt?
    var task: Task<Void, Never>?
    var settlementWaiters: [CheckedContinuation<ComponentState, Never>] = []
    var lastCleanupFailures: [CleanupFailure] = []
    var lastFailureProviders: [AnyServiceKey: ProviderID]?
    /// Once requested, the current unload must settle this component as disposed.
    /// A nonpermanent provider withdrawal cannot clear this intent.
    var permanentDisposalRequested = false
}

/// The actor that owns one complete Cordis context tree.
internal actor CordisRuntime {
    nonisolated let rootContextID: ContextID

    private var contexts: [ContextID: ContextRecord]
    private var components: [ComponentID: ComponentRecord] = [:]
    private var providers: [ProviderID: ProviderRecord] = [:]
    private var effects: [EffectID: EffectRecord] = [:]
    private var listeners: [ListenerID: ListenerRecord] = [:]
    private var disposedProviderIDs: Set<ProviderID> = []
    private var disposedEffectIDs: Set<EffectID> = []

    init() {
        let rootID = ContextID()
        rootContextID = rootID
        contexts = [rootID: ContextRecord(id: rootID, parentID: nil)]
    }

    // MARK: Context tree

    func createChild(parentID: ContextID) throws -> ContextID {
        try requireLiveContext(parentID)
        let childID = ContextID()
        contexts[childID] = ContextRecord(id: childID, parentID: parentID)
        contexts[parentID]?.childIDs.append(childID)
        return childID
    }

    func disposeContext(_ contextID: ContextID) async throws {
        guard let context = contexts[contextID] else {
            throw CordisError.disposedContext(contextID)
        }
        let failures: [CleanupFailure]
        switch context.lifecycle {
        case .live:
            failures = await disposeContextInternal(contextID)
        case .disposing:
            failures = await withCheckedContinuation { continuation in
                contexts[contextID]?.disposalWaiters.append(continuation)
            }
        case .disposed:
            failures = []
        }
        if !failures.isEmpty {
            throw CordisError.cleanup(CleanupAggregateError(failures: failures))
        }
    }

    private func disposeContextInternal(_ contextID: ContextID) async -> [CleanupFailure] {
        guard var context = contexts[contextID] else { return [] }
        switch context.lifecycle {
        case .disposed:
            return []
        case .disposing:
            return await withCheckedContinuation { continuation in
                contexts[contextID]?.disposalWaiters.append(continuation)
            }
        case .live:
            break
        }
        context.lifecycle = .disposing
        contexts[contextID] = context

        var failures: [CleanupFailure] = []
        for childID in context.childIDs.reversed() {
            failures += await disposeContextInternal(childID)
        }
        for componentID in context.componentIDs.reversed() {
            failures += await unloadComponent(componentID, permanently: true, visiting: [])
        }
        let ambientProviderIDs = context.providers.values.compactMap { providerID -> ProviderID? in
            guard case .ambient? = providers[providerID]?.owner else { return nil }
            return providerID
        }
        for providerID in ambientProviderIDs.reversed() {
            failures += await withdrawProvider(providerID, visiting: [])
        }

        contexts[contextID]?.providers.removeAll()
        for listenerID in context.listenerIDs {
            listeners.removeValue(forKey: listenerID)
        }
        contexts[contextID]?.listenerIDs.removeAll()
        contexts[contextID]?.lifecycle = .disposed
        contexts[contextID]?.cleanupFailures = failures
        let waiters = contexts[contextID]?.disposalWaiters ?? []
        contexts[contextID]?.disposalWaiters.removeAll()
        if let parentID = context.parentID {
            contexts[parentID]?.childIDs.removeAll { $0 == contextID }
        }
        for waiter in waiters { waiter.resume(returning: failures) }
        return failures
    }

    // MARK: Lookup

    func find<Value: Sendable>(
        _ key: ServiceKey<Value>,
        contextID: ContextID
    ) throws -> Value? {
        try requireLiveContext(contextID)
        return try typedValue(
            for: resolveProvider(key.erased, from: contextID, includeWithdrawing: false),
            key: key)
    }

    func findForActivation<Value: Sendable>(
        _ key: ServiceKey<Value>,
        contextID: ContextID,
        componentID: ComponentID,
        generation: UInt64
    ) throws -> Value? {
        guard let component = components[componentID],
              component.contextID == contextID,
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              let attempt = component.attempt,
              attempt.generation == generation else {
            throw CordisError.inactiveActivation(componentID)
        }
        if attempt.supplies.contains(where: { $0.key == key.erased }) {
            throw CordisError.cycle(
                componentID: componentID,
                service: ServiceDescriptor(key.erased))
        }
        return try typedValue(
            for: resolveProvider(key.erased, from: contextID, includeWithdrawing: false),
            key: key)
    }

    func findForCleanup<Value: Sendable>(
        _ key: ServiceKey<Value>,
        contextID: ContextID,
        componentID: ComponentID
    ) throws -> Value? {
        guard contexts[contextID] != nil else {
            throw CordisError.disposedContext(contextID)
        }
        var currentID: ContextID? = contextID
        while let candidateID = currentID, let context = contexts[candidateID] {
            if let providerID = context.providers[key.erased],
               let provider = providers[providerID],
               provider.lifecycle == .active || provider.lifecycle == .withdrawing {
                if case .component(let ownerID) = provider.owner, ownerID == componentID {
                    currentID = context.parentID
                    continue
                }
                guard let value = provider.value as? Value else {
                    throw CordisError.typeMismatch(ServiceDescriptor(key.erased))
                }
                return value
            }
            currentID = context.parentID
        }
        return nil
    }

    private func typedValue<Value: Sendable>(
        for provider: ProviderRecord?,
        key: ServiceKey<Value>
    ) throws -> Value? {
        guard let provider else { return nil }
        guard let value = provider.value as? Value else {
            throw CordisError.typeMismatch(ServiceDescriptor(key.erased))
        }
        return value
    }

    private func resolveProvider(
        _ key: AnyServiceKey,
        from contextID: ContextID,
        includeWithdrawing: Bool
    ) -> ProviderRecord? {
        var currentID: ContextID? = contextID
        while let candidateID = currentID, let context = contexts[candidateID] {
            if let providerID = context.providers[key],
               let provider = providers[providerID],
               provider.lifecycle == .active || includeWithdrawing {
                return provider
            }
            currentID = context.parentID
        }
        return nil
    }

    // MARK: Providers

    func supplyAmbient<Value: Sendable>(
        _ key: ServiceKey<Value>,
        value: Value,
        contextID: ContextID
    ) throws -> ProviderHandle {
        try requireLiveContext(contextID)
        if contexts[contextID]?.providers[key.erased] != nil {
            throw CordisError.duplicateSupply(ServiceDescriptor(key.erased))
        }
        let providerID = ProviderID()
        providers[providerID] = ProviderRecord(
            id: providerID,
            key: key.erased,
            contextID: contextID,
            owner: .ambient,
            value: value,
            lifecycle: .active)
        contexts[contextID]?.providers[key.erased] = providerID
        reevaluateAllComponents()
        return ProviderHandle(id: providerID, runtime: self)
    }

    func stageSupply<Value: Sendable>(
        _ key: ServiceKey<Value>,
        value: Value,
        contextID: ContextID,
        componentID: ComponentID,
        generation: UInt64
    ) throws -> ProviderHandle {
        guard var component = components[componentID],
              component.contextID == contextID,
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              var attempt = component.attempt,
              attempt.generation == generation else {
            throw CordisError.inactiveActivation(componentID)
        }
        guard component.definition.provisions.contains(where: { $0.key == key.erased }) else {
            throw CordisError.invalidDefinition(
                componentID: componentID,
                reason: "undeclared provision: \(key.label)")
        }
        if component.definition.dependencies.contains(where: { $0.key == key.erased }) {
            throw CordisError.cycle(
                componentID: componentID,
                service: ServiceDescriptor(key.erased))
        }
        if attempt.supplies.contains(where: { $0.key == key.erased }) {
            throw CordisError.duplicateSupply(ServiceDescriptor(key.erased))
        }
        let providerID = ProviderID()
        attempt.supplies.append(StagedSupply(id: providerID, key: key.erased, value: value))
        component.attempt = attempt
        components[componentID] = component
        return ProviderHandle(id: providerID, runtime: self)
    }

    func disposeProvider(_ providerID: ProviderID) async throws {
        if disposedProviderIDs.contains(providerID) { return }
        for componentID in components.keys {
            guard var component = components[componentID], var attempt = component.attempt else {
                continue
            }
            if attempt.supplies.contains(where: { $0.id == providerID }) {
                attempt.supplies.removeAll { $0.id == providerID }
                component.attempt = attempt
                components[componentID] = component
                disposedProviderIDs.insert(providerID)
                return
            }
        }
        guard let provider = providers[providerID] else {
            throw CordisError.inactiveProvider(providerID)
        }
        let failures: [CleanupFailure]
        switch provider.owner {
        case .ambient:
            failures = await withdrawProvider(providerID, visiting: [])
        case .component(let ownerID):
            // A committed provision is part of its owner's active transaction.
            // Removing only the provider would leave the owner active but invalid.
            failures = await unloadComponent(ownerID, permanently: true, visiting: [])
        }
        reevaluateAllComponents()
        if !failures.isEmpty {
            throw CordisError.cleanup(CleanupAggregateError(failures: failures))
        }
    }

    private func withdrawProvider(
        _ providerID: ProviderID,
        visiting: Set<ComponentID>
    ) async -> [CleanupFailure] {
        guard var provider = providers[providerID] else {
            disposedProviderIDs.insert(providerID)
            return []
        }
        provider.lifecycle = .withdrawing
        providers[providerID] = provider

        let consumers = components.values
            .filter { component in
                component.dependencyProviders.values.contains(providerID)
                    || component.attempt?.dependencyProviders.values.contains(providerID) == true
            }
            .map { $0.definition.id }
        var failures: [CleanupFailure] = []
        for componentID in consumers {
            failures += await unloadComponent(componentID, permanently: false, visiting: visiting)
        }

        if contexts[provider.contextID]?.providers[provider.key] == providerID {
            contexts[provider.contextID]?.providers.removeValue(forKey: provider.key)
        }
        providers.removeValue(forKey: providerID)
        disposedProviderIDs.insert(providerID)
        return failures
    }

    // MARK: Component registration and activation

    func register(
        _ definition: ComponentDefinition,
        contextID: ContextID
    ) throws -> ComponentHandle {
        try requireLiveContext(contextID)
        guard components[definition.id] == nil else {
            throw CordisError.invalidDefinition(
                componentID: definition.id,
                reason: "component ID is already registered")
        }
        components[definition.id] = ComponentRecord(
            definition: definition,
            contextID: contextID)
        contexts[contextID]?.componentIDs.append(definition.id)
        reevaluateAllComponents()
        return ComponentHandle(id: definition.id, runtime: self)
    }

    func componentState(_ componentID: ComponentID) throws -> ComponentState {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        return component.state
    }

    func contextID(ofComponent componentID: ComponentID) throws -> ContextID {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        return component.contextID
    }

    func componentStateHistory(_ componentID: ComponentID) throws -> [ComponentState.Kind] {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        return component.stateHistory
    }

    func componentCleanupFailures(_ componentID: ComponentID) throws -> [CleanupFailure] {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        return component.lastCleanupFailures
    }

    func awaitComponentSettled(_ componentID: ComponentID) async throws -> ComponentState {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        if component.state.isSettled {
            return component.state
        }
        return await withCheckedContinuation { continuation in
            guard var latest = components[componentID] else {
                continuation.resume(returning: .disposed(generation: component.state.generation))
                return
            }
            if latest.state.isSettled {
                continuation.resume(returning: latest.state)
            } else {
                latest.settlementWaiters.append(continuation)
                components[componentID] = latest
            }
        }
    }

    func restartComponent(_ componentID: ComponentID) throws {
        guard var component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        try requireLiveContext(component.contextID)
        guard component.state.kind == .failed || component.state.kind == .pending else {
            throw CordisError.invalidTransition(
                componentID: componentID,
                from: component.state.kind,
                to: .loading)
        }
        component.lastFailureProviders = nil
        components[componentID] = component
        reevaluateAllComponents()
    }

    func disposeComponent(_ componentID: ComponentID) async throws {
        guard let component = components[componentID] else {
            throw CordisError.disposedComponent(componentID)
        }
        if component.state.kind == .disposed { return }
        let failures = await unloadComponent(componentID, permanently: true, visiting: [])
        reevaluateAllComponents()
        if !failures.isEmpty {
            throw CordisError.cleanup(CleanupAggregateError(failures: failures))
        }
    }

    private func reevaluateAllComponents() {
        let componentIDs = Array(components.keys)
        for componentID in componentIDs {
            guard let component = components[componentID],
                  contexts[component.contextID]?.lifecycle == .live,
                  component.task == nil,
                  component.state.kind == .pending || component.state.kind == .failed,
                  let dependencyProviders = resolvedDependencies(for: component) else {
                continue
            }
            if component.state.kind == .failed,
               component.lastFailureProviders == dependencyProviders {
                continue
            }
            startActivation(componentID, dependencyProviders: dependencyProviders)
        }
    }

    private func resolvedDependencies(
        for component: ComponentRecord
    ) -> [AnyServiceKey: ProviderID]? {
        var result: [AnyServiceKey: ProviderID] = [:]
        for dependency in component.definition.dependencies {
            guard let provider = resolveProvider(
                dependency.key,
                from: component.contextID,
                includeWithdrawing: false) else {
                return nil
            }
            result[dependency.key] = provider.id
        }
        return result
    }

    private func startActivation(
        _ componentID: ComponentID,
        dependencyProviders: [AnyServiceKey: ProviderID]
    ) {
        guard var component = components[componentID] else { return }
        let generation = component.state.generation + 1
        guard transition(&component, to: .loading(generation: generation)) else { return }
        component.attempt = ActivationAttempt(
            generation: generation,
            dependencyProviders: dependencyProviders)
        let definition = component.definition
        let contextID = component.contextID
        let activationContext = ActivationContext(
            runtime: self,
            contextID: contextID,
            componentID: componentID,
            generation: generation)
        let task = Task<Void, Never> { [runtime = self] in
            do {
                try await Self.runActivation(
                    definition.activation,
                    context: activationContext)
                await runtime.activationSucceeded(
                    componentID: componentID,
                    generation: generation)
            } catch {
                await runtime.activationFailed(
                    componentID: componentID,
                    generation: generation,
                    failure: CordisFailure(error))
            }
        }
        component.task = task
        components[componentID] = component
    }

    private func activationSucceeded(componentID: ComponentID, generation: UInt64) async {
        guard var component = components[componentID],
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              let attempt = component.attempt,
              attempt.generation == generation else {
            return
        }
        let dependenciesStillMatch = resolvedDependencies(for: component) == attempt.dependencyProviders
        let suppliesDoNotConflict = attempt.supplies.allSatisfy {
            contexts[component.contextID]?.providers[$0.key] == nil
        }
        guard dependenciesStillMatch,
              contexts[component.contextID]?.lifecycle == .live else {
            component.attempt = nil
            component.task = nil
            _ = transition(&component, to: .pending(generation: generation))
            components[componentID] = component
            let failures = await disposeStagedEffects(
                attempt.effects,
                contextID: component.contextID,
                componentID: componentID)
            components[componentID]?.lastCleanupFailures = failures
            settleComponent(componentID)
            reevaluateAllComponents()
            return
        }
        guard suppliesDoNotConflict else {
            component.attempt = nil
            component.task = nil
            component.lastFailureProviders = attempt.dependencyProviders
            _ = transition(
                &component,
                to: .failed(
                    generation: generation,
                    failure: CordisFailure("component supply conflicts with a live local provider")))
            components[componentID] = component
            let failures = await disposeStagedEffects(
                attempt.effects,
                contextID: component.contextID,
                componentID: componentID)
            components[componentID]?.lastCleanupFailures = failures
            settleComponent(componentID)
            return
        }

        var providerIDs: [ProviderID] = []
        for supply in attempt.supplies {
            providers[supply.id] = ProviderRecord(
                id: supply.id,
                key: supply.key,
                contextID: component.contextID,
                owner: .component(componentID),
                value: supply.value,
                lifecycle: .active)
            contexts[component.contextID]?.providers[supply.key] = supply.id
            providerIDs.append(supply.id)
        }
        var effectIDs: [EffectID] = []
        for effect in attempt.effects {
            effects[effect.id] = EffectRecord(
                id: effect.id,
                contextID: component.contextID,
                componentID: componentID,
                dispose: effect.dispose)
            effectIDs.append(effect.id)
        }
        var listenerIDs: [ListenerID] = []
        for listener in attempt.listeners {
            listeners[listener.id] = ListenerRecord(
                id: listener.id,
                key: listener.key,
                contextID: component.contextID,
                owner: .component(componentID),
                simple: listener.simple,
                waterfall: listener.waterfall)
            listenerIDs.append(listener.id)
            contexts[component.contextID]?.listenerIDs.append(listener.id)
        }
        component.dependencyProviders = attempt.dependencyProviders
        component.committedProviderIDs = providerIDs
        component.listenerIDs = listenerIDs
        component.effectIDs = effectIDs
        component.attempt = nil
        component.task = nil
        component.lastCleanupFailures = []
        component.lastFailureProviders = nil
        _ = transition(&component, to: .active(generation: generation))
        components[componentID] = component
        settleComponent(componentID)
        reevaluateAllComponents()
    }

    private func activationFailed(
        componentID: ComponentID,
        generation: UInt64,
        failure: CordisFailure
    ) async {
        guard var component = components[componentID],
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              let attempt = component.attempt,
              attempt.generation == generation else {
            return
        }
        component.attempt = nil
        component.task = nil
        component.lastFailureProviders = attempt.dependencyProviders
        _ = transition(&component, to: .failed(generation: generation, failure: failure))
        components[componentID] = component
        let failures = await disposeStagedEffects(
            attempt.effects,
            contextID: component.contextID,
            componentID: componentID)
        components[componentID]?.lastCleanupFailures = failures
        settleComponent(componentID)
    }

    // MARK: Listeners and event dispatch

    func stageListener(
        contextID: ContextID,
        componentID: ComponentID,
        generation: UInt64,
        key: AnyEventKey,
        simple: AnySimpleListener?,
        waterfall: AnyWaterfallListener?
    ) throws -> ListenerHandle {
        guard var component = components[componentID],
              component.contextID == contextID,
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              var attempt = component.attempt,
              attempt.generation == generation else {
            throw CordisError.inactiveActivation(componentID)
        }
        let listenerID = ListenerID()
        attempt.listeners.append(StagedListener(
            id: listenerID,
            key: key,
            simple: simple,
            waterfall: waterfall))
        component.attempt = attempt
        components[componentID] = component
        return ListenerHandle(id: listenerID, runtime: self)
    }

    func attachListener(
        contextID: ContextID,
        componentID: ComponentID,
        key: AnyEventKey,
        simple: AnySimpleListener?,
        waterfall: AnyWaterfallListener?
    ) throws -> ListenerHandle {
        try requireLiveContext(contextID)
        guard let component = components[componentID],
              component.contextID == contextID,
              component.state.kind == .active else {
            throw CordisError.inactiveActivation(componentID)
        }
        let listenerID = ListenerID()
        listeners[listenerID] = ListenerRecord(
            id: listenerID,
            key: key,
            contextID: contextID,
            owner: .component(componentID),
            simple: simple,
            waterfall: waterfall)
        contexts[contextID]?.listenerIDs.append(listenerID)
        components[componentID]?.listenerIDs.append(listenerID)
        return ListenerHandle(id: listenerID, runtime: self)
    }

    func attachAmbientListener(
        contextID: ContextID,
        key: AnyEventKey,
        simple: AnySimpleListener?,
        waterfall: AnyWaterfallListener?
    ) throws -> ListenerHandle {
        try requireLiveContext(contextID)
        let listenerID = ListenerID()
        listeners[listenerID] = ListenerRecord(
            id: listenerID,
            key: key,
            contextID: contextID,
            owner: .ambient,
            simple: simple,
            waterfall: waterfall)
        contexts[contextID]?.listenerIDs.append(listenerID)
        return ListenerHandle(id: listenerID, runtime: self)
    }

    func removeListener(_ listenerID: ListenerID) throws {
        guard let record = listeners.removeValue(forKey: listenerID) else {
            throw CordisError.unknownListener(listenerID)
        }
        contexts[record.contextID]?.listenerIDs.removeAll { $0 == listenerID }
        if case .component(let ownerID) = record.owner {
            components[ownerID]?.listenerIDs.removeAll { $0 == listenerID }
        }
    }

    func dispatch(
        _ key: AnyEventKey,
        payload: any Sendable,
        contextID: ContextID
    ) async throws -> (any Sendable)? {
        try requireLiveContext(contextID)
        guard ObjectIdentifier(type(of: payload)) == key.payloadTypeIdentity else {
            throw CordisError.eventPayloadMismatch(EventDescriptor(key))
        }
        let matched = collectListeners(key, from: contextID)
        switch key.modeKind {
        case .emit:
            for record in matched {
                guard let simple = record.simple else {
                    throw CordisError.eventListenerMismatch(EventDescriptor(key))
                }
                // Emit is best-effort notification: listener errors are part of
                // the contract to ignore.
                // swiftlint:disable:next silent_try_optional
                try? await simple(payload)
            }
            return nil
        case .serial:
            for record in matched {
                guard let simple = record.simple else {
                    throw CordisError.eventListenerMismatch(EventDescriptor(key))
                }
                try await simple(payload)
            }
            return nil
        case .parallel:
            var firstError: CordisFailure?
            await withTaskGroup(of: Result<Void, CordisFailure>.self) { group in
                for record in matched {
                    guard let simple = record.simple else {
                        firstError = CordisFailure(
                            String(describing: CordisError.eventListenerMismatch(EventDescriptor(key))))
                        return
                    }
                    group.addTask {
                        do {
                            try await simple(payload)
                            return .success(())
                        } catch {
                            return .failure(CordisFailure(error))
                        }
                    }
                }
                for await result in group {
                    if case .failure(let failure) = result, firstError == nil {
                        firstError = failure
                    }
                }
            }
            if let firstError {
                throw firstError
            }
            return nil
        case .bail:
            try await withThrowingTaskGroup(of: Void.self) { group in
                for record in matched {
                    guard let simple = record.simple else {
                        throw CordisError.eventListenerMismatch(EventDescriptor(key))
                    }
                    group.addTask {
                        try await simple(payload)
                    }
                }
                // The first listener to settle decides the outcome; the rest
                // are cancelled.
                guard try await group.next() != nil else { return }
                group.cancelAll()
                // Drain remaining cancellations, ignoring cancellation errors.
                // swiftlint:disable:next silent_try_optional
                while let _ = try? await group.next() {}
            }
            return nil
        case .waterfall:
            let snapshots = try matched.map { record -> AnyWaterfallListener in
                guard let waterfall = record.waterfall else {
                    throw CordisError.eventListenerMismatch(EventDescriptor(key))
                }
                return waterfall
            }
            return try await Self.runWaterfallChain(snapshots, payload: payload)
        }
    }

    /// Runs a waterfall chain: listener `i` receives `next`, which runs the
    /// remaining chain from `i + 1`. A listener that omits `next()` returns
    /// its own value and short-circuits everything downstream.
    private static func runWaterfallChain(
        _ chain: [AnyWaterfallListener],
        payload: any Sendable
    ) async throws -> any Sendable {
        @Sendable func run(from index: Int, value: any Sendable) async throws -> any Sendable {
            guard index < chain.count else { return value }
            return try await chain[index](value) { incoming in
                try await run(from: index + 1, value: incoming)
            }
        }
        return try await run(from: 0, value: payload)
    }

    private func collectListeners(
        _ key: AnyEventKey,
        from contextID: ContextID
    ) -> [ListenerRecord] {
        var matched: [ListenerRecord] = []
        var currentID: ContextID? = contextID
        while let candidateID = currentID, let context = contexts[candidateID] {
            for listenerID in context.listenerIDs {
                if let record = listeners[listenerID], record.key == key {
                    matched.append(record)
                }
            }
            currentID = context.parentID
        }
        return matched
    }

    // MARK: Effects and unloading

    func stageEffect(
        contextID: ContextID,
        componentID: ComponentID,
        generation: UInt64,
        dispose: @escaping @Sendable (CleanupContext) async throws -> Void
    ) throws -> EffectHandle {
        guard var component = components[componentID],
              component.contextID == contextID,
              case .loading(let currentGeneration) = component.state,
              currentGeneration == generation,
              var attempt = component.attempt,
              attempt.generation == generation else {
            throw CordisError.inactiveActivation(componentID)
        }
        let effectID = EffectID()
        attempt.effects.append(StagedEffect(id: effectID, dispose: dispose))
        component.attempt = attempt
        components[componentID] = component
        return EffectHandle(id: effectID, runtime: self)
    }

    /// Registers a cleanup effect for an already-active component, committed
    /// immediately (unlike `stageEffect`, which is activation-scoped).
    func attachEffect(
        contextID: ContextID,
        componentID: ComponentID,
        dispose: @escaping @Sendable (CleanupContext) async throws -> Void
    ) throws -> EffectHandle {
        try requireLiveContext(contextID)
        guard let component = components[componentID],
              component.contextID == contextID,
              component.state.kind == .active else {
            throw CordisError.inactiveActivation(componentID)
        }
        let effectID = EffectID()
        effects[effectID] = EffectRecord(
            id: effectID,
            contextID: contextID,
            componentID: componentID,
            dispose: dispose)
        components[componentID]?.effectIDs.append(effectID)
        return EffectHandle(id: effectID, runtime: self)
    }

    func disposeEffect(_ effectID: EffectID) async throws {
        if disposedEffectIDs.contains(effectID) { return }
        for componentID in components.keys {
            guard var component = components[componentID], var attempt = component.attempt else {
                continue
            }
            if let index = attempt.effects.firstIndex(where: { $0.id == effectID }) {
                let effect = attempt.effects.remove(at: index)
                component.attempt = attempt
                components[componentID] = component
                let failures = await disposeStagedEffects(
                    [effect],
                    contextID: component.contextID,
                    componentID: componentID)
                disposedEffectIDs.insert(effectID)
                if !failures.isEmpty {
                    throw CordisError.cleanup(CleanupAggregateError(failures: failures))
                }
                return
            }
        }
        guard let effect = effects.removeValue(forKey: effectID) else {
            throw CordisError.inactiveEffect(effectID)
        }
        components[effect.componentID]?.effectIDs.removeAll { $0 == effectID }
        let failures = await runEffects([effect])
        disposedEffectIDs.insert(effectID)
        if !failures.isEmpty {
            throw CordisError.cleanup(CleanupAggregateError(failures: failures))
        }
    }

    private func unloadComponent(
        _ componentID: ComponentID,
        permanently: Bool,
        visiting: Set<ComponentID>
    ) async -> [CleanupFailure] {
        guard var component = components[componentID] else { return [] }
        if component.state.kind == .disposed { return [] }
        if permanently {
            component.permanentDisposalRequested = true
            components[componentID] = component
        }
        if visiting.contains(componentID) { return [] }
        var nextVisiting = visiting
        nextVisiting.insert(componentID)
        var failures: [CleanupFailure] = []

        if component.state.kind == .unloading {
            do {
                _ = try await awaitComponentSettled(componentID)
            } catch {
                preconditionFailure("Unloading component disappeared: \(componentID.rawValue)")
            }
            // The unload owner reports its cleanup result. A concurrent caller
            // waits for the same settlement but must not report those failures again.
            return []
        }

        var stagedEffects: [StagedEffect] = []
        var activationTask: Task<Void, Never>?
        if let attempt = component.attempt {
            stagedEffects = attempt.effects
            component.attempt = nil
            activationTask = component.task
            component.task = nil
        }
        if component.state.kind == .loading || component.state.kind == .active {
            _ = transition(
                &component,
                to: .unloading(generation: component.state.generation))
        }
        components[componentID] = component

        activationTask?.cancel()
        if let activationTask {
            await activationTask.value
        }
        component = components[componentID] ?? component
        if !stagedEffects.isEmpty {
            failures += await disposeStagedEffects(
                stagedEffects,
                contextID: component.contextID,
                componentID: componentID)
            component = components[componentID] ?? component
        }

        for providerID in component.committedProviderIDs.reversed() {
            failures += await withdrawProvider(providerID, visiting: nextVisiting)
        }
        component = components[componentID] ?? component
        component.committedProviderIDs.removeAll()

        let ownedEffects = component.effectIDs.reversed().compactMap { effects.removeValue(forKey: $0) }
        component.effectIDs.removeAll()

        for listenerID in component.listenerIDs.reversed() {
            if let record = listeners.removeValue(forKey: listenerID) {
                contexts[record.contextID]?.listenerIDs.removeAll { $0 == listenerID }
            }
        }
        component.listenerIDs.removeAll()
        components[componentID] = component
        failures += await runEffects(Array(ownedEffects))
        for effect in ownedEffects { disposedEffectIDs.insert(effect.id) }

        component = components[componentID] ?? component
        component.dependencyProviders.removeAll()
        component.lastCleanupFailures = failures
        component.lastFailureProviders = nil
        let mustDispose = component.permanentDisposalRequested
        let target: ComponentState = mustDispose
            ? .disposed(generation: component.state.generation)
            : .pending(generation: component.state.generation)
        _ = transition(&component, to: target)
        components[componentID] = component
        settleComponent(componentID)
        return failures
    }

    private func disposeStagedEffects(
        _ stagedEffects: [StagedEffect],
        contextID: ContextID,
        componentID: ComponentID
    ) async -> [CleanupFailure] {
        let records = stagedEffects.reversed().map {
            EffectRecord(
                id: $0.id,
                contextID: contextID,
                componentID: componentID,
                dispose: $0.dispose)
        }
        let failures = await runEffects(records)
        for effect in stagedEffects { disposedEffectIDs.insert(effect.id) }
        return failures
    }

    private nonisolated static func runActivation(
        _ activation: ComponentDefinition.Activation,
        context: ActivationContext
    ) async throws {
        try await activation(context)
    }

    private nonisolated static func runCleanup(
        _ dispose: @Sendable (CleanupContext) async throws -> Void,
        context: CleanupContext
    ) async throws {
        try await dispose(context)
    }

    private func runEffects(_ records: [EffectRecord]) async -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        for effect in records {
            do {
                try await Self.runCleanup(
                    effect.dispose,
                    context: CleanupContext(
                        runtime: self,
                        contextID: effect.contextID,
                        componentID: effect.componentID))
            } catch {
                failures.append(CleanupFailure(
                    effectID: effect.id,
                    error: CordisFailure(error)))
            }
        }
        return failures
    }

    // MARK: Diagnostics and state transitions

    func diagnostics(contextID: ContextID) throws -> [ComponentDiagnostic] {
        try requireLiveContext(contextID)
        let visibleComponentIDs = descendantContextIDs(from: contextID).flatMap {
            contexts[$0]?.componentIDs ?? []
        }
        return visibleComponentIDs.compactMap { componentID in
            guard let component = components[componentID] else { return nil }
            switch component.state {
            case .failed(_, let failure):
                return ComponentDiagnostic(
                    componentID: componentID,
                    label: component.definition.label,
                    reason: .failed(failure))
            case .pending:
                let missing = component.definition.dependencies.filter {
                    resolveProvider($0.key, from: component.contextID, includeWithdrawing: false) == nil
                }
                guard !missing.isEmpty else { return nil }
                let missingKeys = Set(missing.map(\.key))
                let pendingProvisionKeys = Set(components.values
                    .filter { $0.state.kind == .pending }
                    .flatMap { $0.definition.provisions.map(\.key) })
                let descriptors = missing.map(\.descriptor)
                let reason: ComponentDiagnostic.Reason = missingKeys.isSubset(of: pendingProvisionKeys)
                    ? .possibleDependencyCycle(descriptors)
                    : .missingDependencies(descriptors)
                return ComponentDiagnostic(
                    componentID: componentID,
                    label: component.definition.label,
                    reason: reason)
            case .loading, .active, .unloading, .disposed:
                return nil
            }
        }
    }

    private func descendantContextIDs(from contextID: ContextID) -> [ContextID] {
        guard let context = contexts[contextID] else { return [] }
        return [contextID] + context.childIDs.flatMap(descendantContextIDs)
    }

    private func transition(_ component: inout ComponentRecord, to state: ComponentState) -> Bool {
        let from = component.state.kind
        let to = state.kind
        let allowed: Bool = switch (from, to) {
        case (.pending, .loading), (.pending, .disposed),
             (.loading, .active), (.loading, .failed), (.loading, .pending),
             (.loading, .unloading), (.loading, .disposed),
             (.active, .unloading), (.active, .disposed),
             (.unloading, .pending), (.unloading, .disposed),
             (.failed, .loading), (.failed, .pending), (.failed, .disposed),
             (.disposed, .disposed):
            true
        default:
            false
        }
        guard allowed else { return false }
        component.state = state
        if component.stateHistory.last != to {
            component.stateHistory.append(to)
        }
        return true
    }

    private func settleComponent(_ componentID: ComponentID) {
        guard var component = components[componentID], component.state.isSettled else { return }
        let state = component.state
        let waiters = component.settlementWaiters
        component.settlementWaiters.removeAll()
        components[componentID] = component
        for waiter in waiters {
            waiter.resume(returning: state)
        }
    }

    private func requireLiveContext(_ contextID: ContextID) throws {
        guard let context = contexts[contextID], context.lifecycle == .live else {
            throw CordisError.disposedContext(contextID)
        }
    }
}
