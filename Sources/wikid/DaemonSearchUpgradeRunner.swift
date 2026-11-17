#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Phase 5.2 (plans/daemon-only-access.md): the DAEMON-side search-upgrade
// backfill. The embedding work the app used to run in `WikiStoreModel
// .upgradeSearchIndex` (local MiniLM embed + chunk writes) now runs here,
// against the daemon's prepared store, with progress delivered as
// `wikid.search-upgrade-event.v1` envelopes on the event firehose.
//
// Discipline carried over from the app's deleted implementation:
// - The embedder (MLX/Metal) is pure off-store compute; the chunk writes go
//   through the store's method-atomic mutators (`storePageChunks` et al.),
//   each of which emits its own change events. No inference runs inside a
//   store transaction — the scan, the embed, and the write are separate
//   await steps.
// - One run per wiki at a time (single-flight). A re-trigger while a run is
//   in flight reports the current run (`started`, current total) and starts
//   nothing.
// - The work runs on a detached task so the `upgradeSearchIndex` RPC reply
//   (`started` + total) is immediate; progress arrives on the firehose and
//   the terminal `complete`/`failed` event ends the run. Cancellation of the
//   daemon's per-wiki services (wiki close/delete/evict) cancels the task;
//   an embed loop iteration observes cancellation before each write.
//
// Tests never require the MLX model: `EmbeddingService.installTestEmbedder`
// (the existing DEBUG seam) installs a fixed-vector embedder in the fixture
// daemon's process, so the scan → embed → store loop runs model-less. A real
// model run is an optional smoke check (documented in the plan), not a gate.
// Sendable invariant: all mutable state (`runs`) is NSLock-guarded; the
// `deliver` closure is handed in per call and used from the detached run
// task only. The strong-dictionary + lock discipline mirrors
// `DaemonStoreEventCoordinator` (see its header).
// swiftlint:disable:next unchecked_sendable
final class DaemonSearchUpgradeRunner: @unchecked Sendable {

    private let lock = NSLock()
    /// Per-wiki in-flight run tasks (single-flight admission + cancellation).
    private var runs: [String: Task<Void, Never>] = [:]

    deinit {
        for task in runs.values { task.cancel() }
    }

    /// Handle one `upgradeSearchIndex` start request: configure the
    /// embedder, scan the missing work, and start the run when there is any.
    /// Returns the typed reply the executor encodes.
    ///
    /// `deliver` receives every progress/terminal event for the wiki (the
    /// daemon fans it out to live sinks). It is called from the runner's
    /// detached task — keep it non-blocking (an XPC fire-and-forget send).
    func start(
        wikiID: WikiID,
        store: any WikiStore,
        deliver: @escaping @Sendable (DaemonSearchUpgradeEvent) -> Void
    ) async -> DaemonSearchUpgradeStartReply {
        let key = wikiID.rawValue
        // Single-flight: an in-flight run answers `started` with a fresh scan
        // total (the caller's sheet re-syncs from the next progress event;
        // the run itself is not duplicated).
        if inFlightLocked(key) {
            // The re-trigger's total is informational (the caller's sheet
            // re-syncs from the next progress event); a failed rescan just
            // reports 0 — the failure is logged, never swallowed.
            let total: Int
            do {
                total = try await missingWorkTotal(store)
            } catch {
                DebugLog.store("wikid search-upgrade: re-trigger rescan failed: \(error)")
                total = 0
            }
            return DaemonSearchUpgradeStartReply(outcome: .started, total: total)
        }

        // Embedder availability: the daemon loads MiniLM through the
        // WikiFSMLX bootstrap installed at daemon start. Without a bundled
        // model (plain test executables) this answers `.embedderUnavailable`
        // — no sheet, no events.
        await EmbeddingService.configure()
        guard EmbeddingService.isAvailable else {
            return DaemonSearchUpgradeStartReply(outcome: .embedderUnavailable, total: 0)
        }

        let work: Work
        do {
            work = try await collectWork(store)
        } catch {
            DebugLog.store("wikid search-upgrade: missing-work scan failed: \(error)")
            return DaemonSearchUpgradeStartReply(outcome: .embedderUnavailable, total: 0)
        }
        let workTotal = work.pages.count + work.sources.count + work.chats.count
        guard workTotal > 0 else {
            return DaemonSearchUpgradeStartReply(outcome: .notNeeded, total: 0)
        }

        // Publish the run with a re-check under the same lock: two
        // concurrent starts cannot both admit (the loser sees the winner's
        // admission and answers `started`).
        let run = Task.detached(priority: .utility) { [weak self] () -> Void in
            await self?.runWork(work, wikiID: wikiID, store: store, deliver: deliver)
        }
        let admitted = admitLocked(key: key, task: run)
        guard admitted else {
            run.cancel()
            // Same informational-rescan rule as the in-flight branch above.
            let total: Int
            do {
                total = try await missingWorkTotal(store)
            } catch {
                DebugLog.store("wikid search-upgrade: post-admission-loss rescan failed: \(error)")
                total = 0
            }
            return DaemonSearchUpgradeStartReply(outcome: .started, total: total)
        }
        return DaemonSearchUpgradeStartReply(outcome: .started, total: workTotal)
    }

    /// Cancel any in-flight run for `wikiID` (wiki close/delete/evict).
    func cancel(wikiID: WikiID) {
        lock.lock()
        let task = runs.removeValue(forKey: wikiID.rawValue)
        lock.unlock()
        task?.cancel()
    }

    /// Test/lifecycle seam: whether a run is currently admitted.
    func isRunning(wikiID: WikiID) -> Bool {
        inFlightLocked(wikiID.rawValue)
    }

    // MARK: - Work

    /// One run's scanned work. The task closures carry it as ONE Sendable
    /// value (mutable locals cannot cross a `@Sendable` boundary).
    private typealias Work = (
        pages: [(id: PageID, text: String)],
        sources: [(id: SourceID, text: String)],
        chats: [(id: ChatID, text: String)]
    )

    private func inFlightLocked(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runs[key] != nil
    }

    /// Publish `task` for `key`; answers false when a run was already
    /// admitted (the lock makes check-and-set atomic).
    private func admitLocked(key: String, task: Task<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard runs[key] == nil else { return false }
        runs[key] = task
        return true
    }

    /// The missing-work scan (pages → sources → chats), mirroring the app's
    /// deleted scan order.
    private func collectWork(
        _ store: any WikiStore
    ) async throws -> Work {
        let pages = try await store.missingPageEmbeddingWork()
        let sources = try await store.missingSourceEmbeddingWork()
        let chats = try await store.missingChatEmbeddingWork()
        return (pages, sources, chats)
    }

    private func missingWorkTotal(_ store: any WikiStore) async throws -> Int {
        let work = try await collectWork(store)
        return work.pages.count + work.sources.count + work.chats.count
    }

    /// The embed loop: chunk + embed each document off the store, write the
    /// Float32 blobs through the store's chunk mutators, and deliver one
    /// progress event per finished item plus the terminal event.
    private func runWork(
        _ work: (
            pages: [(id: PageID, text: String)],
            sources: [(id: SourceID, text: String)],
            chats: [(id: ChatID, text: String)]
        ),
        wikiID: WikiID,
        store: any WikiStore,
        deliver: @escaping @Sendable (DaemonSearchUpgradeEvent) -> Void
    ) async {
        let total = work.pages.count + work.sources.count + work.chats.count
        var done = 0

        func emit(_ phase: DaemonSearchUpgradeEvent.Phase) {
            deliver(DaemonSearchUpgradeEvent(
                wikiID: wikiID.rawValue, phase: phase, done: done,
                total: total, state: .running))
        }

        func embedLoop<ID: Hashable & Sendable>(
            _ items: [(id: ID, text: String)],
            phase: DaemonSearchUpgradeEvent.Phase,
            storeChunks: (ID, [Data]) async throws -> Void
        ) async {
            for (id, text) in items {
                if Task.isCancelled { return }
                let blobs = await Task.detached(priority: .utility) {
                    EmbeddingService.chunkedEmbeddings(for: text)
                }.value
                if !blobs.isEmpty {
                    do {
                        try await storeChunks(id, blobs)
                    } catch {
                        DebugLog.store("wikid search-upgrade: chunk write failed: \(error)")
                    }
                }
                done += 1
                emit(phase)
                await Task.yield()
            }
        }

        emit(.pages)
        await embedLoop(work.pages, phase: .pages) { id, chunks in
            try await store.storePageChunks(id: id, chunks: chunks)
        }
        if Task.isCancelled { finish(wikiID, done: done, total: total, cancelled: true, deliver: deliver); return }
        emit(.sources)
        await embedLoop(work.sources, phase: .sources) { id, chunks in
            try await store.storeSourceChunks(id: id, chunks: chunks)
        }
        if Task.isCancelled { finish(wikiID, done: done, total: total, cancelled: true, deliver: deliver); return }
        emit(.chats)
        await embedLoop(work.chats, phase: .chats) { id, chunks in
            try await store.storeChatChunks(id: id, chunks: chunks)
        }

        finish(wikiID, done: done, total: total, cancelled: Task.isCancelled, deliver: deliver)
    }

    /// Release the admission slot and deliver the terminal event. The
    /// terminal event carries the run's FINAL counters (so the client's
    /// sheet resolves on real numbers, not zeros). A cancelled run delivers
    /// `failed` (the client's sheet resolves either way — it must never
    /// hang waiting for a `complete` that never comes).
    private func finish(
        _ wikiID: WikiID,
        done: Int,
        total: Int,
        cancelled: Bool,
        deliver: @escaping @Sendable (DaemonSearchUpgradeEvent) -> Void
    ) {
        lock.lock()
        runs.removeValue(forKey: wikiID.rawValue)
        lock.unlock()
        deliver(DaemonSearchUpgradeEvent(
            wikiID: wikiID.rawValue, phase: .chats, done: done, total: total,
            state: cancelled ? .failed : .complete))
    }
}
#endif
