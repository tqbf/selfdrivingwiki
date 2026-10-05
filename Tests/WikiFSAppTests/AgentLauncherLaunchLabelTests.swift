#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
import WikiFSCore

/// #1368 (defect 1): the launch-failure message must name the ACTUAL
/// provider. Both catch sites in `AgentLauncher` hardcoded
/// "Failed to launch claude: …" — a user whose selected provider was
/// codex-acp read "trying to start claude" in the failure banner and
/// misdiagnosed the failure (the incident transcript: chat
/// 01M45104K1THXB7AREMWRKTZ6G, "Failed to launch claude: … env: node: No
/// such file or directory" while `provider=ProviderID(rawValue: "codex-acp")`
/// sat on the neighboring log line).
///
/// Drives the REAL catch sites — the queued `run()` spawn catch and the
/// `startInteractiveQuery` backend.start catch — against a
/// `FakeAgentBackend` whose `start()` throws, with a NON-claude provider
/// label ("Codex ACP"). Message text only: the surrounding error flow is
/// untouched, so the observable contract is exactly `preflightError`.
@MainActor
@Suite("Launch failure names the actual provider (#1368)")
struct AgentLauncherLaunchLabelTests {

    private static let providerLabel = "Codex ACP"

    /// Wire a launcher exactly like `AgentLauncherLaunchFailureCompletionTests.
    /// makeFailingLauncher` (fake provider with a selected model so
    /// `SpawnModelGuard` passes; injectable `resolveBackend` returning the
    /// scripted fake), but with a NON-claude provider label.
    private func makeFailingLauncher(
        backend: FakeAgentBackend,
        tempDir: URL
    ) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, _, _ in backend }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = {
            AgentProvider(
                id: ProviderID(rawValue: "codex-acp"),
                label: Self.providerLabel,
                command: ["/usr/bin/false"],
                env: [:],
                enabled: true,
                isDefault: true)
        }
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: ProviderID(rawValue: "codex-acp"), label: Self.providerLabel,
                              command: ["/usr/bin/false"], enabled: true, isDefault: true)
            ],
            selectedModelIds: ["codex-acp": ModelID(rawValue: "fake-model")])
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

    /// A small (< 4 KB) source keeps `run()` on the single-session path —
    /// the path whose spawn catch owns the queued-run message.
    private func smallSource() -> OperationRequest.StagedSource {
        OperationRequest.StagedSource(
            bytes: Data("# page\n".utf8),
            ext: "md",
            displayPath: "sources/by-id/01FAKE01KQ8HDDR3ZXK72XHG6R.md",
            name: "Small Source",
            sourceID: SourceID(rawValue: "01FAKE01KQ8HDDR3ZXK72XHG6R"))
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-label-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The queued `run()` spawn catch: the message must carry the resolved
    /// provider's label and never a hardcoded agent name.
    @Test("queued run() spawn failure names the selected provider")
    func queuedRunFailureNamesProvider() async throws {
        let fake = FakeAgentBackend(behaviors: [FakeSessionBehavior(shouldFailOnStart: true)])
        let tempDir = try makeTempDir("run")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeFailingLauncher(backend: fake, tempDir: tempDir)

        await launcher.run(
            request: .ingest(sources: [smallSource()], stateMarkdown: "# State"),
            wikiID: WikiID(rawValue: "test-wiki"),
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onEvent: nil,
            onLock: {},
            onUnlock: {}
        )

        let message = try #require(launcher.preflightError)
        #expect(message.contains(Self.providerLabel),
                "the failure must name the actual provider, got: \(message)")
        #expect(!message.lowercased().contains("claude"),
                "no hardcoded agent name may appear, got: \(message)")
    }

    /// The interactive chat catch (the incident's exact site): same
    /// contract — the selected provider's label, never a hardcoded one.
    @Test("interactive start failure names the selected provider")
    func interactiveStartFailureNamesProvider() async throws {
        let fake = FakeAgentBackend(behaviors: [FakeSessionBehavior(shouldFailOnStart: true)])
        let tempDir = try makeTempDir("interactive")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeFailingLauncher(backend: fake, tempDir: tempDir)

        await launcher.startInteractiveQuery(
            firstMessage: "hello",
            stateMarkdown: "",
            wikiID: WikiID(rawValue: "test-wiki"),
            wikiRoot: "/tmp",
            systemPrompt: "",
            wikictlDirectory: "/tmp",
            chatID: ChatID(rawValue: "chat-1"),
            onLock: {},
            onUnlock: {}
        )

        let message = try #require(launcher.preflightError)
        #expect(message.contains(Self.providerLabel),
                "the failure must name the actual provider, got: \(message)")
        #expect(!message.lowercased().contains("claude"),
                "no hardcoded agent name may appear, got: \(message)")
    }
}
#endif
