#if os(macOS)
import Testing
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// #830: Tests for ACP session resume in the chat lifecycle.
@MainActor
@Suite("ACP chat resume (#830)")
struct ACPChatResumeTests {

    /// Thread-safe box for the `onAcpSessionId` callback's values.
    private final class SessionIdRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String?] = []
        func record(_ value: String?) {
            lock.lock(); _values.append(value); lock.unlock()
        }
        var values: [String?] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dummy = dir.appendingPathComponent("fake-agent")
        let script = "#!/bin/sh\nexit 0\n"
        try script.write(to: dummy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dummy.path)
        return dir
    }

    private func makeLauncher(
        backend: FakeAgentBackend, dummyPath: String, tempDir: URL
    ) -> AgentLauncher {
        let provider = AgentProvider(
            id: "test-acp", label: "TestACP", command: [dummyPath],
            env: [:], enabled: true, isDefault: true)
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, _ in backend }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = { provider }
        let config = AgentProvidersConfig(
            providers: [provider],
            selectedModelIds: [provider.id: "fake-model"])
        try? config.save(to: tempDir)
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        return launcher
    }

    /// AC.7: when `priorAcpSessionId` is set and `resume()` returns a handle,
    /// `backend.start()` is NOT called (resume succeeded) and the first
    /// message sent is the raw user message (not the task prompt + preamble).
    @Test func continueChatResumesAndSkipsFreshStart() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dummyPath = tempDir.appendingPathComponent("fake-agent").path
        let backend = FakeAgentBackend(
            behaviors: [FakeSessionBehavior()], resumeSessionID: "resumed-1")
        let recorder = SessionIdRecorder()
        let launcher = makeLauncher(
            backend: backend, dummyPath: dummyPath, tempDir: tempDir)

        await launcher.startInteractiveQuery(
            firstMessage: "preamble text",
            firstMessageDisplay: "user question",
            stateMarkdown: "",
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "",
            wikictlDirectory: "/tmp",
            chatID: "chat-1",
            priorAcpSessionId: "prior-session-id",
            onAcpSessionId: { recorder.record($0) },
            onLock: {},
            onUnlock: {}
        )

        #expect(launcher.preflightError == nil)
        let resumedIDs = await backend.resumedSessionIDs
        #expect(resumedIDs == ["prior-session-id"])
        let startCount = await backend.startCount
        #expect(startCount == 0)
        let sentTexts = try await waitForSendCount(atLeast: 1, on: backend)
        #expect(sentTexts.count == 1)
        #expect(sentTexts[0] == "user question")
    }

    /// AC.8: when `priorAcpSessionId` is set and `resume()` returns nil,
    /// `backend.start()` IS called (fresh start fallback) and the stale
    /// session ID is cleared via `onAcpSessionId?(nil)`.
    @Test func continueChatFallsBackToFreshStartOnResumeFailure() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dummyPath = tempDir.appendingPathComponent("fake-agent").path
        let backend = FakeAgentBackend(behaviors: [FakeSessionBehavior()])
        let recorder = SessionIdRecorder()
        let launcher = makeLauncher(
            backend: backend, dummyPath: dummyPath, tempDir: tempDir)

        await launcher.startInteractiveQuery(
            firstMessage: "preamble text",
            firstMessageDisplay: "user question",
            stateMarkdown: "",
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "",
            wikictlDirectory: "/tmp",
            chatID: "chat-1",
            priorAcpSessionId: "prior-session-id",
            onAcpSessionId: { recorder.record($0) },
            onLock: {},
            onUnlock: {}
        )

        #expect(launcher.preflightError == nil)
        let resumedIDs = await backend.resumedSessionIDs
        #expect(resumedIDs == ["prior-session-id"])
        let startCount = await backend.startCount
        #expect(startCount == 1)
        let sentTexts = try await waitForSendCount(atLeast: 1, on: backend)
        #expect(sentTexts.count >= 1)
        #expect(sentTexts[0].contains("preamble text") == true)
        #expect(sentTexts[0] != "user question")
        #expect(recorder.values.contains(nil) == true)
    }

    /// AC.8b: when `priorAcpSessionId` is nil (a new chat or pre-#830 chat),
    /// no resume attempt is made and `backend.start()` runs normally.
    @Test func startChatWithoutPriorSessionDoesNotAttemptResume() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dummyPath = tempDir.appendingPathComponent("fake-agent").path
        let backend = FakeAgentBackend(behaviors: [FakeSessionBehavior()])
        let recorder = SessionIdRecorder()
        let launcher = makeLauncher(
            backend: backend, dummyPath: dummyPath, tempDir: tempDir)

        await launcher.startInteractiveQuery(
            firstMessage: "hello world",
            stateMarkdown: "",
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "",
            wikictlDirectory: "/tmp",
            chatID: "chat-1",
            onAcpSessionId: { recorder.record($0) },
            onLock: {},
            onUnlock: {}
        )

        #expect(launcher.preflightError == nil)
        let resumedIDs = await backend.resumedSessionIDs
        #expect(resumedIDs.isEmpty)
        let startCount = await backend.startCount
        #expect(startCount == 1)
        #expect(recorder.values.filter { $0 == nil }.isEmpty)
    }

    private func waitForSendCount(
        atLeast min: Int, on backend: FakeAgentBackend, timeoutMs: Int = 5000
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            let count = await backend.sendCount
            if count >= min {
                return await backend.sentTexts
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await backend.sentTexts
    }
}
#endif
