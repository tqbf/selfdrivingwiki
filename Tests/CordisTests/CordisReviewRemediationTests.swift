import Cordis
import Foundation
import Testing

@Suite("Cordis review remediation", .serialized, .timeLimit(.minutes(1)))
struct CordisReviewRemediationTests {
    @Test("gate cancellation releases one waiter without opening the gate")
    func gateCancellationReleasesWaiter() async throws {
        let gate = AsyncGate()
        let completed = AsyncStream<Void>.makeStream()
        let waiter = Task<Void, Never> {
            await gate.wait()
            completed.continuation.yield(())
            completed.continuation.finish()
        }
        _ = try await firstValue(from: gate.arrivals)

        waiter.cancel()

        _ = try await firstValue(from: completed.stream)
        await waiter.value
    }

    @Test("provider withdrawal cancels cooperative activation without manual release")
    func providerWithdrawalCancelsCooperativeActivation() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let gate = AsyncGate()
        let cancellation = CancellationProbe()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(dependencyKey)]) { _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    cancellation.observed()
                }
            }
        let handle = try await context.register(definition)
        let provider = try await context.supply(dependencyKey, value: "value")
        _ = try await firstValue(from: gate.arrivals)
        let withdrawal = Task<Void, Error> { try await provider.dispose() }
        _ = try await firstValue(from: cancellation.events)

        try await withdrawal.value

        #expect(try await handle.state.kind == .pending)
    }

    @Test("provider withdrawal drains cancellation-resistant child work before settlement")
    func providerWithdrawalDrainsActivation() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let suppliedKey = ServiceKey<Int>(label: "supplied")
        let workGate = AsyncGate()
        let cancellation = CancellationProbe()
        let cleanupLog = EventLog<Int>()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(dependencyKey)],
            provisions: [ServiceDependency(suppliedKey)]) { activation in
                _ = try await activation.effect { _ in await cleanupLog.append(1) }
                _ = try await activation.effect { _ in await cleanupLog.append(2) }
                _ = try await activation.supply(suppliedKey, value: 1)
                let child = Task<Void, Never> { await workGate.wait() }
                await withTaskCancellationHandler {
                    await child.value
                } onCancel: {
                    cancellation.observed()
                }
            }
        let handle = try await context.register(definition)
        let provider = try await context.supply(dependencyKey, value: "old")
        _ = try await firstValue(from: workGate.arrivals)
        let settled = Task<ComponentState, Error> { try await handle.awaitSettled() }
        let withdrawal = Task<Void, Error> { try await provider.dispose() }
        _ = try await firstValue(from: cancellation.events)

        #expect(try await handle.state.kind == .unloading)
        #expect(await cleanupLog.snapshot().isEmpty)

        await workGate.open()
        try await withdrawal.value
        #expect(try await settled.value.kind == .pending)
        #expect(await cleanupLog.snapshot() == [2, 1])
        #expect(try await context.find(suppliedKey) == nil)
    }

    @Test("component disposal upgrades an in-flight withdrawal to permanent disposal")
    func componentDisposalUpgradesInFlightWithdrawal() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let gate = AsyncGate()
        let cancellation = CancellationProbe()
        let cleanupCount = Counter()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(dependencyKey)]) { activation in
                _ = try await activation.effect { _ in await cleanupCount.increment() }
                let child = Task<Void, Never> { await gate.wait() }
                await withTaskCancellationHandler {
                    await child.value
                } onCancel: {
                    cancellation.observed()
                }
            }
        let handle = try await context.register(definition)
        let provider = try await context.supply(dependencyKey, value: "value")
        _ = try await firstValue(from: gate.arrivals)
        let withdrawal = Task<Void, Error> { try await provider.dispose() }
        _ = try await firstValue(from: cancellation.events)
        #expect(try await handle.state.kind == .unloading)

        let disposal = Task<Void, Error> { try await handle.dispose() }
        await gate.open()
        try await withdrawal.value
        try await disposal.value

        #expect(try await handle.state.kind == .disposed)
        #expect(await cleanupCount.get() == 1)
        #expect(try await context.find(dependencyKey) == nil)
    }

    @Test("context disposal upgrades an in-flight withdrawal to permanent disposal")
    func contextDisposalUpgradesInFlightWithdrawal() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let gate = AsyncGate()
        let cancellation = CancellationProbe()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(dependencyKey)]) { _ in
                let child = Task<Void, Never> { await gate.wait() }
                await withTaskCancellationHandler {
                    await child.value
                } onCancel: {
                    cancellation.observed()
                }
            }
        let handle = try await context.register(definition)
        let provider = try await context.supply(dependencyKey, value: "value")
        _ = try await firstValue(from: gate.arrivals)
        let withdrawal = Task<Void, Error> { try await provider.dispose() }
        _ = try await firstValue(from: cancellation.events)
        #expect(try await handle.state.kind == .unloading)

        let disposal = Task<Void, Error> { try await context.dispose() }
        await gate.open()
        try await withdrawal.value
        try await disposal.value

        #expect(try await handle.state.kind == .disposed)
        await #expect(throws: CordisError.disposedContext(context.id)) {
            try await context.find(dependencyKey)
        }
    }

    @Test("disposing a committed provision disposes its owner")
    func committedProviderDisposalDisposesOwner() async throws {
        let key = ServiceKey<String>(label: "owned")
        let cleanupCount = Counter()
        let providerStream = AsyncStream<ProviderHandle>.makeStream()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "provider",
            provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.effect { _ in await cleanupCount.increment() }
                let provider = try await activation.supply(key, value: "value")
                providerStream.continuation.yield(provider)
                providerStream.continuation.finish()
            }
        let handle = try await context.register(definition)
        let provider = try await firstValue(from: providerStream.stream)
        #expect(try await handle.awaitSettled().kind == .active)
        #expect(try await context.require(key) == "value")

        try await provider.dispose()

        #expect(try await handle.state.kind == .disposed)
        #expect(try await context.find(key) == nil)
        #expect(await cleanupCount.get() == 1)
        try await provider.dispose()
        #expect(await cleanupCount.get() == 1)
    }

    @Test("context disposal drains a cancellation-resistant activation")
    func contextDisposalDrainsActivation() async throws {
        let gate = AsyncGate()
        let cancellation = CancellationProbe()
        let context = CordisContext()
        let definition = try ComponentDefinition(label: "consumer") { _ in
            let child = Task<Void, Never> { await gate.wait() }
            await withTaskCancellationHandler {
                await child.value
            } onCancel: {
                cancellation.observed()
            }
        }
        let handle = try await context.register(definition)
        _ = try await firstValue(from: gate.arrivals)
        let disposal = Task<Void, Error> { try await context.dispose() }
        _ = try await firstValue(from: cancellation.events)

        #expect(try await handle.state.kind == .unloading)

        await gate.open()
        try await disposal.value
        #expect(try await handle.state.kind == .disposed)
    }

    @Test("revoked generation rejects late mutations before replacement activation")
    func revokedGenerationCannotMutateReplacement() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let suppliedKey = ServiceKey<String>(label: "supplied")
        let lateKey = ServiceKey<Int>(label: "late")
        let oldGate = AsyncGate()
        let newGate = AsyncGate()
        let cancellation = CancellationProbe()
        let lateFailures = EventLog<CordisError>()
        let lateCleanup = Counter()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "provider",
            dependencies: [ServiceDependency(dependencyKey)],
            provisions: [ServiceDependency(suppliedKey), ServiceDependency(lateKey)]) { activation in
                let dependency = try await activation.require(dependencyKey)
                _ = try await activation.supply(suppliedKey, value: dependency)
                if dependency == "old" {
                    let child = Task<Void, Never> { await oldGate.wait() }
                    await withTaskCancellationHandler {
                        await child.value
                    } onCancel: {
                        cancellation.observed()
                    }
                    do {
                        _ = try await activation.supply(lateKey, value: 1)
                    } catch let error as CordisError {
                        await lateFailures.append(error)
                    }
                    do {
                        _ = try await activation.effect { _ in await lateCleanup.increment() }
                    } catch let error as CordisError {
                        await lateFailures.append(error)
                    }
                } else {
                    await newGate.wait()
                }
            }
        let handle = try await context.register(definition)
        let oldProvider = try await context.supply(dependencyKey, value: "old")
        _ = try await firstValue(from: oldGate.arrivals)
        let withdrawal = Task<Void, Error> { try await oldProvider.dispose() }
        _ = try await firstValue(from: cancellation.events)
        #expect(try await handle.state.kind == .unloading)

        await oldGate.open()
        try await withdrawal.value
        #expect(await lateFailures.snapshot() == [
            .inactiveActivation(handle.id),
            .inactiveActivation(handle.id),
        ])
        #expect(await lateCleanup.get() == 0)
        #expect(try await context.find(lateKey) == nil)

        let replacement = try await context.supply(dependencyKey, value: "new")
        #expect(oldProvider.id != replacement.id)
        _ = try await firstValue(from: newGate.arrivals)
        await newGate.open()
        let state = try await handle.awaitSettled()
        #expect(state.kind == .active)
        #expect(state.generation == 2)
        #expect(try await context.require(suppliedKey) == "new")
        try await oldProvider.dispose()
        #expect(try await context.require(dependencyKey) == "new")
        #expect(try await context.require(suppliedKey) == "new")
    }

    @Test("awaitSettled waits while loading")
    func awaitSettledWaitsWhileLoading() async throws {
        let gate = AsyncGate()
        let context = CordisContext()
        let definition = try ComponentDefinition(label: "loading") { _ in await gate.wait() }
        let handle = try await context.register(definition)
        _ = try await firstValue(from: gate.arrivals)
        let settlement = Task<ComponentState, Error> { try await handle.awaitSettled() }

        #expect(try await handle.state.kind == .loading)

        await gate.open()
        let state = try await settlement.value
        #expect(state.kind == .active)
        #expect(state.generation == 1)
    }
}
