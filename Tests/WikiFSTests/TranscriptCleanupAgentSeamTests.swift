import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// The transcript-cleanup production seam (issue #1379): the dedicated
/// stage's one-shot entry refuses foreign-stage preparations, and
/// `ModelTranscriptCleanupAgent` maps "nothing usable" model results to
/// `.emptyOutput`. Real `AgentProviderRuntime` fixtures + a scripted
/// `AgentProviderServices` stub — the same shape as
/// `AgentProviderRuntimeLeaseTests`. Nothing spawns.
///
/// Acquire-before-backend ordering is NOT re-tested here: the cleanup path's
/// `modelTransform` shares the summarizer lane's lease mechanics verbatim,
/// and that ordering is already pinned by
/// `AgentProviderRuntimeLeaseTests.disposeRemovesLeasesAfterBackendShutdown`.
@Suite("Transcript cleanup production seam", .serialized, .timeLimit(.minutes(2)))
struct TranscriptCleanupAgentSeamTests {

    private let alpha = ProviderID(rawValue: "alpha")

    // MARK: - Fixtures

    /// A config with BOTH the summarizer and the transcriptCleanup stages
    /// pinned to the same provider, each with its own model — so a
    /// summarizer-stage preparation exists to reject, and a real
    /// cleanup-stage preparation exists to accept.
    private func config() -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: alpha, label: "Alpha",
                    command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
                    isDefault: true),
            ],
            selectedModelIds: [alpha.rawValue: ModelID(rawValue: "alpha-default")],
            ingestStageModelIds: [
                "summarizer": ModelID(rawValue: "summary-model"),
                "transcriptCleanup": ModelID(rawValue: "cleanup-model"),
            ],
            stageProviderIds: ["summarizer": alpha, "transcriptCleanup": alpha])
    }

    private func isolatedLeaseRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mirrors `AgentProviderRuntimeLeaseTests.makeRuntime` — a real runtime
    /// over a locked config with every spawn seam injected.
    private func makeRuntime(
        config: LockedConfig,
        leaseParent: URL,
        backendFactory: @escaping AgentProviderRuntime.BackendFactory = { _, _, _, _ in FakeAgentBackend() }
    ) -> AgentProviderRuntime {
        AgentProviderRuntime(
            readConfiguration: { config.read() },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: backendFactory,
            resolveLoginShellPATH: AgentProviderRuntimeTestSupport.stubLoginShellPATH,
            packageRunnerTempParent: leaseParent)
    }

    private func summarizerPreparation(
        _ service: AgentProviderRuntime
    ) async throws -> AgentOperationPreparation {
        let result = try await service.prepareSummarization()
        guard case .model(let preparation) = result else {
            throw AgentProviderRuntimeError.noProvider
        }
        return preparation
    }

    /// Box mirroring the lease suite's `LockedBox` (private there).
    final class LockedConfig: Sendable {
        private let storage: Mutex<AgentProvidersConfig>
        init(_ value: AgentProvidersConfig) { storage = Mutex(value) }
        func read() -> AgentProvidersConfig { storage.withLock { $0 } }
    }

    /// The scripted one-turn backend: yields one assistant text then stops.
    private actor ScriptedReplyBackend: AgentBackend {
        let replyText: String
        init(replyText: String) { self.replyText = replyText }

        func start(
            profile: BackendProfile,
            systemPrompt: String,
            onExit: @escaping @Sendable (Int) -> Void
        ) async throws -> SessionHandle {
            SessionHandle(id: "cleanup-seam-\(UUID().uuidString)")
        }

        func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
            AsyncStream { continuation in
                continuation.yield(.assistantText(replyText))
                continuation.yield(.messageStop)
                continuation.finish()
            }
        }

        func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? { nil }
        func cancel(_ session: SessionHandle) async {}
        func shutdown() async {}
    }

    /// Scripted `AgentProviderServices` for the agent-mapping tests: the
    /// cleanup-stage preparation is REAL (minted by the runtime fixture) and
    /// `modelTransform` replays one scripted result. Everything else throws
    /// `.unavailable` — the cleanup path touches nothing else.
    private struct ScriptedCleanupServices: AgentProviderServices {
        enum TransformResult {
            case reply(String)
            case nilReply
            case emptyReply
        }

        let preparation: AgentOperationPreparation
        let transformResult: TransformResult

        func prepareTranscriptCleanup() async throws -> AgentOperationPreparation {
            preparation
        }

        func modelTransform(
            text: String,
            systemPrompt: String,
            preparation: AgentOperationPreparation
        ) async throws -> String? {
            switch transformResult {
            case .reply(let text): return text
            case .nilReply: return nil
            case .emptyReply: return "   "
            }
        }

        func prepareInteractive(
            providerOverride: ProviderID?, modelOverride: ModelID?,
            configuredThinkingOptionID: ChatConfigurationValueID?,
            priorEffectiveThinkingOptionID: ChatConfigurationValueID?
        ) async throws -> AgentInteractivePreparation {
            throw AgentProviderRuntimeError.unavailable
        }
        func prepare(
            _ operation: AgentProviderOperationKind, providerOverride: ProviderID?,
            modelOverride: ModelID?, thinkingOverride: String?, queuedWorkUnits: Int?
        ) async throws -> AgentOperationPreparation {
            throw AgentProviderRuntimeError.unavailable
        }
        func preparation(
            from token: AgentProviderAttemptToken, stage: AgentProviderStage
        ) async throws -> AgentOperationPreparation {
            throw AgentProviderRuntimeError.unavailable
        }
        func fallbackPreparation(
            from token: AgentProviderAttemptToken, stage: AgentProviderStage,
            fallbackProviderID: ProviderID
        ) async throws -> AgentOperationPreparation {
            throw AgentProviderRuntimeError.unavailable
        }
        func prepareSummarization() async throws -> AgentProviderSummaryPreparation {
            throw AgentProviderRuntimeError.unavailable
        }
        func discoverCatalog(for provider: AgentProvider) async throws -> ACPProviderCatalogObservation {
            throw AgentProviderRuntimeError.unavailable
        }
        func modelSummary(
            text: String, preparation: AgentOperationPreparation
        ) async throws -> String? {
            throw AgentProviderRuntimeError.unavailable
        }
        func release(_ token: AgentProviderAttemptToken) async {}
        func readiness() async -> Bool { true }
    }

    // MARK: - (a) Stage guard

    @Test("modelTransform refuses a summarizer-stage preparation")
    func modelTransformRejectsASummarizerStagePreparation() async throws {
        let config = LockedConfig(config())
        let leaseRoot = try isolatedLeaseRoot()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let service = makeRuntime(config: config, leaseParent: leaseRoot)

        // A REAL summarizer-stage preparation — the token another one-shot
        // lane legitimately holds — must not unlock the cleanup stage.
        let summarizerPreparation = try await summarizerPreparation(service)
        await #expect(throws: AgentProviderRuntimeError.stageMismatch) {
            _ = try await service.modelTransform(
                text: "raw transcript",
                systemPrompt: "system prompt",
                preparation: summarizerPreparation)
        }
    }

    // MARK: - (b) Agent result mapping

    @Test("nil model result maps to emptyOutput")
    func cleanupAgentMapsNilModelResultToEmptyOutput() async throws {
        let (preparation, leaseRoot) = try await cleanupPreparation()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let agent = ModelTranscriptCleanupAgent(services: ScriptedCleanupServices(
            preparation: preparation, transformResult: .nilReply))

        await #expect(throws: TranscriptCleanupError.emptyOutput) {
            _ = try await agent.clean(rawTranscript: "uh um RAW CAPTIONS")
        }
    }

    @Test("empty model result maps to emptyOutput")
    func cleanupAgentMapsEmptyModelResultToEmptyOutput() async throws {
        let (preparation, leaseRoot) = try await cleanupPreparation()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let agent = ModelTranscriptCleanupAgent(services: ScriptedCleanupServices(
            preparation: preparation, transformResult: .emptyReply))

        await #expect(throws: TranscriptCleanupError.emptyOutput) {
            _ = try await agent.clean(rawTranscript: "uh um RAW CAPTIONS")
        }
    }

    @Test("a usable model result comes back as the cleaned text")
    func cleanupAgentReturnsTheCleanedText() async throws {
        let (preparation, leaseRoot) = try await cleanupPreparation()
        defer {
            do { try FileManager.default.removeItem(at: leaseRoot) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let agent = ModelTranscriptCleanupAgent(services: ScriptedCleanupServices(
            preparation: preparation, transformResult: .reply("Cleaned captions.")))

        let cleaned = try await agent.clean(rawTranscript: "uh um RAW CAPTIONS")
        #expect(cleaned == "Cleaned captions.")
    }

    /// Mints a REAL cleanup-stage preparation through the runtime fixture
    /// (the same shape the production path resolves) and returns it with
    /// the lease root the caller must clean up.
    private func cleanupPreparation() async throws -> (AgentOperationPreparation, URL) {
        let config = LockedConfig(config())
        let leaseRoot = try isolatedLeaseRoot()
        do {
            let service = makeRuntime(
                config: config, leaseParent: leaseRoot,
                backendFactory: { _, _, _, _ in ScriptedReplyBackend(replyText: "cleaned") })
            let preparation = try await service.prepareTranscriptCleanup()
            return (preparation, leaseRoot)
        } catch {
            // The preparation failed — the original error is what matters.
            // Removing the temp lease root here is genuinely best-effort
            // cleanup of a directory nothing owns yet.
            try? FileManager.default.removeItem(at: leaseRoot)
            throw error
        }
    }
}
