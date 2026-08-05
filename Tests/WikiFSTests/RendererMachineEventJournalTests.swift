import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererMachineEventJournalTests {
    @Test func freshJournalHasZeroHighWater() async throws {
        let journal = RendererMachineEventJournal(layout: try layout("fresh"))
        #expect(try await journal.highWater(scope: scope) == 0)
    }

    @Test func coordinatedMutationAllocatesScopedMonotoneRecords() async throws {
        let store = RendererMachineIndexStore(layout: try layout("monotone"))
        _ = try await store.read()
        let first = try await store.mutateAndAppendMachineEvent(expectedGeneration: 0, scope: scope, payload: .machineSafeModeChanged(isEnabled: true), eventIDGenerator: IDs(), sequenceGenerator: Sequences(), clock: Clock()) { _, safeMode in safeMode = true }
        let second = try await store.mutateAndAppendMachineEvent(expectedGeneration: 1, scope: scope, payload: .machineSafeModeChanged(isEnabled: false), eventIDGenerator: IDs(), sequenceGenerator: Sequences(), clock: Clock()) { _, safeMode in safeMode = false }
        #expect(first.record.sequence == 1)
        #expect(second.record.sequence == 2)
    }

    @Test func failedCoordinatedMutationLeavesNoRecord() async throws {
        let layout = try layout("rollback")
        let store = RendererMachineIndexStore(layout: layout)
        _ = try await store.read()
        await #expect(throws: Failure.self) {
            try await store.mutateAndAppendMachineEvent(expectedGeneration: 0, scope: scope, payload: .machineSafeModeChanged(isEnabled: true)) { _, _ in throw Failure() }
        }
        let journal = RendererMachineEventJournal(layout: layout)
        #expect(try await journal.highWater(scope: scope) == 0)
        #expect(try await store.read().generation == 0)
    }

    @Test func scopedOrderedDrainIsBoundedAndReportsHighWater() async throws {
        let layout = try layout("drain")
        let journal = RendererMachineEventJournal(layout: layout)
        try await journal.append(record(sequence: 1))
        try await journal.append(record(sequence: 2))
        let batch = try await journal.records(after: 0, scope: scope, limit: 1)
        #expect(batch.records.map(\.sequence) == [1])
        #expect(batch.highWater == 2)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventLeaseTests {
    @Test func productionGeneratedFractionalOffsetTimestampsPreserveLeaseBoundaries() async throws {
        let journal = RendererMachineEventJournal(layout: try layout("production-timestamps"))
        let registry = RendererMachineLeaseRegistry(journal: journal)
        let zone = try #require(TimeZone(secondsFromGMT: 19_800))
        let started = RFC3339Timestamp(date: Date(timeIntervalSince1970: 10_000), timeZone: zone)
        let lease = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: started, now: started)
        let beforeExpiry = RFC3339Timestamp(date: Date(timeIntervalSince1970: 10_059.9), timeZone: zone)
        await #expect(throws: RendererMachineEventJournalError.liveLeaseCannotBeReclaimed) { try await registry.reclaim(lease, at: beforeExpiry, isProcessLive: false) }
        let expired = RFC3339Timestamp(date: Date(timeIntervalSince1970: 10_061), timeZone: zone)
        try await registry.reclaim(lease, at: expired, isProcessLive: false)
    }

    @Test func retiredLeaseCannotBeResurrectedByHeartbeat() async throws {
        let registry = RendererMachineLeaseRegistry(journal: RendererMachineEventJournal(layout: try layout("retired-heartbeat")))
        let lease = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: time, now: time)
        try await registry.retire(lease, at: later("2026-08-05T12:00:01+00:00"))
        await #expect(throws: RendererMachineEventJournalError.liveLeaseCannotBeReclaimed) { try await registry.heartbeat(lease, at: later("2026-08-05T12:00:02+00:00")) }
    }
    @Test func twoLiveSameSubsystemLeasesAreIndependent() async throws {
        let journal = RendererMachineEventJournal(layout: try layout("leases"))
        let registry = RendererMachineLeaseRegistry(journal: journal)
        let first = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: "host", startedAt: time, now: time)
        let second = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 2, executableIdentity: "renderer", hostIdentity: "host", startedAt: time, now: time)
        #expect(first.leaseID != second.leaseID)
        #expect(try await registry.cursor(scope: scope, subsystemID: subsystem, leaseID: first.leaseID) == 0)
        #expect(try await registry.cursor(scope: scope, subsystemID: subsystem, leaseID: second.leaseID) == 0)
    }

    @Test func liveLeaseAndHeartbeatCannotBeReclaimed() async throws {
        let registry = RendererMachineLeaseRegistry(journal: RendererMachineEventJournal(layout: try layout("live")))
        let lease = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: time, now: time)
        try await registry.heartbeat(lease, at: later("2026-08-05T12:00:50+00:00"))
        await #expect(throws: RendererMachineEventJournalError.liveLeaseCannotBeReclaimed) { try await registry.reclaim(lease, at: later("2026-08-05T12:01:01+00:00"), isProcessLive: false) }
        await #expect(throws: RendererMachineEventJournalError.liveLeaseCannotBeReclaimed) { try await registry.reclaim(lease, at: later("2026-08-05T13:00:00+00:00"), isProcessLive: true) }
    }

    @Test func staleAndCleanRetiredLeasesObserveSafetyWindows() async throws {
        let registry = RendererMachineLeaseRegistry(journal: RendererMachineEventJournal(layout: try layout("stale")))
        let lease = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: time, now: time)
        try await registry.reclaim(lease, at: later("2026-08-05T12:01:01+00:00"), isProcessLive: false)
        let replacement = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: time, now: time)
        try await registry.retire(replacement, at: time)
        await #expect(throws: RendererMachineEventJournalError.liveLeaseCannotBeReclaimed) { try await registry.reclaim(replacement, at: later("2026-08-05T12:04:59+00:00"), isProcessLive: false) }
        try await registry.reclaim(replacement, at: later("2026-08-05T12:05:00+00:00"), isProcessLive: false)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererTimestampPersistenceTests {
    @Test func malformedPersistedTimestampFailsClosed() throws {
        let data = Data("\"not-a-timestamp\"".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RFC3339Timestamp.self, from: data) }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventCursorTests {
    @Test func cursorAdvancesOnlyAfterExplicitSuccessAndCheckpointIsConservative() async throws {
        let journal = RendererMachineEventJournal(layout: try layout("cursor"))
        let registry = RendererMachineLeaseRegistry(journal: journal)
        let lease = try await registry.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "renderer", hostIdentity: nil, startedAt: time, now: time)
        let event = record(sequence: 1)
        try await journal.append(event)
        #expect(try await registry.cursor(scope: scope, subsystemID: subsystem, leaseID: lease.leaseID) == 0)
        try await registry.markHandled(event, lease: lease)
        #expect(try await registry.cursor(scope: scope, subsystemID: subsystem, leaseID: lease.leaseID) == 1)
    }

    @Test func unsupportedEnvelopeSchemaIsRejectedBeforeSuccess() throws {
        #expect(throws: RendererValidationError.self) {
            try PersistedWikiStoreChangeRecord(schemaVersion: 2, eventID: UUID(), sequence: 1, scope: .machine(scope), payload: .rendererSettings(.machineSafeModeChanged(isEnabled: true)), committedAt: time)
        }
    }
}

private let scope = try! RendererMachineScopeID(validating: "renderer-machine")
private let subsystem = try! RendererEventSubsystemID(validating: "renderer-registry")
private let time = try! RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
private func later(_ raw: String) -> RFC3339Timestamp { try! RFC3339Timestamp(validating: raw) }
private func layout(_ name: String) throws -> RendererPackageStoreLayout { let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-event-\(name)-\(UUID().uuidString)", isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return try RendererPackageStoreLayout(appGroupContainerRoot: root) }
private func record(sequence: UInt64) -> PersistedWikiStoreChangeRecord { try! PersistedWikiStoreChangeRecord(eventID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(sequence)")!, sequence: sequence, scope: .machine(scope), payload: .rendererSettings(.machineSafeModeChanged(isEnabled: true)), committedAt: time) }
private struct IDs: RendererEventIDGenerating { func nextEventID() -> UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! } }
private struct Sequences: RendererEventSequenceGenerating { func nextSequence(after sequence: UInt64) -> UInt64 { sequence + 1 } }
private struct Clock: RendererEventClock { func now() -> RFC3339Timestamp { time } }
private struct Failure: Error {}
