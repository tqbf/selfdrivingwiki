import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Live ACP smoke harness — drives `ACPBackend` against a REAL ACP agent
/// subprocess, validating the wire path the unit tests can't: launch →
/// `initialize` → (auth) → `newSession` → `sendPrompt` → streamed `AgentEvent`s
/// → `.messageStop`.
///
/// **Opt-in ONLY.** Skipped unless `ACP_SMOKE=1` is set, so it never runs in CI
/// or the default suite (it spawns a real subprocess + may hit the network).
/// Run it explicitly:
///
/// ```
/// ACP_SMOKE=1 swift test --filter ACPSmoke
/// # full turn (needs a valid key the agent accepts):
/// ACP_SMOKE=1 ANTHROPIC_API_KEY=sk-... swift test --filter ACPSmoke
/// ```
///
/// Config (env, all optional):
/// - `ACP_AGENT_PATH` (default `npx`), `ACP_AGENT_ARGS` (default
///   `--yes @agentclientprotocol/claude-agent-acp`) — the ACP agent spawn.
/// - `ANTHROPIC_API_KEY` / `ACP_API_KEY` — auth key. Without one, the test still
///   validates launch + `initialize` + the auth-decision gate (the agent
///   advertises `authMethods` → `ACPBackendError.missingAPIKey`).
/// - `ACP_SMOKE_PROMPT` (default `Reply with exactly: ACP_OK`).
@Suite(
    .timeLimit(.minutes(5)),
    .disabled(
        if: ProcessInfo.processInfo.environment["ACP_SMOKE"] == nil,
        "Set ACP_SMOKE=1 (and ANTHROPIC_API_KEY for a full turn) to run the live ACP smoke test.")
)
struct ACPSmokeTests {

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test func liveACPHandshakeAndTurn() async throws {
        let agentPath = env("ACP_AGENT_PATH") ?? "npx"
        let agentArgs = env("ACP_AGENT_ARGS") ?? "--yes @agentclientprotocol/claude-agent-acp"
        let apiKey = env("ANTHROPIC_API_KEY") ?? env("ACP_API_KEY")
        let prompt = env("ACP_SMOKE_PROMPT") ?? "Reply with exactly: ACP_OK"

        // The swift-acp SDK's launch() does NOT do PATH lookup — resolve a bare
        // command (e.g. "npx") to an absolute path via the login shell, mirroring
        // the launcher's preflight (so the default works without ACP_AGENT_PATH).
        let resolvedAgentPath: String
        switch PathPreflight.resolveOnLoginShell(executable: agentPath) {
        case .found(let path):
            resolvedAgentPath = path
        case .missing(let reason):
            print("[acp-smoke] agent executable '\(agentPath)' not found on login-shell PATH: \(reason)")
            Issue.record("ACP agent executable '\(agentPath)' not found: \(reason)")
            return
        }

        // A per-run scratch dir is the agent's cwd (mirrors the launcher).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var hints: [String: String] = [
            HintKey.acpAgentPath.rawValue: resolvedAgentPath,
            HintKey.acpAgentArgs.rawValue: agentArgs,
        ]
        if let apiKey { hints[HintKey.acpAgentApiKey.rawValue] = apiKey }

        let profile = BackendProfile(
            model: nil,
            providerHints: hints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: nil
        )
        let backend = ACPBackend(permissionPolicy: .bypass)

        // start() launches the agent, handshakes `initialize`, and applies the
        // auth decision. Without a key, an agent that advertises `authMethods`
        // (Claude does) throws `missingAPIKey` — which itself proves launch +
        // initialize + the auth-decision path worked live. With a key it
        // proceeds to `newSession`.
        let handle: SessionHandle
        do {
            handle = try await backend.start(
                profile: profile,
                systemPrompt: "You are a test agent.",
                onExit: { status in print("[acp-smoke] agent exited status=\(status)") }
            )
        } catch ACPBackendError.missingAPIKey {
            // Reached the auth gate: the agent launched + initialized + advertised
            // authMethods, and the resolver correctly demanded a key. That is the
            // live-handshake validation; a full turn needs ANTHROPIC_API_KEY.
            print("[acp-smoke] OK: reached auth gate (missingAPIKey) — launch + initialize + auth-decision verified live. Set ANTHROPIC_API_KEY for a full turn.")
            #expect(Bool(true), "ACP live handshake reached the auth gate (launch + initialize succeeded).")
            return
        }

        // Full turn: send + drain the streamed events, assert the turn boundary.
        print("[acp-smoke] session started; sending prompt: \(prompt)")
        var events: [AgentEvent] = []
        let stream = await backend.send(TurnInput(userText: prompt), into: handle)
        for await event in stream {
            events.append(event)
            print("[acp-smoke] event: \(event)")
        }
        print("[acp-smoke] turn complete: \(events.count) event(s)")
        #expect(events.last == .messageStop, "turn must end with .messageStop")
        #expect(events.contains { if case .assistantTextDelta = $0 { true } else { false } },
               "expected at least one assistantTextDelta")
        await backend.cancel(handle)
    }
}
