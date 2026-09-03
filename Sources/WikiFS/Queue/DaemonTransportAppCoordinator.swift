#if os(macOS)
// pattern: Imperative Shell

import Foundation
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

@MainActor
final class DaemonTransportAppCoordinator {
    private enum Lifecycle {
        case idle
        case started
        case stopped
    }

    private let services: DaemonTransportServices
    private let bridge: DaemonTransportAppBridge
    private let queueController: LocalQueueRuntimeController
    private var replaceChatCoordinator: @MainActor (ChatDaemonCoordinator?) -> Void
    private let observeEvent: @MainActor (DaemonTransportEvent) -> Void
    private var lifecycle: Lifecycle = .idle
    private var eventTask: Task<Void, Never>?
    private var connectedCandidateID: DaemonTransportCandidateID?
    private var generation: UInt64 = 0

    init(
        services: DaemonTransportServices,
        bridge: DaemonTransportAppBridge,
        queueController: LocalQueueRuntimeController,
        replaceChatCoordinator: @escaping @MainActor (ChatDaemonCoordinator?) -> Void,
        observeEvent: @escaping @MainActor (DaemonTransportEvent) -> Void
    ) {
        self.services = services
        self.bridge = bridge
        self.queueController = queueController
        self.replaceChatCoordinator = replaceChatCoordinator
        self.observeEvent = observeEvent
    }

    func startIfNeeded() {
        guard lifecycle == .idle else { return }
        lifecycle = .started
        generation &+= 1
        eventTask = Task { [weak self, services] in
            let events = await services.events()
            guard let self, self.lifecycle == .started else { return }
            await services.startAdmission()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    func shutdown() async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        generation &+= 1
        let task = eventTask
        eventTask = nil
        task?.cancel()
        await task?.value
        connectedCandidateID = nil
        replaceChatCoordinator(nil)
        await services.stop()
        await bridge.stop()
        observeEvent(.stopped)
    }

    private func handle(_ event: DaemonTransportEvent) async {
        guard lifecycle == .started else { return }
        observeEvent(event)
        switch event {
        case .awaitingAcceptance(let id):
            await acceptCandidate(id, generation: generation)
        case .connected(let id):
            connectedCandidateID = id
        case .candidateRejected(let id), .acceptanceExpired(let id):
            await bridge.remove(id, invalidate: false)
        case .disconnected:
            await handleInvalidation()
        case .interrupted(let id):
            await handleInterruption(id)
        case .stopped:
            lifecycle = .stopped
            eventTask = nil
            connectedCandidateID = nil
            replaceChatCoordinator(nil)
            await bridge.stop()
        case .reconnecting:
            break
        }
    }

    private func acceptCandidate(
        _ id: DaemonTransportCandidateID,
        generation expectedGeneration: UInt64
    ) async {
        guard isAdmitted(expectedGeneration),
              let connection = await bridge.resolve(id),
              isAdmitted(expectedGeneration) else {
            await services.acknowledge(.init(candidateID: id, outcome: .retry))
            return
        }

        let outcome = await reconnectOutcome(
            connection: connection,
            generation: expectedGeneration)
        guard isAdmitted(expectedGeneration) else {
            replaceChatCoordinator(nil)
            await bridge.remove(id, invalidate: false)
            return
        }
        switch outcome {
        case .connected:
            guard await bridge.markConnected(id) else {
                replaceChatCoordinator(nil)
                await services.acknowledge(.init(candidateID: id, outcome: .retry))
                return
            }
        case .retry, .localFallbackReady:
            // The coordinator now returns `.connected` after safe queue
            // relinquishment so chat remains available. Keep the shared
            // outcome exhaustive for defensive handling of future callers.
            await bridge.remove(id, invalidate: false)
        }
        await services.acknowledge(.init(candidateID: id, outcome: outcome))
    }

    private func reconnectOutcome(
        connection: WikiDaemonConnection,
        generation expectedGeneration: UInt64
    ) async -> DaemonTransportAcceptanceOutcome {
        do {
            let workloadClient = try DaemonWorkloadClient(connection: connection)
            let makeEndpoint: @MainActor (QueueOwnershipEpoch) -> (
                endpoint: LocalQueueRuntimeController.DaemonEndpoint,
                chatCoordinator: ChatDaemonCoordinator
            ) = { epoch in
                let eventSink = DaemonQueueEventSink()
                workloadClient.registerEventSink(eventSink)
                let proxy = XPCQueueEngineProxy(
                    workloadClient: workloadClient,
                    eventSink: eventSink)
                return (
                    .init(client: proxy, epoch: epoch),
                    ChatDaemonCoordinator(client: workloadClient, eventSink: eventSink))
            }
            let makeChatCoordinator: () -> ChatDaemonCoordinator = {
                let eventSink = DaemonQueueEventSink()
                workloadClient.registerEventSink(eventSink)
                return ChatDaemonCoordinator(client: workloadClient, eventSink: eventSink)
            }

            if case .shutdownBlocked = queueController.state {
                let status = try await workloadClient.queueOwnershipStatus()
                guard isAdmitted(expectedGeneration),
                      status.hostState == .serving else { return .retry }
                let daemon = makeEndpoint(status.epoch)
                guard isAdmitted(expectedGeneration) else { return .retry }
                let accepted = await queueController.retryBlockedShutdownForDaemon(daemon.endpoint)
                guard isAdmitted(expectedGeneration) else { return .retry }
                if accepted { replaceChatCoordinator(daemon.chatCoordinator) }
                return accepted ? .connected : .retry
            }

            if case .daemonOwnershipUnresolved(let expectedEpoch, _) = queueController.state {
                DebugLog.store("WikiFSApp: daemon reconnected — requesting queue relinquishment")
                do {
                    let success = try await workloadClient.relinquishQueue(expectedEpoch: expectedEpoch)
                    guard isAdmitted(expectedGeneration) else { return .retry }
                    let fellBack = await queueController.fallBackAfterRelinquishment(
                        success,
                        expectedEpoch: expectedEpoch)
                    guard isAdmitted(expectedGeneration) else { return .retry }
                    if fellBack {
                        DebugLog.store("WikiFSApp: daemon relinquished queue ownership — local runtime ready")
                        replaceChatCoordinator(makeChatCoordinator())
                        return .connected
                    }
                    return .retry
                } catch {
                    let status = try await workloadClient.queueOwnershipStatus()
                    guard isAdmitted(expectedGeneration),
                          status.hostState == .serving,
                          status.epoch != expectedEpoch else { throw error }
                    let daemon = makeEndpoint(status.epoch)
                    guard isAdmitted(expectedGeneration) else { return .retry }
                    let accepted = await queueController.replaceUnresolvedDaemon(
                        daemon.endpoint,
                        expectedEpoch: expectedEpoch)
                    guard isAdmitted(expectedGeneration) else { return .retry }
                    if accepted {
                        replaceChatCoordinator(daemon.chatCoordinator)
                    }
                    return accepted ? .connected : .retry
                }
            }

            let status = try await workloadClient.queueOwnershipStatus()
            guard isAdmitted(expectedGeneration),
                  status.hostState == .serving else { return .retry }
            let daemon = makeEndpoint(status.epoch)
            guard isAdmitted(expectedGeneration) else { return .retry }
            let accepted = await queueController.activateDaemon(daemon.endpoint)
            guard isAdmitted(expectedGeneration) else { return .retry }
            if accepted { replaceChatCoordinator(daemon.chatCoordinator) }
            return accepted ? .connected : .retry
        } catch {
            DebugLog.store("WikiFSApp: reconnect queue transition failed: \(error)")
            return .retry
        }
    }

    private func isAdmitted(_ expectedGeneration: UInt64) -> Bool {
        lifecycle == .started && generation == expectedGeneration && !Task.isCancelled
    }

    private func handleInvalidation() async {
        let id = connectedCandidateID
        connectedCandidateID = nil
        if let id {
            await bridge.remove(id, invalidate: false)
        } else {
            DebugLog.store("WikiFSApp: daemon disconnected before candidate state was published")
        }
        replaceChatCoordinator(nil)
        guard case .daemonActive(let epoch) = queueController.state else {
            DebugLog.store("WikiFSApp: daemon disconnected — local queue ownership remains local")
            return
        }
        DebugLog.store("WikiFSApp: daemon disconnected — queue ownership is unresolved")
        await queueController.daemonOwnershipBecameUnresolved(
            expectedEpoch: epoch,
            reason: "Daemon connection was invalidated")
    }

    private func handleInterruption(_ id: DaemonTransportCandidateID) async {
        guard id == connectedCandidateID,
              let connection = await bridge.resolve(id) else { return }
        DebugLog.store("WikiFSApp: daemon interrupted — re-registering event sink on same connection")
        do {
            let workloadClient = try DaemonWorkloadClient(connection: connection)
            let eventSink = DaemonQueueEventSink()
            workloadClient.registerEventSink(eventSink)
            replaceChatCoordinator(ChatDaemonCoordinator(
                client: workloadClient,
                eventSink: eventSink))
        } catch {
            DebugLog.store("WikiFSApp: interrupt re-registration failed: \(error)")
        }
    }
}
#endif
