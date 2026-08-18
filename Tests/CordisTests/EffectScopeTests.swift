import Cordis
import Foundation
import Testing

@Suite("Effect scopes", .timeLimit(.minutes(1)))
struct EffectScopeTests {
    @Test("effects dispose in strict LIFO order")
    func disposesLIFO() async throws {
        let log = EventLog<Int>()
        let context = CordisContext()
        let definition = try ComponentDefinition(label: "effects") { activation in
            _ = try await activation.effect { _ in await log.append(1) }
            _ = try await activation.effect { _ in await log.append(2) }
            _ = try await activation.effect { _ in await log.append(3) }
        }
        let handle = try await context.register(definition)
        _ = try await handle.awaitSettled()

        try await handle.dispose()

        #expect(await log.snapshot() == [3, 2, 1])
    }

    @Test("cleanup continues and aggregates failures")
    func cleanupAggregatesFailuresAndContinues() async throws {
        let log = EventLog<Int>()
        let failureEffectIDs = EventLog<EffectID>()
        let context = CordisContext()
        let definition = try ComponentDefinition(label: "failing effects") { activation in
            let first = try await activation.effect { _ in
                await log.append(1)
                throw FirstCleanupError()
            }
            await failureEffectIDs.append(first.id)
            let second = try await activation.effect { _ in
                await log.append(2)
                throw SecondCleanupError()
            }
            await failureEffectIDs.append(second.id)
            _ = try await activation.effect { _ in
                await log.append(3)
            }
        }
        let handle = try await context.register(definition)
        _ = try await handle.awaitSettled()
        let registeredFailureIDs = await failureEffectIDs.snapshot()
        #expect(registeredFailureIDs.count == 2)

        do {
            try await handle.dispose()
            Issue.record("Expected cleanup aggregate")
        } catch let CordisError.cleanup(aggregate) {
            #expect(aggregate.failures.count == 2)
            #expect(aggregate.failures.map(\.effectID) == Array(registeredFailureIDs.reversed()))
            #expect(aggregate.failures.map(\.error.typeName) == [
                String(reflecting: SecondCleanupError.self),
                String(reflecting: FirstCleanupError.self),
            ])
        }

        #expect(await log.snapshot() == [3, 2, 1])
        #expect(try await handle.state.kind == .disposed)
    }

    @Test("effect and component disposal are idempotent")
    func disposalIsIdempotent() async throws {
        let counter = Counter()
        let context = CordisContext()
        let effectBox = EffectHandleBox()
        let definition = try ComponentDefinition(label: "effect") { activation in
            let handle = try await activation.effect { _ in await counter.increment() }
            await effectBox.set(handle)
        }
        let component = try await context.register(definition)
        _ = try await component.awaitSettled()
        let effect = try #require(await effectBox.get())

        try await effect.dispose()
        try await effect.dispose()
        try await component.dispose()
        try await component.dispose()

        #expect(await counter.get() == 1)
    }
}

private struct FirstCleanupError: Error {}
private struct SecondCleanupError: Error {}

actor EffectHandleBox {
    private var handle: EffectHandle?

    func set(_ handle: EffectHandle) {
        self.handle = handle
    }

    func get() -> EffectHandle? {
        handle
    }
}
