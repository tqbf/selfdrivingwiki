import Foundation
import WikiFSEngine
import Testing
import ACPModel
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Regression tests for issue #475: `AgentLauncher.run()` must not return
/// until the agent's turn stream completes. Previously, the stream loop was
/// spawned as a fire-and-forget `Task`, so `run()` returned immediately after
/// spawn — the queue marked the item `completed` while the agent was still
/// working, and a concurrent ingest's transcript landed on the wrong item.
///
/// These tests drive `run()` end-to-end with a `FakeAgentBackend` (injected
/// via `resolveBackend`), verifying:
/// 1. All events are consumed and forwarded to `onAgentEvent` before `run()` returns.
/// 2. `finish()` is called (gate released, `isRunning == false`) before `run()` returns.
/// 3. A second `run()` can proceed immediately after the first (no gate leak).
@MainActor
struct RunAwaitsTurnTests {

    // MARK: - Helpers

    private func makeLauncher(backend: any AgentBackend) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _ in backend }
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = {
            AgentProvider(
                id: "fake",
                label: "Fake",
                command: ["/usr/bin/true"],
                enabled: true,
                isDefault: true
            )
        }
        // Avoid touching the TCC-protected App Group container — use a
        // temp directory so provider config load/seed/save doesn't block.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        return launcher
    }

    private func makeRequest() -> OperationRequest {
        .ingest(
            sources: [OperationRequest.StagedSource(
                bytes: Data("# Test\n".utf8),
                ext: "md",
                displayPath: "sources/by-id/test.md"
            )],
            stateMarkdown: "# State"
        )
    }

    private func runOneShot(
        launcher: AgentLauncher,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async {
        await launcher.run(
            request: makeRequest(),
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onEvent: onEvent,
            onLock: {},
            onUnlock: {}
        )
    }

    // MARK: - Tests

    /// All events from the stream must be consumed and forwarded to the
    /// `onAgentEvent` callback before `run()` returns. Before the fix, `run()`
    /// returned immediately after spawn (fire-and-forget Task), so events
    /// arrived after the caller had already moved on — the caller would see
    /// zero events at the point `run()` returned.
    @Test func runForwardsAllEventsBeforeReturning() async throws {
        let testEvents: [AgentEvent] = [
            .assistantText("Step 1"),
            .assistantText("Step 2"),
            .assistantText("Step 3"),
            .messageStop,
        ]
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: testEvents)
        ])
        let launcher = makeLauncher(backend: backend)
        let collected = CollectedEvents()

        await runOneShot(launcher: launcher, onEvent: { event in
            collected.append(event)
        })

        // After run() returns, all 4 events should have been forwarded.
        // Before the fix, this was 0 because the stream Task hadn't run yet.
        let events = collected.snapshot
        #expect(events.count == 4)
        #expect(events.contains(.messageStop))

        // The launcher's own events array also has all 4.
        #expect(launcher.events.count == 4)
        #expect(launcher.isRunning == false)
    }

    /// After `run()` returns, `finish()` has been called: the gate is released
    /// and `isRunning` is false. Before the fix, `run()` returned while the
    /// agent was still streaming — `isRunning` was still true and the gate
    /// was still held.
    @Test func runCallsFinishBeforeReturning() async throws {
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.messageStop])
        ])
        let launcher = makeLauncher(backend: backend)

        await runOneShot(launcher: launcher)

        #expect(launcher.isRunning == false)
        #expect(launcher.generationSlotWaiterCount == 0)

        let sendCount = await backend.sendCount
        #expect(sendCount == 1)
    }

    /// After `run()` returns, a second `run()` can proceed immediately (no
    /// gate leak / deadlock). Before the fix, the gate was released only when
    /// `finish()` eventually fired from `onExit` — which could take minutes.
    @Test func secondRunProceedsWithoutDeadlock() async throws {
        let backend1 = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.messageStop])
        ])
        let launcher = makeLauncher(backend: backend1)

        await runOneShot(launcher: launcher)
        #expect(launcher.isRunning == false)

        // A second run with a fresh backend can acquire the gate immediately.
        let backend2 = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.messageStop])
        ])
        launcher.resolveBackend = { _ in backend2 }

        await runOneShot(launcher: launcher)
        #expect(launcher.isRunning == false)

        let sendCount = await backend2.sendCount
        #expect(sendCount == 1)
    }
}

// MARK: - CollectedEvents helper

/// A lock-protected array for collecting events from a `@Sendable` callback.
private final class CollectedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var snapshot: [AgentEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
