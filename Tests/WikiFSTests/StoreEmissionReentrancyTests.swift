import Testing
import Foundation
@testable import WikiFSCore

/// Structural safety of emission via `mutate()` (AC.3). Emission happens
/// strictly AFTER the recursive lock is released at the outermost `mutate()`
/// exit and AFTER the transaction commits, so:
/// (a) a `withTransaction`-wrapped mutation emits once and never deadlocks;
/// (b) a subscriber that re-enters the store to READ observes COMMITTED state;
/// (c) a mutation that throws / rolls back emits NOTHING.
///
/// No public EMIT method currently composes another public EMIT method (verified
/// by grep), so `mutate`-within-`mutate` nesting does not arise today; the
/// depth-0 design is future-proofing for graph-model ref-repoint methods. The
/// per-method `StoreEmissionTests` already prove each top-level mutator emits
/// exactly once (no double-emit).
@Suite(.tags(.integration), .timeLimit(.minutes(5)))
struct StoreEmissionReentrancyTests {

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        var count: Int { snapshot.count }
    }

    private func awaitCount(_ recorder: Recorder, _ expected: Int, timeoutMs: Int = 800) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.count >= expected { return }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeHarness() throws -> (GRDBWikiStore, WikiEventBus, Recorder) {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (store, bus, recorder)
    }

    /// (a) A `withTransaction`-wrapped mutation (deletePage) re-enters the
    /// recursive lock; the event must flush once at the outermost exit, with no
    /// deadlock (R1).
    @Test func withTransactionMutationEmitsOnceNoDeadlock() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Doomed")
        // createPage already emitted one event; clear so we isolate deletePage.
        try await awaitCount(rec, 1)
        let beforeDelete = rec.count
        try store.deletePage(id: page.id)
        try await awaitCount(rec, beforeDelete + 1)
        // Exactly one new event for the delete — no double-emit, no deadlock.
        #expect(rec.count == beforeDelete + 1)
        #expect(rec.snapshot.last?.kind == .page)
        #expect(rec.snapshot.last?.change == .deleted)
    }

    /// (b) A subscriber that re-enters the store to READ observes the COMMITTED
    /// value (the event fires post-commit, after the lock is released). This
    /// catches a misplaced/inner flush that would let a reader see uncommitted
    /// (or locked-out) state.
    @Test func reentrantReaderSeesCommittedState() async throws {
        let (store, _, _) = try makeHarness()

        // A thread-safe slot for the handler's read result.
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var value: WikiPage?
            func set(_ p: WikiPage) { lock.lock(); value = p; lock.unlock() }
            func get() -> WikiPage? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let slot = Slot()
        store.eventBus?.subscribe(nil) { event in
            guard event.kind == .page, event.change == .created else { return }
            // Re-enter the store via its public READ API. This acquires the lock
            // again; it must succeed (lock is free post-flush) and read the row
            // that was just committed.
            if let page = try? store.getPage(id: PageID(rawValue: event.id)) {
                slot.set(page)
            }
        }

        let created = try store.createPage(title: "Committed")
        // Wait for the handler's read to land.
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline, slot.get() == nil {
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        let read = slot.get()
        #expect(read != nil, "re-entrant read returned nothing (deadlock or pre-commit flush)")
        #expect(read?.id == created.id)
        #expect(read?.title == "Committed")
    }

    /// (c) A mutation that throws / rolls back emits NOTHING (no subscriber ever
    /// acts on an aborted change).
    @Test func throwingMutationEmitsNothing() async throws {
        let (store, _, rec) = try makeHarness()
        // updatePage on a non-existent id throws .notFound AFTER the UPDATE runs
        // (0 rows changed) — inside mutate's body, so the catch branch discards
        // the buffered event.
        #expect(throws: WikiStoreError.self) {
            try store.updatePage(id: PageID(rawValue: "01HNONEXISTENT00000000"), title: "x", body: "y")
        }
        // Drain the run loop; nothing should arrive.
        await flushBusDeliveries()
        try? await Task.sleep(for: .milliseconds(20))
        await flushBusDeliveries()
        #expect(rec.count == 0, "a rolled-back mutation must not emit")
    }

    /// A burst of independent mutations emits one event per mutation (coalescing
    /// is the subscriber's job, not the bus's). Confirms the seq counter and the
    /// registry stay consistent across a burst.
    @Test func burstEmitsOneEventPerMutation() async throws {
        let (store, _, rec) = try makeHarness()
        for i in 0..<5 { _ = try store.createPage(title: "P\(i)") }
        try await awaitCount(rec, 5)
        #expect(rec.count == 5)
        // Every event is distinct (distinct page ids) and seq is strictly
        // increasing.
        let ids = rec.snapshot.map(\.id)
        #expect(Set(ids).count == 5)
        let seqs = rec.snapshot.map(\.seq)
        #expect(seqs == seqs.sorted())
    }
}
