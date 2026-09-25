import Foundation
import os
import Testing
@testable import WikiFSEngine
import WikiFSCore

/// The daemon→engine configuration mapping (Tier 1 Phase 4): configured
/// `AgentProvidersConfig.maxConcurrent` must actually reach the engine's
/// ingestion admission. `WikiDaemon.buildQueueResources` is private and
/// cannot be behavior-tested directly, so the mapping lives in
/// `QueueEngineConfig.daemonConfig(agents:)` and is pinned here — mapping
/// AND defaults — plus a behavioral concurrency test through the mapped
/// config.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct QueueEngineDaemonConfigTests {

    // MARK: - Test helpers

    /// A fresh on-disk `queue.sqlite` URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-daemon-config-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    /// A trivial payload for tests that don't care about payload specifics.
    private func makePayload() -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [SourceID(rawValue: "CFGDSTEST01")])
    }

    // MARK: - Mapping (AC.6)

    @Test func daemonConfigMapsMaxConcurrentIntoIngestionLimits() {
        var agents = AgentProvidersConfig()
        agents.maxConcurrent = ["prov-a": 3, "prov-b": 7]
        let config = QueueEngineConfig.daemonConfig(agents: agents)

        #expect(config.ingestionLimits == ["prov-a": 3, "prov-b": 7])
        #expect(config.ingestionLimit(for: ProviderID(rawValue: "prov-a")) == 3)
        #expect(config.ingestionLimit(for: ProviderID(rawValue: "prov-b")) == 7)
        // Unconfigured providers keep the engine default of 1.
        #expect(config.ingestionLimit(for: ProviderID(rawValue: "prov-c")) == 1)
    }

    @Test func daemonConfigKeepsExtractionLimitsAtNamedDefaults() {
        var agents = AgentProvidersConfig()
        agents.maxConcurrent = ["prov-a": 9]
        let config = QueueEngineConfig.daemonConfig(agents: agents)

        // Extraction stays at the struct's defaults: local pdf2md serialized,
        // remote backends at 2. The provider config must not leak into them.
        #expect(config.localExtractionLimit == 1)
        #expect(config.remoteExtractionLimit == 2)
        #expect(config.extractionLimit(for: ProviderID(rawValue: "local-pdf2md")) == 1)
        #expect(config.extractionLimit(for: ProviderID(rawValue: "prov-a")) == 2)
        #expect(config.recentLimit == 200)
    }

    // MARK: - Behavioral concurrency through the mapped config (AC.6)

    @Test func mappedLimitTwoRunsTwoConcurrentlyAndOneSerializes() async throws {
        // limit 2: two items for the same provider run concurrently.
        try await assertMappedConcurrency(
            maxConcurrent: 2,
            expectedConcurrent: 2)
        // limit 1: they serialize.
        try await assertMappedConcurrency(
            maxConcurrent: 1,
            expectedConcurrent: 1)
    }

    private func assertMappedConcurrency(
        maxConcurrent: Int,
        expectedConcurrent: Int
    ) async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        // Both workers park; the high-water mark of simultaneously parked
        // workers is the effective concurrency.
        let highWater = MaxConcurrentTracker()
        let factory = FakeWorkerFactory(
            providerID: { _ in ProviderID(rawValue: "prov-a") },
            worker: { _ in
                highWater.enter()
                // Hold long enough for a second worker to enter if allowed.
                try await Task.sleep(nanoseconds: 300_000_000)
                highWater.exit()
            })
        var agents = AgentProvidersConfig()
        agents.maxConcurrent = ["prov-a": maxConcurrent]
        let engine = QueueEngine(
            store: store,
            config: QueueEngineConfig.daemonConfig(agents: agents),
            workerFactory: factory)
        await engine.start()

        _ = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w1"), payload: makePayload()))
        _ = try await engine.enqueue(QueueItemRequest(
            queue: .ingestion, wikiID: WikiID(rawValue: "w2"), payload: makePayload()))

        // Wait past the hold window; the high-water mark is settled.
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(highWater.maxObserved == expectedConcurrent)

        // Unwind deterministically.
        await engine.cancelAllInFlight()
        _ = await engine.shutdownForHandoff()
        store.close()
    }
}

/// Tracks the high-water mark of simultaneously executing workers.
private final class MaxConcurrentTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (active: 0, max: 0))

    var maxObserved: Int {
        lock.withLock { $0.max }
    }

    func enter() {
        lock.withLock { state in
            state.active += 1
            state.max = max(state.max, state.active)
        }
    }

    func exit() {
        lock.withLock { state in
            state.active -= 1
        }
    }
}
