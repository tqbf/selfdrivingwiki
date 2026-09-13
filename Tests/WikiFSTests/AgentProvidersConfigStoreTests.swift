import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized) struct AgentProvidersConfigStoreTests {
    // CI's 3-vCPU runner starves the cooperative pool under the full parallel
    // suite (neighboring trivial tests wall-clock ~29 s there), so the store's
    // 5 s production lock deadline can elapse on scheduler delay alone —
    // delayed `Task.sleep` resumptions count against it even though the lock
    // holder released in microseconds. These tests assert serialization
    // semantics, not lock latency, so give the deadline starvation headroom.
    private static let lockTimeout: Duration = .seconds(60)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func concurrentMutationsPreserveBothEditsAndStrictlyIncreaseGeneration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)
        let first = AgentProvidersConfigStore(directory: directory, lockTimeout: Self.lockTimeout)
        let second = AgentProvidersConfigStore(directory: directory, lockTimeout: Self.lockTimeout)
        async let selected = first.mutate {
            $0.settingSelectedModel(ModelID(rawValue: "opus"), forProvider: ProviderID(rawValue: "claude-acp"))
        }
        async let favorited = second.mutate {
            $0.togglingFavoriteModel(ModelID(rawValue: "sonnet"), forProvider: ProviderID(rawValue: "claude-acp"))
        }
        let results = try await [selected, favorited]
        let loaded = try #require(AgentProvidersConfig.load(from: directory))
        #expect(loaded.selectedModelId(forProvider: ProviderID(rawValue: "claude-acp")) == ModelID(rawValue: "opus"))
        #expect(loaded.isFavoriteModel(ModelID(rawValue: "sonnet"), forProvider: ProviderID(rawValue: "claude-acp")))
        #expect(Set(results.map(\.generation)) == [1, 2])
        #expect(loaded.generation == 2)
    }

    @Test func failedMutationDoesNotReplaceOrSignal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = AgentProvidersConfig.seed(discovered: [])
        try original.writeAtomically(to: directory)
        let signals = SignalCounter()
        let store = AgentProvidersConfigStore(
            directory: directory,
            lockTimeout: Self.lockTimeout,
            write: { _, _ in throw TestFailure.write },
            postLocal: { _ in signals.incrementLocal() },
            postDarwin: { signals.incrementDarwin() })
        await #expect(throws: TestFailure.self) {
            try await store.mutate {
                $0.settingSelectedModel(ModelID(rawValue: "opus"), forProvider: ProviderID(rawValue: "claude-acp"))
            }
        }
        let loaded = try #require(AgentProvidersConfig.load(from: directory))
        #expect(loaded.generation == 0)
        #expect(signals.snapshot() == (0, 0))
    }

    @Test func successfulMutationSignalsOnlyAfterReplacementAndUnlock() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)
        let observed = GenerationRecorder(directory: directory)
        let store = AgentProvidersConfigStore(
            directory: directory,
            lockTimeout: Self.lockTimeout,
            postLocal: { _ in observed.record() },
            postDarwin: { observed.record() })
        _ = try await store.mutate {
            $0.settingSelectedModel(ModelID(rawValue: "opus"), forProvider: ProviderID(rawValue: "claude-acp"))
        }
        #expect(observed.snapshot() == [1, 1])
        // A second coordinator can acquire immediately, proving signals ran
        // after the first coordinator released the kernel and process gates.
        let second = try await AgentProvidersConfigStore(directory: directory, lockTimeout: Self.lockTimeout).mutate { $0 }
        #expect(second.generation == 2)
    }
}

private enum TestFailure: Error { case write }

private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var local = 0
    private var darwin = 0
    func incrementLocal() { lock.withLock { local += 1 } }
    func incrementDarwin() { lock.withLock { darwin += 1 } }
    func snapshot() -> (Int, Int) { lock.withLock { (local, darwin) } }
}

private final class GenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var values: [UInt64] = []
    init(directory: URL) { self.directory = directory }
    func record() {
        let generation = AgentProvidersConfig.load(from: directory)?.generation ?? .max
        lock.withLock { values.append(generation) }
    }
    func snapshot() -> [UInt64] { lock.withLock { values } }
}
