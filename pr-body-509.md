## Summary

Fixes #509 — two typing gaps in the agent launch configuration layer.

### R7: Route `legacy-extraction` through `ExtractionBackend.legacyAgentName`

The raw `"legacy-extraction"` agent-name literal was duplicated outside the `ExtractionBackend` enum at multiple call sites. Added a single `ExtractionBackend.legacyAgentName` constant and routed all checks through it.

**Changed sites:**
- `ExtractionBackend.legacyAgentName` constant added to `MarkdownExtractor.swift`
- `ExtractionAlternative.backendDisplayName(agentName:)` — uses the constant instead of raw string
- `SourceDetailView.swift` — removed duplicate `backendDisplayName(forAgent:)` method (it duplicated `ExtractionAlternative.backendDisplayName`); both call sites now delegate to the canonical implementation
- `SQLiteWikiStore.swift` — SQL literals now interpolate the constant

### R8: Typed `HintKey` + `StageRoutingKey` enums for magic string keys

`BackendProfile.providerHints` and `QueueItemPayload.stageRouting` used bare string-literal keys (`"acpAgentPath"`, `"acpAgentArgs"`, `"acpAgentApiKey"`, `"acpSelectedModelId"`, `"env." + key`, `"backend"`) that were not compile-time-checked.

**New types:**
- `HintKey` enum (`Sources/WikiFSEngine/HintKey.swift`) — cases for `acpAgentPath`, `acpAgentArgs`, `acpAgentApiKey`, `acpSelectedModelId`, plus `env(_:)` builder and `envKey(from:)` extractor for the `env.<key>` dynamic form
- `StageRoutingKey` enum (`Sources/WikiFSCore/QueueTypes.swift`) — `backend` case for re-extraction override

**Changed sites:**
- `AgentBackendFactory.providerHints` — writes via `HintKey`
- `ACPBackend.resolveSpawnConfig` — reads via `HintKey` (including `envKey(from:)` for env-prefix extraction)
- `ACPBackend.start` — reads `acpSelectedModelId` via `HintKey`
- `ACPBackendError.noAgentConfigured` — error message interpolates `HintKey`
- `AgentLauncher` — `env.WIKI_WORKSPACE` and `env.WIKI_AUTHOR` writes via `HintKey.env(_:)`
- `QueueExtractionWorker` — `stageRouting?["backend"]` via `StageRoutingKey.backend.rawValue`
- `SourceDetailView` — `["backend": ...]` via `StageRoutingKey.backend.rawValue`

All test files referencing these string keys also updated to use the typed enums.

## Test plan

- [x] `swift build` passes
- [x] Fast test tier passes (2444 tests):
      `swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests|ChatSummaryTests|ProjectionTreeTests'`
