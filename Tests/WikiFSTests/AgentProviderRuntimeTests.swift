import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("AgentProviderRuntime")
struct AgentProviderRuntimeTests {
    private let alpha = ProviderID(rawValue: "alpha")
    private let beta = ProviderID(rawValue: "beta")

    private func configuration(summarizer: Bool = false) -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(id: alpha, label: "Alpha", command: ["/secret/alpha"], env: ["SECRET_ENV": "do-not-leak"], isDefault: true),
                AgentProvider(id: beta, label: "Beta", command: ["/secret/beta"], isDefault: false)
            ],
            selectedModelIds: [alpha.rawValue: ModelID(rawValue: "alpha-default"), beta.rawValue: ModelID(rawValue: "beta-default")],
            ingestStageModelIds: ["chat": ModelID(rawValue: "chat-model"), "planner": ModelID(rawValue: "planner-model"), "executor": ModelID(rawValue: "executor-model"), "finalizer": ModelID(rawValue: "final-model"), "lint": ModelID(rawValue: "lint-model"), "summarizer": ModelID(rawValue: "summary-model")],
            stageProviderIds: summarizer ? ["summarizer": alpha] : [:])
    }

    private func runtime(config: LockedBox<AgentProvidersConfig>, counts: RuntimeCounts, factory: @escaping AgentProviderRuntime.BackendFactory = { _, _, _ in FakeAgentBackend() }) -> AgentProviderRuntime {
        AgentProviderRuntime(
            readConfiguration: { counts.incrementConfigurationReads(); return config.read() },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in counts.incrementCredentials(); return "key-not-public" },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: factory)
    }

    @Test("One configuration read freezes all stage models and chains")
    func snapshotFreezesStages() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let service = runtime(config: config, counts: counts)
        let initial = try await service.prepare(.ingest)
        #expect(initial.selection.stage == .planner)
        #expect(initial.selection.model == ModelID(rawValue: "planner-model"))
        let executor = try await service.preparation(from: initial.selection.token, stage: .executor)
        #expect(executor.selection.model == ModelID(rawValue: "executor-model"))
        #expect(counts.configurationReads == 1)
        #expect(counts.commandCalls == 1)
        #expect(counts.credentialCalls == 2)
    }

    @Test("Interactive preparation uses one configuration snapshot")
    func interactivePreparationUsesOneConfigurationSnapshot() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let service = runtime(config: config, counts: counts)

        let prepared = try await service.prepareInteractive(
            providerOverride: beta,
            modelOverride: nil,
            configuredThinkingOptionID: nil,
            priorEffectiveThinkingOptionID: nil)

        #expect(counts.configurationReads == 1)
        #expect(prepared.operation.selection.descriptor.id == beta)
        #expect(prepared.operation.selection.model == ModelID(rawValue: "beta-default"))
    }

    @Test("Chat provider override uses the override provider model")
    func chatProviderOverrideUsesProviderModel() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let service = runtime(config: config, counts: counts)

        let preparation = try await service.prepare(
            .interactive,
            providerOverride: beta,
            modelOverride: nil,
            thinkingOverride: nil)

        #expect(preparation.selection.descriptor.id == beta)
        #expect(preparation.selection.model == ModelID(rawValue: "beta-default"))
    }

    @Test("Fallback uses the frozen chain after settings mutation")
    func fallbackIsFrozen() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts(); let service = runtime(config: config, counts: counts)
        let initial = try await service.prepare(.ingest)
        config.mutate { $0.stageProviderIds["planner"] = beta; $0.providers[1].enabled = false }
        let fallback = try await service.fallbackPreparation(from: initial.selection.token, stage: .planner, fallbackProviderID: beta)
        #expect(fallback.selection.descriptor.id == beta)
        #expect(fallback.selection.model == ModelID(rawValue: "planner-model"))
    }

    @Test("Tokens reject invalid stage, invalid fallback, cross runtime, and disposal")
    func tokenValidation() async throws {
        let config = LockedBox(configuration()); let counts = RuntimeCounts()
        let first = runtime(config: config, counts: counts); let second = runtime(config: config, counts: counts)
        let preparation = try await first.prepare(.ingest)
        let descriptors = try await first.frozenProviderDescriptors(
            from: preparation.selection.token,
            stage: .executor)
        #expect(descriptors.map(\.id) == [alpha, beta])
        await #expect(throws: AgentProviderRuntimeError.stageMismatch) { try await first.preparation(from: preparation.selection.token, stage: .chat) }
        await #expect(throws: AgentProviderRuntimeError.invalidFallback) { try await first.fallbackPreparation(from: preparation.selection.token, stage: .planner, fallbackProviderID: ProviderID(rawValue: "missing")) }
        let derived = try await first.preparation(
            from: preparation.selection.token,
            stage: .executor)
        await #expect(throws: AgentProviderRuntimeError.stageMismatch) {
            try await first.fallbackPreparation(
                from: derived.selection.token,
                stage: .finalizer,
                fallbackProviderID: beta)
        }
        await #expect(throws: AgentProviderRuntimeError.invalidToken) { try await second.preparation(from: preparation.selection.token, stage: .planner) }
        await first.dispose()
        await #expect(throws: AgentProviderRuntimeError.unavailable) { try await first.preparation(from: preparation.selection.token, stage: .planner) }
    }

    @Test("Cached backend is reused per snapshot provider and fallback gets another backend")
    func backendReuse() async throws {
        let config = LockedBox(configuration()); let counts = RuntimeCounts(); let backendCount = Counter()
        let service = runtime(config: config, counts: counts, factory: { _, _, _ in backendCount.increment(); return FakeAgentBackend() })
        let initial = try await service.prepare(.ingest)
        _ = try await service.preparedBackend(from: initial.selection.token, stage: .planner)
        _ = try await service.preparedBackend(from: initial.selection.token, stage: .planner)
        let fallback = try await service.fallbackPreparation(from: initial.selection.token, stage: .planner, fallbackProviderID: beta)
        _ = try await service.preparedBackend(from: fallback.selection.token, stage: .planner)
        #expect(backendCount.count == 2)
    }

    @Test("Distinct ingest stage models reuse one backend for the same provider")
    func stageModelsReuseProviderBackend() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let backendCount = Counter()
        let service = runtime(
            config: config,
            counts: counts,
            factory: { _, _, _ in
                backendCount.increment()
                return FakeAgentBackend()
            })
        let initial = try await service.prepare(.ingest)
        let executor = try await service.preparation(
            from: initial.selection.token,
            stage: .executor)
        let finalizer = try await service.preparation(
            from: initial.selection.token,
            stage: .finalizer)

        _ = try await service.preparedBackend(
            from: initial.selection.token,
            stage: .planner)
        _ = try await service.preparedBackend(
            from: executor.selection.token,
            stage: .executor)
        _ = try await service.preparedBackend(
            from: finalizer.selection.token,
            stage: .finalizer)

        #expect(initial.selection.model == ModelID(rawValue: "planner-model"))
        #expect(executor.selection.model == ModelID(rawValue: "executor-model"))
        #expect(finalizer.selection.model == ModelID(rawValue: "final-model"))
        #expect(backendCount.count == 1)
    }

    @Test("Release invalidates all snapshot tokens and backend cache entries")
    func releaseInvalidatesSnapshot() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let backendCount = Counter()
        let service = runtime(
            config: config,
            counts: counts,
            factory: { _, _, _ in
                backendCount.increment()
                return FakeAgentBackend()
            })
        let initial = try await service.prepare(.ingest)
        let executor = try await service.preparation(
            from: initial.selection.token,
            stage: .executor)
        _ = try await service.preparedBackend(
            from: executor.selection.token,
            stage: .executor)

        await service.release(executor.selection.token)

        await #expect(throws: AgentProviderRuntimeError.invalidToken) {
            try await service.preparation(
                from: initial.selection.token,
                stage: .planner)
        }
        await #expect(throws: AgentProviderRuntimeError.invalidToken) {
            try await service.preparedBackend(
                from: executor.selection.token,
                stage: .executor)
        }
        let next = try await service.prepare(.ingest)
        _ = try await service.preparedBackend(
            from: next.selection.token,
            stage: .planner)
        #expect(backendCount.count == 2)
    }

    @Test("Default summary does not resolve command, credential, or backend")
    func defaultSummaryIsCheap() async throws {
        let config = LockedBox(configuration()); let counts = RuntimeCounts()
        let service = runtime(config: config, counts: counts)
        let result = try await service.prepareSummarization()
        #expect(result == .defaultTruncation)
        #expect(counts.configurationReads == 1)
        #expect(counts.commandCalls == 0)
        #expect(counts.credentialCalls == 0)
    }

    @Test("Model summary uses bypass policy and redacts secrets")
    func modelSummaryAndRedaction() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let counts = RuntimeCounts()
        let policies = PolicyRecorder()
        let service = AgentProviderRuntime(
            readConfiguration: {
                counts.incrementConfigurationReads()
                return config.read()
            },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in
                counts.incrementCredentials()
                return "key-not-public"
            },
            resolvePermissionPolicy: { _ in .alwaysAsk },
            makeBackend: { policy, _, _ in
                policies.record(policy)
                return FakeAgentBackend()
            })
        let result = try await service.prepareSummarization()
        guard case .model(let preparation) = result else {
            Issue.record("expected model summary")
            return
        }
        _ = try await service.preparedBackend(
            from: preparation.selection.token,
            stage: AgentProviderStage.summarizer)
        #expect(preparation.selection.model == ModelID(rawValue: "summary-model"))
        #expect(preparation.policy.permissionPolicy == PermissionPolicy.bypass)
        #expect(policies.values == [PermissionPolicy.bypass])
        #expect(counts.commandCalls == 1)
        #expect(counts.credentialCalls == 2)
        let rendered = "\(preparation) \(preparation.selection.token)"
        #expect(!rendered.contains("/secret"))
        #expect(!rendered.contains("key-not-public"))
        #expect(!rendered.contains("do-not-leak"))
    }
}

private final class RuntimeCounts: Sendable {
    private let storage = Mutex((configurationReads: 0, commandCalls: 0, credentialCalls: 0))
    var configurationReads: Int { storage.withLock { $0.configurationReads } }
    var commandCalls: Int { storage.withLock { $0.commandCalls } }
    var credentialCalls: Int { storage.withLock { $0.credentialCalls } }
    func incrementConfigurationReads() { storage.withLock { $0.configurationReads += 1 } }
    func incrementCommands() { storage.withLock { $0.commandCalls += 1 } }
    func incrementCredentials() { storage.withLock { $0.credentialCalls += 1 } }
}

private final class LockedBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    func read() -> Value { storage.withLock { $0 } }
    func mutate(_ body: @Sendable (inout Value) -> Void) { storage.withLock { body(&$0) } }
}

private final class Counter: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

private final class PolicyRecorder: Sendable {
    private let storage = Mutex<[PermissionPolicy]>([])
    var values: [PermissionPolicy] { storage.withLock { $0 } }
    func record(_ policy: PermissionPolicy) { storage.withLock { $0.append(policy) } }
}
