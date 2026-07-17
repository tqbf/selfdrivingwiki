import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Slice 2 wiring tests (`plans/acp-backend-and-permissions.md`): backend
/// selection, ACP profile wiring, the drain-on-cancel, and the turn-end
/// synthesis extraction. Pure logic only — NO live agent subprocess (the slice
/// forbids end-to-end testing). The translator + delegate-policy behavior are
/// already covered by `ACPBackendTests`; this suite covers the NEW wiring.
@Suite struct ACPWiringTests {

    // MARK: - Backend selection (AgentBackendFactory)

    /// ACP-only (Phase 4, `plans/acp-multi-provider.md`): the factory always
    /// returns the ACP backend, which conforms to `PermissionResolving` (the
    /// capability seam the launcher downcasts to surface pending requests).
    @Test func factorySelectsACP() {
        let backend = AgentBackendFactory.makeBackend(policy: .bypass)
        #expect(backend is ACPBackend)
        #expect(backend is PermissionResolving)
    }

    /// Permission policy threading: the factory threads `alwaysAsk` into the ACP
    /// backend. We can't introspect the private policy, but we CAN assert the
    /// construction doesn't crash and yields an ACP backend for both policies
    /// (the policy's effect on the delegate is covered by `ACPBackendTests`).
    @Test func factoryThreadsBothPolicies() {
        let yolo = AgentBackendFactory.makeBackend(policy: .bypass)
        let alwaysAsk = AgentBackendFactory.makeBackend(policy: .alwaysAsk)
        #expect(yolo is ACPBackend)
        #expect(alwaysAsk is ACPBackend)
    }

    // MARK: - ACP provider hints (AgentProvider → profile)

    /// The resolved executable path becomes `acpAgentPath`; the rest of the
    /// argv becomes `acpAgentArgs` (joined; the key goes through the Keychain
    /// store, tested separately).
    @Test func providerHintsFromResolvedCommand() {
        let provider = AgentProvider(id: "claude-acp", label: "Claude")
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/npx", "--yes", "@agentclientprotocol/claude-agent-acp"],
            apiKey: nil)
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/usr/local/bin/npx")
        #expect(hints[HintKey.acpAgentArgs.rawValue] == "--yes @agentclientprotocol/claude-agent-acp")
    }

    /// An empty resolved command yields an empty dict (→ `ACPBackend` throws
    /// `noAgentConfigured`).
    @Test func providerHintsEmptyWhenUnconfigured() {
        let provider = AgentProvider(id: "x", label: "X")
        let hints = AgentBackendFactory.providerHints(
            provider: provider, resolvedCommand: [], apiKey: nil)
        #expect(hints.isEmpty)
    }

    /// Only the executable (no args) → just `acpAgentPath`.
    @Test func providerHintsPathOnly() {
        let provider = AgentProvider(id: "x", label: "X")
        let hints = AgentBackendFactory.providerHints(
            provider: provider, resolvedCommand: ["/bin/agent"], apiKey: nil)
        #expect(hints.count == 1)
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/bin/agent")
    }

    // MARK: - AgentSpawnConfig.environment (Phase 2, plans/acp-multi-provider.md)

    /// `env.`-prefixed `providerHints` (the convention
    /// `AgentBackendFactory.providerHints` emits from `AgentProvider.env`) are
    /// collected into `AgentSpawnConfig.environment`, stripped of the prefix.
    /// This is the config `ACPBackend.start` later merges over the inherited
    /// process environment.
    @Test func resolveSpawnConfigCollectsEnvPrefixedHints() {
        let profile = BackendProfile(providerHints: [
            HintKey.acpAgentPath.rawValue: "/usr/local/bin/hermes",
            HintKey.acpAgentArgs.rawValue: "acp",
            HintKey.env("ZAI_API_KEY"): "secretish",
            HintKey.env("HERMES_MODE"): "fast",
        ])
        let spawn = ACPBackend.resolveSpawnConfig(from: profile)
        #expect(spawn?.executablePath == "/usr/local/bin/hermes")
        #expect(spawn?.environment == ["ZAI_API_KEY": "secretish", "HERMES_MODE": "fast"])
    }

    /// No `env.`-prefixed hints → empty environment (no merge, unchanged
    /// behavior for providers with no extra env).
    @Test func resolveSpawnConfigEmptyEnvironmentWhenUnconfigured() {
        let profile = BackendProfile(providerHints: [HintKey.acpAgentPath.rawValue: "/bin/agent"])
        let spawn = ACPBackend.resolveSpawnConfig(from: profile)
        #expect(spawn?.environment.isEmpty == true)
    }

    // MARK: - buildAgentEnv (issue #441: WIKI_ROOT no longer exported)

    /// `buildAgentEnv` exports `WIKI_DB` and `WIKICTL` but NOT `WIKI_ROOT` —
    /// the mount is optional; wikictl is the primary read surface.
    @Test func buildAgentEnvDoesNotExportWikiRoot() {
        let cli = CLIProfile(
            operation: .queryChat(stateFilePath: "/tmp/state.md"),
            wikiRoot: "/tmp/fake-mount",
            wikiID: "FAKEWIKIID",
            wikictlDirectory: "/tmp/wikictl-bin")
        let env = ACPBackend.buildAgentEnv(
            from: cli,
            baseEnv: ["PATH": "/usr/bin:/bin"],
            spawnEnvironment: [:])
        #expect(env["WIKI_ROOT"] == nil)
        #expect(env["WIKI_DB"] == "FAKEWIKIID")
        #expect(env["WIKICTL"] == "/tmp/wikictl-bin/wikictl")
        #expect(env["PATH"] == "/tmp/wikictl-bin:/usr/bin:/bin")
    }

    /// Spawn environment (provider hints) are merged into the result.
    @Test func buildAgentEnvMergesSpawnEnvironment() {
        let cli = CLIProfile(
            operation: .queryChat(stateFilePath: "/tmp/state.md"),
            wikiRoot: "/tmp/fake-mount",
            wikiID: "FAKEWIKIID",
            wikictlDirectory: "/tmp/wikictl-bin")
        let env = ACPBackend.buildAgentEnv(
            from: cli,
            baseEnv: ["PATH": "/usr/bin:/bin"],
            spawnEnvironment: ["MY_API_KEY": "secret"])
        #expect(env["MY_API_KEY"] == "secret")
        #expect(env["WIKI_ROOT"] == nil)
    }

    // MARK: - Turn-end synthesis (extracted from ACPBackend.send)

    /// A successful prompt completion synthesizes exactly `.messageStop` (the
    /// port's turn-boundary contract — every ACP stopReason is a turn boundary).
    @Test func turnEndSynthesisOnSuccess() {
        #expect(ACPBackend.turnEndEvents(error: nil) == [.messageStop])
    }

    /// A failed prompt synthesizes a `.turnFailed` event THEN `.messageStop`, so
    /// the consumer's for-await still exits and the generation gate releases
    /// (an error is also a turn boundary). The `.turnFailed` carries a
    /// structured `TurnFailureReason` that persists and renders as a banner. (#422)
    @Test func turnEndSynthesisOnError() {
        struct Boom: Error {}
        let events = ACPBackend.turnEndEvents(error: Boom())
        #expect(events.count == 2)
        // First event is a `.turnFailed` carrying the error as `.agentError`.
        if case .turnFailed(let reason)? = events.first {
            if case .agentError(let message) = reason {
                #expect(!message.isEmpty)
            } else {
                Issue.record("expected .agentError reason, got \(reason)")
            }
        } else {
            Issue.record("expected a .turnFailed event first, got \(String(describing: events.first))")
        }
        // Last event is always the turn-boundary marker.
        #expect(events.last == .messageStop)
    }

    /// Both branches end in an `endsGeneration` event — the launcher keys its
    /// gate/lock/flush off this. Pinned so a future refactor can't drop it.
    @Test func turnEndSynthesisAlwaysEndsGeneration() {
        for error: Error? in [nil, NSError(domain: "x", code: 1)] {
            for event in ACPBackend.turnEndEvents(error: error) {
                if event == ACPBackend.turnEndEvents(error: error).last {
                    #expect(AgentEvent.endsGeneration(event))
                }
            }
        }
    }

    // MARK: - Drain-on-cancel (no continuation leak)

    /// `cancelAllPending()` resumes a deferred always-ask continuation as
    /// cancelled and empties the pending map — so cancelling a session never
    /// leaks a `CheckedContinuation`. Mirrors `ACPBackend.cancel`'s teardown.
    @Test func cancelAllPendingResumesAsCancelledAndClears() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let request = RequestPermissionRequest(
            options: [PermissionOption(kind: "allow_once", name: "Allow", optionId: "opt-allow")],
            sessionId: SessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: "tc-drain", title: "Write"))

        // Suspend a request (always-ask defers).
        let requestTask = Task<RequestPermissionResponse, Error> {
            try await delegate.handlePermissionRequest(request: request)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.pendingSnapshot().count == 1)

        // Drain — the launcher's cancel path.
        let drained = delegate.cancelAllPending()
        #expect(drained == 1)

        // The suspended request resumes with a cancelled outcome.
        let response = try await requestTask.value
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        // Pending map is empty (no leak).
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// Draining with nothing pending is a no-op returning 0 (cancel on an idle
    /// session must be safe).
    @Test func cancelAllPendingNoOpWhenIdle() async {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let drained = delegate.cancelAllPending()
        #expect(drained == 0)
        #expect(delegate.pendingSnapshot().isEmpty)
    }

    /// Drain resumes MULTIPLE pending requests (a session can have more than
    /// one queued if the agent emits several writes before pausing).
    @Test func cancelAllPendingDrainsMultiple() async throws {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        // Two distinct pending requests.
        for id in ["tc-1", "tc-2"] {
            let request = RequestPermissionRequest(
                options: [PermissionOption(kind: "allow_once", name: "Allow", optionId: "opt-\(id)")],
                sessionId: SessionId("s1"),
                toolCall: ToolCallUpdate(toolCallId: id, title: "Write"))
            _ = Task<Void, Never> { _ = try? await delegate.handlePermissionRequest(request: request) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.pendingSnapshot().count == 2)

        let drained = delegate.cancelAllPending()
        #expect(drained == 2)
        #expect(delegate.pendingSnapshot().isEmpty)
    }
}
