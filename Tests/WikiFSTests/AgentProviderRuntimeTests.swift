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
        // Issue #1276: dispose tears the snapshot down (scratch removed) so
        // the test leaves no temp directories behind.
        await service.dispose()
    }

    // MARK: - Summarizer sandbox ownership + teardown ordering (issue #1276)

    @Test("Summarizer preparation returns a read-only profile with a unique owned scratch")
    func summarizerBackendOwnsReadOnlySandboxScratch() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let counts = RuntimeCounts()
        let service = runtime(config: config, counts: counts)

        let first = try await service.prepareSummarization()
        guard case .model(let firstPreparation) = first else {
            Issue.record("expected model summarization")
            return
        }
        let prepared = try await service.preparedBackend(
            from: firstPreparation.selection.token,
            stage: .summarizer)
        let profile = prepared.profile
        #expect(profile.isReadOnly)
        let scratchURL = try #require(profile.scratchDirectory, "summarizer profiles own a scratch directory")
        let sandbox = try #require(profile.sandbox, "summarizer profiles name a read-only sandbox")
        // The invocation's SCRATCH_DIR is the EXACT owned directory (the
        // seatbelt's canonical form of it) and the wiki database is NOT
        // allowed — no define, no allowance.
        #expect(sandbox.defines.first { $0.0 == "SCRATCH_DIR" }?.1 == SandboxProfile.canonical(scratchURL.path))
        #expect(sandbox.defines.contains { $0.0 == "WIKI_DB" } == false)
        #expect(sandbox.profile.contains("(deny file-write*)"))
        // The scratch-local temp root exists before any spawn.
        #expect(FileManager.default.fileExists(atPath: scratchURL.appendingPathComponent(".tmp").path))

        // Each preparation owns a UNIQUE scratch directory.
        let second = try await service.prepareSummarization()
        guard case .model(let secondPreparation) = second else {
            Issue.record("expected second model summarization")
            return
        }
        let prepared2 = try await service.preparedBackend(
            from: secondPreparation.selection.token,
            stage: .summarizer)
        let scratch2 = try #require(prepared2.profile.scratchDirectory)
        #expect(scratch2.path != scratchURL.path, "each snapshot owns its own scratch")

        await service.release(firstPreparation.selection.token)
        await service.release(secondPreparation.selection.token)
        #expect(!FileManager.default.fileExists(atPath: scratchURL.path))
        #expect(!FileManager.default.fileExists(atPath: scratch2.path))
    }

    @Test("Release waits for the active summary, shuts the backend down, then removes scratch")
    func releaseWaitsForActiveSummaryBeforeBackendShutdownAndScratchRemoval() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let counts = RuntimeCounts()
        let order = TeardownOrder()
        let gate = GateBox()
        let gated = GatedSummarizerBackend(gate: gate, order: order, replyText: "one line summary")
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _ in gated })

        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(
            from: preparation.selection.token,
            stage: .summarizer)
        let scratchPath = try #require(prepared.profile.scratchDirectory).path
        #expect(FileManager.default.fileExists(atPath: scratchPath))

        // An ACTIVE summary: its `send` parks on the gate mid-turn.
        let summaryTask = Task {
            await order.record("summary-returned")
            _ = try? await service.modelSummary(text: "long text", preparation: preparation)
        }
        try await waitFor { await order.values.contains("send-start") }

        // Release must NOT tear anything down while the summary is active.
        let releaseTask = Task {
            await service.release(preparation.selection.token)
            await order.record("release-done")
        }
        // Race-exposure window (250 ms): a BROKEN release would reach shutdown
        // here. The hard ordering proof is the final sequence below; this
        // bounded window is what makes a broken teardown LIKELY to be caught,
        // rather than only possible.
        do {
            try await waitFor(
                { await order.values.contains("shutdown") },
                timeout: .milliseconds(250))
            Issue.record("backend shutdown ran while the summary lease was still active")
        } catch is TeardownTimeout {
            // Expected: release is still quiescing.
        }
        #expect(FileManager.default.fileExists(atPath: scratchPath),
                "scratch survives while a cached backend can still use it")

        // Finish the summary — release then completes in the pinned order.
        await gate.open()
        try await waitForTask(releaseTask)
        await summaryTask.value
        let final = await order.values
        let sendStart = try #require(final.firstIndex(of: "send-start"))
        let sendEnd = try #require(final.firstIndex(of: "send-end"))
        let shutdownIndex = try #require(final.firstIndex(of: "shutdown"))
        let done = try #require(final.firstIndex(of: "release-done"))
        #expect(sendEnd > sendStart)
        #expect(shutdownIndex > sendEnd, "shutdown happens only after the summary drained")
        #expect(done > shutdownIndex)
        #expect(!FileManager.default.fileExists(atPath: scratchPath),
                "scratch is removed only after the backend terminated")

        // Retired snapshot: new work is rejected.
        do {
            _ = try await service.modelSummary(text: "more text", preparation: preparation)
            Issue.record("post-release summary must be rejected")
        } catch let error as AgentProviderRuntimeError {
            #expect(error == .invalidToken)
        }
    }

    @Test("Dispose waits for the active title, shuts the backend down, then removes scratch")
    func disposeWaitsForActiveTitleBeforeBackendShutdownAndScratchRemoval() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let counts = RuntimeCounts()
        let order = TeardownOrder()
        let gate = GateBox()
        let gated = GatedSummarizerBackend(gate: gate, order: order, replyText: "Titled Nicely")
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _ in gated })

        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(
            from: preparation.selection.token,
            stage: .summarizer)
        let scratchPath = try #require(prepared.profile.scratchDirectory).path

        // An ACTIVE title generation parks on the gate mid-turn.
        let titleTask = Task {
            _ = try? await service.modelTitle(
                question: "What is a venturi mask?",
                answer: "An oxygen delivery device…",
                preparation: preparation)
        }
        try await waitFor { await order.values.contains("send-start") }

        let disposeTask = Task {
            await service.dispose()
            await order.record("dispose-done")
        }
        do {
            try await waitFor(
                { await order.values.contains("shutdown") },
                timeout: .milliseconds(250))
            Issue.record("backend shutdown ran while the title lease was still active")
        } catch is TeardownTimeout {
            // Expected: dispose is still quiescing.
        }
        #expect(FileManager.default.fileExists(atPath: scratchPath))

        await gate.open()
        try await waitForTask(disposeTask)
        await titleTask.value
        let final = await order.values
        let sendEnd = try #require(final.firstIndex(of: "send-end"))
        let shutdownIndex = try #require(final.firstIndex(of: "shutdown"))
        let done = try #require(final.firstIndex(of: "dispose-done"))
        #expect(shutdownIndex > sendEnd)
        #expect(done > shutdownIndex)
        #expect(!FileManager.default.fileExists(atPath: scratchPath))
    }

    /// `prepareSummarization` unwrapped to its preparation.
    private func summarizerPreparation(_ service: AgentProviderRuntime) async throws -> AgentOperationPreparation {
        let result = try await service.prepareSummarization()
        guard case .model(let preparation) = result else {
            throw AgentProviderRuntimeError.noProvider
        }
        return preparation
    }

    @Test("Overlapping release and dispose tear the backend down exactly once")
    func overlappingReleaseAndDisposeNeverDoubleShutdown() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let order = TeardownOrder()
        let gate = GateBox()
        let gated = GatedSummarizerBackend(gate: gate, order: order, replyText: "summary")
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _ in gated })

        let preparation = try await summarizerPreparation(service)
        let prepared = try await service.preparedBackend(
            from: preparation.selection.token,
            stage: .summarizer)
        let scratchPath = try #require(prepared.profile.scratchDirectory).path

        // One ACTIVE lease; both teardown paths race it.
        let summaryTask = Task {
            _ = try? await service.modelSummary(text: "text", preparation: preparation)
        }
        try await waitFor { await order.values.contains("send-start") }

        let releaseTask = Task {
            await service.release(preparation.selection.token)
            await order.record("release-done")
        }
        let disposeTask = Task {
            await service.dispose()
            await order.record("dispose-done")
        }

        await gate.open()
        try await waitForTask(releaseTask)
        try await waitForTask(disposeTask)
        await summaryTask.value

        let values = await order.values
        let shutdowns = values.filter { $0 == "shutdown" }
        #expect(shutdowns.count == 1,
                "exactly one shutdown across overlapping teardowns, got \(shutdowns.count)")
        let sendEnd = try #require(values.firstIndex(of: "send-end"))
        let shutdownIndex = try #require(values.firstIndex(of: "shutdown"))
        #expect(shutdownIndex > sendEnd,
                "even under overlap, shutdown never precedes the active lease draining")
        #expect(!FileManager.default.fileExists(atPath: scratchPath))
    }

    @Test("Disposal during summarizer preparation removes the scratch and refuses")
    func disposalDuringPreparationRemovesScratchAndRefuses() async throws {
        let config = LockedBox(configuration(summarizer: true))
        let commandGate = GateBox()
        let signals = TeardownOrder()
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { _ in
                await signals.record("resolve-entered")
                await commandGate.wait()
                return [:]
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass })

        // Park preparation inside command resolution, dispose underneath it.
        let startedAt = Date()
        let prepareTask = Task {
            _ = try? await service.prepareSummarization()
        }
        try await waitFor { await signals.values.contains("resolve-entered") }
        // Only dirs CREATED after we started can be ours — the temp root is
        // shared with concurrently-running suites.
        let scratchBefore = Self.summarizerScratchPaths(createdAfter: startedAt)
        #expect(!scratchBefore.isEmpty, "the parked preparation already owns its scratch")

        await service.dispose()
        await commandGate.open()
        await prepareTask.value

        // The disposed runtime never resurrects the snapshot: no active
        // snapshot remains and the parked preparation's scratch is gone.
        let activeAfter = await service.activeSnapshotCount()
        #expect(activeAfter == 0)
        // Bounded poll: the parked scratch must disappear.
        try await waitFor(
            { Self.summarizerScratchPaths(createdAfter: startedAt).isEmpty },
            timeout: .seconds(2),
            pollInterval: .milliseconds(20))
    }

    /// Parked-preparation scratch dirs are visible under the temp root by the
    /// production name prefix, optionally scoped to dirs created after a
    /// timestamp so concurrently-running suites do not pollute the check.
    private static func summarizerScratchPaths(createdAfter date: Date? = nil) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [URLResourceKey.creationDateKey])) ?? []
        return contents.filter { url in
            guard url.lastPathComponent.hasPrefix("summarizer-") else { return false }
            if let date,
               let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < date {
                return false
            }
            return true
        }.map { $0.path }
    }

    // MARK: - Catalog sandbox ordering (issue #1276, AC.4)

    @Test("discoverCatalog returns the probe observation through the sandbox gate")
    func discoverCatalogReturnsProbeObservation() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let observation = ACPProviderCatalogObservation(
            providerID: alpha,
            fingerprint: nil,
            models: [],
            currentModelID: nil,
            thinkingCapability: nil)
        let probedCommand = LockedBox<[String]?>(nil)
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in "key" },
            resolvePermissionPolicy: { _ in .bypass },
            probeCatalog: { _, resolvedCommand, _ in
                probedCommand.mutate { $0 = resolvedCommand }
                return observation
            })

        let result = try await service.discoverCatalog(for: config.read().providers[0])
        #expect(result == observation)
        #expect(probedCommand.read() == ["/secret/alpha"])
        #expect(counts.commandCalls == 1)
    }

    @Test("An unusable sandbox makes discoverCatalog fail before command resolution")
    func catalogSandboxFailurePrecedesCommandResolution() async throws {
        let config = LockedBox(configuration())
        let counts = RuntimeCounts()
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                counts.incrementCommands()
                return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            probeCatalog: { _, _, _ in
                Issue.record("the probe must never run when the sandbox is unusable")
                throw ACPProviderModelProbeError.notConfigured
            },
            sandboxUsability: { _ in false })

        await #expect(throws: ACPProviderModelProbeError.sandboxUnavailable) {
            try await service.discoverCatalog(for: config.read().providers[0])
        }
        #expect(counts.commandCalls == 0,
                "command resolution must not run before the sandbox gate passes")
    }

    @Test("discoverCatalog surfaces the typed sandbox-unavailable error")
    func discoverCatalogSurfacesSandboxUnavailable() async throws {
        let config = LockedBox(configuration())
        let service = AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { _ in [:] },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            sandboxUsability: { _ in false })

        do {
            _ = try await service.discoverCatalog(for: config.read().providers[0])
            Issue.record("expected sandboxUnavailable")
        } catch let error as ACPProviderModelProbeError {
            #expect(error == .sandboxUnavailable)
        }
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

// MARK: - Issue #1276 test doubles (nonblocking — no Thread.sleep, no semaphores)

struct TeardownTimeout: Error {}

/// A one-shot open/close gate the tests use to park a fake backend's `send`
/// mid-turn, so release/dispose ordering is observable. Supports multiple
/// waiters; `open()` is idempotent and releases them all.
private actor GateBox {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        let waiters = continuations
        continuations = []
        for waiter in waiters { waiter.resume() }
    }
}

/// Append-only event log for teardown-order assertions.
private actor TeardownOrder {
    private var storage: [String] = []
    func record(_ event: String) { storage.append(event) }
    var values: [String] { storage }
}

/// A scripted summarizer backend whose `send` parks on a `GateBox` until the
/// test opens it. Records the release/dispose lifecycle events in order:
/// send-start → (parked) → send-end → cancel → shutdown.
private actor GatedSummarizerBackend: AgentBackend {
    private let gate: GateBox
    private let order: TeardownOrder
    private let replyText: String
    private var sessionCounter = 0

    init(gate: GateBox, order: TeardownOrder, replyText: String) {
        self.gate = gate
        self.order = order
        self.replyText = replyText
    }

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        sessionCounter += 1
        return SessionHandle(id: "gated-\(sessionCounter)")
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        await order.record("send-start")
        await gate.wait()
        await order.record("send-end")
        return AsyncStream { continuation in
            continuation.yield(.assistantText(replyText))
            continuation.yield(.messageStop)
            continuation.finish()
        }
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? { nil }

    func cancel(_ session: SessionHandle) async {
        await order.record("cancel")
    }

    func shutdown() async {
        await order.record("shutdown")
    }
}

/// Poll a predicate until it holds or the timeout elapses. Task.sleep only —
/// never a blocking wait (house rule, #1051).
private func waitFor(
    _ predicate: () async -> Bool,
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(20)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await predicate()) {
        if ContinuousClock.now >= deadline { throw TeardownTimeout() }
        try await Task.sleep(for: pollInterval)
    }
}

/// Await a task's completion, racing it against a diagnosed timeout so a
/// starved pool fails fast instead of hanging the suite.
private func waitForTask(_ task: Task<Void, Never>, timeout: Duration = .seconds(10)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await task.value }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TeardownTimeout()
        }
        try await group.next()
        group.cancelAll()
    }
}
