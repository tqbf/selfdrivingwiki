# ACP Multi-Provider Configuration

**Status:** implementation complete (2026-07-12). All 4 phases shipped;
ACP multi-provider plan fully delivered.

## Definition of done

1. A single **Agents** settings tab with two sections:
   - **Providers** — an editable list seeded with `claude-acp`, `hermes`, and
     `opencode`. Users can add custom ACP providers (label, command argv, env),
     remove or disable any entry, mark any one as default, store a per-provider
     API key in the Keychain, and pick a preferred model from the provider's
     discovered model list. If the list ever becomes empty, `claude-acp` is
     re-seeded (empty-list guard only — Claude is otherwise fully editable and
     removable).
   - **Ingestion Stages** — three optional (provider, model) assignments for
     **planner**, **executor**, and **finalizer**. Unset means "use the app
     default provider and its selected model".
2. Legacy code deleted: `ClaudeCLIBackend`, `AgentCommandConfig`
   (`agent-command-config.json`), `ACPAgentConfig` (`acp-agent-config.json`),
   the `useACPBackend` UserDefaults toggle, the old **Agent** and **Providers**
   settings tabs, the `IngestPlan` opus/sonnet hardcoding, and the
   `findSonnetModelId` substring heuristic. The app is ACP-only.
3. The ACP ingestion pipeline resolves each stage's provider and model
   independently and can mix providers within a single run (e.g. hermes plans,
   opencode executes sections). Chat continues to use the default provider.
4. Existing `agent-providers.json` files load cleanly (new fields optional,
   old force-Claude normalization dropped without breaking decode). Tests
   updated and passing.

## Current state (what this replaces)

Three overlapping config surfaces exist today:

| Surface | File | Used by |
| --- | --- | --- |
| `AgentCommandConfig` (Agent tab) | `agent-command-config.json` | `ClaudeCLIBackend` only |
| `ACPAgentConfig` (Agent tab, behind `useACPBackend` toggle) | `acp-agent-config.json` | **nothing** — dead wiring kept for old tests |
| `AgentProvidersConfig` (Providers tab, read-only UI) | `agent-providers.json` | `AgentLauncher.resolveSelectedProvider()` — the real path |

`ACPBackend` (Sources/WikiFSEngine/ACPBackend.swift) is already
provider-agnostic — it spawns any executable+args over stdio JSON-RPC. The
Claude lock-in lives entirely in `AgentProvidersConfig.normalized()` (forcibly
re-inserts `claude-acp`, forces it default) and `seed()` (ignores discovery,
emits only Claude). The ACP ingestion pipeline
(`AgentLauncher.runACPIngestPlannerExecutors`) runs planner and finalizer on
the user-selected model and picks the executor model by substring-matching
`"sonnet"` against the provider's advertised model list.

Paseo (~/work/paseo) validates the shape we're adopting: providers are a
record of `{label, command: [argv], env, models?}` entries; model selection
happens over the live ACP session, not CLI args; hermes is `["hermes", "acp"]`.
Both `hermes acp` and `opencode acp` are verified working on this machine.

## Design

### Data model (Sources/WikiFSCore)

**`AgentProvider`** (existing struct, extended):

```swift
struct AgentProvider: Codable, Equatable, Identifiable, Sendable {
    var id: String              // stable slug, e.g. "hermes"
    var label: String
    var command: [String]?      // argv: [binary, args...]
    var environment: [String: String]?  // NEW, optional -> old JSON decodes
    var isEnabled: Bool
    var isDefault: Bool
    // backend field removed with the CLI backend (or kept as always-.acp
    // during transition, then deleted)
}
```

Seeds (all editable, all removable):

```swift
static let claudeAcpDefault = AgentProvider(
    id: "claude-acp", label: "Claude (ACP)",
    command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
    isEnabled: true, isDefault: true)
static let hermesDefault = AgentProvider(
    id: "hermes", label: "Hermes",
    command: ["hermes", "acp"], isEnabled: true, isDefault: false)
static let opencodeDefault = AgentProvider(
    id: "opencode", label: "OpenCode",
    command: ["opencode", "acp"], isEnabled: true, isDefault: false)
```

**`AgentProvidersConfig`** changes:

- `normalized()` no longer force-inserts or force-defaults `claude-acp`.
  New invariants: at most one `isDefault`; if none is default, promote the
  first enabled provider; if `providers.isEmpty`, re-seed all three defaults.
- `seed(discovered:)` emits the three seed providers.
- Remove `claudeCachedModels` injection (`["opus","sonnet","haiku"]`) — with
  the CLI backend gone, model lists always come from ACP discovery
  (`providerModels` capture already exists). Keep the captured-models cache.
- NEW: `stageAssignments: [IngestStage: StageAssignment]?`

```swift
enum IngestStage: String, Codable, CaseIterable, Sendable {
    case planner, executor, finalizer
}
struct StageAssignment: Codable, Equatable, Sendable {
    var providerId: String
    var modelId: String?   // nil = provider's selectedModelId / agent default
}
```

- NEW resolution API:

```swift
func resolvedProvider(for stage: IngestStage) -> (AgentProvider, modelId: String?)
```

Falls back to `(selectedProvider(), selectedModelIds[provider.id])` when the
stage has no assignment, the assigned provider was deleted, or it is disabled.
Stale assignments are pruned in `normalized()`.

Persistence stays `agent-providers.json` (atomic JSON in the App Group
container). All new fields are optional, so existing files decode unchanged;
saving rewrites in the new shape. No version bump needed. The two orphaned
JSON files (`agent-command-config.json`, `acp-agent-config.json`) are simply
no longer read; leave them on disk.

API keys: keep `KeychainACPCredentialStore` provider-keyed API
(`setAPIKey(_:forProvider:)`). Delete the keyless global-key API with the
legacy Agent tab.

### Backend / launcher (Sources/WikiFSEngine)

- Delete `ClaudeCLIBackend`, `AgentBackendFactory.makeBackend(useACPBackend:policy:)`,
  and `AgentLauncher.useACPBackendKey`. `AgentBackendFactory` builds only
  `ACPBackend` from an `AgentProvider`.
- `providerHints(...)` gains `env`: `AgentSpawnConfig` gets
  `environment: [String: String]` merged over the inherited environment when
  spawning. (Paseo does the same; hermes/opencode often need provider API keys
  via env, e.g. `ZAI_API_KEY`.)
- Keep the existing `bun` special case (prefer bundled helper binary) — it
  applies whenever `command[0] == "bun"`, provider-agnostic.
- `runACPIngestPlannerExecutors`:
  - Planner: `resolvedProvider(for: .planner)` → spawn config → session; if a
    modelId is set, send `session/set_model` after session creation (existing
    mechanism).
  - Executors: `resolvedProvider(for: .executor)`. Delete `findSonnetModelId`.
    If the executor stage is unassigned, executors use the default provider's
    selected model (no more silent model downgrade).
  - Finalizer: `resolvedProvider(for: .finalizer)`.
  - Connection management: cache one live backend per distinct
    (providerId, modelId) within the run; stages sharing a resolution reuse
    the connection, differing ones spawn their own subprocess. Tear all down
    at run end (including the fallback path).
- Delete `IngestPlan` opus/curator tiering (`IngestPlan.swift`) along with the
  CLI backend; the ACP planner/executor/finalizer path (with its existing
  single-session fallback) is the only ingestion strategy.
- Chat (`ChatView`) keeps using `selectedProvider()` — unchanged behavior.

### Settings UI (Sources/WikiFS)

Replace the **Agent** and **Providers** tabs with one **Agents** tab
(`AgentsSettingsView.swift`), two sections:

**Providers section**
- `List` of providers: enable toggle, label, monospaced command summary,
  "Default" badge; select to edit.
- Editor (sheet or inspector): label, command (single text field parsed with
  shell-style word splitting, matching how Paseo docs render argv), env vars
  (key/value table), API key `SecureField` (Keychain, per-provider id),
  model picker fed from `providerModels[providerId]` with a "Refresh models"
  button that spins up a short-lived ACP session to capture the advertised
  list (reuse the existing model-capture path).
- Toolbar: **+** (menu: Claude / Hermes / OpenCode / Custom…), **−** (delete,
  with confirmation; deleting the default promotes the first enabled entry),
  "Make default".
- Executable status dot per provider via the existing `PathPreflight`
  login-shell resolution.

**Ingestion Stages section**
- Three rows — Planner, Executor, Finalizer — each with:
  - Provider `Picker`: "App default" + enabled providers.
  - Model `Picker` (enabled when a provider is chosen): "Provider default" +
    that provider's captured models.
- Footnote explaining fallback semantics.

The permission-mode picker (currently in the Agent tab) moves to the bottom of
the Agents tab. `WikiFSApp.swift` tab registration updated; old view files
deleted.

## Implementation phases

Each phase compiles and passes tests independently.

1. **Core model** (WikiFSCore): `AgentProvider.environment`, seeds, un-forced
   `normalized()`, `IngestStage`/`StageAssignment`, `resolvedProvider(for:)`,
   pruning, decode-compat tests for old JSON.
2. **Engine** (WikiFSEngine): spawn env plumbing, per-stage resolution in
   `runACPIngestPlannerExecutors`, per-(provider,model) connection cache,
   delete `findSonnetModelId`.
3. **UI** (WikiFS): `AgentsSettingsView` + editor, tab swap in `WikiFSApp`.
4. **Legacy deletion**: `ClaudeCLIBackend`, `AgentCommandConfig`,
   `ACPAgentConfig`, `useACPBackend`, `IngestPlan`, old settings views,
   keyless credential API; migrate/rewrite affected tests (`ACPWiringTests`
   etc.).

## Risks / notes

- hermes and opencode model discovery: both advertise models over ACP, but the
  id formats differ (e.g. opencode uses `provider/model` ids). The model
  picker must treat ids as opaque strings.
- Env vars are stored in plain JSON. Rule: secrets go in the Keychain API-key
  field; env is for non-secret knobs. The editor UI notes this.
- Stage-level provider mixing multiplies subprocess count; the per-resolution
  connection cache keeps it at ≤3 per run.
