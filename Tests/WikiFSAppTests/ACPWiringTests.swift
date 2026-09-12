#if os(macOS)
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
@Suite(.serialized, .timeLimit(.minutes(2))) struct ACPWiringTests {

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

    /// #609: `makeBackend` exposes `turnCeilingTimeout` and threads it into the
    /// `ACPBackend` constructor untouched. The launcher picks the value via
    /// `TurnLivenessPolicy.ceiling(for:)`; this test pins the factory plumbing
    /// (default interactive → 1800s; explicit 600s → the queued-ingestion
    /// ceiling) so a future refactor can't silently drop the parameter.
    @Test func factoryThreadsTurnCeilingTimeout() async {
        // Default (omitted) = interactive 1800s — preserves pre-#609 behavior
        // for callers that don't differentiate (and matches the underlying
        // `ACPBackend.init` default).
        let interactive = AgentBackendFactory.makeBackend(policy: .bypass)
        let interactiveACP = await (interactive as! ACPBackend).ceilingTimeout()
        #expect(interactiveACP == TurnLivenessPolicy.defaultCeilingTimeout)
        #expect(interactiveACP == 1800)

        // Explicit queued-ingestion ceiling (600s) — what ingest/lint pass.
        let queued = AgentBackendFactory.makeBackend(
            policy: .bypass,
            turnCeilingTimeout: TurnLivenessPolicy.queuedIngestCeiling)
        let queuedACP = await (queued as! ACPBackend).ceilingTimeout()
        #expect(queuedACP == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(queuedACP == 600)
    }

    // MARK: - ACP provider hints (AgentProvider → profile)

    /// The resolved executable path becomes `acpAgentPath`; the rest of the
    /// argv becomes `acpAgentArgs` (joined; the key goes through the Keychain
    /// store, tested separately).
    @Test func providerHintsFromResolvedCommand() {
        let provider = AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude")
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
        let provider = AgentProvider(id: ProviderID(rawValue: "x"), label: "X")
        let hints = AgentBackendFactory.providerHints(
            provider: provider, resolvedCommand: [], apiKey: nil)
        #expect(hints.isEmpty)
    }

    /// Only the executable (no args) → `acpAgentPath` + `acpProviderId`
    /// (the provider id is always threaded, #727).
    @Test func providerHintsPathOnly() {
        let provider = AgentProvider(id: ProviderID(rawValue: "x"), label: "X")
        let hints = AgentBackendFactory.providerHints(
            provider: provider, resolvedCommand: ["/bin/agent"], apiKey: nil)
        #expect(hints.count == 2)
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/bin/agent")
        #expect(hints[HintKey.acpProviderId.rawValue] == "x")
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

    /// Queue-derived ingest provenance is first serialized as a raw child
    /// environment value, then converted to the `env.` provider-hint convention.
    /// Drive the produced hints through the real ACP spawn resolver: a raw hint
    /// key would be omitted from the child environment.
    @Test func ingestRequestHintsResolveQueueSourceEnvironment() throws {
        let first = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "first.md", name: "first",
            sourceID: SourceID(rawValue: "a"))
        let second = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "second.md", name: "second",
            sourceID: SourceID(rawValue: "b"))
        let request = OperationRequest.ingest(sources: [first, second], stateMarkdown: "")

        let hints = AgentLauncher.ingestProvenanceProviderHints(
            for: request,
            addingTo: [HintKey.acpAgentPath.rawValue: "/bin/agent"])
        let spawn = try #require(ACPBackend.resolveSpawnConfig(from: BackendProfile(providerHints: hints)))

        #expect(spawn.environment["WIKI_INGEST_SOURCE_IDS"] == "a,b")
    }

    /// Large-source executor profiles are built independently from the
    /// single-session profile and, on the serial path, again for each fallback
    /// provider. Pin the executor-style hints through `resolveSpawnConfig` so
    /// that every `wikictl` child receives the same queue evidence.
    @Test func largeSourceExecutorHintsResolveQueueSourceEnvironment() throws {
        let first = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "first.md", name: "first",
            sourceID: SourceID(rawValue: "a"))
        let second = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "second.md", name: "second",
            sourceID: SourceID(rawValue: "b"))
        let request = OperationRequest.ingest(sources: [first, second], stateMarkdown: "")

        let executorHints = AgentLauncher.ingestProvenanceProviderHints(
            for: request,
            addingTo: [
                HintKey.acpAgentPath.rawValue: "/bin/agent",
                HintKey.acpSelectedModelId.rawValue: "executor-model",
            ])
        let spawn = try #require(ACPBackend.resolveSpawnConfig(from: BackendProfile(providerHints: executorHints)))

        #expect(executorHints[HintKey.acpSelectedModelId.rawValue] == "executor-model")
        #expect(spawn.environment["WIKI_INGEST_SOURCE_IDS"] == "a,b")
    }

    // MARK: - buildAgentEnv (issue #441: WIKI_ROOT no longer exported)

    /// `buildAgentEnv` exports `WIKI_DB` and `WIKICTL` but NOT `WIKI_ROOT` —
    /// the mount is optional; wikictl is the primary read surface.
    @Test func buildAgentEnvDoesNotExportWikiRoot() {
        let cli = CLIProfile(
            operation: .queryChat(stateFilePath: "/tmp/state.md"),
            wikiRoot: "/tmp/fake-mount",
            wikiID: WikiID(rawValue: "FAKEWIKIID"),
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
            wikiID: WikiID(rawValue: "FAKEWIKIID"),
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

    // MARK: - Seatbelt application (issue #1251)

    /// The provider config-home derivation mirrors `launchHint`'s substring
    /// convention: the command tokens are the truth, not a provider id.
    /// Package runners layer their own caches (npx → `~/.npm`, `bun x` →
    /// `~/.bun`) and providers layer their config homes (codex → `~/.codex`,
    /// gemini → `~/.gemini`); a plain claude binary needs nothing (the base
    /// profile already allows `~/.claude`). Unknown commands get no extras —
    /// a denied config-home write is the visible signal to add a mapping.
    @Test func providerHomeSubpathsDeriveFromCommandTokens() {
        // The exact launch shape that failed on the first wrapped chat:
        // npx writes ~/.npm/_cacache before the adapter even starts.
        #expect(ACPBackend.providerHomeSubpaths(
            forCommand: "/Users/me/.local/bin/npx @agentclientprotocol/claude-agent-acp") == [".npm"])
        // bun x adapters get the bun install cache instead.
        #expect(ACPBackend.providerHomeSubpaths(
            forCommand: "/opt/homebrew/bin/bun x @agentclientprotocol/claude-agent-acp") == [".bun"])
        // A plain claude binary needs no runner cache and no extra home.
        #expect(ACPBackend.providerHomeSubpaths(forCommand: "/usr/local/bin/claude") == [])
        #expect(ACPBackend.providerHomeSubpaths(forCommand: "/usr/local/bin/codex acp") == [".codex"])
        #expect(ACPBackend.providerHomeSubpaths(forCommand: "/usr/local/bin/gemini --experimental-acp") == [".gemini"])
        #expect(ACPBackend.providerHomeSubpaths(forCommand: "/usr/local/bin/hermes acp") == [])
    }

    /// Fail-closed usability gate: the real system front-end passes; a
    /// missing path, a non-executable regular file, and a directory all fail.
    @Test func sandboxExecutableIsUsableRejectsUnusablePaths() throws {
        #expect(ACPBackend.sandboxExecutableIsUsable(at: SandboxProfile.sandboxExecutablePath))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-sandbox-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("sandbox gate cleanup failed: \(error)") }
        }

        #expect(!ACPBackend.sandboxExecutableIsUsable(at: root.appendingPathComponent("missing").path))

        let plainFile = root.appendingPathComponent("plain")
        try Data("#!/bin/sh\n".utf8).write(to: plainFile)
        guard chmod(plainFile.path, 0o400) == 0 else { throw POSIXError(.EIO) }
        #expect(!ACPBackend.sandboxExecutableIsUsable(at: plainFile.path))

        #expect(!ACPBackend.sandboxExecutableIsUsable(at: root.path))
    }

    /// The profile carries the resolved invocation to the backend — the seam
    /// issue #1251 found missing. Defaults stay nil (unsandboxed) for call
    /// sites that intentionally skip confinement (none today; the resolver
    /// fail-opens and logs).
    @Test func backendProfileThreadsSandboxInvocation() {
        let base = BackendProfile(providerHints: [:])
        #expect(base.sandbox == nil)

        let invocation = SandboxProfile.invocation(
            homePath: "/Users/me",
            scratchDir: "/tmp/scratch",
            wikiDBPath: "/db/wiki.sqlite")
        let confined = BackendProfile(providerHints: [:], sandbox: invocation)
        #expect(confined.sandbox == invocation)
    }

    /// Pin the TMPDIR relocation constants the wrap writes into the child
    /// environment: the launcher pre-creates `<scratch>/.tmp`
    /// (`createSandboxTmpDir`), so the values must not drift apart.
    @Test func tmpRelocationTargetsThePrecreatedScratchTmp() {
        #expect(ACPBackend.tmpRelocationLeaf == ".tmp")
        #expect(ACPBackend.tmpRelocationKey == "TMPDIR")
    }

    /// The derived spawn plan wraps the real agent behind `sandbox-exec`,
    /// layers the provider's config home into the effective profile, and
    /// relocates TMPDIR into the scratch `.tmp` leaf — while preserving the
    /// rest of the child environment.
    @Test func sandboxedSpawnPlanWrapsArgvRelocatesTmpdirAndLayersProviderHome() {
        let invocation = SandboxProfile.invocation(
            homePath: "/Users/me",
            scratchDir: "/tmp/scratch",
            wikiDBPath: "/db/wiki.sqlite")
        let plan = ACPBackend.sandboxedSpawnPlan(
            invocation: invocation,
            executablePath: "/usr/local/bin/codex",
            arguments: ["acp"],
            environment: ["WIKI_DB": "01WIKI", "PATH": "/usr/bin:/bin"],
            scratchDirectory: URL(fileURLWithPath: "/tmp/scratch"))

        #expect(plan.executablePath == "/usr/bin/sandbox-exec")
        #expect(plan.arguments.first == "-p")
        #expect(plan.arguments.contains("--"))
        #expect(plan.arguments.count > 3)
        if let separator = plan.arguments.firstIndex(of: "--") {
            #expect(Array(plan.arguments[(separator + 1)...]) == ["/usr/local/bin/codex", "acp"])
        } else {
            Issue.record("wrapped argv lost the -- separator")
        }
        // Provider config home for the codex command is layered in.
        #expect(plan.arguments.contains("-D") == true)
        let profileText = plan.arguments.first { $0.contains("file-write*") } ?? ""
        #expect(profileText.contains("\"/.codex\""))
        // Defines pass through unchanged by the extras.
        #expect(plan.defines.map { $0.0 } == invocation.defines.map { $0.0 })
        // TMPDIR relocated into the scratch .tmp; other env preserved.
        #expect(plan.environment["TMPDIR"] == "/tmp/scratch/.tmp")
        #expect(plan.environment["WIKI_DB"] == "01WIKI")
        #expect(plan.environment["PATH"] == "/usr/bin:/bin")
    }

    /// A plain claude binary launch layers nothing: the plan's embedded
    /// profile equals the base invocation's exactly (no appended allow
    /// rules), and a nil scratch skips the TMPDIR relocation.
    @Test func sandboxedSpawnPlanAddsNothingForPlainClaudeBinary() {
        let invocation = SandboxProfile.invocation(
            homePath: "/Users/me",
            scratchDir: "/tmp/scratch",
            wikiDBPath: "/db/wiki.sqlite")
        let plan = ACPBackend.sandboxedSpawnPlan(
            invocation: invocation,
            executablePath: "/usr/local/bin/claude",
            arguments: [],
            environment: [:],
            scratchDirectory: nil)

        #expect(plan.defines.map { $0.0 } == invocation.defines.map { $0.0 })
        #expect(plan.defines.map { $0.1 } == invocation.defines.map { $0.1 })
        // The single -p payload is byte-identical to the base profile.
        let profilePayload = plan.arguments.first { $0.contains("(version 1)") }
        #expect(profilePayload == invocation.profile)
        // No provider-home extras were appended.
        #expect(plan.arguments.contains("\"/.npm\"") == false)
        #expect(plan.arguments.contains("\"/.codex\"") == false)
        // nil scratch → no TMPDIR relocation, no invented env.
        #expect(plan.environment["TMPDIR"] == nil)
        #expect(plan.environment.isEmpty)
    }

    /// The bun resolution memoization contract, exercised through the
    /// injected resolver + probe seams (second-round review MAJOR-3):
    /// (a) two calls locate once; (b) a failing resolver locates once across
    /// calls (negative memo); (c) a changed identity re-locates exactly once
    /// and the third call reuses.
    @Test func bunResolutionMemoizationContract() async throws {
        // Synthetic identity pair: the resolver "installs" identity A first,
        // then identity B after the cache goes stale.
        let identityA = RuntimeExecutableIdentity(device: 1, inode: 100, mode: 0o100755, size: 10)
        let identityB = RuntimeExecutableIdentity(device: 1, inode: 200, mode: 0o100755, size: 20)
        let bunName = try #require(ExtractorRuntimeName(rawValue: "bun"))
        let counter = InvocationCounter()
        // Which identity the FILE PROBE sees: A until the cache is stale,
        // then B (the binary was swapped under the cached path).
        let probeIdentityFlipper = InvocationCounter()

        let backend = ACPBackend(
            resolveBunRuntime: {
                let count = counter.bump()
                return RuntimeCommandResolution(
                    command: bunName,
                    source: .loginShell,
                    executableURL: URL(fileURLWithPath: "/synthetic/bun"),
                    identity: count == 1 ? identityA : identityB,
                    description: RuntimePathDescription(
                        redactedPath: "bun", basename: "bun", fingerprint: "test"))
            },
            probeExecutable: { _ in
                probeIdentityFlipper.bump() >= 2
                    ? .identity(identityB)
                    : .identity(identityA)
            })

        // (a) two calls, one locate; probe sees A, matching the resolution.
        _ = await backend.resolvedBunResolution()
        _ = await backend.resolvedBunResolution()
        #expect(counter.value == 1)

        // (c) the probe now sees B — the cached identity is stale. The next
        // call re-locates exactly once (resolver returns identity B), and the
        // call after that reuses the refreshed memo.
        _ = await backend.resolvedBunResolution()
        #expect(counter.value == 2)
        _ = await backend.resolvedBunResolution()
        #expect(counter.value == 2)
    }

    /// A failing resolver is negative-cached: two calls locate once, and the
    /// caller gets nil both times (the configured command runs unchanged).
    @Test func bunResolutionNegativeCachesFailures() async {
        let counter = InvocationCounter()
        let backend = ACPBackend(resolveBunRuntime: {
            counter.bump()
            return nil
        })
        _ = await backend.resolvedBunResolution()
        _ = await backend.resolvedBunResolution()
        #expect(counter.value == 1)
    }

    /// MINOR-5 follow-up: the unresolved-bun fallback's sandbox consequence
    /// is real — the configured npx command keeps running, so the effective
    /// profile layers `~/.npm` for the npm package cache. (The plan-level
    /// test above pins the profile; this pins the fallback decision that
    /// selects it.)
    @Test func unresolvedBunFallsBackToNpxWithNpmCacheLayering() {
        let spawn = ACPBackend.AgentSpawnConfig(
            executablePath: "/Users/me/.local/bin/npx",
            arguments: ["@agentclientprotocol/claude-agent-acp"])
        // nil bun → no canonicalization → the configured npx command runs.
        #expect(ACPBackend.canonicalizedSpawn(spawn, resolvedBunPath: nil) == nil)
        // Its provider-home layering is therefore ~/.npm, not ~/.bun.
        #expect(ACPBackend.providerHomeSubpaths(
            forCommand: spawn.executablePath + " "
                + spawn.arguments.joined(separator: " ")) == [".npm"])
    }

    /// An npx-launched adapter rewrites to `<resolved bun> x <spec>` — the
    /// exact shape whose npm-cache write EPERM'd the first wrapped chat — and
    /// every other spawn field survives the rebuild.
    @Test func canonicalizedSpawnRewritesNpxThroughResolvedBun() throws {
        let spawn = ACPBackend.AgentSpawnConfig(
            executablePath: "/Users/me/.local/bin/npx",
            arguments: ["@agentclientprotocol/claude-agent-acp"],
            workingDirectory: "/tmp/scratch",
            apiKey: "secret",
            environment: ["WIKI_DB": "01WIKI"])
        let bun = "/Users/me/.local/share/mise/installs/bun/1.4.0/bin/bun"
        let canonical = try #require(ACPBackend.canonicalizedSpawn(spawn, resolvedBunPath: bun))
        #expect(canonical.executablePath == bun)
        #expect(canonical.arguments == ["x", "@agentclientprotocol/claude-agent-acp"])
        #expect(canonical.workingDirectory == "/tmp/scratch")
        #expect(canonical.apiKey == "secret")
        #expect(canonical.environment == ["WIKI_DB": "01WIKI"])
        // The rewritten command is a `bun x` shape, so the provider-home
        // layering drops ~/.npm and layers ~/.bun instead.
        #expect(ACPBackend.providerHomeSubpaths(
            forCommand: canonical.executablePath + " "
                + canonical.arguments.joined(separator: " ")) == [".bun"])
    }

    /// `npm exec` in both flag orders and the `npm x` alias rewrite; npx-only
    /// runner flags (`-y`, `--yes`) and a leading `--` are stripped (bun x
    /// tolerates but does not document them — the review verified this
    /// against the local bun and the rewrite removes the reliance).
    @Test func canonicalizedSpawnHandlesNpmExecAliasesAndStripsRunnerFlags() throws {
        let bun = "/usr/local/bin/bun"
        let execNoDash = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/usr/local/bin/npm",
                arguments: ["exec", "@agentclientprotocol/claude-agent-acp"]),
            resolvedBunPath: bun))
        #expect(execNoDash.arguments == ["x", "@agentclientprotocol/claude-agent-acp"])

        let execWithDash = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/usr/local/bin/npm",
                arguments: ["exec", "--", "@agentclientprotocol/claude-agent-acp", "--port", "9"]),
            resolvedBunPath: bun))
        #expect(execWithDash.arguments == [
            "x", "@agentclientprotocol/claude-agent-acp", "--port", "9"])

        let npmAlias = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(executablePath: "/usr/local/bin/npm", arguments: ["x", "some-acp"]),
            resolvedBunPath: bun))
        #expect(npmAlias.arguments == ["x", "some-acp"])

        let npxYes = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/Users/me/.local/bin/npx",
                arguments: ["-y", "@agentclientprotocol/claude-agent-acp"]),
            resolvedBunPath: bun))
        #expect(npxYes.arguments == ["x", "@agentclientprotocol/claude-agent-acp"])

        let npmExecYes = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/usr/local/bin/npm",
                arguments: ["exec", "--yes", "--", "some-acp"]),
            resolvedBunPath: bun))
        #expect(npmExecYes.arguments == ["x", "some-acp"])

        let bunx = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/usr/local/bin/bunx",
                arguments: ["@agentclientprotocol/claude-agent-acp"]),
            resolvedBunPath: bun))
        #expect(bunx.arguments == ["x", "@agentclientprotocol/claude-agent-acp"])
    }

    /// A `bun x` launch is repointed at the resolved bun (it stops depending
    /// on whatever `bun` the PATH had) with its arguments untouched.
    @Test func canonicalizedSpawnRepointsBunXLaunches() throws {
        let canonical = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/some/user/bun",
                arguments: ["x", "@agentclientprotocol/claude-agent-acp"],
                workingDirectory: "/tmp/scratch",
                apiKey: nil,
                environment: [:]),
            resolvedBunPath: "/resolved/bun"))
        #expect(canonical.executablePath == "/resolved/bun")
        #expect(canonical.arguments == ["x", "@agentclientprotocol/claude-agent-acp"])
        #expect(canonical.workingDirectory == "/tmp/scratch")
    }

    /// Non-adapter shapes, translatable runner flags, and a missing
    /// resolution all return nil — the caller keeps the configured command
    /// and logs the fallback.
    @Test func canonicalizedSpawnReturnsNilForUnsafeOrNonAdapterShapes() {
        let bun = "/usr/local/bin/bun"
        // Plain provider binaries are never rewritten.
        #expect(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/usr/local/bin/claude",
                arguments: ["-p", "hi"],
                workingDirectory: "/tmp",
                apiKey: "k",
                environment: ["A": "b"]),
            resolvedBunPath: bun) == nil)
        #expect(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(executablePath: "/usr/local/bin/codex", arguments: ["acp"]),
            resolvedBunPath: bun) == nil)
        // npm without the exec/x subcommand is not an adapter shape.
        #expect(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(executablePath: "/usr/local/bin/npm", arguments: ["run", "build"]),
            resolvedBunPath: bun) == nil)
        // No resolved bun (locate failed) → keep the configured command.
        for missing in [nil, ""] {
            #expect(ACPBackend.canonicalizedSpawn(
                ACPBackend.AgentSpawnConfig(
                    executablePath: "/Users/me/.local/bin/npx",
                    arguments: ["@agentclientprotocol/claude-agent-acp"]),
                resolvedBunPath: missing) == nil)
        }
        // Committee round 2: spec forms `bun x` cannot execute fail safe to
        // the configured command instead of breaking working launches.
        for unsupported in [
            "github:org/repo",
            "git+ssh://git@github.com/org/repo.git",
            "https://example.com/adapter/pkg.tgz",
            "file:../adapter",
            "./local-adapter",
        ] {
            #expect(ACPBackend.canonicalizedSpawn(
                ACPBackend.AgentSpawnConfig(
                    executablePath: "/Users/me/.local/bin/npx",
                    arguments: [unsupported]),
                resolvedBunPath: bun) == nil, "spec \(unsupported) must fail safe")
        }
    }

    /// The shape gate that keeps non-adapter launches from paying for the
    /// bun locate at all.
    @Test func isJSAdapterLaunchMatchesOnlyAdapterShapes() {
        #expect(ACPBackend.isJSAdapterLaunch(
            executablePath: "/Users/me/.local/bin/npx", arguments: ["pkg"]))
        #expect(ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/bunx", arguments: ["pkg"]))
        #expect(ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/npm", arguments: ["exec", "pkg"]))
        #expect(ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/npm", arguments: ["x", "pkg"]))
        #expect(ACPBackend.isJSAdapterLaunch(
            executablePath: "/some/user/bun", arguments: ["x", "pkg"]))
        #expect(!ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/npm", arguments: ["run", "build"]))
        #expect(!ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/claude", arguments: []))
        #expect(!ACPBackend.isJSAdapterLaunch(
            executablePath: "/usr/local/bin/codex", arguments: ["acp"]))
    }

    /// Committee round 2 (M4): the primary happy path keeps a plan-level
    /// guard — a canonicalized `bun x` command must produce the `/.bun`
    /// write allowance in the emitted seatbelt profile and must not keep the
    /// `/.npm` allowance, or the original first-chat EPERM regresses
    /// undetected.
    @Test func sandboxedSpawnPlanForCanonicalizedBunXLayersBunCache() throws {
        let invocation = SandboxProfile.invocation(
            homePath: "/Users/me",
            scratchDir: "/tmp/scratch",
            wikiDBPath: "/db/wiki.sqlite")
        let canonical = try #require(ACPBackend.canonicalizedSpawn(
            ACPBackend.AgentSpawnConfig(
                executablePath: "/Users/me/.local/bin/npx",
                arguments: ["@agentclientprotocol/claude-agent-acp"]),
            resolvedBunPath: "/resolved/bun"))
        let plan = ACPBackend.sandboxedSpawnPlan(
            invocation: invocation,
            executablePath: canonical.executablePath,
            arguments: canonical.arguments,
            environment: [:],
            scratchDirectory: URL(fileURLWithPath: "/tmp/scratch"))

        let profilePayload = plan.arguments.first { $0.contains("(version 1)") }
        #expect(profilePayload?.contains(
            "(allow file-write* (subpath (string-append (param \"HOME\") \"/.bun\")))") == true)
        #expect(profilePayload?.contains("\"/.npm\"") == false)
        #expect(plan.executablePath == SandboxProfile.sandboxExecutablePath)
    }

    /// Committee round 2 (Sol MAJOR-2 + Claude M3): concurrent first callers
    /// share ONE locate (the in-flight task), and the shared result is not
    /// lost to a stale waiter overwriting a newer generation.
    @Test func concurrentBunResolutionCallersShareOneLocate() async throws {
        let identity = RuntimeExecutableIdentity(device: 1, inode: 300, mode: 0o100755, size: 10)
        let bunName = try #require(ExtractorRuntimeName(rawValue: "bun"))
        let counter = InvocationCounter()
        let backend = ACPBackend(resolveBunRuntime: {
            counter.bump()
            // A small real suspension so callers genuinely overlap.
            do { try await Task.sleep(for: .milliseconds(50)) } catch {}
            return RuntimeCommandResolution(
                command: bunName,
                source: .loginShell,
                executableURL: URL(fileURLWithPath: "/synthetic/bun"),
                identity: identity,
                description: RuntimePathDescription(
                    redactedPath: "bun", basename: "bun", fingerprint: "test"))
        })

        await withTaskGroup(of: RuntimeCommandResolution?.self) { group in
            for _ in 0..<5 {
                group.addTask { await backend.resolvedBunResolution() }
            }
            for await resolution in group {
                #expect(resolution?.executableURL.path == "/synthetic/bun")
            }
        }
        #expect(counter.value == 1)
    }
}
#endif

/// Thread-safe call counter for the resolver/probe seams the bun-resolution
/// memoization tests inject.
final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
