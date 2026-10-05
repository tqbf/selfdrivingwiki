#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFSCore

/// #1364: end-to-end pin that `ACPBackend.send`'s watchdog actually reads
/// the fanout's activity timestamp and fires the idle-stall recovery.
///
/// Nothing else exercises that branch against a real backend:
/// `TurnLivenessPolicy` is unit-tested pure, the config-threading tests pin
/// the constructor values, and `FakeAgentBackend` replaces `send` entirely —
/// swapping the watchdog's `fanout.activityTimestamp` read (ACPBackend.send)
/// for `Date()` would pass every other test. This suite drives the REAL
/// `ACPBackend` against a fake ACP agent subprocess that completes the
/// handshake (`initialize`, `session/new`) and then goes SILENT on
/// `session/prompt`: alive, never responding, never notifying — exactly the
/// #1364 incident shape. With tiny injected poll/idle bounds the watchdog
/// must fail the turn as `.turnFailed(.stalled(idleSeconds:))` followed by
/// `.messageStop`.
///
/// No production seam is needed: the agent is a plain python3 script
/// speaking the SDK's newline-delimited JSON-RPC over stdio. Per the repo's
/// non-blocking test rules (#1051) the stream consumption is raced against a
/// timeout (never a bare continuation), and the suite is serialized with a
/// time limit because it spawns a subprocess.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ACPIdleStallWatchdogTests {

    /// Named fixture values — no bare literals at use sites.
    private enum Fixture {
        /// Watchdog poll interval small enough that the stall is detected
        /// within a couple of polls.
        static let pollInterval: TimeInterval = 0.2
        /// Idle bound small enough to trip while the fake agent idles
        /// silently after the handshake.
        static let idleStallTimeout: TimeInterval = 0.3
        /// Generous wall budget for subprocess spawn + handshake + a few
        /// polls before the consumer race fails the test fast (a watchdog
        /// regression must not hang the suite).
        static let consumerTimeout: Duration = .seconds(10)
        /// The macOS system python. Always present where these tests can
        /// run: building the package requires Command Line Tools, which
        /// provide this binary.
        static let pythonPath = "/usr/bin/python3"
        /// Placeholder session id the fake agent returns from `session/new`.
        static let fakeSessionID = "fake-idle-stall-session"
    }

    /// The error the consumer race throws when the watchdog fails to fire —
    /// a fast, diagnosed failure instead of an infinite hang (#1051).
    private struct ConsumerTimeout: Error {}

    /// Writes the fake ACP agent script and returns its URL. The agent:
    /// responds to `initialize` (no authMethods → the backend skips
    /// authenticate) and `session/new`, then on `session/prompt` parks
    /// forever — alive and silent, emitting no `session/update`, so the
    /// fanout's activity timestamp stays frozen at process start.
    private func writeFakeAgentScript(to dir: URL) throws -> URL {
        let script = """
        import json
        import sys
        import time

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                respond(message.get("id"), {"protocolVersion": 1, "agentCapabilities": {}})
            elif method == "session/new":
                respond(message.get("id"), {"sessionId": "\(Fixture.fakeSessionID)"})
            elif method == "session/prompt":
                # The stall (issue #1364): read the prompt, never respond,
                # never notify, stay alive. Notification silence is the only
                # remaining failure signal.
                while True:
                    time.sleep(60)
            # Anything else (client notifications, session/cancel): ignore.
        """
        let url = dir.appendingPathComponent("fake-idle-stall-agent.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Consumes the turn stream until `.messageStop` or the timeout wins.
    /// The race follows the repo's non-blocking pattern: the sleeper throws,
    /// so a wedged watchdog produces a fast failure, and `cancelAll` tears
    /// down the loser.
    private func collectUntilTurnEnd(_ stream: AsyncStream<AgentEvent>) async throws -> [AgentEvent] {
        try await withThrowingTaskGroup(of: [AgentEvent].self) { group in
            group.addTask {
                var events: [AgentEvent] = []
                for await event in stream {
                    events.append(event)
                    if event == .messageStop { break }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: Fixture.consumerTimeout)
                throw ConsumerTimeout()
            }
            guard let first = try await group.next() else {
                throw ConsumerTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    @Test("silent fanout trips the idle-stall watchdog and fails the turn (#1364)")
    func silentFanoutTripsIdleStallWatchdog() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-idle-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = try writeFakeAgentScript(to: dir)

        // Tiny injected bounds + the default 1800s ceiling: the idle bound
        // must win long before the ceiling could.
        let backend = ACPBackend(
            idleStallTimeout: Fixture.idleStallTimeout,
            watchdogPollInterval: Fixture.pollInterval)

        let profile = BackendProfile(
            model: nil,
            providerHints: [
                HintKey.acpAgentPath.rawValue: Fixture.pythonPath,
                HintKey.acpAgentArgs.rawValue: scriptURL.path,
            ],
            scratchDirectory: dir,
            isReadOnly: false,
            cli: nil)

        // launch → initialize → (skip auth) → session/new — the fake agent
        // answers both handshake requests.
        let handle = try await backend.start(
            profile: profile,
            systemPrompt: "",
            onExit: { _ in })

        let stream = await backend.send(
            TurnInput(userText: "reply with anything"), into: handle)
        let collected = try await collectUntilTurnEnd(stream)

        // Teardown BEFORE assertions: kill the (still parked) fake agent so
        // no process outlives the test regardless of the asserts below.
        await backend.cancel(handle)

        // The turn must end with the synthesized stall tail: exactly
        // `.turnFailed(.stalled(idleSeconds:))` followed by `.messageStop`.
        #expect(collected.count == 2,
                "expected exactly the synthesized stall tail, got \(collected)")
        guard collected.count == 2 else { return }
        #expect(collected.last == .messageStop)
        if case .turnFailed(.stalled(let idleSeconds)) = collected.first {
            // The reported idle is measured from the fanout's frozen
            // activity timestamp, so it must be at least the configured
            // bound (that is the predicate that fired).
            #expect(idleSeconds >= Fixture.idleStallTimeout,
                    "idle \(idleSeconds)s is below the configured bound")
        } else {
            Issue.record("expected .turnFailed(.stalled) first, got \(collected.first)")
        }
    }
}
#endif
