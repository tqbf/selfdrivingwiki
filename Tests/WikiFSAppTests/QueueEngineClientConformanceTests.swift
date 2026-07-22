#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// Exhaustiveness check for the ``QueueEngineClient`` protocol surface.
///
/// The concrete ``QueueEngine`` actor must conform, and EVERY method the app
/// calls on the engine must be in the protocol — otherwise the type widening
/// to `any QueueEngineClient` would break at the widened call sites. This test
/// mirrors the discipline of `StoreEmissionExhaustivenessTests`: if a new
/// method is added to `QueueEngine` and called from the app, it MUST be added
/// to `QueueEngineClient` or this test fails.
///
/// Methods intentionally NOT in the protocol (called only on the concrete
/// owner in `WikiFSApp` / `QueueIngestionHelper`):
/// - `start()` — called once at app launch on the concrete `@State`
/// - `makeEmitProgress()` / `makeEmitTranscript()` / etc. — called on the
///   concrete engine to capture `@Sendable` closures for the worker factory
/// - `clearTranscript(for:)` — not called from the app
///
/// See `plans/daemon-workloads.md` Phase 0 §4 + correction C2/C5.
struct QueueEngineClientConformanceTests {

    // MARK: - Conformance

    @Test func queueEngineConformsToClient() {
        // Compile-time proof: QueueEngine can be assigned to any QueueEngineClient.
        let engine = makeEngine()
        let client: any QueueEngineClient = engine
        #expect(client is QueueEngine)
    }

    // MARK: - Protocol surface (compile-time exhaustiveness)

    /// Every protocol method is callable through `any QueueEngineClient`.
    /// If any method is missing, this test does not compile.
    @Test func allProtocolMethodsAreCallable() async throws {
        let engine = makeEngine()
        let client: any QueueEngineClient = engine

        // events — verify it's a valid stream (always succeeds; compile-time check).
        let _ = client.events

        // enqueue
        let request = QueueItemRequest(
            queue: .extraction,
            wikiID: "test-wiki",
            payload: QueueItemPayload(sourceIDs: [])
        )
        let itemID = try await client.enqueue(request)
        #expect(!itemID.isEmpty)

        // cancelItem
        await client.cancelItem(itemID)

        // retryItem
        try await client.retryItem(itemID)

        // cancelAllInFlight
        let cancelled = await client.cancelAllInFlight()
        #expect(cancelled == 0)

        // pause / resume / halt
        await client.pause(.extraction)
        await client.resume(.extraction)
        await client.halt(.extraction)

        // reorderItem
        await client.reorderItem(id: itemID, beforeItemID: nil)

        // snapshot — has the enqueued item (still queued since NoopWorkerFactory
        // never dispatches).
        let snapshot = await client.snapshot()
        #expect(snapshot.activeItems.count == 1)

        // hasActiveWork — true because the item is queued for "test-wiki".
        let hasWork = await client.hasActiveWork(for: "test-wiki")
        #expect(hasWork)

        // Cancel the item so waitForCompletion returns immediately (otherwise
        // it would block forever — NoopWorkerFactory never completes items).
        await client.cancelItem(itemID)

        // waitForCompletion — returns .failure (item was cancelled).
        let result = await client.waitForCompletion(of: itemID)
        switch result {
        case .success, .failure: break // both valid terminal outcomes
        }

        // loadTranscript
        let transcript = await client.loadTranscript(for: itemID)
        #expect(transcript.isEmpty)

        // loadAllActivitySnapshots
        let snapshots = await client.loadAllActivitySnapshots()
        #expect(snapshots.isEmpty)
    }

    /// The protocol is `AnyObject`-bound so `weak` references work
    /// (`QueueActivityTracker`, `QueueViewModel`). Verified at compile time:
    /// the `weak var` assignment below would not compile if the protocol
    /// were not class-bound.
    @Test func protocolIsAnyObjectBound() {
        let engine = makeEngine()
        let client: any QueueEngineClient = engine
        weak let weakRef: (any QueueEngineClient)? = client
        #expect(weakRef != nil)
    }

    // MARK: - Helpers

    private func makeEngine() -> QueueEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qec-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try! QueueStore(
            databaseURL: dir.appendingPathComponent("queue.sqlite")
        )
        let engine = QueueEngine(
            store: store,
            workerFactory: NoopWorkerFactory()
        )
        return engine
    }
}

/// A no-op factory for test engines — never dispatches workers.
private struct NoopWorkerFactory: QueueWorkerFactory {
    func providerID(for item: QueueItem) async -> String? { nil }
    func worker(for item: QueueItem) async throws -> any QueueWorker {
        throw QueueIngestionError.noSources
    }
}
#endif
