import Testing
import Foundation
import WikiFSEngine
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// #609 wiring pin: the launcher routes the right `turnCeilingTimeout` to the
/// `ACPBackend` per operation kind, via `TurnLivenessPolicy.ceiling(for:)`:
/// - `.ingest` (one-shot + `runACPIngestPlannerExecutors`) and `.lint` runs —
///   the 600s queued-ingestion ceiling.
/// - `.chat` (interactive `startInteractiveQuery`) — the 1800s interactive
///   default.
///
/// These tests drive the actual `run()` / `startInteractiveQuery()` call sites
/// (NOT just `TurnLivenessPolicy.ceiling(for:)` in isolation), so a future
/// refactor that swaps the launcher's `ceiling(for:)` call to a hardcoded
/// `defaultCeilingTimeout` would fail here — the per-kind wiring is the
/// contract the issue asks for ("ceiling used by `runACPIngestPlannerExecutors`
/// is the queued-ingestion value (600s), and the interactive path keeps using
/// 1800s").
///
/// The tests early-return at `resolveACPProviderSpawn` because the test
/// provider has `command = nil` (after `resolveBackend` is called) — so the
/// captured ceiling is observable WITHOUT spawning a real subprocess.
@MainActor
@Suite("AgentLauncher ceiling wiring (#609)")
struct AgentLauncherCeilingWiringTests {

    /// Thread-safe box for the LAST `turnCeilingTimeout` value the launcher
    /// passed to `resolveBackend`. `@unchecked Sendable` so the `@Sendable`
    /// closure body (run on the main actor) can write into it.
    private final class CapturedCeiling: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: TimeInterval?
        func record(_ ceiling: TimeInterval) {
            lock.lock(); _value = ceiling; lock.unlock()
        }
        var value: TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _value == nil ? 0 : 1
        }
    }

    /// A provider with `command = nil` so `resolveACPProviderSpawn` returns nil
    /// (early-return AFTER `resolveBackend` was called). The provider's
    /// `selectedModelId` is pre-seeded in the test config so the chat path's
    /// `SpawnModelGuard.validate` (which fires before `resolveBackend`) passes.
    private let noCommandProvider = AgentProvider(
        id: "fake-no-cmd",
        label: "FakeNoCommand",
        command: nil,
        env: [:],
        enabled: true,
        isDefault: true
    )

    /// Build a launcher wired so `resolveBackend` records the ceiling it was
    /// called with, and `run()` / `startInteractiveQuery()` early-return at
    /// `resolveACPProviderSpawn` (no spawn attempted). The fake-acp provider
    /// has a model selected (`fake-model`) so the chat path's
    /// `SpawnModelGuard` lets the run reach `resolveBackend`.
    private func makeLauncher(captured: CapturedCeiling, tempDir: URL) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, ceiling in
            captured.record(ceiling)
            return FakeAgentBackend()
        }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = { noCommandProvider }
        let config = AgentProvidersConfig(
            providers: [noCommandProvider],
            selectedModelIds: [noCommandProvider.id: "fake-model"])
        do {
            try config.save(to: tempDir)
        } catch {
            Issue.record("Failed to save provider config to temp dir: \(error)")
        }
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        return launcher
    }

    /// The ingest path (`run(.ingest(...))`) routes to `runACPIngestPlannerExecutors`
    /// for large sources AND stays on the single-session path for small ones —
    /// both reuse the backend `run()` constructed with `permissionKind = .ingest`.
    /// That kind feeds `TurnLivenessPolicy.ceiling(for:)` → the 600s
    /// queued-ingestion ceiling. Pinned: a single stalled ingest turn burns 10
    /// minutes, not 30 (issue #609 symptom on 2026-07-18).
    @Test func ingestPathPassesQueuedCeiling() async throws {
        let captured = CapturedCeiling()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceiling-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeLauncher(captured: captured, tempDir: tempDir)

        await launcher.run(
            request: .ingest(
                sources: [OperationRequest.StagedSource(
                    bytes: Data("# Test\n".utf8),
                    ext: "md",
                    displayPath: "sources/by-id/test.md",
                    name: "Test Source",
                    sourceID: "01TEST01KQ8HDDR3ZXK72XHG6R"
                )],
                stateMarkdown: "# State"),
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onLock: {},
            onUnlock: {}
        )

        // The launcher called `resolveBackend` exactly once (at run() :964).
        #expect(captured.callCount == 1)
        // It passed the queued-ingestion ceiling (600s), NOT the interactive
        // 1800s default — exactly the wiring #609 prescribes for the path
        // `runACPIngestPlannerExecutors` runs under.
        #expect(captured.value == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(captured.value == 600)
    }

    /// The lint path is the other unattended pipeline kind — it shares the
    /// same `.ingest` permission-kind routing for the budget, and the ceiling
    /// splits identically: `.lint` → 600s, NOT 1800s. Pinned so a future
    /// refactor can't accidentally widen the lint ceiling back to interactive.
    @Test func lintPathPassesQueuedCeiling() async throws {
        let captured = CapturedCeiling()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceiling-lint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeLauncher(captured: captured, tempDir: tempDir)

        await launcher.run(
            request: .lint(stateMarkdown: "# State"),
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onLock: {},
            onUnlock: {}
        )

        #expect(captured.callCount == 1)
        #expect(captured.value == TurnLivenessPolicy.queuedIngestCeiling)
        #expect(captured.value == 600)
    }

    /// The interactive chat path (`startInteractiveQuery`) routes the 1800s
    /// interactive default — long reasoning chains are legitimate in a
    /// user-attended session, and the UI chip is the release valve. This is
    /// the "interactive path keeps using 1800s" half of the #609 verification.
    @Test func interactivePathPassesInteractiveCeiling() async throws {
        let captured = CapturedCeiling()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceiling-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeLauncher(captured: captured, tempDir: tempDir)

        await launcher.startInteractiveQuery(
            firstMessage: "hello",
            stateMarkdown: "",
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "",
            wikictlDirectory: "/tmp",
            onLock: {},
            onUnlock: {}
        )

        // The chat path's `resolveBackend` is at `startInteractiveQuery` :2188,
        // AFTER `SpawnModelGuard.validate` (passes because fake-model is
        // pre-seeded) and BEFORE `resolveACPProviderSpawn` (returns nil — no
        // command, early return). So the ceiling is observable WITHOUT a
        // real subprocess.
        #expect(captured.callCount == 1)
        #expect(captured.value == TurnLivenessPolicy.defaultCeilingTimeout)
        #expect(captured.value == 1800)
    }
}
