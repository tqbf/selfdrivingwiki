import Cordis
import Foundation
import Testing

private struct Ping: Sendable, Equatable {
    var value: Int
}

private struct Boom: Error, Sendable {}

@Suite("Cordis events", .serialized, .timeLimit(.minutes(1)))
struct CordisEventsTests {
    @Test("emit dispatches to all listeners in registration order")
    func emitOrder() async throws {
        let key = EventKey<Ping, EmitMode>(label: "test.emit")
        let context = CordisContext()
        let order = OrderRecorder()
        try await context.on(key) { _ in await order.append("ambient-1") }
        try await context.on(key) { _ in await order.append("ambient-2") }
        await context.emit(key, Ping(value: 1))
        #expect(await order.values == ["ambient-1", "ambient-2"])
    }

    @Test("emit ignores listener errors by contract")
    func emitIgnoresErrors() async throws {
        let key = EventKey<Ping, EmitMode>(label: "test.emit-error")
        let context = CordisContext()
        let seen = OrderRecorder()
        try await context.on(key) { _ in throw Boom() }
        try await context.on(key) { _ in await seen.append("after") }
        await context.emit(key, Ping(value: 1))
        #expect(await seen.values == ["after"])
    }

    @Test("serial dispatch propagates the first listener error")
    func serialPropagates() async throws {
        let key = EventKey<Ping, SerialMode>(label: "test.serial")
        let context = CordisContext()
        let seen = OrderRecorder()
        try await context.on(key) { _ in await seen.append("first") }
        try await context.on(key) { _ in throw Boom() }
        try await context.on(key) { _ in await seen.append("never") }
        await #expect(throws: Boom.self) {
            try await context.emit(key, Ping(value: 1))
        }
        #expect(await seen.values == ["first"])
    }

    @Test("parallel dispatch runs all listeners and reports the first error")
    func parallelDispatch() async throws {
        let key = EventKey<Ping, ParallelMode>(label: "test.parallel")
        let context = CordisContext()
        let seen = OrderRecorder()
        try await context.on(key) { _ in await seen.append("ok") }
        try await context.on(key) { _ in throw Boom() }
        await #expect(throws: (any Error).self) {
            try await context.emit(key, Ping(value: 1))
        }
    }

    @Test("waterfall passes payload through next() in order")
    func waterfallPropagation() async throws {
        let key = EventKey<Ping, WaterfallMode>(label: "test.waterfall")
        let context = CordisContext()
        let seen = OrderRecorder()
        try await context.on(key) { ping, next in
            await seen.append("l1")
            var value = try await next()
            value.value += 1
            return value
        }
        try await context.on(key) { ping, next in
            await seen.append("l2:\(ping.value)")
            return try await next()
        }
        let result = try await context.waterfall(key, Ping(value: 10))
        #expect(result == Ping(value: 11))
        #expect(await seen.values == ["l1", "l2:10"])
    }

    @Test("waterfall listener that omits next() short-circuits downstream")
    func waterfallShortCircuit() async throws {
        let key = EventKey<Ping, WaterfallMode>(label: "test.waterfall-short")
        let context = CordisContext()
        let seen = OrderRecorder()
        try await context.on(key) { ping, _ in
            await seen.append("short-circuit")
            return Ping(value: ping.value * 2)
        }
        try await context.on(key) { _, _ in
            await seen.append("never")
            throw Boom()
        }
        let result = try await context.waterfall(key, Ping(value: 3))
        #expect(result == Ping(value: 6))
        #expect(await seen.values == ["short-circuit"])
    }

    @Test("listener registered during activation is disposed with its component (LIFO)")
    func activationListenerDisposal() async throws {
        let key = EventKey<Ping, EmitMode>(label: "test.lifecycle")
        let context = CordisContext()
        let seen = OrderRecorder()
        let definition = try ComponentDefinition(label: "listener owner") { activation in
            try await activation.on(key) { _ in await seen.append("component") }
        }
        let handle = try await context.register(definition)
        #expect(try await handle.awaitSettled().kind == .active)

        try await context.on(key) { _ in await seen.append("ambient") }
        await context.emit(key, Ping(value: 1))
        #expect(await seen.values == ["component", "ambient"])

        try await handle.dispose()
        await seen.removeAll()
        await context.emit(key, Ping(value: 2))
        #expect(await seen.values == ["ambient"])
    }

    @Test("mid-flight listener via ComponentHandle is reversible")
    func midFlightListener() async throws {
        let key = EventKey<Ping, EmitMode>(label: "test.midflight")
        let context = CordisContext()
        let seen = OrderRecorder()
        let definition = try ComponentDefinition(label: "passive") { _ in }
        let handle = try await context.register(definition)
        #expect(try await handle.awaitSettled().kind == .active)

        let listener = try await handle.on(key) { _ in await seen.append("owned") }
        await context.emit(key, Ping(value: 1))
        #expect(await seen.values == ["owned"])

        try await listener.dispose()
        await context.emit(key, Ping(value: 2))
        #expect(await seen.values == ["owned"])
    }

    @Test("mid-flight effect registration runs on component unload (LIFO)")
    func midFlightEffect() async throws {
        let context = CordisContext()
        let seen = OrderRecorder()
        let definition = try ComponentDefinition(label: "effect owner") { activation in
            _ = try await activation.effect { _ in await seen.append("activation-effect") }
        }
        let handle = try await context.register(definition)
        #expect(try await handle.awaitSettled().kind == .active)

        _ = try await handle.effect { _ in await seen.append("mid-flight-effect") }
        try await handle.dispose()
        // LIFO: the mid-flight effect (registered last) runs first.
        #expect(await seen.values == ["mid-flight-effect", "activation-effect"])
    }

    @Test("child context sees parent listeners; parent does not see child listeners")
    func contextShadowing() async throws {
        let key = EventKey<Ping, EmitMode>(label: "test.hierarchy")
        let parent = CordisContext()
        let child = try await parent.child()
        let seen = OrderRecorder()
        try await parent.on(key) { _ in await seen.append("parent") }
        try await child.on(key) { _ in await seen.append("child") }

        await child.emit(key, Ping(value: 1))
        #expect(await seen.values == ["child", "parent"])

        await seen.removeAll()
        await parent.emit(key, Ping(value: 2))
        #expect(await seen.values == ["parent"])
    }

    @Test("bail dispatch settles on the first completed listener")
    func bailDispatch() async throws {
        let key = EventKey<Ping, BailMode>(label: "test.bail")
        let context = CordisContext()
        let gate = AsyncGate()
        let seen = OrderRecorder()
        try await context.on(key) { _ in
            await gate.wait()
            await seen.append("slow")
        }
        try await context.on(key) { _ in
            await seen.append("fast")
        }
        try await context.emit(key, Ping(value: 1))
        // "fast" settled first; the gated listener was cancelled and only
        // resumes after the gate treats cancellation as release.
        #expect(await seen.values.first == "fast")
        await gate.open()
    }
}

/// A thread-safe recorder for ordering assertions.
private actor Recorder {
    var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }

    func removeAll() {
        values.removeAll()
    }
}

private struct OrderRecorder {
    let recorder = Recorder()

    var values: [String] {
        get async { await recorder.snapshot() }
    }

    func append(_ value: String) async {
        await recorder.append(value)
    }

    func removeAll() async {
        await recorder.removeAll()
    }
}
