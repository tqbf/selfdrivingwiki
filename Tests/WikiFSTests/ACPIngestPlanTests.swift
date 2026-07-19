import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
import ACPModel
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for the multi-phase ACP ingestion plan schema, tolerant JSON
/// extraction, and prompt builders.
///
/// The multi-session orchestration itself (`runACPIngestPlannerExecutors`) is
/// integration-level — it requires a live ACP agent or a fully-wired
/// `AgentLauncher` with generation gate + edit lock. The `FakeAgentBackend`
/// infrastructure is provided for future integration tests that drive the
/// launcher end-to-end.
@Suite struct ACPIngestPlanTests {

    // MARK: - Plan schema (AC.2)

    @Test func testPlanDecodeRoundTrip() {
        let plan = ACPIngestPlan(
            pages: [
                ACPIngestPageAssignment(
                    title: "Photosynthesis",
                    sourceFile: "source-1.md",
                    sourceRanges: "lines 1-80",
                    outline: "Overview of photosynthesis."),
                ACPIngestPageAssignment(
                    title: "Calvin Cycle",
                    sourceFile: "source-1.md",
                    sourceRanges: "lines 81-120",
                    outline: "Carbon fixation pathway."),
            ],
            sourceIDs: ["01J5ABC", "01J5DEF"])

        let encoder = JSONEncoder()
        let data = try! encoder.encode(plan)

        let decoder = JSONDecoder()
        let decoded = try! decoder.decode(ACPIngestPlan.self, from: data)

        #expect(decoded == plan)
        #expect(decoded.pages.count == 2)
        #expect(decoded.sourceIDs == ["01J5ABC", "01J5DEF"])
    }

    @Test func testAssignmentsForSource() {
        let plan = ACPIngestPlan(
            pages: [
                ACPIngestPageAssignment(title: "A", sourceFile: "source-1.md", sourceRanges: "1-10", outline: "a"),
                ACPIngestPageAssignment(title: "B", sourceFile: "source-2.md", sourceRanges: "1-10", outline: "b"),
                ACPIngestPageAssignment(title: "C", sourceFile: "source-1.md", sourceRanges: "11-20", outline: "c"),
            ],
            sourceIDs: ["id1", "id2"])

        let source1 = plan.assignments(forSource: "source-1.md")
        #expect(source1.count == 2)
        #expect(source1.map(\.title) == ["A", "C"])

        let source2 = plan.assignments(forSource: "source-2.md")
        #expect(source2.count == 1)
        #expect(source2.first?.title == "B")

        #expect(plan.assignments(forSource: "source-3.md").isEmpty)
    }

    @Test func testDistinctSourceFiles() {
        let plan = ACPIngestPlan(
            pages: [
                ACPIngestPageAssignment(title: "A", sourceFile: "source-1.md", sourceRanges: "", outline: ""),
                ACPIngestPageAssignment(title: "B", sourceFile: "source-2.md", sourceRanges: "", outline: ""),
                ACPIngestPageAssignment(title: "C", sourceFile: "source-1.md", sourceRanges: "", outline: ""),
            ],
            sourceIDs: [])

        // First-occurrence order, no duplicates.
        #expect(plan.distinctSourceFiles == ["source-1.md", "source-2.md"])
    }

    @Test func testAllPageTitles() {
        let plan = ACPIngestPlan(
            pages: [
                ACPIngestPageAssignment(title: "Alpha", sourceFile: "s1.md", sourceRanges: "", outline: ""),
                ACPIngestPageAssignment(title: "Beta", sourceFile: "s1.md", sourceRanges: "", outline: ""),
            ],
            sourceIDs: [])

        #expect(plan.allPageTitles == ["Alpha", "Beta"])
    }

    // MARK: - Tolerant JSON extraction (AC.2)

    @Test func testTolerantJSONExtractionClean() {
        let raw = """
        {"pages":[{"title":"Test","sourceFile":"s.md","sourceRanges":"1-10","outline":"desc"}],"sourceIDs":["id1"]}
        """
        let plan = ACPIngestPlan.extract(from: raw)
        #expect(plan != nil)
        #expect(plan?.pages.count == 1)
        #expect(plan?.pages.first?.title == "Test")
        #expect(plan?.sourceIDs == ["id1"])
    }

    @Test func testTolerantJSONExtractionFenced() {
        let raw = """
        Here is my plan:

        ```json
        {"pages":[{"title":"Fenced","sourceFile":"s.md","sourceRanges":"1-5","outline":"x"}],"sourceIDs":["a"]}
        ```

        That's it.
        """
        let plan = ACPIngestPlan.extract(from: raw)
        #expect(plan != nil)
        #expect(plan?.pages.first?.title == "Fenced")
    }

    @Test func testTolerantJSONExtractionProseWrapped() {
        let raw = """
        I analyzed the sources and here is the plan:

        {"pages":[{"title":"Prose","sourceFile":"s.md","sourceRanges":"entire","outline":"y"}],"sourceIDs":["b"]}

        The above plan covers all content.
        """
        let plan = ACPIngestPlan.extract(from: raw)
        #expect(plan != nil)
        #expect(plan?.pages.first?.title == "Prose")
    }

    @Test func testTolerantJSONExtractionInvalid() {
        #expect(ACPIngestPlan.extract(from: "") == nil)
        #expect(ACPIngestPlan.extract(from: "no json here at all") == nil)
        #expect(ACPIngestPlan.extract(from: "```json\nnot valid json\n```") == nil)
        #expect(ACPIngestPlan.extract(from: "{ broken json }") == nil)
    }

    @Test func testTolerantJSONExtractionFromData() {
        let raw = #"{"pages":[],"sourceIDs":[]}"#
        let data = raw.data(using: .utf8)!
        let plan = ACPIngestPlan.extract(from: data)
        #expect(plan != nil)
        #expect(plan?.pages.isEmpty == true)
    }

    @Test func testLoadFromDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let plan = ACPIngestPlan(
            pages: [ACPIngestPageAssignment(title: "X", sourceFile: "s.md", sourceRanges: "1", outline: "x")],
            sourceIDs: ["id1"])
        let data = try JSONEncoder().encode(plan)
        try data.write(to: tmpDir.appendingPathComponent("plan.json"))

        let loaded = ACPIngestPlan.load(from: tmpDir)
        #expect(loaded != nil)
        #expect(loaded?.pages.first?.title == "X")
    }

    @Test func testLoadFromDirectoryMissing() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(ACPIngestPlan.load(from: tmpDir) == nil)
    }

    // MARK: - Prompt builders

    @Test func testPlannerPromptFillsPlaceholders() {
        let prompt = ACPIngestPrompts.plannerPrompt(
            stateFilePath: "/tmp/WIKI_STATE.md",
            stagedSourcePaths: ["/tmp/scratch/source-1.md", "/tmp/scratch/source-2.md"],
            sourceIDs: ["01ABC", "01DEF"])

        #expect(prompt.contains("/tmp/WIKI_STATE.md"))
        #expect(prompt.contains("source-1.md"))
        #expect(prompt.contains("source-2.md"))
        #expect(prompt.contains("01ABC"))
        #expect(prompt.contains("01DEF"))
        #expect(prompt.contains("plan.json"))
    }

    @Test func testExecutorPromptFillsPlaceholders() {
        let assignments = [
            ACPIngestPageAssignment(title: "Alpha", sourceFile: "source-1.md", sourceRanges: "lines 1-50", outline: "Overview of alpha."),
            ACPIngestPageAssignment(title: "Beta", sourceFile: "source-1.md", sourceRanges: "lines 51-100", outline: "Details of beta."),
        ]
        let prompt = ACPIngestPrompts.executorPrompt(
            stateFilePath: "/tmp/state.md",
            assignments: assignments,
            allPageTitles: ["Alpha", "Beta", "Gamma"],
            sourceIDs: ["id1"])

        #expect(prompt.contains("Alpha"))
        #expect(prompt.contains("Beta"))
        #expect(prompt.contains("lines 1-50"))
        #expect(prompt.contains("lines 51-100"))
        #expect(prompt.contains("Gamma"))  // cross-link reference
        #expect(prompt.contains("source-1.md"))
    }

    @Test func testFinalizerPromptFillsPlaceholders() {
        let prompt = ACPIngestPrompts.finalizerPrompt(
            stateFilePath: "/tmp/state.md",
            sourceFileNames: ["source-1.md", "source-2.md"],
            sourceIDs: ["id1", "id2"])

        #expect(prompt.contains("source-1.md"))
        #expect(prompt.contains("source-2.md"))
        #expect(prompt.contains("id1"))
        #expect(prompt.contains("id2"))
        #expect(prompt.contains("index set"))
        #expect(prompt.contains("log append"))
    }

    // MARK: - Provider hints (Phase 2, plans/acp-multi-provider.md —
    // #604 removed the per-stage routing previously exercised here; the
    // providerHints threading tests below pin the still-relevant model-id
    // propagation from `AgentProvidersConfig.selectedModelId(forProvider:)`
    // into `ACPBackend.start`.)

    @Test func testProviderHintsIncludesProviderEnv() {
        let provider = AgentProvider(
            id: "hermes", label: "Hermes", command: ["hermes", "acp"],
            env: ["ZAI_API_KEY": "secretish", "HERMES_MODE": "fast"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/hermes", "acp"],
            apiKey: nil,
            selectedModelId: nil)
        #expect(hints[HintKey.env("ZAI_API_KEY")] == "secretish")
        #expect(hints[HintKey.env("HERMES_MODE")] == "fast")
    }

    /// The resolved model id (`selectedModelId(forProvider:)`) is threaded
    /// into `acpSelectedModelId`, which `ACPBackend.start` reads to call
    /// `session/set_model`. Pins the model-threading half of the providerHints
    /// construction (post-#604: planner/executor/finalizer all share this one
    /// resolution at the top of `runACPIngestPlannerExecutors`).
    @Test func testProviderHintsThreadsSelectedModelId() {
        let provider = AgentProvider(id: "opencode", label: "OpenCode", command: ["opencode", "acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/opencode", "acp"],
            apiKey: nil,
            selectedModelId: "anthropic/claude-sonnet")
        #expect(hints[HintKey.acpSelectedModelId.rawValue] == "anthropic/claude-sonnet")
    }

    // MARK: - FakeAgentBackend recording

    @Test func testFakeBackendRecordsCalls() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let planData = try JSONEncoder().encode(ACPIngestPlan(
            pages: [ACPIngestPageAssignment(title: "Test", sourceFile: "source-1.md", sourceRanges: "1-10", outline: "x")],
            sourceIDs: ["id1"]))

        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: [.assistantText("Planning..."), .messageStop], planJSON: planData),
            FakeSessionBehavior(events: [.toolUse(name: "Bash", inputSummary: "wikictl page upsert"), .messageStop]),
            FakeSessionBehavior(events: [.toolUse(name: "Bash", inputSummary: "wikictl index set"), .messageStop]),
        ])

        let profile = BackendProfile(scratchDirectory: scratch)

        // Simulate 3 phases: planner → executor → finalizer.
        let session1 = try await fake.start(profile: profile, systemPrompt: "sys") { _ in }
        _ = await fake.send(TurnInput(userText: "planner prompt"), into: session1)
        await fake.cancel(session1)

        let session2 = try await fake.start(profile: profile, systemPrompt: "sys") { _ in }
        _ = await fake.send(TurnInput(userText: "executor prompt"), into: session2)
        await fake.cancel(session2)

        let session3 = try await fake.start(profile: profile, systemPrompt: "sys") { _ in }
        _ = await fake.send(TurnInput(userText: "finalizer prompt"), into: session3)
        await fake.cancel(session3)

        // Assert the recording matches the expected sequence.
        let startCount = await fake.startCount
        let sendCount = await fake.sendCount
        let cancelCount = await fake.cancelCount
        #expect(startCount == 3)
        #expect(sendCount == 3)
        #expect(cancelCount == 3)

        let texts = await fake.sentTexts
        #expect(texts == ["planner prompt", "executor prompt", "finalizer prompt"])

        // plan.json was written by session 1.
        let plan = ACPIngestPlan.load(from: scratch)
        #expect(plan != nil)
        #expect(plan?.pages.first?.title == "Test")

        // Events were recorded.
        let events = await fake.allYieldedEvents
        #expect(events.count == 6) // 2 per session
    }

    @Test func testFakeBackendFailureOnStart() async {
        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(shouldFailOnStart: true),
        ])

        let profile = BackendProfile()
        do {
            _ = try await fake.start(profile: profile, systemPrompt: "") { _ in }
            #expect(Bool(false), "Should have thrown")
        } catch {
            // Expected
        }

        let startCount = await fake.startCount
        #expect(startCount == 1) // start was attempted (recorded before throw)
    }

    @Test func testFakeBackendDefaultBehaviorWhenEmpty() async throws {
        let fake = FakeAgentBackend(behaviors: [])

        let session = try await fake.start(profile: BackendProfile(), systemPrompt: "") { _ in }
        let stream = await fake.send(TurnInput(userText: "test"), into: session)
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
        }
        #expect(events == [.messageStop])
    }

    @Test func testFakeBackendRecordsModelHints() async throws {
        let fake = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(),
            FakeSessionBehavior(),
        ])

        let hints1 = BackendProfile(providerHints: [HintKey.acpSelectedModelId.rawValue: "opus-4"])
        _ = try await fake.start(profile: hints1, systemPrompt: "") { _ in }

        let hints2 = BackendProfile(providerHints: [HintKey.acpSelectedModelId.rawValue: "sonnet-4"])
        _ = try await fake.start(profile: hints2, systemPrompt: "") { _ in }

        let recorded = await fake.startModelHints
        #expect(recorded == ["opus-4", "sonnet-4"])
    }
}

/// #604 launcher-level pin: per-stage routing is gone, so the multi-phase
/// ingest path (`runACPIngestPlannerExecutors`) must resolve ONE backend at
/// the top (in `run()` prior to delegating) and reuse it across all three
/// phases (planner → executors → finalizer) — never construct a backend
/// per-stage, never call `resolveBackend` again after `run()` set
/// `self.backend`. Drives `launcher.run(...)` end-to-end with a
/// `FakeAgentBackend` + a large (>4 KB) source so `plan.isLargeSource`
/// routes to the multi-phase path.
///
/// **Fork-from-planner is NOT pinned here** — `FakeAgentBackend` is not an
/// `ACPBackend` (the fork optimization downcasts via
/// `backend as? ACPBackend`), so each executor phase falls back to a fresh
/// `backend.start()` on the SAME backend instance. That is the desired
/// contract post-#604: the backend instance is reused across phases (no
/// per-stage construction), even when fork is unsupported by the test double.
/// A live ACP run would use the planner's session handle as the fork source
/// on the same `self.backend` instance.
@MainActor
@Suite("ACPIngest collapsed routing (#604)")
struct ACPIngestCollapsedRoutingTests {

    /// A counter that tracks how many times `resolveBackend` was invoked.
    /// Used to pin the #604 collapse: a single call means no per-stage
    /// re-resolution. Final class + lock so the @Sendable closure can
    /// increment from any actor.
    private final class ResolveBackendCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() {
            lock.lock(); _count += 1; lock.unlock()
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }

    /// Build a launcher wired for an end-to-end multi-phase ingest on a
    /// `FakeAgentBackend`. The provider (`fake-acp`) has a model selected
    /// (`fake-model`) so `SpawnModelGuard` lets the run proceed.
    ///
    /// `tempDir` is created by the caller and lives for the test's duration
    /// (the caller defers its removal) so `providersConfig()` reads inside
    /// `run()` see the saved file. A `defer` here would wipe it before
    /// `run()` runs.
    private func makeLauncher(
        backend: FakeAgentBackend,
        counter: ResolveBackendCallCounter,
        tempDir: URL
    ) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _ in
            counter.increment()
            return backend
        }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.resolveSelectedProvider = {
            AgentProvider(
                id: "fake-acp",
                label: "Fake",
                command: ["/usr/bin/true"],
                env: [:],
                enabled: true,
                isDefault: true
            )
        }
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "fake-acp", label: "Fake",
                              command: ["/usr/bin/true"], enabled: true, isDefault: true)
            ],
            selectedModelIds: ["fake-acp": "fake-model"])
        do {
            try config.save(to: tempDir)
        } catch {
            // Per house rules — never bare try?. Rare save failure on a temp
            // dir would mask the test wiring; surface it here.
            Issue.record("Failed to save provider config to temp dir: \(error)")
        }
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        return launcher
    }

    /// A source larger than `IngestPlan.tinySourceByteThreshold` (4 KB) so
    /// `plan.isLargeSource == true` and `run()` delegates to the multi-phase
    /// path at `AgentLauncher.swift:1022`.
    private func largeSource() -> OperationRequest.StagedSource {
        let pad = String(repeating: "# page\n", count: 600)  // ~4800 bytes
        return OperationRequest.StagedSource(
            bytes: Data(pad.utf8),
            ext: "md",
            displayPath: "sources/by-id/large.md"
        )
    }

    @Test func runACPIngestResolvesOneBackendAcrossAllPhases() async throws {
        // Plan the planner will write: one source file, one page assignment.
        let planData = try JSONEncoder().encode(ACPIngestPlan(
            pages: [ACPIngestPageAssignment(
                title: "Padded Page", sourceFile: "large.md",
                sourceRanges: "1-600", outline: "padding for size threshold")],
            sourceIDs: ["01FAKE"]))
        let fake = FakeAgentBackend(behaviors: [
            // Phase 1 — planner: writes plan.json, emits a messageStop so
            // runPhase returns the session.
            FakeSessionBehavior(events: [.messageStop], planJSON: planData),
            // Phase 2 — executor (one source file → one executor session).
            FakeSessionBehavior(events: [.messageStop]),
            // Phase 3 — finalizer.
            FakeSessionBehavior(events: [.messageStop]),
        ])
        let counter = ResolveBackendCallCounter()
        // Per-test tempDir lifecycle: defer in the test body, NOT in
        // `makeLauncher`, so the saved agent-providers.json is present when
        // `run()` calls `providersConfig()` on the main actor.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-collapse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let launcher = makeLauncher(backend: fake, counter: counter, tempDir: tempDir)

        await launcher.run(
            request: .ingest(sources: [largeSource()], stateMarkdown: "# State"),
            wikiID: "test-wiki",
            wikiRoot: "/tmp",
            systemPrompt: "sys",
            wikictlDirectory: "/tmp",
            ingestingSourceIDs: [],
            onEvent: nil,
            onLock: {},
            onUnlock: {}
        )

        // The collapse pin: `resolveBackend` was invoked EXACTLY ONCE — by
        // `run()` at `:954` to build `self.backend`. `runACPIngestPlannerExecutors`
        // reuses that instance and never calls `resolveBackend` again. A
        // reintroduction of per-stage routing would push this to 3 (planner +
        // executor + finalizer).
        #expect(counter.count == 1)

        // All three phases' `backend.start()` calls landed on the SAME fake
        // instance: planner (1) + executor (1) + finalizer (1) = 3. This
        // transitively pins "no per-stage backend construction" —
        // resolveBackend would have been called 3 times if each phase built its
        // own backend (and `startCount` then would be split across instances,
        // never accumulating to 3 on one).
        let startCount = await fake.startCount
        #expect(startCount == 3, "All three phases (planner/executor/finalizer) must call backend.start on the same fake instance — preflightError=\(launcher.preflightError ?? "nil")")

        // Run completed (finish() was called).
        #expect(launcher.isRunning == false)
    }
}
