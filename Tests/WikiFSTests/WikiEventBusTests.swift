import Testing
import Foundation
@testable import WikiFSCore

/// Unit tests for the pure per-wiki event bus (`WikiEventBus`).
///
/// Delivery is async: `emit` dispatches each `@MainActor` handler via
/// `Task { @MainActor in … }`. The tests use a lock-guarded collector and a
/// bounded poll (rather than sleeps) so they wait exactly until the expected
/// events land — no timing flakes.
struct WikiEventBusTests {

    /// Lock-guarded, synchronous collector — handlers append from the main
    /// actor without needing to `await`, so the non-async handler signature works.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ event: ResourceChangeEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }
        var snapshot: [ResourceChangeEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
        var count: Int { snapshot.count }
    }

    /// Wait until `collector` holds at least `expected` events (bounded so a
    /// missing delivery fails the test rather than hanging).
    private func awaitCount(_ collector: Collector, _ expected: Int, timeoutMs: Int = 800) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if collector.count >= expected { return }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func emitDeliversToAllEventsSubscriber() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let collector = Collector()
        bus.subscribe(nil) { collector.append($0) }

        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .created))
        try await awaitCount(collector, 1)

        let events = collector.snapshot
        #expect(events.count == 1)
        #expect(events[0].wikiID == "W")
        #expect(events[0].kind == .page)
        #expect(events[0].id == "p1")
        #expect(events[0].change == .created)
    }

    @Test func kindFilterOnlyDeliversMatchingKind() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let pageCollector = Collector()
        let sourceCollector = Collector()
        bus.subscribe(.page) { pageCollector.append($0) }
        bus.subscribe(.source) { sourceCollector.append($0) }

        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .updated))
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .source, id: "s1", change: .created))
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .bookmark, id: "b1", change: .created))
        try await awaitCount(pageCollector, 1)

        let pages = pageCollector.snapshot.map { $0.id }
        let sources = sourceCollector.snapshot.map { $0.id }
        #expect(pages == ["p1"])
        #expect(sources == ["s1"])
    }

    @Test func coarseNilKindEventReachesOnlyAllEventsSubscribers() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let allEvents = Collector()
        let pageOnly = Collector()
        bus.subscribe(nil) { allEvents.append($0) }
        bus.subscribe(.page) { pageOnly.append($0) }

        // The bridge's coarse external event (kind == nil) must reach the
        // all-events subscriber (model's .external reload) but NOT a
        // kind-filtered subscriber.
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: nil, id: "", change: .updated))
        try await awaitCount(allEvents, 1)

        #expect(allEvents.count == 1)
        // Give the page-only subscriber a chance to (not) receive.
        try await Task.sleep(for: .milliseconds(20))
        #expect(pageOnly.count == 0)
    }

    @Test func multipleSubscribersAllReceive() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let a = Collector()
        let b = Collector()
        _ = bus.subscribe(nil) { a.append($0) }
        _ = bus.subscribe(nil) { b.append($0) }

        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .created))
        try await awaitCount(a, 1)
        try await awaitCount(b, 1)

        #expect(a.count == 1)
        #expect(b.count == 1)
    }

    @Test func unsubscribeStopsDelivery() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let collector = Collector()
        let token = bus.subscribe(nil) { collector.append($0) }

        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .created))
        try await awaitCount(collector, 1)
        #expect(collector.count == 1)

        bus.unsubscribe(token)
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p2", change: .created))
        // Drain the run loop; no new event should arrive.
        try await Task.sleep(for: .milliseconds(30))
        #expect(collector.count == 1)
    }

    @Test func unsubscribeUnknownTokenIsNoOp() async throws {
        let bus = WikiEventBus(wikiID: "W")
        // A token never registered must not crash and must not affect delivery.
        bus.unsubscribe(SubscriptionToken())
        let collector = Collector()
        bus.subscribe(nil) { collector.append($0) }
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .created))
        try await awaitCount(collector, 1)
        #expect(collector.count == 1)
    }

    @Test func seqIsMonotoneAcrossEmits() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let collector = Collector()
        bus.subscribe(nil) { collector.append($0) }

        for i in 0..<5 {
            bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p\(i)", change: .updated))
        }
        try await awaitCount(collector, 5)

        let seqs = collector.snapshot.map(\.seq)
        // Starts at 1, strictly increasing by 1.
        #expect(seqs == [1, 2, 3, 4, 5])
    }

    @Test func callerSeqZeroIsOverwrittenByBus() async throws {
        let bus = WikiEventBus(wikiID: "W")
        let collector = Collector()
        bus.subscribe(nil) { collector.append($0) }

        // Callers pass seq 0; the bus must stamp the real value (never deliver 0).
        bus.emit(ResourceChangeEvent(wikiID: "W", kind: .page, id: "p1", change: .created, seq: 0))
        try await awaitCount(collector, 1)

        #expect(collector.snapshot[0].seq == 1)
    }
}
