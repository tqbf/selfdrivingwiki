import Foundation
import Testing

actor AsyncGate {
    private var isOpen = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let arrivalContinuation: AsyncStream<Void>.Continuation
    let arrivals: AsyncStream<Void>

    init() {
        let arrivalPair = AsyncStream<Void>.makeStream()
        arrivals = arrivalPair.stream
        arrivalContinuation = arrivalPair.continuation
    }

    func wait() async {
        if isOpen {
            arrivalContinuation.yield(())
            return
        }
        let waiterID = UUID()
        let pair = AsyncStream<Void>.makeStream()
        waiters[waiterID] = pair.continuation
        arrivalContinuation.yield(())
        await withTaskCancellationHandler {
            for await _ in pair.stream {
                break
            }
        } onCancel: {
            pair.continuation.finish()
        }
        waiters.removeValue(forKey: waiterID)
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.yield(())
            continuation.finish()
        }
    }

    deinit {
        arrivalContinuation.finish()
        for continuation in waiters.values {
            continuation.finish()
        }
    }
}

struct CancellationProbe: Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func observed() {
        continuation.yield(())
    }
}

actor EventLog<Element: Sendable> {
    private var values: [Element] = []

    func append(_ value: Element) {
        values.append(value)
    }

    func snapshot() -> [Element] {
        values
    }
}

actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }

    func get() -> Int {
        value
    }
}

func firstValue<Element: Sendable>(from stream: AsyncStream<Element>) async throws -> Element {
    for await value in stream {
        return value
    }
    throw TestSupportError.streamFinished
}

enum TestSupportError: Error {
    case streamFinished
}
