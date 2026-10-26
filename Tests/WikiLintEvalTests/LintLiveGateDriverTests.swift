import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
import WikiLintEval

#if canImport(WikiFSEngine) && os(macOS)
/// Deterministic W3 driver plumbing: suite composition, budget/backoff,
/// evaluated-configuration resolution (named prerequisites), oracle hunk
/// attribution, and the AC.13 mechanical verdict. Live runs are NOT
/// unit-tested — these cover the pure planning and reporting seams.
struct LintLiveGateDriverTests {

    // MARK: - Suite composition

    private func canonical() throws -> LintEvalFixtureManifest {
        try LintEvalCanonicalFixtures.loadGateManifest()
    }

    @Test func suiteComposesBailFloorPlusGroupRuns() throws {
        let manifest = try canonical()
        let trials = try LintLiveGateSuiteComposer.compose(
            manifest: manifest, bailTrials: 20, groupRuns: 3)
        let bail = trials.filter { $0.fixtureID == LintLiveGateSuiteComposer.bailFixtureID }
        #expect(bail.count == 20)
        #expect(Set(bail.map(\.trialIndex)).count == 20, "bail trials are independent")
        // Every remaining fixture runs exactly 3 times.
        let others = Set((manifest.tuning + manifest.heldOut).map(\.id))
            .subtracting([LintLiveGateSuiteComposer.bailFixtureID])
        for fixtureID in others {
            let runs = trials.filter { $0.fixtureID == fixtureID }
            #expect(runs.count == 3, "fixture \(fixtureID) must run 3 times")
        }
        #expect(trials.count == 20 + 3 * others.count)
        // The clean fixture's runs are idempotence pairs (AC-06).
        let clean = trials.filter { $0.fixtureID == "clean-page" }
        #expect(!clean.isEmpty && clean.allSatisfy(\.isIdempotencePair))
        let nonClean = trials.filter { $0.fixtureID != "clean-page" }
        #expect(nonClean.allSatisfy { !$0.isIdempotencePair })
    }

    @Test func suiteComposerRejectsMissingBailFixture() throws {
        let manifest = try canonical()
        // A manifest without the bail fixture cannot compose a gate suite.
        let withoutBail = LintEvalFixtureManifest(
            tuning: manifest.tuning.filter { $0.id != LintLiveGateSuiteComposer.bailFixtureID },
            heldOut: manifest.heldOut)
        #expect(throws: LintLiveGateError.self) {
            _ = try LintLiveGateSuiteComposer.compose(
                manifest: withoutBail, bailTrials: 20, groupRuns: 3)
        }
    }

    // MARK: - Budget + backoff

    @Test func budgetBackoffIsExponentialAndCapped() {
        let budget = LintLiveGateBudget(
            now: .now, ceiling: .seconds(8 * 3600))
        #expect(budget.backoffSeconds(retry: 1, base: 5, cap: 120) == 5)
        #expect(budget.backoffSeconds(retry: 2, base: 5, cap: 120) == 10)
        #expect(budget.backoffSeconds(retry: 3, base: 5, cap: 120) == 20)
        #expect(budget.backoffSeconds(retry: 0, base: 5, cap: 120) == 0)
        #expect(budget.backoffSeconds(retry: 10, base: 5, cap: 120) == 120, "capped")
        #expect(budget.backoffSeconds(retry: 30, base: 5, cap: 120) == 120, "overflow-safe cap")
    }

    @Test func budgetExhaustsAtTheDeadline() async throws {
        let clock = ContinuousClock()
        let budget = LintLiveGateBudget(now: clock.now, ceiling: .milliseconds(50))
        #expect(!budget.isExhausted(now: clock.now))
        try await Task.sleep(for: .milliseconds(80))
        #expect(budget.isExhausted(now: clock.now))
        #expect(budget.timeRemaining(now: clock.now) == .zero, "clamped at zero")
    }

    // MARK: - Evaluated-configuration resolution

    /// Write a provider configuration with an enabled provider whose probed
    /// model catalog carries effort choices.
    private func writeConfig(
        directory: URL,
        enabledProviderID: String,
        models: [[String: Any]]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "generation": 1,
            "providers": [[
                "id": enabledProviderID,
                "label": "Test Provider",
                "enabled": true,
                "isDefault": false,
                "env": [String: String](),
                "command": ["/bin/echo"],
            ]],
            "providerModels": [enabledProviderID: models],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("agent-providers.json"))
        return directory
    }

    private func pipeline() throws -> LintAcceptanceManifest.Pipeline {
        try LintAcceptanceManifest.Pipeline.live()
    }

    @Test func resolutionPicksTheLowestAdvertisedEffortByNamePrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeConfig(
            directory: root,
            enabledProviderID: "zai",
            models: [[
                "modelId": "glm-5.3-flash",
                "name": "GLM 5.3 Flash (Latest)",
                "thinkingOptionCatalog": [
                    "configOptionID": "thought_level",
                    "choices": [
                        ["id": "high", "label": "High"],
                        ["id": "medium", "label": "Medium"],
                        ["id": "low", "label": "Low"],
                    ],
                ],
            ]])
        let config = AgentProvidersConfig.loadOrSeed(from: dir, discover: { [] })
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "zai",
            requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline())
        #expect(evaluated.providerID == "zai")
        #expect(evaluated.modelID == "glm-5.3-flash")
        #expect(evaluated.effort == "low", "the lowest advertised tier wins")
        let expectedPipeline = try pipeline()
        #expect(evaluated.components.promptSHA256 == expectedPipeline.promptSHA256)
        #expect(evaluated.components.effort == "low")
    }

    @Test func resolutionNamesMissingPrerequisites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // No provider named zai — the exact state this machine is in.
        let dir = try writeConfig(
            directory: root, enabledProviderID: "codex-acp", models: [])
        let config = AgentProvidersConfig.loadOrSeed(from: dir, discover: { [] })
        #expect(throws: LintLiveGateError.providerAbsent(requested: "zai", configured: ["codex-acp"])) {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "zai",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline())
        }
        // Provider present, model absent: the static catalog is empty, so
        // the pi agent catalog fallback runs — a fixture catalog WITHOUT the
        // requested model names the miss and lists what IS advertised.
        let catalogWithoutModel = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: ["fireworks": [
                ["id": "accounts/fireworks/routers/deepseek-flash-latest",
                 "name": "DeepSeek V4.1 Flash (Latest)"],
            ]])
        #expect(throws: LintLiveGateError.modelAbsent(
            requested: "GLM 5.3 Flash", provider: "codex-acp",
            available: ["accounts/fireworks/routers/deepseek-flash-latest"])) {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "codex-acp",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline(),
                piCatalogURL: catalogWithoutModel)
        }
        // Provider + model, but no advertised effort tiers.
        let withModel = try writeConfig(
            directory: root.appendingPathComponent("b"),
            enabledProviderID: "zai",
            models: [["modelId": "glm-5.3-flash", "name": "GLM 5.3 Flash"]])
        let config2 = AgentProvidersConfig.loadOrSeed(from: withModel, discover: { [] })
        #expect(throws: LintLiveGateError.effortUnadvertised(provider: "zai", model: "GLM 5.3 Flash")) {
            _ = try LintLiveGateResolution.resolve(
                configuration: config2, requestedProviderID: "zai",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline())
        }
    }

    // MARK: - Label-declared effort tiers (codex-acp)

    /// The real codex-acp catalog shape: every effort tier is its own
    /// model variant, the tier lives in the label's trailing parenthesized
    /// suffix, and no entry advertises a thinking-option catalog.
    private func codexVariantModels() -> [[String: Any]] {
        [
            ["modelId": "gpt-6.1-sol[low]", "name": "6.1 Sol (low)"],
            ["modelId": "gpt-6.1-sol[medium]", "name": "6.1 Sol (medium)"],
            ["modelId": "gpt-6.1-sol[high]", "name": "6.1 Sol (high)"],
            ["modelId": "gpt-6.1-sol[xhigh]", "name": "6.1 Sol (xhigh)"],
            ["modelId": "gpt-6.1-sol[max]", "name": "6.1 Sol (max)"],
            ["modelId": "gpt-6.1-sol[ultra]", "name": "6.1 Sol (ultra)"],
            ["modelId": "gpt-6-astra[low]", "name": "6 Astra (low)"],
            ["modelId": "gpt-6-astra[medium]", "name": "6 Astra (medium)"],
        ]
    }

    @Test func resolutionRecordsEffortFromVariantLabelTier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeConfig(
            directory: root, enabledProviderID: "codex-acp",
            models: codexVariantModels())
        let config = AgentProvidersConfig.loadOrSeed(from: dir, discover: { [] })
        // "6.1 Sol" prefix-matches the lowest advertised variant, whose
        // label declares the effort — resolution proceeds and records it.
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "codex-acp",
            requestedModelID: "6.1 Sol", pipeline: try pipeline())
        #expect(evaluated.modelID == "gpt-6.1-sol[low]")
        #expect(evaluated.modelLabel == "6.1 Sol (low)")
        #expect(evaluated.effort == "low", "the label declares the tier")
        #expect(evaluated.components.effort == "low")
        #expect(evaluated.components.model == "gpt-6.1-sol[low]")
        // Matching is case-insensitive; the value records lowercased.
        let mixedCase = try writeConfig(
            directory: root.appendingPathComponent("case"),
            enabledProviderID: "codex-acp",
            models: [["modelId": "gpt-6.1-sol[ultra]", "name": "6.1 Sol (Ultra)"]])
        let evaluated2 = try LintLiveGateResolution.resolve(
            configuration: AgentProvidersConfig.loadOrSeed(
                from: mixedCase, discover: { [] }),
            requestedProviderID: "codex-acp",
            requestedModelID: "6.1 Sol", pipeline: try pipeline())
        #expect(evaluated2.effort == "ultra")
    }

    @Test func resolutionTierlessPiCatalogModelStillRecordsAgentDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        let catalog = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: ["deepseek": [
                ["id": "deepseek-v4.1", "name": "DeepSeek V4.1"],
            ]])
        // A label with no parenthesized suffix at all: the pi catalog
        // advertises no tiers, so the effort still names the agent
        // default — the label-tier parse never reaches this path.
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "pi-acp",
            requestedModelID: "DeepSeek V4.1", pipeline: try pipeline(),
            piCatalogURL: catalog)
        #expect(evaluated.modelID == "deepseek-v4.1")
        #expect(evaluated.effort == "agent-default")
        #expect(evaluated.components.effort == "agent-default")
    }

    @Test func resolutionStaysImpossibleWithoutAnyTierAdvertisement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A static model with no tier in its label AND no advertised
        // catalog has nowhere to source an effort — the named prerequisite
        // fires, exactly as before the label-tier accommodation.
        let tierless = try writeConfig(
            directory: root.appendingPathComponent("tierless"),
            enabledProviderID: "codex-acp",
            models: [["modelId": "gpt-6.1-sol", "name": "6.1 Sol"]])
        let tierlessConfig = AgentProvidersConfig.loadOrSeed(
            from: tierless, discover: { [] })
        #expect(throws: LintLiveGateError.effortUnadvertised(
            provider: "codex-acp", model: "6.1 Sol")) {
            _ = try LintLiveGateResolution.resolve(
                configuration: tierlessConfig, requestedProviderID: "codex-acp",
                requestedModelID: "6.1 Sol", pipeline: try pipeline())
        }
        // A parenthesized suffix that is NOT a recognized tier never
        // masquerades as one.
        let nonTier = try writeConfig(
            directory: root.appendingPathComponent("non-tier"),
            enabledProviderID: "codex-acp",
            models: [["modelId": "glm-5.3-flash", "name": "GLM 5.3 Flash (Latest)"]])
        let nonTierConfig = AgentProvidersConfig.loadOrSeed(
            from: nonTier, discover: { [] })
        #expect(throws: LintLiveGateError.effortUnadvertised(
            provider: "codex-acp", model: "GLM 5.3 Flash (Latest)")) {
            _ = try LintLiveGateResolution.resolve(
                configuration: nonTierConfig, requestedProviderID: "codex-acp",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline())
        }
    }

    // MARK: - Pi agent catalog fallback

    /// Write a pi-agent-shaped catalog file: `providers.<key>.models[]`
    /// with entries carrying `id` + `name` (the real file's shape).
    private func writePiCatalog(
        directory: URL,
        providers: [String: [[String: String]]]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["providers": providers.mapValues { ["models": $0] }],
            options: [.sortedKeys])
        let url = directory.appendingPathComponent("models.json")
        try data.write(to: url)
        return url
    }

    /// A provider configuration whose enabled provider carries NO static
    /// models — the state that triggers the catalog fallback.
    private func configWithoutModels(
        providerID: String, root: URL
    ) throws -> AgentProvidersConfig {
        let dir = try writeConfig(directory: root, enabledProviderID: providerID, models: [])
        return AgentProvidersConfig.loadOrSeed(from: dir, discover: { [] })
    }

    /// The real catalog's GLM entries, fixture-shaped.
    private func fireworksCatalogFixture() -> [String: [[String: String]]] {
        ["fireworks": [
            ["id": "auto", "name": "Auto"],
            ["id": "accounts/fireworks/routers/glm-fast-latest", "name": "GLM 5.3 Fast (Latest)"],
            ["id": "accounts/fireworks/routers/glm-flash-latest", "name": "GLM 5.3 Flash (Latest)"],
        ]]
    }

    @Test func resolutionFallsBackToPiCatalogByLabel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        let catalog = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: fireworksCatalogFixture())
        // "GLM 5.3 Flash" (no suffix) matches the label "GLM 5.3 Flash (Latest)".
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "pi-acp",
            requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline(),
            piCatalogURL: catalog)
        #expect(evaluated.modelID == "accounts/fireworks/routers/glm-flash-latest")
        #expect(evaluated.modelLabel == "GLM 5.3 Flash (Latest)")
        #expect(evaluated.providerID == "pi-acp")
        // The pi catalog advertises no thinking tiers, so the effort names
        // the agent default instead of inventing a tier id.
        #expect(evaluated.effort == "agent-default")
        #expect(evaluated.components.model == "accounts/fireworks/routers/glm-flash-latest")
        #expect(evaluated.components.effort == "agent-default")
    }

    @Test func resolutionFallsBackToPiCatalogByExactID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        let catalog = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: fireworksCatalogFixture())
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "pi-acp",
            requestedModelID: "accounts/fireworks/routers/glm-flash-latest",
            pipeline: try pipeline(), piCatalogURL: catalog)
        #expect(evaluated.modelID == "accounts/fireworks/routers/glm-flash-latest")
        #expect(evaluated.modelLabel == "GLM 5.3 Flash (Latest)")
    }

    @Test func resolutionPrefersExactCatalogProviderKeyOverUnion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        // The catalog carries BOTH a pi-acp key and an upstream key; the
        // exact key's entry wins.
        let catalog = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: [
                "pi-acp": [["id": "pi-acp-model", "name": "PI ACP Model"]],
                "fireworks": [["id": "accounts/fireworks/routers/glm-flash-latest",
                               "name": "GLM 5.3 Flash (Latest)"]],
            ])
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config, requestedProviderID: "pi-acp",
            requestedModelID: "PI ACP Model", pipeline: try pipeline(),
            piCatalogURL: catalog)
        #expect(evaluated.modelID == "pi-acp-model")
        // And the upstream key's models are NOT visible to the exact-key
        // provider: a request that only the union could satisfy must miss.
        #expect(throws: LintLiveGateError.self) {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "pi-acp",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline(),
                piCatalogURL: catalog)
        }
    }

    @Test func resolutionCatalogMissNamesPrerequisiteAndListsAdvertised() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        let catalog = try writePiCatalog(
            directory: root.appendingPathComponent("catalog"),
            providers: fireworksCatalogFixture())
        do {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "pi-acp",
                requestedModelID: "Nova 9 Ultra", pipeline: try pipeline(),
                piCatalogURL: catalog)
            Issue.record("expected modelAbsent")
        } catch let error as LintLiveGateError {
            #expect(error == .modelAbsent(
                requested: "Nova 9 Ultra", provider: "pi-acp",
                available: [
                    "auto",
                    "accounts/fireworks/routers/glm-fast-latest",
                    "accounts/fireworks/routers/glm-flash-latest",
                ]))
            // The BLOCKED message lists the advertised ids.
            #expect(error.localizedDescription.contains("glm-flash-latest"))
        }
    }

    @Test func resolutionNamesMissingPiCatalogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        let missing = root.appendingPathComponent("absent").appendingPathComponent("models.json")
        do {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "pi-acp",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline(),
                piCatalogURL: missing)
            Issue.record("expected piCatalogUnreadable")
        } catch let error as LintLiveGateError {
            guard case .piCatalogUnreadable(let path, let reason) = error else {
                Issue.record("expected piCatalogUnreadable, got \(error)")
                return
            }
            #expect(path == missing.path)
            #expect(!reason.isEmpty)
            #expect(error.localizedDescription.contains("named prerequisite"))
        }
    }

    @Test func resolutionNamesMalformedPiCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-eval-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try configWithoutModels(providerID: "pi-acp", root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("catalog"), withIntermediateDirectories: true)
        let malformed = root.appendingPathComponent("catalog").appendingPathComponent("models.json")
        try Data("{ not json".utf8).write(to: malformed)
        do {
            _ = try LintLiveGateResolution.resolve(
                configuration: config, requestedProviderID: "pi-acp",
                requestedModelID: "GLM 5.3 Flash", pipeline: try pipeline(),
                piCatalogURL: malformed)
            Issue.record("expected piCatalogUnreadable")
        } catch let error as LintLiveGateError {
            guard case .piCatalogUnreadable(_, let reason) = error else {
                Issue.record("expected piCatalogUnreadable, got \(error)")
                return
            }
            #expect(reason.contains("malformed"))
        }
    }

    // MARK: - Oracle hunk attribution

    private func fixture(
        seeds: [LintEvalFixture.SeededDefect],
        repairs: [LintEvalFixture.AllowedRepair]
    ) -> LintEvalFixture {
        LintEvalFixture(
            id: "test", body: "", seededDefects: seeds,
            allowedRepairs: repairs, protectedByteRanges: [],
            permittedUnresolvedClasses: [], kind: "mechanical")
    }

    @Test func observedHunksAttributeByDeclaration() {
        let original = "```markdown\n# page\n\nold text\n```\n"
        let repaired = "# page\n\nold text\n"
        // Both fence removals declared — the real bail fixture's shape.
        let fixture = fixture(
            seeds: [LintEvalFixture.SeededDefect(
                defectClass: "D25", evidence: "```markdown\n", expectRepair: true)],
            repairs: [
                LintEvalFixture.AllowedRepair(
                    defectClass: "D25", oldText: "```markdown\n", newText: ""),
                LintEvalFixture.AllowedRepair(
                    defectClass: "D25", oldText: "```\n", newText: ""),
            ])
        let reconstructed = LintLiveGateDriver.observedHunks(
            before: original, after: repaired, fixture: fixture)
        #expect(reconstructed.hunks.count == 2, "declaration-anchored: both removals")
        #expect(reconstructed.hunks.allSatisfy { $0.defectClass.rawValue == "D25" })
        #expect(reconstructed.repairedClasses == Set(["D25"]))
        #expect(reconstructed.unresolvedClasses.isEmpty)
        // The oracle accepts the reconstructed hunks (server-observed bytes
        // reproduce; declarations match, each consumed once).
        let verdict = LintDiffOracle.verify(
            original: original, new: repaired,
            hunks: reconstructed.hunks, fixture: fixture)
        #expect(verdict.accepted, "rejections: \(verdict.rejections)")
    }

    @Test func observedHunksLeaveUnmatchedEditsUnattributable() {
        let original = "# page\n\nbody\n"
        let rewritten = "# replaced\n"
        let fixture = fixture(
            seeds: [LintEvalFixture.SeededDefect(
                defectClass: "D03", evidence: "body", expectRepair: true)],
            repairs: [LintEvalFixture.AllowedRepair(
                defectClass: "D03", oldText: "body", newText: "new body")])
        let reconstructed = LintLiveGateDriver.observedHunks(
            before: original, after: rewritten, fixture: fixture)
        // The edit matches no declaration and no seed evidence → the fence
        // fallback class; the oracle rejects it as an undeclared repair.
        let verdict = LintDiffOracle.verify(
            original: original, new: rewritten,
            hunks: reconstructed.hunks, fixture: fixture)
        #expect(verdict.accepted == false)
        #expect(verdict.rejections.contains(.undeclaredRepair(hunkIndex: 0)))
    }

    @Test func observedRegionsTrimCommonPrefixAndSuffix() {
        let before = "aaaXYZbbb"
        let after = "aaaWbbb"
        let regions = LintLiveGateDriver.observedRegions(before: before, after: after)
        #expect(regions.count == 1)
        #expect(regions[0].old == 3..<6)
        #expect(regions[0].new == 3..<4)
        #expect(LintLiveGateDriver.observedRegions(before: "same", after: "same").isEmpty)
    }

    // MARK: - AC.13 mechanical verdict

    private func record(
        fixtureID: String, trialIndex: Int, passed: Bool
    ) -> LintLiveTrialRecord {
        LintLiveTrialRecord(
            fixtureID: fixtureID, trialIndex: trialIndex, isIdempotencePair: false,
            wikiID: "01TEST", startedAt: Date(), finishedAt: Date(),
            authorityTier: "evaluationAdmission", authorityReason: nil,
            runStatus: "dispatched", runDetail: "",
            appliedClasses: passed ? ["D25"] : [], hits: passed ? ["D25#1"] : [],
            oracleAccepted: passed, oracleRejections: [],
            scorePassed: passed, scoreFailures: passed ? [] : ["D25#1: seeded defect missed entirely"],
            idempotenceWrites: nil, rateLimitRetries: 0,
            seededBodySHA256: "a", finalBodySHA256: "b",
            transcriptDirectory: nil, error: nil)
    }

    @Test func verdictPassesOnlyOnAFullCleanSuite() throws {
        let manifest = try canonical()
        let trials = try LintLiveGateSuiteComposer.compose(
            manifest: manifest, bailTrials: 20, groupRuns: 3)
        let allPassed = trials.map { record(fixtureID: $0.fixtureID, trialIndex: $0.trialIndex, passed: true) }
        let (passed, reasons) = LintLiveGateReport.verdict(
            records: allPassed, plannedTrials: trials.count, bailTrials: 20,
            groupRuns: 3, manifest: manifest, abortedEarly: false)
        #expect(passed == "PASSED")
        #expect(reasons.isEmpty)

        // One bail failure fails the gate and names the count.
        var oneFailed = allPassed
        oneFailed[3] = record(fixtureID: LintLiveGateSuiteComposer.bailFixtureID, trialIndex: 4, passed: false)
        let (failed, failedReasons) = LintLiveGateReport.verdict(
            records: oneFailed, plannedTrials: trials.count, bailTrials: 20,
            groupRuns: 3, manifest: manifest, abortedEarly: false)
        #expect(failed == "FAILED")
        #expect(failedReasons.contains { $0.contains("19/20") })
        #expect(failedReasons.contains { $0.contains("1 failing trial") })

        // An early abort fails the gate even with a clean record set.
        let (aborted, abortReasons) = LintLiveGateReport.verdict(
            records: [], plannedTrials: trials.count, bailTrials: 20,
            groupRuns: 3, manifest: manifest, abortedEarly: true)
        #expect(aborted == "FAILED")
        #expect(abortReasons.contains { $0.contains("aborted") })
    }

    @Test func trialRecordFailsOnNonzeroIdempotenceWrites() {
        // A clean/idempotence trial that WROTE anything fails, even when the
        // oracle and score both read clean.
        let wrote = LintLiveTrialRecord(
            fixtureID: "clean-page", trialIndex: 1, isIdempotencePair: true,
            wikiID: "01TEST", startedAt: Date(), finishedAt: Date(),
            authorityTier: "evaluationAdmission", authorityReason: nil,
            runStatus: "dispatched", runDetail: "",
            appliedClasses: [], hits: [],
            oracleAccepted: true, oracleRejections: [],
            scorePassed: true, scoreFailures: [],
            idempotenceWrites: [0, 1], rateLimitRetries: 0,
            seededBodySHA256: "a", finalBodySHA256: "b",
            transcriptDirectory: nil, error: nil)
        #expect(wrote.passed == false)
    }
}
#endif
