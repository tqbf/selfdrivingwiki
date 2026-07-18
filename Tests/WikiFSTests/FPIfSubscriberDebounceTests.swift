import Testing
import Foundation
@testable import WikiFSCore

/// Integration tests for the File-Provider subscriber seam (AC.4, AC.7): a burst
/// of store events collapses to a single FP signal through the bus + the pure
/// `ChangeCoalescer`. This is exactly how `FileProviderFacade.subscribeBus(for:bus:)`
/// wires the active store's bus (a real `Task.sleep` scheduler in production); a
/// manual scheduler stands in for the window so the collapse is asserted
/// deterministically (no real File Provider domain is touched — that path is
/// untestable, as today).
@MainActor
struct FPIfSubscriberDebounceTests {

    /// Captures scheduled flush work so the test fires/cancels on demand — the
    /// same fake-clock pattern `ChangeCoalescerTests` uses.
    private final class ManualScheduler {
        private var pending: [Int: () -> Void] = [:]
        private var nextID = 0
        private(set) var cancelledIDs: [Int] = []

        func schedule(_ work: @escaping () -> Void) -> ChangeCoalescer.Handle {
            let id = nextID; nextID += 1
            pending[id] = work
            return ChangeCoalescer.Handle { [weak self] in
                self?.pending[id] = nil
                self?.cancelledIDs.append(id)
            }
        }
        func fireAll() {
            let items = pending.sorted { $0.key < $1.key }.map(\.value)
            pending.removeAll()
            for work in items { work() }
        }
    }

    /// `@MainActor` holder for the coalescer so the `@MainActor @Sendable` bus
    /// handler can reach it across the Task hop without a data-race (mirrors how
    /// production reaches it through the `@MainActor` `FileProviderFacade` `self`).
    /// Also counts deliveries so the test can deterministically await the async
    /// bus dispatch before firing the fake scheduler.
    private final class SignalBox {
        let coalescer: ChangeCoalescer
        private(set) var noteCount = 0
        init(_ coalescer: ChangeCoalescer) { self.coalescer = coalescer }
        func note(wikiID: String) {
            noteCount += 1
            coalescer.noteChange(forWikiID: wikiID)
        }
    }

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-debounce-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Wait until `box` has recorded `expected` bus deliveries (bounded). The bus
    /// dispatches each handler async via `Task { @MainActor in … }`, so the test
    /// must let the run loop spin before firing the fake scheduler.
    private func awaitDeliveries(_ box: SignalBox, expected: Int, timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if box.noteCount >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Wire the production seam: a store's bus → a `ChangeCoalescer` (with the
    /// given scheduler) whose flush records the wikiID, mirroring
    /// `FileProviderFacade.subscribeBus(for:bus:)`.
    private func wireSeam(scheduler: ManualScheduler, flushes: @escaping (String) -> Void) throws -> (GRDBWikiStore, WikiEventBus, SignalBox) {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus
        let box = SignalBox(ChangeCoalescer(
            schedule: { scheduler.schedule($0) },
            flush: { flushes($0) }
        ))
        // The production subscriber registers for ALL kinds/origins.
        bus.subscribe(nil) { _ in box.note(wikiID: "W") }
        return (store, bus, box)
    }

    /// AC.4 — a single local write signals the File Provider exactly once via the
    /// bus (no `onPageDidChange` involved).
    @Test func singleWriteSignalsOnce() async throws {
        let scheduler = ManualScheduler()
        var flushes: [String] = []
        let (store, _, box) = try wireSeam(scheduler: scheduler) { flushes.append($0) }

        _ = try store.createPage(title: "One")
        try await awaitDeliveries(box, expected: 1)
        scheduler.fireAll()
        #expect(flushes == ["W"])
    }

    /// AC.7 — a burst of writes (batch `addFiles` / many saves) collapses to a
    /// single FP signal (debounce now at the subscriber edge).
    @Test func burstCollapsesToOneSignal() async throws {
        let scheduler = ManualScheduler()
        var flushes: [String] = []
        let (store, _, box) = try wireSeam(scheduler: scheduler) { flushes.append($0) }

        for i in 0..<6 { _ = try store.createPage(title: "P\(i)") }
        try await awaitDeliveries(box, expected: 6)
        // Only the last-scheduled timer survives; the prior 5 were cancelled.
        #expect(scheduler.cancelledIDs.count == 5)

        scheduler.fireAll()
        #expect(flushes == ["W"])
    }

    /// A second burst after the first flush re-arms a fresh signal (the pending
    /// slot was cleared on flush), so back-to-back edits each get one signal.
    @Test func secondBurstAfterFlushSignalsAgain() async throws {
        let scheduler = ManualScheduler()
        var flushes: [String] = []
        let (store, _, box) = try wireSeam(scheduler: scheduler) { flushes.append($0) }
        _ = try store.createPage(title: "A")
        try await awaitDeliveries(box, expected: 1)
        scheduler.fireAll()
        #expect(flushes == ["W"])

        _ = try store.createPage(title: "B")
        try await awaitDeliveries(box, expected: 2)
        scheduler.fireAll()
        #expect(flushes == ["W", "W"])
    }
}
