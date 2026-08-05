import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventAtLeastOnceTests {
    @Test func crashAfterHandlerBeforeCursorCausesReplay() async throws {
        let fixture = try await DeliveryFixture("crash-replay")
        let probe = DeliveryProbe()
        let replacement = try await fixture.makeLease()
        try await fixture.journal.append(fixture.record(sequence: 1))
        let first = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            await probe.record()
        }
        // Model a crash after authoritative handler success, before durable
        // cursor advancement: a replacement lease sees the event again.
        await probe.record()
        let second = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: replacement) { _ in
            await probe.record()
        }
        try await second.receiveWake()
        #expect(await probe.count == 2)
        #expect(try await fixture.leases.cursor(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: replacement.leaseID) == 1)
        _ = first
    }

    @Test func replayProducesIdempotentFinalModelState() async throws {
        let fixture = try await DeliveryFixture("idempotent")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let projection = IdempotentProjection()
        let reader = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            await projection.reload()
        }
        try await reader.receiveWake()
        try await reader.receiveWake()
        #expect(await projection.value == 1)
    }

    @Test func handlerFailureLeavesCursorUnchanged() async throws {
        let fixture = try await DeliveryFixture("handler-failure")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let reader = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            throw DeliveryFailure()
        }
        await #expect(throws: DeliveryFailure.self) { try await reader.receiveWake() }
        #expect(try await fixture.leases.cursor(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: fixture.lease.leaseID) == 0)
    }

}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventRetentionTests {
    @Test func retentionGapReloadsAuthorityAndResetsCursorAndCheckpoint() async throws {
        let fixture = try await DeliveryFixture("retention-gap")
        let reloads = DeliveryProbe()
        let deliveries = DeliveryProbe()
        try await fixture.journal.append(fixture.record(sequence: 1))
        try await fixture.journal.append(fixture.record(sequence: 2))
        try await fixture.journal.append(fixture.record(sequence: 3))
        try await fixture.leases.markHandled(fixture.record(sequence: 1), lease: fixture.lease)
        try await fixture.journal.discardRecords(through: 2, scope: fixture.scope)

        let reader = RendererMachineEventReader(
            journal: fixture.journal,
            leases: fixture.leases,
            lease: fixture.lease,
            handler: { _ in await deliveries.record() },
            retentionGapHandler: { await reloads.record() }
        )
        try await reader.receiveWake()

        #expect(await reloads.count == 1)
        #expect(await deliveries.count == 0)
        #expect(try await fixture.leases.cursor(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: fixture.lease.leaseID) == 3)
        #expect(try await fixture.leases.checkpoint(scope: fixture.scope, subsystemID: fixture.subsystem) == 3)
    }

    @Test func cursorBeyondHighWaterReloadsAuthorityInsteadOfSilentlyNoOping() async throws {
        let fixture = try await DeliveryFixture("cursor-ahead")
        let reloads = DeliveryProbe()
        try await fixture.journal.append(fixture.record(sequence: 1))
        try await fixture.journal.append(fixture.record(sequence: 2))
        try await fixture.leases.resetAfterAuthoritativeReload(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: fixture.lease.leaseID, highWater: 4)
        let reader = RendererMachineEventReader(
            journal: fixture.journal,
            leases: fixture.leases,
            lease: fixture.lease,
            handler: { _ in },
            retentionGapHandler: { await reloads.record() }
        )

        try await reader.receiveWake()

        #expect(await reloads.count == 1)
        #expect(try await fixture.leases.cursor(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: fixture.lease.leaseID) == 2)
        #expect(try await fixture.leases.checkpoint(scope: fixture.scope, subsystemID: fixture.subsystem) == 2)
    }

    @Test func cancellationDuringHandlerDoesNotAdvanceRetiredLeaseCursor() async throws {
        let fixture = try await DeliveryFixture("retired-lease")
        let barrier = DeliveryHandlerBarrier()
        try await fixture.journal.append(fixture.record(sequence: 1))
        try await fixture.journal.append(fixture.record(sequence: 2))
        let reader = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            await barrier.recordEntry()
            try await barrier.waitForRelease()
        }

        let drain = Task { try await reader.receiveWake() }
        try await waitForDeliveryCondition("handler entry") { await barrier.entered }
        try await reader.cancel(at: fixture.time)
        await barrier.release()
        try await drain.value

        #expect(await barrier.entryCount == 1)
        #expect(try await fixture.leases.cursor(scope: fixture.scope, subsystemID: fixture.subsystem, leaseID: fixture.lease.leaseID) == 0)
        #expect(try await fixture.leases.checkpoint(scope: fixture.scope, subsystemID: fixture.subsystem) == 0)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventTwoInstanceDeliveryTests {
    @Test func twoIndependentInstancesDeliverAfterBothLeasesAreReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-two-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let scope = try RendererMachineScopeID(validating: "renderer-machine")
        let subsystem = try RendererEventSubsystemID(validating: "renderer-registry")
        let time = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let firstJournal = RendererMachineEventJournal(layout: layout)
        let secondJournal = RendererMachineEventJournal(layout: layout)
        let firstLeases = RendererMachineLeaseRegistry(journal: firstJournal)
        let secondLeases = RendererMachineLeaseRegistry(journal: secondJournal)
        let firstLease = try await firstLeases.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "instance-one", hostIdentity: nil, startedAt: time, now: time)
        let secondLease = try await secondLeases.createLease(scope: scope, subsystemID: subsystem, processID: 2, executableIdentity: "instance-two", hostIdentity: nil, startedAt: time, now: time)
        let event = try PersistedWikiStoreChangeRecord(eventID: UUID(), sequence: 1, scope: .machine(scope), payload: .rendererSettings(.machineSafeModeChanged(isEnabled: true)), committedAt: time)
        try await firstJournal.append(event)
        let deliveries = DeliveryProbe()
        let firstReader = RendererMachineEventReader(journal: firstJournal, leases: firstLeases, lease: firstLease) { _ in await deliveries.record() }
        let secondReader = RendererMachineEventReader(journal: secondJournal, leases: secondLeases, lease: secondLease) { _ in await deliveries.record() }

        async let firstDrain: Void = firstReader.receiveWake()
        async let secondDrain: Void = secondReader.receiveWake()
        try await firstDrain
        try await secondDrain

        #expect(await deliveries.count == 2)
        #expect(try await firstLeases.cursor(scope: scope, subsystemID: subsystem, leaseID: firstLease.leaseID) == 1)
        #expect(try await secondLeases.cursor(scope: scope, subsystemID: subsystem, leaseID: secondLease.leaseID) == 1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererEventWakeTests {
    @Test func wakeWithoutCommittedRecordIsNoOp() async throws {
        let fixture = try await DeliveryFixture("wake-noop")
        let probe = DeliveryProbe()
        let reader = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            await probe.record()
        }
        try await reader.receiveWake()
        #expect(await probe.count == 0)
    }

    @Test func duplicateWakeRunsOneOrderedDrainPerLease() async throws {
        let fixture = try await DeliveryFixture("duplicate")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let probe = DeliveryProbe()
        let reader = RendererMachineEventReader(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease) { _ in
            await probe.record()
        }
        async let first: Void = reader.receiveWake()
        async let second: Void = reader.receiveWake()
        try await first
        try await second
        #expect(await probe.count == 1)
    }

    @Test func machineRoutingRejectsResourceNames() throws {
        let scope = try RendererMachineScopeID(validating: "renderer-machine")
        #expect(RendererMachineWakeRouting.scope(forNotificationName: RendererChangeNotification.machineName(for: scope), observedScopes: [scope]) == scope)
        #expect(RendererMachineWakeRouting.scope(forNotificationName: WikiChangeNotification.name(forWikiID: "01H"), observedScopes: [scope]) == nil)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererMachineEventFanOutTests {
    @Test func machineEventRefreshesTwoLiveWikiSessions() async throws {
        let fixture = try await DeliveryFixture("fanout")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let first = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("first.sqlite")))
        let second = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("second.sqlite")))
        let subscription = RendererMachineEventSubscription(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease)
        subscription.register(first)
        subscription.register(second)
        try await subscription.receiveWake()
        #expect(first.rendererMachineAvailabilityRevision == 1)
        #expect(second.rendererMachineAvailabilityRevision == 1)
    }

    @Test func inactiveWikiRefreshesOnNextOpen() async throws {
        let fixture = try await DeliveryFixture("inactive")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let live = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("live.sqlite")))
        let inactive = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("inactive.sqlite")))
        let subscription = RendererMachineEventSubscription(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease)
        subscription.register(live)
        try await subscription.receiveWake()
        #expect(live.rendererMachineAvailabilityRevision == 1)
        #expect(inactive.rendererMachineAvailabilityRevision == 0)
        subscription.register(inactive)
        inactive.reloadRendererMachineAvailability()
        #expect(inactive.rendererMachineAvailabilityRevision == 1)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsProjectionIsolationTests {
    @Test func rendererSettingsDoNotReloadResourceProjection() async throws {
        let fixture = try await DeliveryFixture("isolation")
        try await fixture.journal.append(fixture.record(sequence: 1))
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("wiki.sqlite")))
        let initialSummaries = model.summaries
        let subscription = RendererMachineEventSubscription(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease)
        subscription.register(model)
        try await subscription.receiveWake()
        #expect(model.rendererMachineAvailabilityRevision == 1)
        #expect(model.summaries == initialSummaries)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsSubscriptionTests {
    @Test func teardownRetiresLeaseAndStopsWakeReads() async throws {
        let fixture = try await DeliveryFixture("teardown")
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: fixture.root.appendingPathComponent("wiki.sqlite")))
        let subscription = RendererMachineEventSubscription(journal: fixture.journal, leases: fixture.leases, lease: fixture.lease)
        subscription.register(model)
        try await subscription.teardown(at: fixture.time)
        try await fixture.journal.append(fixture.record(sequence: 1))
        try await subscription.receiveWake()
        #expect(model.rendererMachineAvailabilityRevision == 0)
    }
}

private actor DeliveryProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor IdempotentProjection {
    private(set) var value = 0
    func reload() { value = 1 }
}

private enum DeliveryWaitFailure: Error { case timedOut }

private actor DeliveryHandlerBarrier {
    private(set) var entered = false
    private(set) var entryCount = 0
    private var released = false

    func recordEntry() {
        entered = true
        entryCount += 1
    }

    func release() { released = true }

    func waitForRelease() async throws {
        while released == false {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func waitForDeliveryCondition(_ description: String, condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DeliveryWaitFailure.timedOut
}

private struct DeliveryFailure: Error {}

private struct DeliveryFixture {
    let root: URL
    let scope: RendererMachineScopeID
    let subsystem: RendererEventSubsystemID
    let time: RFC3339Timestamp
    let journal: RendererMachineEventJournal
    let leases: RendererMachineLeaseRegistry
    let lease: RendererEventProcessLease

    init(_ name: String) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-delivery-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope = try RendererMachineScopeID(validating: "renderer-machine")
        subsystem = try RendererEventSubsystemID(validating: "renderer-registry")
        time = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        journal = RendererMachineEventJournal(layout: layout)
        leases = RendererMachineLeaseRegistry(journal: journal)
        lease = try await leases.createLease(scope: scope, subsystemID: subsystem, processID: 1, executableIdentity: "tests", hostIdentity: nil, startedAt: time, now: time)
    }

    func makeLease() async throws -> RendererEventProcessLease {
        try await leases.createLease(scope: scope, subsystemID: subsystem, processID: 2, executableIdentity: "tests", hostIdentity: nil, startedAt: time, now: time)
    }

    func record(sequence: UInt64) throws -> PersistedWikiStoreChangeRecord {
        try PersistedWikiStoreChangeRecord(eventID: UUID(), sequence: sequence, scope: .machine(scope), payload: .rendererSettings(.machineSafeModeChanged(isEnabled: true)), committedAt: time)
    }
}
