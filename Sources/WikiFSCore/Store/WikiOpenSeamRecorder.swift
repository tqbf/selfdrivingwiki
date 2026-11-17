import Foundation

/// The client-reachable storage factories the daemon-only migration guards
/// (plans/daemon-only-access.md, Phase 0 open-seam harness). Each case is one
/// injected open seam; `ClientLocalOpenBoundaryTests` counts the records.
public enum WikiStorageSeam: String, CaseIterable, Sendable {
    /// The read/write wiki store opened by `StorePlugin` (composition) or
    /// the `StoreBackend` default factory.
    case wikiStore
    /// The read-only connections opened by `WikiReadService`'s private pool.
    case wikiReadOnlyStore
    /// The local queue database opened by `QueueRuntimeFactory` and the
    /// `AppQueueExtractionProvider` follow-on paths.
    case queueStore
    /// The local Tantivy writer assembled by
    /// `SearchRuntimeCompositionFactory`.
    case tantivyIndexerWriter
    /// One app-local queue-provider WORKER invocation (the
    /// `QueueExtractionProvider` / `QueueIngestionProvider` entry points the
    /// queue engine calls to execute an item). Recorded only by the APP
    /// providers (`AppQueueExtractionProvider` / `AppQueueIngestionProvider`)
    /// — the daemon's provider types never touch this recorder, so a record
    /// proves a pipeline ran in the app process. Phase 4's gate
    /// (plans/daemon-only-access.md, AC.8) asserts ZERO of these once the
    /// app-local engine is gone; slice 1 removes the engine (the only
    /// caller), so the count is already zero, and the P4.3 workload
    /// migration deletes the provider types' remaining non-worker consumers.
    case queueProviderInvocation
}

/// One recorded open at an injected seam.
public struct WikiOpenSeamRecord: Equatable, Sendable {
    public let seam: WikiStorageSeam
    /// Free-form attribution the injecting factory supplies (e.g. the wiki
    /// database path). Test assertions match on it.
    public let label: String

    public init(seam: WikiStorageSeam, label: String) {
        self.seam = seam
        self.label = label
    }
}

/// Process-wide recorder for the injected storage-open seams.
///
/// The recorder is consulted ONLY by factories that a composition explicitly
/// injected (the test harness wires recording factories into the app
/// composition; the daemon keeps its plain factories). Attribution is
/// therefore by construction: an open recorded here happened on a path the
/// harness explicitly instrumented, and daemon-side fixture opens never reach
/// it. `ClientLocalOpenBoundaryTests` uses `records()`/`count(_:)` to assert
/// the per-phase permitted-access columns and `reset()` between scenarios.
///
/// Thread safety: every read and write of the record list is covered by an
/// NSLock, which is what makes the @unchecked Sendable conformance safe.
// swiftlint:disable:next unchecked_sendable
public final class WikiOpenSeamRecorder: @unchecked Sendable {
    public static let shared = WikiOpenSeamRecorder()

    private let lock = NSLock()
    private var records: [WikiOpenSeamRecord] = []

    private init() {}

    /// Called by injected factories immediately before (or after) the real
    /// open. `label` identifies the storage location (database path, index
    /// directory).
    public func record(seam: WikiStorageSeam, label: String) {
        lock.lock()
        defer { lock.unlock() }
        records.append(WikiOpenSeamRecord(seam: seam, label: label))
    }

    /// Convenience for factory closures that both record and construct.
    public func recording<Success>(
        seam: WikiStorageSeam,
        label: String,
        _ make: () throws -> Success
    ) rethrows -> Success {
        record(seam: seam, label: label)
        return try make()
    }

    /// All records since the last `reset()`, in open order.
    public func allRecords() -> [WikiOpenSeamRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// Number of recorded opens for one seam since the last `reset()`.
    public func count(_ seam: WikiStorageSeam) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return records.lazy.filter { $0.seam == seam }.count
    }

    /// Distinct labels recorded for one seam since the last `reset()`.
    public func labels(_ seam: WikiStorageSeam) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        var ordered: [String] = []
        for record in records where record.seam == seam && seen.insert(record.label).inserted {
            ordered.append(record.label)
        }
        return ordered
    }

    /// Drops every recorded open. Called between harness scenarios.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }
}
