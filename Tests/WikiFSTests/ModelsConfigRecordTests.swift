import Foundation
import Testing
import ACPModel
@testable import WikiFSEngine
@testable import WikiFSCore

/// Swift Testing coverage for the `models.json` artifact written at ingestion
/// start (see `plans/log-ingestion-models.md`). Asserts both the JSON shape
/// written today and the forward-compatible `phases` array (which future
/// per-phase model selection will populate without changing the schema).
///
/// Uses Swift Testing (not XCTest) per the project convention for new tests —
/// see `docs/skills/swift-testing-pro/SKILL.md`. Structs, `init` over setUp, and
/// `#expect`/`#require` over XCTAssert*. Per-test scratch dirs are UUID'd
/// under the system temp dir and left for the OS to reap (no struct `deinit`).
struct ModelsConfigRecordTests {

    /// Per-test scratch dir, isolated via UUID so parallel runs don't collide.
    /// Returned instead of stored as instance state (struct `deinit` isn't
    /// available on Swift 6.0).
    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelsConfigRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - record shape

    @Test func buildRecordPopulatesAllFields() {
        let choice = ThinkingEffortOption.Choice(value: "high", label: "High")
        let thinking = ThinkingEffortOption(
            configId: "thought_level",
            currentValue: "high",
            choices: [choice, ThinkingEffortOption.Choice(value: "medium", label: "Medium")])
        let startedAt = Date(timeIntervalSince1970: 1_753_000_000)

        let record = DebugRunLogger.makeRecord(
            chatULID: "01HXY8ATQRTESTCHAT000",
            startedAt: startedAt,
            operationKind: "ingest",
            providerId: "claude",
            providerLabel: "Claude",
            selectedModelId: "claude-sonnet-4-5",
            thinkingEffort: thinking,
            sourceFiles: ["sources/by-id/01HXY8ATQR.md", "sources/by-id/01HXY8ATQZ.md"],
            sourceIDs: ["01HXY8ATQR", "01HXY8ATQZ"])

        #expect(record.schemaVersion == 1)
        #expect(record.chatULID == "01HXY8ATQRTESTCHAT000")
        #expect(record.operationKind == "ingest")
        #expect(record.provider.id == "claude")
        #expect(record.provider.label == "Claude")
        #expect(record.selectedModelId == "claude-sonnet-4-5")
        #expect(record.thinkingEffort?.configId == "thought_level")
        #expect(record.thinkingEffort?.currentValue == "high")
        #expect(record.thinkingEffort?.choices?.count == 2)
        #expect(record.thinkingEffort?.choices?.first?.value == "high")
        #expect(record.sourceFiles == ["sources/by-id/01HXY8ATQR.md", "sources/by-id/01HXY8ATQZ.md"])
        #expect(record.sourceIDs == ["01HXY8ATQR", "01HXY8ATQZ"])
        // Forward-compat slot: empty today, present so future per-phase population
        // doesn't rewrite the schema.
        #expect(record.phases.isEmpty)
    }

    @Test func emptySelectedModelIdNormalizesToNil() {
        let record = DebugRunLogger.makeRecord(
            chatULID: nil,
            startedAt: Date(),
            operationKind: "query",
            providerId: "glm",
            providerLabel: nil,
            selectedModelId: "",
            thinkingEffort: nil,
            sourceFiles: [],
            sourceIDs: [])
        // An empty `selectedModelId` becomes `nil` (no model selected), not `""`.
        #expect(record.selectedModelId == nil)
        #expect(record.thinkingEffort == nil)
        #expect(record.provider.label == nil)
    }

    // MARK: - file write

    @Test func writeCreatesModelsJSONInScratchDir() throws {
        let scratch = try makeScratch()
        let thinking = ThinkingEffortOption(
            configId: "thought_level",
            currentValue: "high",
            choices: [ThinkingEffortOption.Choice(value: "high", label: "High")])
        let record = DebugRunLogger.makeRecord(
            chatULID: "01HTESTCHAT",
            startedAt: Date(timeIntervalSince1970: 1_753_000_000),
            operationKind: "ingest",
            providerId: "claude",
            providerLabel: "Claude",
            selectedModelId: "claude-sonnet-4-5",
            thinkingEffort: thinking,
            sourceFiles: ["sources/by-id/X.md"],
            sourceIDs: ["X"])

        DebugRunLogger.writeModelsConfig(record, to: scratch)

        let url = scratch.appendingPathComponent("models.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Round-trip the file through the Codable shape.
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ModelsConfigRecord.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.chatULID == "01HTESTCHAT")
        #expect(decoded.operationKind == "ingest")
        #expect(decoded.provider == ModelsConfigRecord.ProviderInfo(id: "claude", label: "Claude"))
        #expect(decoded.selectedModelId == "claude-sonnet-4-5")
        #expect(decoded.thinkingEffort?.configId == "thought_level")
        #expect(decoded.thinkingEffort?.currentValue == "high")
        #expect(decoded.thinkingEffort?.choices?.first?.value == "high")
        #expect(decoded.thinkingEffort?.choices?.first?.label == "High")
        #expect(decoded.sourceFiles == ["sources/by-id/X.md"])
        #expect(decoded.sourceIDs == ["X"])
        // The forward-compat slot round-trips as `[]`.
        #expect(decoded.phases == [])
    }

    @Test func writeDoesNotThrowWhenScratchDirMissing() throws {
        // A scratch dir that doesn't exist: write should log + return, not throw.
        // (Read-back should find no file.)
        let scratch = try makeScratch()
        let bogus = scratch.appendingPathComponent("does-not-exist", isDirectory: true)
        let record = DebugRunLogger.makeRecord(
            chatULID: nil,
            startedAt: Date(),
            operationKind: "lint",
            providerId: "glm",
            providerLabel: nil,
            selectedModelId: nil,
            thinkingEffort: nil,
            sourceFiles: [],
            sourceIDs: [])
        DebugRunLogger.writeModelsConfig(record, to: bogus)
        let url = bogus.appendingPathComponent("models.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: - JSON passthrough shape (no Codable decode — assert raw keys)

    @Test func writeProducesSortedPrettyJSONWithExpectedTopLevelKeys() throws {
        let scratch = try makeScratch()
        let record = DebugRunLogger.makeRecord(
            chatULID: "C",
            startedAt: Date(timeIntervalSince1970: 1_753_000_000),
            operationKind: "ingest",
            providerId: "p",
            providerLabel: "P",
            selectedModelId: "m",
            thinkingEffort: nil,
            sourceFiles: [],
            sourceIDs: [])

        DebugRunLogger.writeModelsConfig(record, to: scratch)
        let url = scratch.appendingPathComponent("models.json", isDirectory: false)
        let raw = try String(contentsOf: url, encoding: .utf8)

        // Pretty-printed (multi-line).
        #expect(raw.contains("\n"))
        // Top-level required keys present (sorted alphabetically by encoder).
        #expect(raw.contains("\"chatULID\""))
        #expect(raw.contains("\"operationKind\""))
        #expect(raw.contains("\"phases\""))
        #expect(raw.contains("\"provider\""))
        #expect(raw.contains("\"schemaVersion\""))
        #expect(raw.contains("\"selectedModelId\""))
        #expect(raw.contains("\"sourceFiles\""))
        #expect(raw.contains("\"sourceIDs\""))
        #expect(raw.contains("\"startedAt\""))
        // `thinkingEffort` is `nil` here → key omitted (encodeIfPresent behavior
        // is the synthesized default for optional Codable properties).
        #expect(raw.contains("\"thinkingEffort\"") == false)
    }

    // MARK: - forward-compat phases (semantic contract)

    @Test func phasesSlotAcceptsFuturePerPhaseEntries() throws {
        // Simulate a future record where per-phase model selection has landed:
        // a planner phase overrides the top-level model, the executor inherits.
        // This MUST decode cleanly into today's `ModelsConfigRecord` (additive
        // forward-compat — readers treat absent/empty phases as "the top-level
        // triple applies to every phase", a non-empty entry as an override).
        let futureJSON = """
        {
          "chatULID": "C",
          "operationKind": "ingest",
          "phases": [
            { "name": "planner", "selectedModelId": "opus-4" },
            { "name": "executor", "selectedModelId": "sonnet-4" }
          ],
          "provider": { "id": "claude", "label": "Claude" },
          "schemaVersion": 1,
          "sourceFiles": ["sources/by-id/X.md"],
          "sourceIDs": ["X"],
          "startedAt": "2026-07-19T12:34:56Z"
        }
        """
        let data = try #require(futureJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ModelsConfigRecord.self, from: data)
        #expect(decoded.phases.count == 2)
        #expect(decoded.phases[0].name == "planner")
        #expect(decoded.phases[0].selectedModelId == "opus-4")
        #expect(decoded.phases[1].name == "executor")
        #expect(decoded.phases[1].selectedModelId == "sonnet-4")
        // Top-level triple still present (the default applying to every phase
        // absent an override).
        #expect(decoded.provider.id == "claude")
        // `selectedModelId` was absent at the top level here → nil (the agent
        // default applies; per-phase entries override).
        #expect(decoded.selectedModelId == nil)
    }

    // MARK: - AgentLauncher.sourceFilesAndIDs(for:)

    @Test func sourceFilesAndIDsForIngest() {
        let op = WikiOperation.ingest(
            sourcePaths: ["sources/by-id/01HXY8ATQR.md", "sources/by-id/01HXY8ATQZ.md"],
            stagedSourcePaths: ["/scratch/source-1.md", "/scratch/source-2.md"],
            stateFilePath: "/scratch/WIKI_STATE.md",
            plan: .singleOpus)
        let (files, ids) = AgentLauncher.sourceFilesAndIDs(for: op)
        #expect(files == ["sources/by-id/01HXY8ATQR.md", "sources/by-id/01HXY8ATQZ.md"])
        // Source IDs are the leaf filename without extension (the same projection
        // `WikiOperation.sourceID(fromPath:)` uses for the prompts).
        #expect(ids == ["01HXY8ATQR", "01HXY8ATQZ"])
    }

    @Test func sourceFilesAndIDsForNonIngestAreEmpty() {
        // `.query`, `.lint`, `.lintPage`, and `.queryChat` all carry no sources —
        // `models.json` records `[]` for both arrays.
        let query = WikiOperation.query(question: "what?", stateFilePath: "/x/WIKI_STATE.md")
        #expect(AgentLauncher.sourceFilesAndIDs(for: query).sourceFiles.isEmpty)
        #expect(AgentLauncher.sourceFilesAndIDs(for: query).sourceIDs.isEmpty)

        let lint = WikiOperation.lint(stateFilePath: "/x/WIKI_STATE.md")
        #expect(AgentLauncher.sourceFilesAndIDs(for: lint).sourceFiles.isEmpty)

        let lintPage = WikiOperation.lintPage(
            pageTitle: "X", brokenLinks: [], stateFilePath: "/x/WIKI_STATE.md")
        #expect(AgentLauncher.sourceFilesAndIDs(for: lintPage).sourceIDs.isEmpty)

        let chat = WikiOperation.queryChat(stateFilePath: "/x/WIKI_STATE.md")
        #expect(AgentLauncher.sourceFilesAndIDs(for: chat).sourceFiles.isEmpty)
    }
}
