import Testing
import Foundation
@testable import WikiFSCore

/// GRDBWikiStore-specific emission-reentrancy regression tests (issue #591).
///
/// `GRDBWikiStore` uses GRDB's `DatabaseQueue` — a serial queue that does NOT
/// allow reentrant reads. Calling `dbQueue.read` from within a `dbQueue.write`
/// context traps with `Fatal error: Database methods are not reentrant`
/// (`SerializedDatabase.swift`). The former `SQLiteWikiStore` side-stepped this
/// with an `NSRecursiveLock`; GRDB's `DatabaseQueue` has no such escape hatch.
///
/// The `mutate()` seam protects against reentrance via **deferred emission**:
/// the event is *computed* inside the transaction (committed state) but
/// *emitted* AFTER `dbQueue.write` returns — outside the serial queue. Combined
/// with `WikiEventBus.emit`'s async dispatch (`Task { @MainActor in … }`),
/// subscribers' reads always land after the write commits and never re-enter
/// the writer queue.
///
/// These tests verify that contract for `GRDBWikiStore` specifically. The
/// existing `StoreEmissionReentrancyTests` only exercise `SQLiteWikiStore`
/// (whose `NSRecursiveLock` masks the problem); this suite is the regression
/// net for the backend that is actually vulnerable.
struct GRDBEmissionReentrancyTests {

    /// Thread-safe event recorder (subscribers fire on the main actor).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        var count: Int { snapshot.count }
    }

    private func awaitCount(_ recorder: Recorder, _ expected: Int, timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.count >= expected { return }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb-reentry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func makeHarness() throws -> (GRDBWikiStore, WikiEventBus, Recorder) {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus
        let recorder = Recorder()
        bus.subscribe(nil) { recorder.append($0) }
        return (store, bus, recorder)
    }

    // MARK: - (b) Reentrant read sees committed state (the core #591 scenario)

    /// A subscriber that re-enters `GRDBWikiStore` to READ via its public API
    /// (`getPage`) during event emission must observe the COMMITTED row — no
    /// `Database methods are not reentrant` trap. This is the exact crash
    /// scenario from the issue: before the deferred-emission fix, the event was
    /// emitted while the `DatabaseQueue` serial lock was still held.
    @Test func reentrantReaderSeesCommittedState() async throws {
        let (store, _, _) = try makeHarness()

        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var value: WikiPage?
            func set(_ p: WikiPage) { lock.lock(); value = p; lock.unlock() }
            func get() -> WikiPage? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let slot = Slot()
        store.eventBus?.subscribe(nil) { event in
            guard event.kind == .page, event.change == .created else { return }
            // Re-enter the store via its public READ API. On GRDB this does
            // dbQueue.read; if the writer queue were still held this traps.
            if let page = try? store.getPage(id: PageID(rawValue: event.id)) {
                slot.set(page)
            }
        }

        let created = try store.createPage(title: "Committed")
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, slot.get() == nil {
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        let read = slot.get()
        #expect(read != nil, "re-entrant read returned nothing (trap or pre-commit flush)")
        #expect(read?.id == created.id)
        #expect(read?.title == "Committed")
    }

    // MARK: - Burst emits one event per mutation

    /// A burst of independent mutations emits one event per mutation (coalescing
    /// is the subscriber's job, not the bus's). Confirms seq is strictly
    /// increasing and every page id is distinct.
    @Test func burstEmitsOneEventPerMutation() async throws {
        let (store, _, rec) = try makeHarness()
        for i in 0..<5 { _ = try store.createPage(title: "P\(i)") }
        try await awaitCount(rec, 5)
        #expect(rec.count == 5)
        let ids = rec.snapshot.map(\.id)
        #expect(Set(ids).count == 5)
        let seqs = rec.snapshot.map(\.seq)
        #expect(seqs == seqs.sorted())
    }

    // MARK: - Delete emits exactly one .deleted event

    /// `deletePage` emits exactly one `.deleted` event — no double-emit, no
    /// deadlock from re-entering the writer queue.
    @Test func deletePageEmitsOneDeletedEvent() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Doomed")
        try await awaitCount(rec, 1)
        let beforeDelete = rec.count
        try store.deletePage(id: page.id)
        try await awaitCount(rec, beforeDelete + 1)
        #expect(rec.count == beforeDelete + 1)
        #expect(rec.snapshot.last?.kind == .page)
        #expect(rec.snapshot.last?.change == .deleted)
    }

    // MARK: - Update emits exactly one .updated event with reentrant read

    /// `updatePage` emits `.updated`, and a subscriber that reads the updated
    /// body observes the new content (post-commit, outside the writer queue).
    @Test func updatePageEmitsUpdatedEventReentrantRead() async throws {
        let (store, _, rec) = try makeHarness()
        let page = try store.createPage(title: "Original")
        try await awaitCount(rec, 1)

        final class BodySlot: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let bodySlot = BodySlot()
        store.eventBus?.subscribe(nil) { event in
            guard event.kind == .page, event.change == .updated else { return }
            if let p = try? store.getPage(id: PageID(rawValue: event.id)) {
                bodySlot.set(p.bodyMarkdown)
            }
        }

        try store.updatePage(id: page.id, title: "Updated", body: "new body text", lastEditedBy: nil)
        try await awaitCount(rec, 2)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, bodySlot.get() == nil {
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(rec.snapshot.last?.change == .updated)
        #expect(bodySlot.get() == "new body text",
               "re-entrant read after update must see the new body")
    }
}
