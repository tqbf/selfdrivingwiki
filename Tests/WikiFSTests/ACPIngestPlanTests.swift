import Foundation
import Testing
import ACPModel
@testable import WikiFSCore
@testable import WikiFS

/// Unit tests for the multi-phase ACP ingestion plan schema, tolerant JSON
/// extraction, prompt builders, and the `findSonnetModelId` helper.
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

    // MARK: - findSonnetModelId

    @Test func testFindSonnetModelIdMatch() {
        let models = [
            ModelInfo(modelId: "claude-opus-4-20250514", name: "Claude Opus 4"),
            ModelInfo(modelId: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5"),
            ModelInfo(modelId: "claude-haiku-3-5", name: "Claude Haiku 3.5"),
        ]
        let result = AgentLauncher.findSonnetModelId(in: models)
        #expect(result == "claude-sonnet-4-5-20250929")
    }

    @Test func testFindSonnetModelIdByName() {
        let models = [
            ModelInfo(modelId: "model-abc", name: "Sonnet Pro"),
        ]
        let result = AgentLauncher.findSonnetModelId(in: models)
        #expect(result == "model-abc")
    }

    @Test func testFindSonnetModelIdNoMatch() {
        let models = [
            ModelInfo(modelId: "claude-opus-4", name: "Opus"),
            ModelInfo(modelId: "gpt-4o", name: "GPT-4o"),
        ]
        let result = AgentLauncher.findSonnetModelId(in: models)
        #expect(result == nil)
    }

    @Test func testFindSonnetModelIdEmpty() {
        #expect(AgentLauncher.findSonnetModelId(in: []) == nil)
    }

    @Test func testFindSonnetModelIdCaseInsensitive() {
        let models = [
            ModelInfo(modelId: "CLAUDE-SONNET-4", name: "Sonnet"),
        ]
        let result = AgentLauncher.findSonnetModelId(in: models)
        #expect(result == "CLAUDE-SONNET-4")
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

        let hints1 = BackendProfile(providerHints: ["acpSelectedModelId": "opus-4"])
        _ = try await fake.start(profile: hints1, systemPrompt: "") { _ in }

        let hints2 = BackendProfile(providerHints: ["acpSelectedModelId": "sonnet-4"])
        _ = try await fake.start(profile: hints2, systemPrompt: "") { _ in }

        let recorded = await fake.startModelHints
        #expect(recorded == ["opus-4", "sonnet-4"])
    }
}
