import Testing
import Foundation
import ACPModel
@testable import WikiFS
@testable import WikiFSCore

/// Slice 2 wiring tests (`plans/acp-backend-and-permissions.md`): backend
/// selection, ACP profile wiring, the drain-on-cancel, and the turn-end
/// synthesis extraction. Pure logic only — NO live agent subprocess (the slice
/// forbids end-to-end testing). The translator + delegate-policy behavior are
/// already covered by `ACPBackendTests`; this suite covers the NEW wiring.
@Suite struct ACPWiringTests {

    // MARK: - Backend selection (AgentBackendFactory)

    /// Default-OFF: the factory returns the Claude CLI backend (today's
    /// behavior, unchanged for existing users).
    @Test func factorySelectsClaudeCLIWhenOff() {
        let backend = AgentBackendFactory.makeBackend(useACPBackend: false, policy: .yolo)
        #expect(backend is ClaudeCLIBackend)
    }

    /// Opt-in ON: the factory returns the ACP backend.
    @Test func factorySelectsACPWhenOn() {
        let backend = AgentBackendFactory.makeBackend(useACPBackend: true, policy: .yolo)
        #expect(backend is ACPBackend)
    }

    /// ACP backend also conforms to `PermissionResolving` (the capability seam
    /// the launcher downcasts to surface pending requests); the CLI backend does
    /// NOT (it has no permission channel).
    @Test func acpBackendExposesPermissionCapability() {
        let acp = AgentBackendFactory.makeBackend(useACPBackend: true, policy: .yolo)
        let cli = AgentBackendFactory.makeBackend(useACPBackend: false, policy: .yolo)
        #expect(acp is PermissionResolving)
        #expect(!(cli is PermissionResolving))
    }

    /// Permission policy threading: the factory threads `alwaysAsk` into the ACP
    /// backend. We can't introspect the private policy, but we CAN assert the
    /// construction doesn't crash and yields an ACP backend for both policies
    /// (the policy's effect on the delegate is covered by `ACPBackendTests`).
    @Test func factoryThreadsBothPolicies() {
        let yolo = AgentBackendFactory.makeBackend(useACPBackend: true, policy: .yolo)
        let alwaysAsk = AgentBackendFactory.makeBackend(useACPBackend: true, policy: .alwaysAsk)
        #expect(yolo is ACPBackend)
        #expect(alwaysAsk is ACPBackend)
    }

    // MARK: - ACP provider hints (AgentCommandConfig → profile)

    /// The resolved executable path becomes `acpAgentPath`; prefix args become
    /// `acpAgentArgs`. This is how the Agent command config DOUBLES as the ACP
    /// agent spawn.
    @Test func acpProviderHintsFromConfig() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "/usr/local/bin/npx",
            prefixArguments: "--yes @agentclientprotocol/claude-agent-acp")
        #expect(hints["acpAgentPath"] == "/usr/local/bin/npx")
        #expect(hints["acpAgentArgs"] == "--yes @agentclientprotocol/claude-agent-acp")
    }

    /// Empty inputs yield an empty dict (→ `ACPBackend` throws
    /// `noAgentConfigured`). The opt-in feature requires a configured agent.
    @Test func acpProviderHintsEmptyWhenUnconfigured() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "", prefixArguments: "")
        #expect(hints.isEmpty)
    }

    /// Only the path set (no prefix args) → just `acpAgentPath`.
    @Test func acpProviderHintsPathOnly() {
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "/bin/agent", prefixArguments: "")
        #expect(hints.count == 1)
        #expect(hints["acpAgentPath"] == "/bin/agent")
    }

    /// The args string is tokenized shell-aware at spawn time (in
    /// `ACPBackend.resolveSpawnConfig`), NOT by the factory. The factory passes
    /// the raw string through so a quoted multi-token arg like `--yes @org/agent`
    /// survives intact for the tokenizer to split. This pins the contract: the
    /// factory stores the raw string; the backend tokenizes.
    @Test func acpProviderHintsPreservesRawArgsForTokenization() {
        let raw = "--yes @agentclientprotocol/claude-agent-acp"
        let hints = AgentBackendFactory.acpProviderHints(
            resolvedExecutable: "npx", prefixArguments: raw)
        #expect(hints["acpAgentArgs"] == raw)
    }

    // MARK: - Turn-end synthesis (extracted from ACPBackend.send)

    /// A successful prompt completion synthesizes exactly `.messageStop` (the
    /// port's turn-boundary contract — every ACP stopReason is a turn boundary).
    @Test func turnEndSynthesisOnSuccess() {
        #expect(ACPBackend.turnEndEvents(error: nil) == [.messageStop])
    }

    /// A failed prompt synthesizes a `.raw` error line THEN `.messageStop`, so
    /// the consumer's for-await still exits and the generation gate releases
    /// (an error is also a turn boundary).
    @Test func turnEndSynthesisOnError() {
        struct Boom: Error {}
        let events = ACPBackend.turnEndEvents(error: Boom())
        #expect(events.count == 2)
        // First event is a `.raw` line carrying the error (exact wording is
        // locale/Swift-version dependent, so assert by case + prefix).
        if case .raw(let text)? = events.first {
            #expect(text.hasPrefix("ACP agent error:"))
        } else {
            Issue.record("expected a .raw error line first, got \(String(describing: events.first))")
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
        #expect(await delegate.pendingSnapshot().count == 1)

        // Drain — the launcher's cancel path.
        let drained = await delegate.cancelAllPending()
        #expect(drained == 1)

        // The suspended request resumes with a cancelled outcome.
        let response = try await requestTask.value
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        // Pending map is empty (no leak).
        #expect(await delegate.pendingSnapshot().isEmpty)
    }

    /// Draining with nothing pending is a no-op returning 0 (cancel on an idle
    /// session must be safe).
    @Test func cancelAllPendingNoOpWhenIdle() async {
        let delegate = ACPPermissionDelegate(policy: .alwaysAsk)
        let drained = await delegate.cancelAllPending()
        #expect(drained == 0)
        #expect(await delegate.pendingSnapshot().isEmpty)
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
        #expect(await delegate.pendingSnapshot().count == 2)

        let drained = await delegate.cancelAllPending()
        #expect(drained == 2)
        #expect(await delegate.pendingSnapshot().isEmpty)
    }
}
