#if os(macOS)
import Testing
import Foundation
@testable import WikiFSEngine
@testable import WikiFS
import WikiFSCore

/// #1354: an ingestion job must not report completion when the agent fails to
/// launch. Drives the REAL multi-phase ingest path (`launcher.run` with a
/// large >4 KB source → `runACPIngestPlannerExecutors`) against a
/// `FakeAgentBackend` whose every `start()` throws — the planner phase fails,
/// the single-session fallback also fails, and the orchestrator aborts.
///
/// The observed production failure (job 01M42E58RKD5T5TY0YD54FWDKS): the
/// codex-acp wrapper's stderr read `env: node: No such file or directory`,
/// the abort path called `finish(status: -1)` with no `.turnFailed` event,
/// and the old validator's "nonzero AND turn-failure" conjunction accepted
/// the outcome as success — stamping sources ingested and settling the item
/// `.completed` ~2.4s after start.
///
/// This suite pins the post-fix launcher contract: the abort records the
/// launch diagnostic in `preflightError` alongside `exitStatus == -1` with
/// zero turn failures, and THAT state is rejected by the queue validator.
@MainActor
@Suite("Launch failure cannot complete ingestion (#1354)")
struct AgentLauncherLaunchFailureCompletionTests {

    /// Wire a launcher exactly like `ACPIngestCollapsedRoutingTests.
    /// makeLauncher` (fake provider with a selected model so
    /// `SpawnModelGuard` passes; injectable `resolveBackend` returning the
    /// scripted fake), but pointed at an always-failing backend.
    private func makeFailingLauncher(
        backend: FakeAgentBackend,
        tempDir: URL
    ) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, _ in backend }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = {
            AgentProvider(
                id: ProviderID(rawValue: "fake-acp"),
                label: "Fake",
                command: ["/usr/bin/false"],
                env: [:],
                enabled: true,
                isDefault: true)
        }
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: ProviderID(rawValue: "fake-acp"), label: "Fake",
                              command: ["/usr/bin/false"], enabled: true, isDefault: true)
            ],
            selectedModelIds: ["fake-acp": ModelID(rawValue: "fake-model")])
        do {
            try config.save(to: tempDir)
        } catch {
            Issue.record("Failed to save provider config to temp dir: \(error)")
        }
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        launcher.makeQuotaFallbackCoordinator = {
            QuotaFallbackCoordinator(quotaStateURL: tempDir.appendingPathComponent("quota-state.json"))
        }
        return launcher
    }

    /// A source larger than `IngestPlan.tinySourceByteThreshold` (4 KB) so
    /// `plan.isLargeSource == true` routes to the multi-phase path.
    private func largeSource() -> OperationRequest.StagedSource {
        let pad = String(repeating: "# page\n", count: 600)  // ~4800 bytes
        return OperationRequest.StagedSource(
            bytes: Data(pad.utf8),
            ext: "md",
            displayPath: "sources/by-id/01FAKE01KQ8HDDR3ZXK72XHG6R.md",
            name: "Large Source",
            sourceID: SourceID(rawValue: "01FAKE01KQ8HDDR3ZXK72XHG6R"))
    }

    @Test("planner + fallback launch failures abort with a diagnostic the queue validator rejects")
    func launchFailureAbortsRunWithActionableDiagnostic() async throws {
        // Every start() throws: behavior 1 = the planner phase, behavior 2 =
        // the single-session fallback. Both fail → terminal abort.
        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(shouldFailOnStart: true),
            FakeSessionBehavior(shouldFailOnStart: true),
        ])
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeFailingLauncher(backend: fake, tempDir: tempDir)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: WikiID(rawValue: "test-wiki"),
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onEvent: nil,
            onLock: {},
            onUnlock: {}
        )

        // The launch diagnostic must be recorded (not just logged) so the
        // queue error can carry it. Pre-fix, this abort path reached
        // `finish(status: -1)` with `preflightError == nil`.
        #expect(launcher.preflightError != nil)

        // The exact observed failure tuple: an exit status exists (-1), no
        // agent turn ran, and the run is no longer marked running.
        #expect(launcher.exitStatus == -1)
        #expect(launcher.runHadTurnFailure == false)
        #expect(launcher.isRunning == false)

        // Both launch attempts happened: planner phase + single-session
        // fallback. (A third would mean a phase ran after the abort.)
        let startCount = await fake.startCount
        #expect(startCount == 2)

        // The contract that settles the issue: the launcher's post-abort
        // state is REJECTED by the queue validator — the job fails with the
        // diagnostic instead of completing and stamping sources ingested.
        do {
            try AppQueueIngestionProvider.validateLauncherOutcome(
                exitStatus: launcher.exitStatus,
                preflightError: launcher.preflightError,
                runHadTurnFailure: launcher.runHadTurnFailure)
            Issue.record("Expected the launch-failure outcome to be rejected")
        } catch QueueIngestionError.spawnFailed(let message) {
            #expect(message == launcher.preflightError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// #1354 "keep working" guard: when the planner launch fails but the
    /// single-session fallback SUCCEEDS, the run is a legitimate completion —
    /// `finish(status: 0)`, `preflightError == nil` — and the validator
    /// accepts it. The fallback is a supported intentional recovery, not an
    /// abort.
    @Test("planner launch failure recovered by a successful fallback still completes")
    func plannerFailureWithSuccessfulFallbackCompletes() async throws {
        // Behavior 1 (planner) fails on start; behavior 2 (fallback
        // single-session) starts fine and ends its turn with `.messageStop`.
        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(shouldFailOnStart: true),
            FakeSessionBehavior(events: [.messageStop]),
        ])
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeFailingLauncher(backend: fake, tempDir: tempDir)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: WikiID(rawValue: "test-wiki"),
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onEvent: nil,
            onLock: {},
            onUnlock: {}
        )

        #expect(launcher.exitStatus == 0)
        #expect(launcher.preflightError == nil)
        #expect(launcher.isRunning == false)

        // The recovered run is a valid completion.
        try AppQueueIngestionProvider.validateLauncherOutcome(
            exitStatus: launcher.exitStatus,
            preflightError: launcher.preflightError,
            runHadTurnFailure: launcher.runHadTurnFailure)
    }
}
#endif
