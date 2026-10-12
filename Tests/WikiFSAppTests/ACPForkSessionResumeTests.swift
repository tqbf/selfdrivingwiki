#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFSCore

/// Pins that `ACPBackend.forkSession` makes the forked session live before
/// the first prompt. claude-agent-acp 0.88.0 answers `session/fork` with a
/// new id but holds no live session for it, so a prompt sent straight to
/// that id fails with "Session not found" — the ingest executor then wrote
/// no pages. The fake agent here copies that shape: a forked id becomes
/// promptable only after `session/resume`.
///
/// The agent is a plain python3 script that speaks the SDK's
/// newline-delimited JSON-RPC over stdio (see `ACPIdleStallWatchdogTests`).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ACPForkSessionResumeTests {

    private enum Fixture {
        /// Wall budget for spawn + handshake + one turn before the consumer
        /// race fails the test fast (#1051).
        static let consumerTimeout: Duration = .seconds(10)
        /// The macOS system python (shipped with Command Line Tools).
        static let pythonPath = "/usr/bin/python3"
        static let parentSessionID = "fake-parent-session"
        static let forkedSessionID = "fake-forked-session"
        /// Agent argument that makes `session/resume` fail.
        static let failResumeFlag = "--fail-resume"
    }

    private struct ConsumerTimeout: Error {}

    /// Writes the fake agent. It advertises fork + resume, returns a forked
    /// id from `session/fork` without holding it live, and answers
    /// `session/prompt` with "Session not found" for any id that is not live.
    private func writeFakeAgentScript(to dir: URL) throws -> URL {
        let script = """
        import json
        import sys

        fail_resume = "\(Fixture.failResumeFlag)" in sys.argv
        live = set()

        def send(payload):
            print(json.dumps(dict(jsonrpc="2.0", **payload)), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            params = message.get("params") or {}
            if request_id is None:
                continue  # client notification (e.g. session/cancel)
            if method == "initialize":
                send({"id": request_id, "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {"sessionCapabilities": {"fork": {}, "resume": {}}}}})
            elif method == "session/new":
                live.add("\(Fixture.parentSessionID)")
                send({"id": request_id, "result": {"sessionId": "\(Fixture.parentSessionID)"}})
            elif method == "session/fork":
                send({"id": request_id, "result": {"sessionId": "\(Fixture.forkedSessionID)"}})
            elif method == "session/resume":
                if fail_resume:
                    send({"id": request_id, "error": {"code": -32603, "message": "Resume failed"}})
                else:
                    live.add(params.get("sessionId"))
                    send({"id": request_id, "result": {}})
            elif method == "session/prompt":
                if params.get("sessionId") in live:
                    send({"id": request_id, "result": {"stopReason": "end_turn"}})
                else:
                    send({"id": request_id, "error": {"code": -32603, "message": "Session not found"}})
            else:
                send({"id": request_id, "result": {}})
        """
        let url = dir.appendingPathComponent("fake-fork-agent.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeBackendAndParent(
        dir: URL,
        extraArgs: [String] = []
    ) async throws -> (ACPBackend, SessionHandle) {
        let scriptURL = try writeFakeAgentScript(to: dir)
        let backend = ACPBackend()
        let args = ([scriptURL.path] + extraArgs).joined(separator: " ")
        let profile = BackendProfile(
            model: nil,
            providerHints: [
                HintKey.acpAgentPath.rawValue: Fixture.pythonPath,
                HintKey.acpAgentArgs.rawValue: args,
            ],
            scratchDirectory: dir,
            isReadOnly: false,
            cli: nil)
        let parent = try await backend.start(profile: profile, systemPrompt: "", onExit: { _ in })
        return (backend, parent)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Consumes the turn stream until `.messageStop` or the timeout wins.
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

    @Test("a forked session is resumed so its first prompt succeeds")
    func forkedSessionIsResumedBeforePrompt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backend, parent) = try await makeBackendAndParent(dir: dir)

        let forked = try await backend.forkSession(from: parent, cwd: dir.path)
        let handle = try #require(forked)
        let stream = await backend.send(TurnInput(userText: "write the pages"), into: handle)
        let collected = try await collectUntilTurnEnd(stream)

        await backend.cancel(parent)

        #expect(collected.last == .messageStop)
        let failures = collected.filter {
            if case .turnFailed = $0 { return true }
            return false
        }
        #expect(failures.isEmpty, "forked prompt failed: \(collected)")
    }

    @Test("a failed resume of the forked session throws so the caller starts fresh")
    func failedResumeThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (backend, parent) = try await makeBackendAndParent(
            dir: dir, extraArgs: [Fixture.failResumeFlag])

        await #expect(throws: (any Error).self) {
            _ = try await backend.forkSession(from: parent, cwd: dir.path)
        }

        await backend.cancel(parent)
    }
}
#endif
