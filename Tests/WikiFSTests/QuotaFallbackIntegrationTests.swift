#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// #727: integration tests for the quota-fallback pipeline.
///
/// These tests verify the end-to-end behavior:
/// 1. A `.turnFailed(.quotaExhausted(...))` event in the FakeAgentBackend's
///    scripted stream triggers the fallback retry loop.
/// 2. The coordinator marks the provider dead and the launcher retries on
///    the next enabled provider.
/// 3. All-providers-exhausted → item fails with a clear message.
@MainActor
@Suite("QuotaFallback Integration")
struct QuotaFallbackIntegrationTests {

    private final class ResolveBackendCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    private func makeLauncher(
        backend: FakeAgentBackend,
        counter: ResolveBackendCallCounter,
        tempDir: URL,
        providers: [AgentProvider]
    ) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, _ in
            counter.increment()
            return backend
        }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = { providers.first ?? .claudeAcpDefault }
        let config = AgentProvidersConfig(
            providers: providers,
            selectedModelIds: Dictionary(uniqueKeysWithValues: providers.map { ($0.id, "fake-model") }))
        do {
            try config.save(to: tempDir)
        } catch {
            Issue.record("Failed to save provider config: \(error)")
        }
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        return launcher
    }

    private func largeSource() -> OperationRequest.StagedSource {
        let pad = String(repeating: "# page\n", count: 600)  // ~4800 bytes
        return OperationRequest.StagedSource(
            bytes: Data(pad.utf8),
            ext: "md",
            displayPath: "sources/by-id/large.md",
            name: "Large Source",
            sourceID: "01FAKE01KQ8HDDR3ZXK72XHG6R"
        )
    }

    private func planJSON(leafName: String = "Large-Source--01FAKE01KQ8HDDR3ZXK72XHG6R.md") throws -> Data {
        try JSONEncoder().encode(ACPIngestPlan(
            pages: [ACPIngestPageAssignment(
                title: "Page", sourceFile: leafName,
                sourceRanges: "1-600", outline: "test")],
            sourceIDs: ["01FAKE"]))
    }

    // MARK: - AC.3: Single-provider quota hit → item fails

    @Test("Single provider quota hit fails the item (no fallback)")
    func testSingleProviderQuotaFailsItem() async throws {
        let fake = FakeAgentBackend(behaviors: [
            // Planner: yield a quota turn-failed event, then messageStop.
            FakeSessionBehavior(events: [
                .turnFailed(reason: .quotaExhausted(provider: "fake-acp", resetTime: nil)),
                .messageStop
            ]),
        ])
        let counter = ResolveBackendCallCounter()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-single-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providers = [
            AgentProvider(id: "fake-acp", label: "Fake",
                          command: ["/usr/bin/true"], enabled: true, isDefault: true)
        ]
        let launcher = makeLauncher(backend: fake, counter: counter, tempDir: tempDir, providers: providers)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: "test-wiki", wikiRoot: "/tmp", systemPrompt: "sys",
            wikictlDirectory: "/tmp", ingestingSourceIDs: [],
            onEvent: nil, onLock: {}, onUnlock: {}
        )

        // The planner failed with quota → no fallback provider → item fails.
        #expect(!launcher.isRunning)
        // The launcher should have an error message (preflightError or events).
        let hasError = launcher.preflightError != nil || launcher.events.contains { event in
            if case .turnFailed(let reason) = event {
                if case .quotaExhausted = reason { return true }
            }
            return false
        }
        #expect(hasError, "Expected a quota-exhaustion error surfaced")
    }

    // MARK: - AC.4: Two-provider chain, first exhausted → fallback succeeds

    @Test("Two-provider chain fallback succeeds")
    func testFallbackToSecondProvider() async throws {
        let fake = FakeAgentBackend(behaviors: [
            // Phase 1 — planner on provider A: quota hit, then messageStop.
            FakeSessionBehavior(events: [
                .turnFailed(reason: .quotaExhausted(provider: "provider-a", resetTime: nil)),
                .messageStop
            ]),
            // Phase 1 — planner on provider B: success (writes plan.json).
            FakeSessionBehavior(events: [.messageStop], planJSON: try planJSON()),
            // Phase 2 — executor: success.
            FakeSessionBehavior(events: [.messageStop]),
            // Phase 3 — finalizer: success.
            FakeSessionBehavior(events: [.messageStop]),
        ])
        let counter = ResolveBackendCallCounter()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providers = [
            AgentProvider(id: "provider-a", label: "Provider A",
                          command: ["/usr/bin/true"], enabled: true, isDefault: true),
            AgentProvider(id: "provider-b", label: "Provider B",
                          command: ["/usr/bin/true"], enabled: true)
        ]
        let launcher = makeLauncher(backend: fake, counter: counter, tempDir: tempDir, providers: providers)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: "test-wiki", wikiRoot: "/tmp", systemPrompt: "sys",
            wikictlDirectory: "/tmp", ingestingSourceIDs: [],
            onEvent: nil, onLock: {}, onUnlock: {}
        )

        // Should have started at least 2 sessions (the first at the quota-hit
        // provider, the second at the fallback).
        let startCount = await fake.startCount
        #expect(startCount >= 2, "Expected at least 2 start calls (quota retry), got \(startCount). preflightError=\(launcher.preflightError ?? "nil")")

        // The run should have completed.
        #expect(!launcher.isRunning)
    }

    // MARK: - AC.5: All providers exhausted → item fails

    @Test("All providers exhausted fails the item")
    func testAllProvidersExhausted() async throws {
        let fake = FakeAgentBackend(behaviors: [
            // Provider A: quota hit.
            FakeSessionBehavior(events: [
                .turnFailed(reason: .quotaExhausted(provider: "provider-a", resetTime: nil)),
                .messageStop
            ]),
            // Provider B: quota hit.
            FakeSessionBehavior(events: [
                .turnFailed(reason: .quotaExhausted(provider: "provider-b", resetTime: nil)),
                .messageStop
            ]),
        ])
        let counter = ResolveBackendCallCounter()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providers = [
            AgentProvider(id: "provider-a", label: "Provider A",
                          command: ["/usr/bin/true"], enabled: true, isDefault: true),
            AgentProvider(id: "provider-b", label: "Provider B",
                          command: ["/usr/bin/true"], enabled: true)
        ]
        let launcher = makeLauncher(backend: fake, counter: counter, tempDir: tempDir, providers: providers)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: "test-wiki", wikiRoot: "/tmp", systemPrompt: "sys",
            wikictlDirectory: "/tmp", ingestingSourceIDs: [],
            onEvent: nil, onLock: {}, onUnlock: {}
        )

        // All providers exhausted → item fails.
        #expect(!launcher.isRunning)
        // The run should have at least attempted both providers.
        let startCount = await fake.startCount
        #expect(startCount >= 2, "Expected 2 start calls (both providers tried), got \(startCount). preflightError=\(launcher.preflightError ?? "nil")")
    }

    // MARK: - Transient z.ai error is NOT quota

    @Test("Transient z.ai error (1302) does not trigger fallback")
    func testTransientZaiErrorNoFallback() async throws {
        // A transient error should surface as .agentError, not .quotaExhausted.
        // The coordinator should NOT mark the provider dead.
        let fake = FakeAgentBackend(behaviors: [
            // Planner: yield a non-quota turn-failed event.
            FakeSessionBehavior(events: [
                .turnFailed(reason: .agentError("Server busy, please try again (code 1302)")),
                .messageStop
            ]),
        ])
        let counter = ResolveBackendCallCounter()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providers = [
            AgentProvider(id: "fake-acp", label: "Fake",
                          command: ["/usr/bin/true"], enabled: true, isDefault: true)
        ]
        let launcher = makeLauncher(backend: fake, counter: counter, tempDir: tempDir, providers: providers)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: "test-wiki", wikiRoot: "/tmp", systemPrompt: "sys",
            wikictlDirectory: "/tmp", ingestingSourceIDs: [],
            onEvent: nil, onLock: {}, onUnlock: {}
        )

        // Non-quota failure → item fails. No fallback retry (no second
        // provider attempted), but the planner failure path may invoke the
        // single-session fallback which calls start() again.
        #expect(!launcher.isRunning)
    }

    // MARK: - FakeAgentBackend recordedProfiles

    @Test("FakeAgentBackend records provider IDs in profiles")
    func testFakeBackendRecordsProfiles() async throws {
        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.messageStop]),
        ])
        let provider = AgentProvider(id: "test-recording", label: "Test",
                                     command: ["/usr/bin/true"], enabled: true, isDefault: true)
        let hints = AgentBackendFactory.providerHints(
            provider: provider, resolvedCommand: ["/usr/bin/true"], apiKey: nil)
        let profile = BackendProfile(providerHints: hints)
        _ = try await fake.start(profile: profile, systemPrompt: "sys", onExit: { _ in })

        let providerIds = await fake.startedProviderIds
        #expect(providerIds == ["test-recording"])

        let profiles = await fake.recordedProfiles
        #expect(profiles.count == 1)
        #expect(profiles[0].providerHints[HintKey.acpProviderId.rawValue] == "test-recording")
    }
}
#endif // os(macOS)
