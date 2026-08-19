#if os(macOS)
import Foundation
import Synchronization
import Testing
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

@Suite("Local queue runtime controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LocalQueueRuntimeControllerTests {
    @Test("startup publishes a ready client only after assembly settles")
    func startupPublishesReadyClientOnlyAfterSettlement() async throws {
        let assembly = ControllerAssemblyGate()
        let localClient = ControllerClient(id: "local")
        let handle = ControllerRuntimeHandle(client: localClient)
        let controller = LocalQueueRuntimeController {
            await assembly.wait()
            return handle
        }

        controller.start()
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }

        assembly.release()
        await controller.awaitSettled()

        _ = try await controller.client.snapshot()
        #expect(localClient.snapshotCount == 1)
        #expect(controller.state.name == "localReady")
    }

    @Test("database open failure keeps the stable client unavailable")
    func databaseOpenFailureInstallsUnavailableClient() async {
        let controller = LocalQueueRuntimeController {
            throw ControllerTestError.databaseOpen
        }

        controller.start()
        await controller.awaitSettled()

        #expect(controller.state.name == "unavailable")
        #expect(controller.startupError != nil)
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("daemon activation during startup retires the stale local runtime")
    func daemonActivationDuringStartupRejectsStaleCompletion() async throws {
        let assembly = ControllerAssemblyGate()
        let staleHandle = ControllerRuntimeHandle(client: ControllerClient(id: "stale"))
        let daemonClient = ControllerClient(id: "daemon")
        let controller = LocalQueueRuntimeController {
            await assembly.wait()
            return staleHandle
        }
        controller.start()

        let activationFinished = AsyncStream<Bool>.makeStream()
        let activationTask = Task { @MainActor in
            let accepted = await controller.activateDaemon(.init(
                client: daemonClient,
                epoch: QueueOwnershipEpoch(rawValue: 5)))
            activationFinished.continuation.yield(accepted)
            activationFinished.continuation.finish()
        }
        assembly.release()

        var accepted: Bool?
        for await value in activationFinished.stream {
            accepted = value
            break
        }
        await activationTask.value

        #expect(accepted == true)
        #expect(staleHandle.disposeCount == 1)
        #expect(controller.localHandle == nil)
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }

    @Test("blocked stale startup cleanup refuses daemon takeover")
    func blockedStaleStartupCleanupRefusesDaemonTakeover() async {
        let assembly = ControllerAssemblyGate()
        let blockedID = QueueItem.ID(rawValue: "stale-blocked")
        let staleHandle = ControllerRuntimeHandle(
            client: ControllerClient(id: "stale"),
            immediateResult: .shutdownBlocked(activeItemIDs: [blockedID]))
        let daemonClient = ControllerClient(id: "daemon")
        let controller = LocalQueueRuntimeController {
            await assembly.wait()
            return staleHandle
        }
        controller.start()

        let activationTask = Task { @MainActor in
            await controller.activateDaemon(.init(
                client: daemonClient,
                epoch: QueueOwnershipEpoch(rawValue: 6)))
        }
        assembly.release()

        #expect(!(await activationTask.value))
        #expect(staleHandle.disposeCount == 1)
        #expect(controller.localHandle != nil)
        #expect(controller.state.name == "shutdownBlocked")
        #expect(daemonClient.snapshotCount == 0)
    }

    @Test("daemon activation waits for local disposal")
    func daemonActivationWaitsForLocalShutdown() async throws {
        let localClient = ControllerClient(id: "local")
        let daemonClient = ControllerClient(id: "daemon")
        let disposal = ControllerDisposalGate()
        let handle = ControllerRuntimeHandle(client: localClient, disposalGate: disposal)
        let controller = LocalQueueRuntimeController { handle }
        controller.start()
        await controller.awaitSettled()

        let activationFinished = AsyncStream<Bool>.makeStream()
        let activationTask = Task { @MainActor in
            let accepted = await controller.activateDaemon(.init(
                client: daemonClient,
                epoch: QueueOwnershipEpoch(rawValue: 7)))
            activationFinished.continuation.yield(accepted)
            activationFinished.continuation.finish()
        }
        await disposal.awaitStarted()

        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
        #expect(daemonClient.snapshotCount == 0)

        disposal.release(with: .shutDown)
        var accepted: Bool?
        for await value in activationFinished.stream {
            accepted = value
            break
        }
        await activationTask.value

        #expect(accepted == true)
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
        #expect(controller.localHandle == nil)
        #expect(controller.state.name == "daemonActive")
    }

    @Test("blocked local shutdown refuses daemon takeover and retains the handle")
    func blockedShutdownRefusesDaemonAndSecondLocalRuntime() async throws {
        let localClient = ControllerClient(id: "local")
        let daemonClient = ControllerClient(id: "daemon")
        let blockedID = QueueItem.ID(rawValue: "blocked")
        let handle = ControllerRuntimeHandle(
            client: localClient,
            immediateResult: .shutdownBlocked(activeItemIDs: [blockedID]))
        let assemblyCount = Mutex(0)
        let controller = LocalQueueRuntimeController {
            assemblyCount.withLock { $0 += 1 }
            return handle
        }
        controller.start()
        await controller.awaitSettled()

        let accepted = await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 9)))

        #expect(!accepted)
        #expect(controller.localHandle != nil)
        #expect(controller.state.name == "shutdownBlocked")
        #expect(assemblyCount.withLock { $0 } == 1)
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("blocked shutdown retry installs daemon after worker settlement")
    func blockedShutdownRetryInstallsDaemonAfterWorkerSettlement() async throws {
        let localClient = ControllerClient(id: "local")
        let daemonClient = ControllerClient(id: "daemon")
        let blockedID = QueueItem.ID(rawValue: "blocked-retry")
        let results = Mutex<[QueueEngineShutdownResult]>([
            .shutdownBlocked(activeItemIDs: [blockedID]),
            .shutDown,
        ])
        let handle = ControllerRuntimeHandle(
            client: localClient,
            resultProvider: { results.withLock { $0.removeFirst() } })
        let controller = LocalQueueRuntimeController { handle }
        controller.start()
        await controller.awaitSettled()

        #expect(!(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 10)))))
        #expect(controller.state.name == "shutdownBlocked")

        #expect(await controller.retryBlockedShutdownForDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 10))))
        #expect(handle.disposeCount == 2)
        #expect(controller.localHandle == nil)
        #expect(controller.state.name == "daemonActive")
        _ = try await controller.client.snapshot()
        #expect(daemonClient.snapshotCount == 1)
    }

    @Test("daemon invalidation ignores non-daemon states")
    func daemonInvalidationIgnoresNonDaemonStates() async throws {
        let localClient = ControllerClient(id: "local")
        let controller = LocalQueueRuntimeController {
            ControllerRuntimeHandle(client: localClient)
        }
        controller.start()
        await controller.awaitSettled()

        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: QueueOwnershipEpoch(rawValue: 11),
            reason: "spurious invalidation")

        #expect(controller.state.name == "localReady")
        _ = try await controller.client.snapshot()
        #expect(localClient.snapshotCount == 1)
    }

    @Test("daemon invalidation fails closed and does not construct local fallback")
    func missingRelinquishmentAcknowledgementFailsClosed() async throws {
        let localClient = ControllerClient(id: "local")
        let daemonClient = ControllerClient(id: "daemon")
        let handle = ControllerRuntimeHandle(client: localClient)
        let assemblyCount = Mutex(0)
        let controller = LocalQueueRuntimeController {
            assemblyCount.withLock { $0 += 1 }
            return handle
        }
        controller.start()
        await controller.awaitSettled()
        #expect(await controller.activateDaemon(.init(
            client: daemonClient,
            epoch: QueueOwnershipEpoch(rawValue: 11))))

        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: QueueOwnershipEpoch(rawValue: 11),
            reason: "connection invalidated")

        #expect(controller.state.name == "daemonOwnershipUnresolved")
        #expect(assemblyCount.withLock { $0 } == 1)
        await #expect(throws: UnavailableQueueEngine.Error.self) {
            _ = try await controller.client.snapshot()
        }
    }

    @Test("only a complete matching relinquishment creates one local fallback")
    func acknowledgedDaemonRelinquishmentCreatesOneLocalRuntime() async throws {
        let initialClient = ControllerClient(id: "initial")
        let fallbackClient = ControllerClient(id: "fallback")
        let handles = Mutex([
            ControllerRuntimeHandle(client: initialClient),
            ControllerRuntimeHandle(client: fallbackClient),
        ])
        let assemblyCount = Mutex(0)
        let controller = LocalQueueRuntimeController {
            assemblyCount.withLock { $0 += 1 }
            return handles.withLock { $0.removeFirst() }
        }
        controller.start()
        await controller.awaitSettled()
        #expect(await controller.activateDaemon(.init(
            client: ControllerClient(id: "daemon"),
            epoch: QueueOwnershipEpoch(rawValue: 13))))
        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: QueueOwnershipEpoch(rawValue: 13),
            reason: "transport lost")

        let stale = QueueRelinquishmentSuccess(
            completedEpoch: QueueOwnershipEpoch(rawValue: 12),
            dispatchStopped: true,
            workersSettledOrRequeued: true,
            forwardingStopped: true,
            storeClosed: true)
        let staleAccepted = await controller.fallBackAfterRelinquishment(
            stale,
            expectedEpoch: QueueOwnershipEpoch(rawValue: 13))
        #expect(!staleAccepted)
        #expect(assemblyCount.withLock { $0 } == 1)

        let incomplete = QueueRelinquishmentSuccess(
            completedEpoch: QueueOwnershipEpoch(rawValue: 13),
            dispatchStopped: true,
            workersSettledOrRequeued: true,
            forwardingStopped: false,
            storeClosed: true)
        let incompleteAccepted = await controller.fallBackAfterRelinquishment(
            incomplete,
            expectedEpoch: QueueOwnershipEpoch(rawValue: 13))
        #expect(!incompleteAccepted)
        #expect(assemblyCount.withLock { $0 } == 1)

        let complete = QueueRelinquishmentSuccess(
            completedEpoch: QueueOwnershipEpoch(rawValue: 13),
            dispatchStopped: true,
            workersSettledOrRequeued: true,
            forwardingStopped: true,
            storeClosed: true)
        #expect(await controller.fallBackAfterRelinquishment(
            complete,
            expectedEpoch: QueueOwnershipEpoch(rawValue: 13)))

        #expect(assemblyCount.withLock { $0 } == 2)
        _ = try await controller.client.snapshot()
        #expect(fallbackClient.snapshotCount == 1)
        #expect(controller.state.name == "localReady")
    }

    @Test("fresh daemon epoch replaces unresolved daemon without local fallback")
    func freshDaemonEpochReplacesUnresolvedDaemonWithoutLocalFallback() async throws {
        let localClient = ControllerClient(id: "local")
        let replacementDaemon = ControllerClient(id: "replacement-daemon")
        let assemblyCount = Mutex(0)
        let controller = LocalQueueRuntimeController {
            assemblyCount.withLock { $0 += 1 }
            return ControllerRuntimeHandle(client: localClient)
        }
        controller.start()
        await controller.awaitSettled()
        let oldEpoch = QueueOwnershipEpoch(rawValue: 23)
        #expect(await controller.activateDaemon(.init(
            client: ControllerClient(id: "old-daemon"),
            epoch: oldEpoch)))
        await controller.daemonOwnershipBecameUnresolved(
            expectedEpoch: oldEpoch,
            reason: "daemon replaced")

        #expect(await controller.replaceUnresolvedDaemon(
            .init(
                client: replacementDaemon,
                epoch: QueueOwnershipEpoch(rawValue: 1)),
            expectedEpoch: oldEpoch))

        #expect(assemblyCount.withLock { $0 } == 1)
        #expect(controller.localHandle == nil)
        if case .daemonActive(let epoch) = controller.state {
            #expect(epoch == QueueOwnershipEpoch(rawValue: 1))
        } else {
            Issue.record("Expected daemonActive after fresh daemon replacement")
        }
        _ = try await controller.client.snapshot()
        #expect(replacementDaemon.snapshotCount == 1)
    }

    @Test("overlapping transitions reject without duplicate runtime disposal")
    func overlappingTransitionsRejectWithoutDuplicateRuntimeDisposal() async throws {
        let disposal = ControllerDisposalGate()
        let handle = ControllerRuntimeHandle(
            client: ControllerClient(id: "local"),
            disposalGate: disposal)
        let winningDaemon = ControllerClient(id: "winning-daemon")
        let rejectedDaemon = ControllerClient(id: "rejected-daemon")
        let controller = LocalQueueRuntimeController { handle }
        controller.start()
        await controller.awaitSettled()

        let winningTask = Task { @MainActor in
            await controller.activateDaemon(.init(
                client: winningDaemon,
                epoch: QueueOwnershipEpoch(rawValue: 17)))
        }
        await disposal.awaitStarted()

        let secondActivation = await controller.activateDaemon(.init(
            client: rejectedDaemon,
            epoch: QueueOwnershipEpoch(rawValue: 18)))
        let overlappingDisposal = await controller.dispose()

        #expect(!secondActivation)
        #expect(overlappingDisposal == nil)
        #expect(handle.disposeCount == 1)
        #expect(controller.state.name == "shuttingDownForDaemon")

        disposal.release(with: .shutDown)
        #expect(await winningTask.value)
        #expect(handle.disposeCount == 1)
        #expect(controller.state.name == "daemonActive")
        _ = try await controller.client.snapshot()
        #expect(winningDaemon.snapshotCount == 1)
        #expect(rejectedDaemon.snapshotCount == 0)
    }
}

private enum ControllerTestError: Error, Sendable {
    case databaseOpen
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
    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { [] }
    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
}

private final class ControllerRuntimeHandle: LocalQueueRuntimeHandle, Sendable {
    let client: any QueueEngineClient
    private let disposalGate: ControllerDisposalGate?
    private let immediateResult: QueueEngineShutdownResult
    private let resultProvider: (@Sendable () -> QueueEngineShutdownResult)?
    private let disposals = Mutex(0)

    var disposeCount: Int { disposals.withLock { $0 } }

    init(
        client: any QueueEngineClient,
        disposalGate: ControllerDisposalGate? = nil,
        immediateResult: QueueEngineShutdownResult = .shutDown,
        resultProvider: (@Sendable () -> QueueEngineShutdownResult)? = nil
    ) {
        self.client = client
        self.disposalGate = disposalGate
        self.immediateResult = immediateResult
        self.resultProvider = resultProvider
    }

    func dispose() async throws -> QueueEngineShutdownResult {
        disposals.withLock { $0 += 1 }
        if let disposalGate { return await disposalGate.wait() }
        if let resultProvider { return resultProvider() }
        return immediateResult
    }
}

private final class ControllerAssemblyGate: Sendable {
    private let gate = AsyncStream<Void>.makeStream()

    func wait() async {
        for await _ in gate.stream { break }
    }

    func release() {
        gate.continuation.yield(())
        gate.continuation.finish()
    }
}

private final class ControllerDisposalGate: Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let result = AsyncStream<QueueEngineShutdownResult>.makeStream()

    func wait() async -> QueueEngineShutdownResult {
        started.continuation.yield(())
        started.continuation.finish()
        for await value in result.stream { return value }
        return .shutdownBlocked(activeItemIDs: [])
    }

    func awaitStarted() async {
        for await _ in started.stream { break }
    }

    func release(with value: QueueEngineShutdownResult) {
        result.continuation.yield(value)
        result.continuation.finish()
    }
}
#endif
