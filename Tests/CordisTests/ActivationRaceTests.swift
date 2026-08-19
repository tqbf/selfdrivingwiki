import Cordis
import Foundation
import Testing

@Suite("Activation races", .serialized, .timeLimit(.minutes(1)))
struct ActivationRaceTests {
    @Test("staged supply is never visible before commit")
    func stagedSupplyIsNotVisibleBeforeCommit() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let stagedKey = ServiceKey<Int>(label: "staged")
        let gate = AsyncGate()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "staged provider",
            dependencies: [ServiceDependency(dependencyKey)],
            provisions: [ServiceDependency(stagedKey)]) { activation in
                _ = try await activation.supply(stagedKey, value: 42)
                await gate.wait()
            }
        let handle = try await context.register(definition)
        _ = try await context.supply(dependencyKey, value: "ready")
        _ = try await firstValue(from: gate.arrivals)

        #expect(try await context.find(stagedKey) == nil)

        await gate.open()
        #expect(try await handle.awaitSettled().kind == .active)
        #expect(try await context.require(stagedKey) == 42)
    }

    @Test("withdrawal retires suspended activation and stale supply cannot commit")
    func withdrawalRetiresSuspendedActivation() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let stagedKey = ServiceKey<Int>(label: "staged")
        let gate = AsyncGate()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "stale provider",
            dependencies: [ServiceDependency(dependencyKey)],
            provisions: [ServiceDependency(stagedKey)]) { activation in
                _ = try await activation.supply(stagedKey, value: 1)
                await gate.wait()
            }
        let handle = try await context.register(definition)
        let provider = try await context.supply(dependencyKey, value: "first")
        _ = try await firstValue(from: gate.arrivals)

        try await provider.dispose()
        #expect(try await handle.state.kind == .pending)
        #expect(try await context.find(stagedKey) == nil)

        await gate.open()
        #expect(try await context.find(stagedKey) == nil)
    }

    @Test("activation failure rolls back staged effects and supplies")
    func failureRollsBackPartialEffects() async throws {
        let suppliedKey = ServiceKey<String>(label: "supplied")
        let log = EventLog<Int>()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "failing provider",
            provisions: [ServiceDependency(suppliedKey)]) { activation in
                _ = try await activation.effect { _ in await log.append(1) }
                _ = try await activation.effect { _ in await log.append(2) }
                _ = try await activation.supply(suppliedKey, value: "staged")
                throw CordisFailure("activation failed")
            }
        let handle = try await context.register(definition)

        #expect(try await handle.awaitSettled().kind == .failed)
        #expect(try await context.find(suppliedKey) == nil)
        #expect(await log.snapshot() == [2, 1])
    }

    @Test("final component disposal waits for a retired activation task")
    func disposedComponentOwnsNoTasks() async throws {
        let dependencyKey = ServiceKey<String>(label: "dependency")
        let gate = AsyncGate()
        let completionLog = EventLog<String>()
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "suspended",
            dependencies: [ServiceDependency(dependencyKey)]) { _ in
                await gate.wait()
                await completionLog.append("finished")
            }
        let handle = try await context.register(definition)
        _ = try await context.supply(dependencyKey, value: "ready")
        _ = try await firstValue(from: gate.arrivals)

        let disposal = Task<Void, Error> {
            try await handle.dispose()
        }
        #expect(await completionLog.snapshot().isEmpty)
        await gate.open()
        try await disposal.value

        #expect(await completionLog.snapshot() == ["finished"])
        #expect(try await handle.state.kind == .disposed)
    }

    @Test("self dependency and provision is rejected")
    func selfCycleIsRejected() throws {
        let key = ServiceKey<String>(label: "self")

        #expect(throws: CordisError.self) {
            try ComponentDefinition(
                label: "cycle",
                dependencies: [ServiceDependency(key)],
                provisions: [ServiceDependency(key)]) { _ in }
        }
    }

    @Test("mutual dependency cycle remains pending with diagnostics")
    func mutualCycleIsDiagnosed() async throws {
        let firstKey = ServiceKey<String>(label: "first")
        let secondKey = ServiceKey<Int>(label: "second")
        let context = CordisContext()
        let first = try ComponentDefinition(
            label: "first component",
            dependencies: [ServiceDependency(secondKey)],
            provisions: [ServiceDependency(firstKey)]) { activation in
                _ = try await activation.supply(firstKey, value: "first")
            }
        let second = try ComponentDefinition(
            label: "second component",
            dependencies: [ServiceDependency(firstKey)],
            provisions: [ServiceDependency(secondKey)]) { activation in
                _ = try await activation.supply(secondKey, value: 2)
            }
        let firstHandle = try await context.register(first)
        let secondHandle = try await context.register(second)

        #expect(try await firstHandle.state.kind == .pending)
        #expect(try await secondHandle.state.kind == .pending)
        let diagnostics = try await context.diagnostics()
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy {
            if case .possibleDependencyCycle = $0.reason { return true }
            return false
        })
    }
}
