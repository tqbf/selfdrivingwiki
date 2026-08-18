import Cordis
import Foundation
import Testing

@Suite("Component lifecycle", .timeLimit(.minutes(1)))
struct ComponentLifecycleTests {
    @Test(
        "state settlement classification is finite",
        arguments: [
            (ComponentState.pending(generation: 1), true),
            (.loading(generation: 1), false),
            (.active(generation: 1), true),
            (.unloading(generation: 1), false),
            (.failed(generation: 1, failure: CordisFailure("failure")), true),
            (.disposed(generation: 1), true),
        ])
    func stateSettlementClassification(state: ComponentState, expected: Bool) {
        #expect(state.isSettled == expected)
    }

    @Test("missing dependency stays pending")
    func missingDependencyStaysPending() async throws {
        let key = ServiceKey<String>(label: "dependency")
        let context = CordisContext()
        let counter = Counter()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(key)]) { _ in
                await counter.increment()
            }

        let handle = try await context.register(definition)

        #expect(try await handle.state.kind == .pending)
        #expect(await counter.get() == 0)
    }

    @Test("provide activates once per dependency generation")
    func provideActivatesOncePerGeneration() async throws {
        let key = ServiceKey<String>(label: "dependency")
        let context = CordisContext()
        let counter = Counter()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(key)]) { activation in
                _ = try await activation.require(key)
                await counter.increment()
            }
        let handle = try await context.register(definition)

        let firstProvider = try await context.supply(key, value: "first")
        #expect(try await handle.awaitSettled().kind == .active)
        #expect(await counter.get() == 1)

        try await firstProvider.dispose()
        #expect(try await handle.awaitSettled().kind == .pending)

        _ = try await context.supply(key, value: "second")
        #expect(try await handle.awaitSettled().kind == .active)
        #expect(await counter.get() == 2)
    }

    @Test("explicit restart retries a failed generation")
    func explicitRestartRetriesFailure() async throws {
        let attempts = Counter()
        let context = CordisContext()
        let definition = try ComponentDefinition(label: "failing") { _ in
            await attempts.increment()
            if await attempts.get() == 1 {
                throw CordisFailure("first failure")
            }
        }
        let handle = try await context.register(definition)

        #expect(try await handle.awaitSettled().kind == .failed)
        #expect(await attempts.get() == 1)

        #expect(try await handle.restart().kind == .active)
        #expect(await attempts.get() == 2)
    }

    @Test("state history uses only legal transitions")
    func stateHistoryUsesLegalTransitions() async throws {
        let key = ServiceKey<String>(label: "dependency")
        let context = CordisContext()
        let definition = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(key)]) { _ in }
        let handle = try await context.register(definition)
        let provider = try await context.supply(key, value: "value")
        _ = try await handle.awaitSettled()
        try await provider.dispose()
        _ = try await handle.awaitSettled()

        #expect(try await handle.stateHistory == [.pending, .loading, .active, .unloading, .pending])
    }
}
