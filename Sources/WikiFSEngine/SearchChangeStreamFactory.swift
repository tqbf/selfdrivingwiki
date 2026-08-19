#if os(macOS)
import Foundation
import WikiFSCore

public struct SearchChangeStreamSubscription: Sendable {
    public let bufferedEvents: [ResourceChangeEvent]
    public let stream: AsyncStream<ResourceChangeEvent>

    public init(
        bufferedEvents: [ResourceChangeEvent],
        stream: AsyncStream<ResourceChangeEvent>
    ) {
        self.bufferedEvents = bufferedEvents
        self.stream = stream
    }
}

/// Assembly-only capability that transfers one eagerly subscribed event source
/// to one search runtime.
public protocol SearchChangeStreamFactory: Sendable {
    func take() throws -> SearchChangeStreamSubscription
    func finish()
}

public enum SearchChangeStreamFactoryError: Error, Equatable, Sendable {
    case alreadyConsumed
    case terminated
}

/// Eager, single-consumer adapter over one per-wiki event bus. The lock protects
/// the atomic buffered-to-live handoff and exact-once unsubscription. It also
/// protects every read and write of `token` and `state` across actor boundaries.
// swiftlint:disable:next unchecked_sendable
public final class BusSearchChangeStreamFactory: SearchChangeStreamFactory, @unchecked Sendable {
    private enum State {
        case buffering([ResourceChangeEvent])
        case streaming(AsyncStream<ResourceChangeEvent>.Continuation)
        case terminated
    }

    private let lock = NSLock()
    private let bus: WikiEventBus
    private var token: SubscriptionToken?
    private var state: State = .buffering([])

    @MainActor
    public init(bus: WikiEventBus) {
        self.bus = bus
        token = bus.subscribe(nil) { [weak self] event in
            self?.receive(event)
        }
    }

    public func take() throws -> SearchChangeStreamSubscription {
        let pair = AsyncStream<ResourceChangeEvent>.makeStream(bufferingPolicy: .unbounded)
        let buffered: [ResourceChangeEvent]
        lock.lock()
        switch state {
        case .buffering(let events):
            buffered = events
            state = .streaming(pair.continuation)
            lock.unlock()
        case .streaming:
            lock.unlock()
            pair.continuation.finish()
            throw SearchChangeStreamFactoryError.alreadyConsumed
        case .terminated:
            lock.unlock()
            pair.continuation.finish()
            throw SearchChangeStreamFactoryError.terminated
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.finish()
        }
        return SearchChangeStreamSubscription(
            bufferedEvents: buffered,
            stream: pair.stream)
    }

    public func finish() {
        let continuation: AsyncStream<ResourceChangeEvent>.Continuation?
        let tokenToRemove: SubscriptionToken?
        lock.lock()
        switch state {
        case .buffering:
            continuation = nil
        case .streaming(let active):
            continuation = active
        case .terminated:
            lock.unlock()
            return
        }
        state = .terminated
        tokenToRemove = token
        token = nil
        lock.unlock()

        if let tokenToRemove { bus.unsubscribe(tokenToRemove) }
        continuation?.finish()
    }

    private func receive(_ event: ResourceChangeEvent) {
        let continuation: AsyncStream<ResourceChangeEvent>.Continuation?
        lock.lock()
        switch state {
        case .buffering(var events):
            events.append(event)
            state = .buffering(events)
            continuation = nil
        case .streaming(let active):
            continuation = active
        case .terminated:
            continuation = nil
        }
        lock.unlock()
        continuation?.yield(event)
    }
}

public struct FinishedSearchChangeStreamFactory: SearchChangeStreamFactory {
    public init() {}

    public func take() throws -> SearchChangeStreamSubscription {
        let pair = AsyncStream<ResourceChangeEvent>.makeStream()
        pair.continuation.finish()
        return SearchChangeStreamSubscription(bufferedEvents: [], stream: pair.stream)
    }

    public func finish() {}
}
#endif
