import Foundation
import Testing
@testable import WikiFSCore

/// Focused correctness tests for the DEBUG in-memory `init()` on
/// `GRDBWikiStore` (issue #651). Verifies the `:memory:` path behaves
/// identically to the file-backed init for the three concerns that
/// `mutate()` + the WAL guard touch:
///
/// 1. **Basic CRUD** — `createPage`, `getPage`, `updatePage`, `deletePage`
///    round-trip through the in-memory `DatabaseQueue` connection, proving
///    the migration ladder (`migrateIfNeeded`) and `ensureSearchIndexesPopulated`
///    ran cleanly without WAL.
/// 2. **Event emission** — `ResourceChangeEvent` fires after `mutate()`
///    commits (post-write, outside the writer queue). This pins the same
///    guarantee `StoreEmissionTests` pins for the file-backed store —
///    `unsafeReentrantWrite` is a protocol requirement on `DatabaseWriter`
///    and dispatches identically through `DatabaseQueue` as through
///    `DatabasePool`.
/// 3. **Reentrancy** — `withTransaction` wrapping a `mutate`-based mutator
///    (`deletePage`) nests via `unsafeReentrantWrite` + `inSavepoint` (SAVEPOINT
///    nesting) and emits exactly once. Mirrors `StoreEmissionReentrancyTests`.
///
/// Fast-tier: these are quick (no file I/O, no migration-heavy seeding). They
/// do NOT carry `.tags(.integration)` — they're the canary that the in-memory
/// path compiles + works on every PR, not gated behind the slow integration job.
@Suite("In-memory store init correctness (#651)")
struct InMemoryStoreTests {

    // MARK: - 1. CRUD on :memory:

    @Test func inMemoryStore_createReadUpdateDelete() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Test")
        #expect(try store.getPage(id: page.id).title == "Test")

        try store.updatePage(id: page.id, title: "Updated", body: "body")
        let fetched = try store.getPage(id: page.id)
        #expect(fetched.title == "Updated")
        #expect(fetched.bodyMarkdown == "body")

        try store.deletePage(id: page.id)
        #expect(throws: Error.self) {
            _ = try store.getPage(id: page.id)
        }
    }

    @Test func inMemoryStore_schemaIsAtCurrentVersion() throws {
        // A fresh in-memory DB takes the `version == 0` fast path and stamps
        // to currentSchemaVersion. Re-opening (a fresh :memory:) also reports
        // the same — exercises `migrateIfNeeded` end-to-end on :memory:.
        let store = try TestStoreFactory.inMemory()
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func inMemoryStore_ftsIndexIsPopulatedAfterCreate() throws {
        // Post-#634: FTS5 is gone — `:memory:` no longer has an FTS5 leg for
        // `searchSimilar` to fall back on. With `bm25Leg: nil` and the cosine
        // leg empty under `swift test` (NLEmbedding is app-gated), the result
        // is empty. Prove the contract holds on `:memory:` by supplying a
        // fabricated leg (mirroring `TantivyBM25LegCutoverTests`): with no
        // page_chunks the cosine leg is empty so the fused output equals the
        // leg exactly — proves `mutate()` + `ensureSearchIndexesPopulated` ran
        // cleanly on the `:memory:` `DatabaseQueue` (no WAL pragma, no
        // file-based checkpoint).
        let store = try TestStoreFactory.inMemory()
        _ = try store.createPage(title: "Hypnosis")
        let page = try store.createPage(title: "Notes")
        try store.updatePage(id: page.id, title: "Notes",
                             body: "Details about clinical hypnosis and suggestion.")
        // nil leg → no BM25 results (FTS5 dropped; cosine gated).
        #expect(try store.searchSimilar(query: "hypnosis", limit: 10, bm25Leg: nil).isEmpty)
        // Fabricated leg targeting the page → pass-through unchanged.
        let leg = [WikiPageSummary(
            id: page.id, title: page.title,
            updatedAt: page.updatedAt, createdAt: page.createdAt)]
        let hits = try store.searchSimilar(query: "hypnosis", limit: 10, bm25Leg: leg)
        #expect(hits.contains { $0.id == page.id })
    }

    // MARK: - 2. Event emission

    @MainActor
    @Test func inMemoryStore_emitsEventAfterMutate() async throws {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus

        let recorder = LockRecorder()
        bus.subscribe(nil) { recorder.append($0) }

        let page = try store.createPage(title: "Hello")

        // The bus delivers on the main actor; flush runloop until the event lands.
        try await Self.awaitCount(recorder, expected: 1)

        let events = recorder.snapshot
        #expect(events.count == 1)
        #expect(events.first?.kind == .page)
        #expect(events.first?.change == .created)
        #expect(events.first?.id == page.id.rawValue)
    }

    // MARK: - 3. Reentrancy (mutate inside withTransaction)

    @MainActor
    @Test func inMemoryStore_reentrantMutationEmitsOnceNoDeadlock() async throws {
        let store = try TestStoreFactory.inMemory()
        let bus = WikiEventBus(wikiID: "W")
        store.eventBus = bus

        let recorder = LockRecorder()
        bus.subscribe(nil) { recorder.append($0) }

        let page = try store.createPage(title: "Doomed")
        try await Self.awaitCount(recorder, expected: 1)
        recorder.clear()

        // deletePage is `mutate`-based; wrapping it in `withTransaction` nests
        // `inSavepoint` inside the outer transaction. Verifies that
        // `unsafeReentrantWrite` dispatches correctly on `DatabaseQueue` and
        // the event flushes exactly once at the outermost exit — no deadlock,
        // no double-emit (the structural-safety contract from AC.3).
        try store.withTransaction {
            try store.deletePage(id: page.id)
        }

        try await Self.awaitCount(recorder, expected: 1)
        #expect(recorder.count == 1)
        #expect(recorder.snapshot.first?.kind == .page)
        #expect(recorder.snapshot.first?.change == .deleted)
    }

    // MARK: - Helpers

    /// Lock-guarded synchronous collector — the @MainActor handler appends
    /// without awaiting. Mirrors `StoreEmissionTests.Recorder`.
    private final class LockRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ e: ResourceChangeEvent) { lock.lock(); events.append(e); lock.unlock() }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }
        var count: Int { snapshot.count }
        func clear() { lock.lock(); events.removeAll(); lock.unlock() }
    }

    /// Poll `recording.count` until `expected` is reached (bounded). The bus
    /// delivers on the main actor via `Task`, so we flush the runloop between
    /// checks. Returns silently on timeout (the caller's `#expect` then
    /// surfaces the actual count); mirrors the existing pattern in
    /// `StoreEmissionReentrancyTests.awaitCount`.
    private static func awaitCount(
        _ recorder: LockRecorder,
        expected: Int,
        timeoutMs: Int = 3000
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if recorder.count >= expected { return }
            await flushBusDeliveries()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
