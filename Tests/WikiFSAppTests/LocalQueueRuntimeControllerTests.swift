#if os(macOS)
import Foundation
import Synchronization
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Phase 4 reduced state machine (plans/daemon-only-access.md): the app can
/// never own a local queue engine, so the controller has exactly four states
/// — unavailable / daemonActive / daemonOwnershipUnresolved / disposing — and
/// no local assembly at all. These tests pin the reduced machine: daemon
/// activation installs the daemon client, daemon loss degrades to the
/// unavailable engine, only a fresh epoch resolves the unresolved state, and
/// disposal is unconditional. There are no `localReady` /
/// `shuttingDownForDaemon` / `shutdownBlocked` / `fallingBack` transitions to
/// test: the init takes no assembly closure, so local assembly is not
/// representable.
@Suite("Local queue runtime controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LocalQueueRuntimeControllerTests {
    @Test("a fresh controller starts unavailable with no assembly closure")
    func freshControllerStartsUnavailable() async throws {
        let controller = LocalQueueRuntimeController()

        #expect(controller.state.name == "unavailable")
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("daemon activation installs the daemon client in one swap")
    func daemonActivationInstallsDaemonClient() async throws {
        let controller = LocalQueueRuntimeController()
        let daemonClient = ControllerClient(id: "daemon")

        let accepted = await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 5)))

        #expect(accepted)
        #expect(controller.state.name == "daemonActive")
        if case .daemonActive(let epoch) = controller.state {
            #expect(epoch == QueueOwnershipEpoch(rawValue: 5))
        } else {
            Issue.record("Expected daemonActive after activation")
        }
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }

    @Test("overlapping daemon activations install exactly one client")
    func overlappingActivationsInstallExactlyOne() async throws {
        let controller = LocalQueueRuntimeController()
        let first = ControllerClient(id: "first-daemon")
        let second = ControllerClient(id: "second-daemon")

        // The second activation enters the transition first (the parent task
        // is already on the main actor; the async-let child waits for the
        // actor until the parent suspends in the client swap), so the CHILD
        // activation is the rejected one. Exactly one install wins either
        // way — that is the invariant under test.
        async let childAccepted = controller.activateDaemon(.init(
            client: first,
            epoch: QueueOwnershipEpoch(rawValue: 6)))
        let parentAccepted = await controller.activateDaemon(.init(
            client: second,
            epoch: QueueOwnershipEpoch(rawValue: 7)))
        #expect(parentAccepted)
        #expect(await childAccepted == false)

        #expect(controller.state.name == "daemonActive")
        if case .daemonActive(let epoch) = controller.state {
            #expect(epoch == QueueOwnershipEpoch(rawValue: 7))
        } else {
            Issue.record("Expected the parent activation's epoch to win")
        }
        _ = try await controller.client.snapshot()
        #expect(second.snapshotCount == 1)
        #expect(first.snapshotCount == 0)
    }

    @Test("daemon loss degrades the client to unavailable without any local fallback")
    func daemonLossSurfacesUnavailable() async throws {
        let controller = LocalQueueRuntimeController()
        let daemonClient = ControllerClient(id: "daemon")
        #expect(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 11))))

        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: QueueOwnershipEpoch(rawValue: 11),
            reason: "connection invalidated")

        #expect(controller.state.name == "daemonOwnershipUnresolved")
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("daemon-loss notification for a non-active epoch is a no-op")
    func spuriousInvalidationIsIgnored() async throws {
        let controller = LocalQueueRuntimeController()
        let daemonClient = ControllerClient(id: "daemon")
        #expect(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 12))))

        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: QueueOwnershipEpoch(rawValue: 99),
            reason: "spurious invalidation")

        #expect(controller.state.name == "daemonActive")
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }

    @Test("only a fresh daemon epoch replaces the unresolved state")
    func freshEpochReplacesUnresolved() async throws {
        let controller = LocalQueueRuntimeController()
        let oldEpoch = QueueOwnershipEpoch(rawValue: 23)
        #expect(await controller.activateDaemon(.init(
            client: ControllerClient(id: "old-daemon"),
            epoch: oldEpoch)))
        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: oldEpoch,
            reason: "daemon replaced")

        // A same-epoch daemon presentation cannot resolve the unresolved
        // state — the machine has no local fallback to restore.
        let staleAccepted = await controller.replaceUnresolvedDaemon(
            .init(
                client: ControllerClient(id: "stale-daemon"),
                epoch: oldEpoch),
            expectedEpoch: oldEpoch)
        #expect(!staleAccepted)
        #expect(controller.state.name == "daemonOwnershipUnresolved")

        let replacementDaemon = ControllerClient(id: "replacement-daemon")
        let accepted = await controller.replaceUnresolvedDaemon(
            .init(
                client: replacementDaemon,
                epoch: QueueOwnershipEpoch(rawValue: 1)),
            expectedEpoch: oldEpoch)

        #expect(accepted)
        #expect(controller.state.name == "daemonActive")
        if case .daemonActive(let epoch) = controller.state {
            #expect(epoch == QueueOwnershipEpoch(rawValue: 1))
        } else {
            Issue.record("Expected daemonActive after fresh daemon replacement")
        }
        _ = try await controller.client.snapshot()
        #expect(replacementDaemon.snapshotCount == 1)
    }

    @Test("unresolved replacement on a non-unresolved state is a no-op")
    func replacementOnNonUnresolvedStateIsRejected() async throws {
        let controller = LocalQueueRuntimeController()
        let daemonClient = ControllerClient(id: "daemon")
        #expect(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 31))))

        let accepted = await controller.replaceUnresolvedDaemon(
            .init(
                client: ControllerClient(id: "other-daemon"),
                epoch: QueueOwnershipEpoch(rawValue: 32)),
            expectedEpoch: QueueOwnershipEpoch(rawValue: 31))

        #expect(!accepted)
        #expect(controller.state.name == "daemonActive")
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }

    @Test("disposal swaps the client to unavailable and always completes")
    func disposalAlwaysCompletes() async throws {
        let controller = LocalQueueRuntimeController()
        let daemonClient = ControllerClient(id: "daemon")
        #expect(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 41))))

        let result = await controller.dispose()

        #expect(result == .shutDown)
        #expect(controller.state.name == "disposing")
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("overlapping disposal completes exactly once")
    func overlappingDisposalCompletesExactlyOnce() async throws {
        let controller = LocalQueueRuntimeController()

        // The parent dispose enters the transition first (same actor
        // ordering as the overlap test); the async-let child is rejected.
        async let childResult = controller.dispose()
        let parentResult = await controller.dispose()

        #expect(parentResult == .shutDown)
        #expect(await childResult == nil)
        #expect(controller.state.name == "disposing")
    }

    @Test("activation after disposal still installs the daemon client")
    func activationAfterDisposalReinstallsDaemon() async throws {
        let controller = LocalQueueRuntimeController()
        _ = await controller.dispose()

        let daemonClient = ControllerClient(id: "daemon-after-disposal")
        let accepted = await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 51)))

        #expect(accepted)
        #expect(controller.state.name == "daemonActive")
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }
}

private final class ControllerClient: QueueEngineClient, Sendable {
    let id: String
    private let snapshots = Mutex(0)
    private let stream = AsyncStream<QueueEvent>.makeStream()

    init(id: String) { self.id = id }

    var snapshotCount: Int { snapshots.withLock { $0 } }
    var events: AsyncStream<QueueEvent> { stream.stream }

    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        QueueItem.ID(rawValue: id)
    }
    func cancelItem(_ id: QueueItem.ID) async throws {}
    func cancelAllInFlight() async throws -> Int { 0 }
    func retryItem(_ id: QueueItem.ID) async throws {}
    func pause(_ queue: QueueKind) async throws {}
    func resume(_ queue: QueueKind) async throws {}
    func halt(_ queue: QueueKind) async throws {}
    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {}
    func snapshot() async throws -> QueueSnapshot {
        snapshots.withLock { $0 += 1 }
        return QueueSnapshot()
    }
    func hasActiveWork(for wikiID: WikiID) async throws -> Bool { false }
    func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> { .success(()) }
    func waitForCompletion(
        of id: QueueItem.ID,
        deadline: Duration
    ) async throws -> Result<Void, Error> { .success(()) }
    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { [] }
    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }

    func loadQueueReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult { .notReported }

    func loadQueueReportSummaries(for itemIDs: [QueueItem.ID]) async -> QueueReportSummariesResult { .loaded([:]) }
}
#endif
