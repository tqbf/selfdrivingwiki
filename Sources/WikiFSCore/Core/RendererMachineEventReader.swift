import Foundation

// pattern: Imperative Shell

/// Delivers machine renderer records to one durable process lease. Wakes are
/// deliberately only invitations to scan the journal: the cursor, not a wake
/// count or event UUID, provides at-least-once correctness.
public actor RendererMachineEventReader {
    public typealias EventHandler = @Sendable (PersistedWikiStoreChangeRecord) async throws -> Void
    public typealias RetentionGapHandler = @Sendable () async throws -> Void

    private let journal: RendererMachineEventJournal
    private let leases: RendererMachineLeaseRegistry
    private let lease: RendererEventProcessLease
    private let handler: EventHandler
    private let retentionGapHandler: RetentionGapHandler
    private let batchLimit: Int
    private var isDraining = false
    private var hasPendingWake = false
    private var isCancelled = false

    public init(
        journal: RendererMachineEventJournal,
        leases: RendererMachineLeaseRegistry,
        lease: RendererEventProcessLease,
        batchLimit: Int = RendererEventPolicy.phase3Default.orderedDrainBatchLimit,
        handler: @escaping EventHandler,
        retentionGapHandler: @escaping RetentionGapHandler = {}
    ) {
        self.journal = journal
        self.leases = leases
        self.lease = lease
        self.batchLimit = batchLimit
        self.handler = handler
        self.retentionGapHandler = retentionGapHandler
    }

    /// Handles a wake or registration scan. Concurrent/duplicate wakes only
    /// set a bit; the active drain completes its ordered scan before observing
    /// it, so one lease never handles one sequence concurrently.
    public func receiveWake() async throws {
        guard isCancelled == false else { return }
        guard isDraining == false else {
            hasPendingWake = true
            return
        }
        isDraining = true
        defer { isDraining = false }

        repeat {
            hasPendingWake = false
            try await drainUntilCaughtUp()
        } while hasPendingWake && isCancelled == false
    }

    /// Stops future scans and cleanly retires the lease. It never advances a
    /// cursor for work whose handler has not completed.
    public func cancel(at now: RFC3339Timestamp) async throws {
        isCancelled = true
        hasPendingWake = false
        try await leases.retire(lease, at: now)
    }

    private func drainUntilCaughtUp() async throws {
        while isCancelled == false {
            try Task.checkCancellation()
            let cursor = try await leases.cursor(scope: lease.scope, subsystemID: lease.subsystemID, leaseID: lease.leaseID)
            let batch = try await journal.records(after: cursor, scope: lease.scope, limit: batchLimit)
            guard isCancelled == false else { return }

            if cursor > batch.highWater {
                try await retentionGapHandler()
                guard isCancelled == false else { return }
                try await leases.resetAfterAuthoritativeReload(scope: lease.scope, subsystemID: lease.subsystemID, leaseID: lease.leaseID, highWater: batch.highWater)
                return
            }

            // A nonempty journal whose first retained record skips the cursor
            // is authoritative evidence of a retention gap. Reload, then make
            // the new high-water durable before accepting later records.
            if let first = batch.records.first, first.sequence > cursor + 1 {
                try await retentionGapHandler()
                guard isCancelled == false else { return }
                try await leases.resetAfterAuthoritativeReload(scope: lease.scope, subsystemID: lease.subsystemID, leaseID: lease.leaseID, highWater: batch.highWater)
                return
            }
            guard batch.records.isEmpty == false else { return }

            for record in batch.records {
                try Task.checkCancellation()
                // The journal validates schemas before returning records; keep
                // this guard at the delivery boundary so an injected/future
                // journal cannot call the handler with an unsupported envelope.
                guard record.schemaVersion == 1 else { throw RendererMachineEventJournalError.unsupportedSchemaVersion }
                try await handler(record)
                guard isCancelled == false else { return }
                try await leases.markHandled(record, lease: lease)
            }
        }
    }
}
